//! Non-streaming response parsing: turn a provider's JSON response (or a
//! reassembled SSE stream) into next-turn messages + extracted tool calls,
//! run those tools, and return the turn's final text (or null to loop
//! again). One step* per wire format (Anthropic Messages, OpenAI chat
//! completions, OpenAI Responses — the last lives in agent_request.zig
//! since it shares ResponsesResult/parseResponses); one assemble* per
//! streaming wire format that needs a full body reassembled before the
//! step functions can run on it. Split out of the Agent struct (#123,
//! 600-line goal).

const std = @import("std");
const Value = std.json.Value;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const Agent = agent_mod.Agent;
pub const ToolCall = tools_mod.ToolCall;

const messages_mod = @import("messages.zig");
const util = @import("util.zig");
const eval_control = @import("agent_eval_control.zig");
const codex_chain = @import("codex_chain.zig");
const toolResultMessage = messages_mod.toolResultMessage;
const turn_checkpoint = @import("turn_checkpoint.zig");
const tool_call_args = @import("tool_call_args.zig");
const tool_call_repair = @import("tool_call_repair.zig");
const length = @import("agent_length.zig");

pub fn surfaceUnstreamedText(self: *Agent, text: []const u8) !void {
    if (self.sub or self.streamed_text or text.len == 0) return;
    if (main_mod.json_mode) {
        self.emit(.{ .type = "text", .text = text });
    } else try self.say("{s}\n", .{text});
}

// ssePayload/sseIndex live in agent_stream.zig; reached through the Agent
// struct's member aliases.
const ssePayload = Agent.ssePayload;
const sseIndex = Agent.sseIndex;

/// A RED eval used to END the turn with verifier_hard_stop as its final
/// text — right as a batch boundary, wrong as a turn outcome: the message
/// orders the MODEL to "start a repair turn", but a -p one-shot has no next
/// turn, so the run died at score 0 with the artifact never written (and in
/// the REPL the user had to re-prompt by hand). Grant the repair turn
/// in-loop instead: append the hard-stop as a user steering message and
/// keep stepping. Bounded by max_repair_grants — reset on any green eval in
/// runEval — so a permanently-red eval still terminates; when the budget is
/// spent the caller falls back to the old end-the-turn behavior.
pub fn grantRepairTurn(self: *Agent) !bool {
    if (self.eval_repair_grants >= eval_control.max_repair_grants) return false;
    // A repair turn costs at least a repair call plus a concluding call.
    // Without that headroom in the run budget, granting one just converts
    // the orderly repair-pending turn end into RunBudgetExhausted mid-repair
    // (caught by scripts/test-review-mode.py's max_model_calls=2 gate) —
    // surface the hard stop instead, exactly the pre-grant contract.
    if (self.run_budget) |b| if (!b.canAfford(2)) return false;
    self.eval_repair_grants += 1;
    try self.messages.append(try messages_mod.userNote(self.arena, self.provider.kind, eval_control.verifier_hard_stop));
    return true;
}

/// Consume a Codex `response` object: append its output items to history
/// (verbatim — they're valid Responses input items), surface text, and
/// collect any function calls. Returns final text when no tools were
/// called, else null to loop after running them.
pub fn stepResponses(self: *Agent, response: std.json.ObjectMap) !?[]const u8 {
    // #287/#299: every error.ApiError raised in this file has to leave a cause
    // behind. subagent_run hands agent.last_api_error to the parent's tool
    // result, so a bare `return error.ApiError` reached the parent as the
    // literal string "ApiError" — the opaque failure both issues report.
    const output = response.get("output") orelse {
        try self.sayApiError("api error: codex response had no output field", .{});
        return error.ApiError;
    };
    if (output != .array) {
        try self.sayApiError("api error: codex response output was not an array", .{});
        return error.ApiError;
    }

    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    var final_text: []const u8 = "";

    for (output.array.items) |item| {
        if (item != .object) continue;
        if (@import("agent_async_tools.zig").duplicateItem(self, item)) continue;
        try self.messages.append(item); // valid as next-turn input
        const itype = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (@import("codex_tool_search.zig").isServerSideItem(itype)) {
            continue;
        } else if (std.mem.eql(u8, itype, "message")) {
            if (item.object.get("content")) |c| if (c == .array) {
                for (c.array.items) |block| {
                    if (block != .object) continue;
                    const bt = if (block.object.get("type")) |x| (if (x == .string) x.string else "") else "";
                    if (std.mem.eql(u8, bt, "output_text")) {
                        if (block.object.get("text")) |txt| if (txt == .string) {
                            final_text = txt.string;
                            try surfaceUnstreamedText(self, txt.string);
                        };
                    }
                }
            };
        } else if (std.mem.eql(u8, itype, "function_call")) {
            const name = if (item.object.get("name")) |n| (if (n == .string) n.string else continue) else continue;
            if (@import("xai_hosted.zig").isServerSideCall(itype, name)) continue;
            const call_id = if (item.object.get("call_id")) |c| (if (c == .string) c.string else continue) else continue;
            const args = if (item.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
            const parsed = tool_call_args.parse(self.scratchAlloc(), args); // #124: execution-only tree
            const cut = length.callCut(self.gpa, length.limited(.responses, response), item.object, args);
            try calls.append(self.gpa, .{ .id = call_id, .name = name, .input = parsed.input, .args_ok = parsed.valid and !cut, .cut = cut });
        }
    }
    tool_call_args.repairHistory(self.gpa, self.arena, self.messages.items);
    self.pairContextMeterWithCurrentLocal();

    // Codex WS delta: the server now holds up to here (the output items appended
    // above). The NEXT request sends previous_response_id + only what is appended
    // after this point - the tool results below, and on the following USER turn
    // that turn's prompt, since the chain outlives runTurn now. Only while the WS
    // session lives; codex_chain.record stamps what the anchor is valid for.
    // #194: the watermark and the id it is keyed to must move TOGETHER. Advancing
    // codex_sent_upto while codex_prev_id still points at the PREVIOUS response
    // makes the next delta start after items the server never received, silently
    // dropping them from the conversation. A response carrying no usable id (or a
    // failed dupe) drops the anchor instead; the socket stays and the next request
    // simply re-sends full input.
    if (self.codex_ws != null) {
        const fresh: ?[]const u8 = if (response.get("id")) |idv|
            (if (idv == .string and idv.string.len > 0) self.gpa.dupe(u8, idv.string) catch null else null)
        else
            null;
        if (fresh) |id| {
            if (self.codex_prev_id) |old| self.gpa.free(old);
            self.codex_prev_id = id;
            codex_chain.record(self);
        } else if (self.codex_prev_id) |old| {
            self.gpa.free(old);
            self.codex_prev_id = null;
        }
    }

    if (calls.items.len > 0) {
        const results = try self.runTools(calls.items);
        for (calls.items, results) |call, r| {
            const fco = try toolResultMessage(self.arena, .responses, call.id, r.text, r.is_error);
            try self.messages.append(fco);
        }
        try turn_checkpoint.afterToolBatch(self);
        if (eval_control.shouldStopAfterBatch(calls.items, self.eval_repair_pending)) {
            if (try grantRepairTurn(self)) return null;
            return eval_control.verifier_hard_stop;
        }
        if (self.yielded) |handoff| return handoff;
        if (self.completed) |result| return result;
        return null;
    }
    return final_text;
}

pub fn stepAnthropic(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
    // #287/#299: sayApiError, not say — the text has to survive as
    // last_api_error for the subagent/workflow failure report, not just print.
    const content = root.get("content") orelse {
        try self.sayApiError("api error: response had no content", .{});
        return error.ApiError;
    };
    if (content != .array) {
        try self.sayApiError("api error: malformed content block", .{});
        return error.ApiError;
    }
    const stop_reason = if (root.get("stop_reason")) |s| (if (s == .string) s.string else "") else "";
    // ADR 0219: a safety refusal ends the turn, outside history, never retried.
    if (std.mem.eql(u8, stop_reason, "refusal")) {
        const refusal = @import("claude_refusal.zig");
        const cat = refusal.category(root);
        const line = try refusal.text(self.arena, cat);
        try self.say("{s}\n", .{line});
        if (self.tracer) |tr| tr.note("refusal", cat orelse "unspecified");
        return line;
    }

    const oauth = @import("anthropic_oauth_wire.zig");
    if (oauth.active(self.provider)) {
        const names = try oauth.ToolNames.init(self.scratchAlloc(), self.toolsJson());
        try names.decodeContent(self.arena, content);
    }
    var assistant: std.json.ObjectMap = .empty;
    try assistant.put(self.arena, "role", .{ .string = "assistant" });
    try assistant.put(self.arena, "content", content);
    try self.messages.append(.{ .object = assistant });

    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    var final_text: []const u8 = "";
    for (content.array.items) |*block| { // by pointer: the invalid-input marker is removed in place
        if (block.* != .object) continue;
        const kind = if (block.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (std.mem.eql(u8, kind, "text")) {
            if (block.object.get("text")) |tx| if (tx == .string) {
                final_text = tx.string;
                try surfaceUnstreamedText(self, final_text);
            };
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            const name = if (block.object.get("name")) |n| (if (n == .string) n.string else "") else "";
            if (name.len == 0) continue;
            const id = if (block.object.get("id")) |x| (if (x == .string) x.string else "") else "";
            const why = tool_call_args.takeInvalidMark(&block.object);
            const input = block.object.get("input") orelse Value{ .object = .empty };
            const cut = why == .cut or (length.limited(.anthropic, root) and !block.object.contains("input"));
            if (!block.object.contains("input") or input != .object) try block.object.put(self.arena, "input", .{ .object = .empty });
            try calls.append(self.gpa, .{ .id = id, .name = name, .input = input, .args_ok = why == .none and !cut and input == .object, .cut = cut });
        }
    }
    self.pairContextMeterWithCurrentLocal();

    if (calls.items.len > 0) {
        const results = try self.runTools(calls.items);
        var blocks = std.json.Array.init(self.arena);
        for (calls.items, results) |call, r| {
            const tr = try toolResultMessage(self.arena, .anthropic, call.id, r.text, r.is_error);
            try blocks.append(tr);
        }
        var user_msg: std.json.ObjectMap = .empty;
        try user_msg.put(self.arena, "role", .{ .string = "user" });
        try user_msg.put(self.arena, "content", .{ .array = blocks });
        try self.messages.append(.{ .object = user_msg });
        try turn_checkpoint.afterToolBatch(self);

        if (eval_control.shouldStopAfterBatch(calls.items, self.eval_repair_pending)) {
            if (try grantRepairTurn(self)) return null;
            return eval_control.verifier_hard_stop;
        }
        if (self.yielded) |handoff| return handoff;
        if (self.completed) |result| return result;
        return null; // loop again
    }

    if (std.mem.eql(u8, stop_reason, "pause_turn")) return null;
    if (!std.mem.eql(u8, stop_reason, "end_turn") and !length.limited(.anthropic, root)) try self.say("[stopped: {s}]\n", .{stop_reason});
    return final_text;
}

/// Trailing sampler markers some models leak into chat content (grok-4.6
/// emits `<|eos|>` after strict-schema JSON — caught by graff-evals).
pub const stripEosSuffix = @import("agent_chat_step.zig").stripEosSuffix;
test "stripEosSuffix drops a leaked trailing sampler marker, nothing else" {
    try std.testing.expectEqualStrings("{\"a\":1}", stripEosSuffix("{\"a\":1}<|eos|>"));
    try std.testing.expectEqualStrings("{\"a\":1}", stripEosSuffix("{\"a\":1}<|eos|>\n"));
    try std.testing.expectEqualStrings("done", stripEosSuffix("done"));
    try std.testing.expectEqualStrings("say <|eos|> mid-text", stripEosSuffix("say <|eos|> mid-text"));
}

pub fn stepOpenAI(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
    return @import("agent_chat_step.zig").step(@import("agent_chat_native.zig"), self, root);
}

/// One turn's response, handed to the step function for this wire.
pub fn stepForWire(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
    return switch (self.provider.kind) {
        .anthropic => self.stepAnthropic(root),
        .openai => self.stepOpenAI(root),
        .responses => self.stepResponses(root),
        .interactions => @import("interactions_steps.zig").step(self, root),
    };
}

/// Reassemble a streamed SSE body into the non-streaming response shape
/// the step functions expect. Returns null when the body contains no SSE
/// events (a plain JSON body — error envelope, or a provider that
/// ignored `stream`); the caller falls back to regular parsing.
pub fn assembleStream(self: *Agent, body: []const u8) !?std.json.ObjectMap {
    return switch (self.provider.kind) {
        .anthropic => self.assembleAnthropic(body),
        .openai => self.assembleOpenAI(body),
        .responses => unreachable, // parseResponses owns this path
        .interactions => @import("interactions_stream.zig").assemble(self, body),
    };
}

pub const assembleAnthropic = @import("anthropic_assemble.zig").assembleAnthropic;

const chat_tool_calls = @import("chat_tool_calls.zig");
const sse_error = @import("sse_error_event.zig");

pub fn assembleOpenAI(self: *Agent, body: []const u8) !?std.json.ObjectMap {
    const result_arena = self.messageMutationAlloc();
    var content: std.ArrayList(u8) = .empty;
    var reasoning_content: std.ArrayList(u8) = .empty;
    var reasoning: std.ArrayList(u8) = .empty;
    var calls: chat_tool_calls.Calls = .{};
    var role: []const u8 = "assistant";
    var finish: ?Value = null;
    var usage: ?Value = null;
    var message_id: []const u8 = "";
    var thought_signature: []const u8 = "";
    var extra_content: ?Value = null;
    var saw_chunk = false;
    var saw_done = false; // `data: [DONE]`: the stream ended on purpose even without a finish_reason
    var named_error = false; // the data lines follow an `event: error` name
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const payload = ssePayload(raw_line) orelse {
            saw_done = saw_done or std.mem.eql(u8, std.mem.trim(u8, raw_line, " \r"), "data: [DONE]");
            named_error = sse_error.namesError(raw_line, named_error);
            continue;
        };
        const v = std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), payload, .{ .allocate = .alloc_always }) catch continue; // #124: per-event parse tree is transient (deltas are appendSlice'd into session accumulators)
        if (v != .object) continue;
        // Error-only SSE (`event: error` / `data: {"error":…}`) has no
        // choices chunk. Hand the envelope back so request() reports it
        // instead of falling through to the truncated-body retry (#748).
        if (try sse_error.envelope(result_arena, v.object, named_error)) |env| return env;
        named_error = false;
        // The final usage chunk (stream_options.include_usage) may have
        // an empty choices array.
        if (v.object.get("usage")) |u| if (u == .object) {
            usage = u;
            saw_chunk = true;
        };
        const choices = v.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const c0 = choices.array.items[0];
        if (c0 != .object) continue;
        saw_chunk = true;
        if (c0.object.get("finish_reason")) |fr| if (fr == .string) {
            finish = fr;
        };
        if (v.object.get("id")) |xid| if (xid == .string and std.mem.startsWith(u8, xid.string, "v1_")) {
            message_id = xid.string;
        };
        if (c0.object.get("message")) |msg| if (msg == .object) {
            if (msg.object.get("id")) |xid| {
                if (xid == .string and std.mem.startsWith(u8, xid.string, "v1_")) message_id = xid.string;
            }
            if (msg.object.get("thought_signature")) |ts| {
                if (ts == .string and ts.string.len > 0) thought_signature = ts.string;
            }
            if (msg.object.get("extra_content")) |ec| extra_content = ec;
        };
        const d = c0.object.get("delta") orelse continue;
        if (d != .object) continue;
        if (d.object.get("role")) |x| if (x == .string) {
            role = x.string;
        };
        if (d.object.get("id")) |xid| {
            if (xid == .string and std.mem.startsWith(u8, xid.string, "v1_")) message_id = xid.string;
        }
        if (d.object.get("thought_signature")) |ts| {
            if (ts == .string and ts.string.len > 0) thought_signature = ts.string;
        }
        if (d.object.get("extra_content")) |ec| extra_content = ec;
        if (d.object.get("content")) |x| if (x == .string) try content.appendSlice(result_arena, x.string);
        if (d.object.get("reasoning_content")) |x| if (x == .string) try reasoning_content.appendSlice(result_arena, x.string);
        if (d.object.get("reasoning")) |x| if (x == .string) try reasoning.appendSlice(result_arena, x.string);
        if (d.object.get("tool_calls")) |tcs| if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const acc = try calls.forFragment(result_arena, tc);
                if (tc.object.get("thought_signature")) |x| if (x == .string and x.string.len > 0) {
                    acc.thought_signature = x.string;
                };
                if (tc.object.get("extra_content")) |ec| {
                    acc.extra_content = ec;
                    extra_content = extra_content orelse ec;
                }
                if (tc.object.get("function")) |f| if (f == .object) {
                    if (f.object.get("name")) |x| if (x == .string and x.string.len > 0) {
                        acc.acceptName(x.string);
                    };
                    if (f.object.get("arguments")) |x| if (x == .string) try acc.args.appendSlice(result_arena, x.string);
                };
            }
        };
    }
    if (!saw_chunk) return null;
    const stop: ?[]const u8 = if (finish) |f| (if (f == .string) f.string else null) else if (saw_done) "stop" else null;
    calls.markCut(tool_call_args.responseCut(stop)); // #1218

    var message: std.json.ObjectMap = .empty;
    try message.put(result_arena, "role", .{ .string = try result_arena.dupe(u8, role) }); // #124: role slices the scratch parse tree; dupe so it survives the per-request scratch reset
    if (message_id.len > 0) try message.put(result_arena, "id", .{ .string = try result_arena.dupe(u8, message_id) });
    if (thought_signature.len > 0) try message.put(result_arena, "thought_signature", .{ .string = try result_arena.dupe(u8, thought_signature) });
    // #124: extra_content slices the per-request SCRATCH parse tree, which is
    // reset before the next request — storing it raw left the session holding
    // freed memory (sanitizeValueUtf8 then recursed through garbage until the
    // stack blew). Deep-copy it into the message arena like every other field.
    if (extra_content) |ec| try message.put(result_arena, "extra_content", try util.dupeJsonValue(result_arena, ec));
    try message.put(result_arena, "content", if (content.items.len > 0) Value{ .string = content.items } else .null);
    if (reasoning_content.items.len > 0) try message.put(result_arena, "reasoning_content", .{ .string = reasoning_content.items });
    if (reasoning.items.len > 0) try message.put(result_arena, "reasoning", .{ .string = reasoning.items });
    if (calls.items.items.len > 0) {
        var tcs = std.json.Array.init(result_arena);
        for (calls.items.items) |c| {
            if (c.id.len == 0 and c.name.len == 0) continue;
            var function: std.json.ObjectMap = .empty;
            try function.put(result_arena, "name", .{ .string = try result_arena.dupe(u8, c.name) }); // #124: dupe off the scratch parse tree
            try function.put(result_arena, "arguments", .{ .string = c.arguments() });
            var tc: std.json.ObjectMap = .empty;
            try tc.put(result_arena, "id", .{ .string = try result_arena.dupe(u8, c.id) }); // #124: dupe off the scratch parse tree
            try tc.put(result_arena, "type", .{ .string = "function" });
            try tc.put(result_arena, "function", .{ .object = function });
            const call_sig = if (c.thought_signature.len > 0) c.thought_signature else thought_signature;
            if (call_sig.len > 0) try tc.put(result_arena, "thought_signature", .{ .string = try result_arena.dupe(u8, call_sig) });
            if (c.extra_content) |ec| try tc.put(result_arena, "extra_content", try util.dupeJsonValue(result_arena, ec));
            if (c.cut) try tool_call_args.markChatCut(result_arena, &tc);
            try tcs.append(.{ .object = tc });
        }
        if (tcs.items.len > 0) try message.put(result_arena, "tool_calls", .{ .array = tcs });
    }
    var choice: std.json.ObjectMap = .empty;
    try choice.put(result_arena, "message", .{ .object = message });
    try choice.put(result_arena, "finish_reason", finish orelse Value{ .string = "stop" });
    var choices = std.json.Array.init(result_arena);
    try choices.append(.{ .object = choice });
    var r: std.json.ObjectMap = .empty;
    try r.put(result_arena, "choices", .{ .array = choices });
    if (usage) |u| try r.put(result_arena, "usage", u);
    if (finish == null) try r.put(result_arena, "incomplete", .{ .bool = true });
    return r;
}

test {
    _ = @import("agent_steps_tests.zig");
    _ = @import("anthropic_assemble.zig");
    _ = @import("sse_error_event.zig");
}
