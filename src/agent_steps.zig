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
const ToolCall = tools_mod.ToolCall;

const messages_mod = @import("messages.zig");
const util = @import("util.zig");
const eval_control = @import("agent_eval_control.zig");
const codex_chain = @import("codex_chain.zig");
const toolResultMessage = messages_mod.toolResultMessage;

fn surfaceUnstreamedText(self: *Agent, text: []const u8) !void {
    if (self.sub or self.streamed_text or text.len == 0) return;
    if (main_mod.json_mode) {
        self.emit(.{ .type = "text", .text = text });
    } else try self.say("{s}\n", .{text});
}

// ssePayload/sseIndex live in agent_stream.zig; reached through the Agent
// struct's member aliases.
const ssePayload = Agent.ssePayload;
const sseIndex = Agent.sseIndex;

/// Consume a Codex `response` object: append its output items to history
/// (verbatim — they're valid Responses input items), surface text, and
/// collect any function calls. Returns final text when no tools were
/// called, else null to loop after running them.
pub fn stepResponses(self: *Agent, response: std.json.ObjectMap) !?[]const u8 {
    const output = response.get("output") orelse return error.ApiError;
    if (output != .array) return error.ApiError;

    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    var final_text: []const u8 = "";

    for (output.array.items) |item| {
        if (item != .object) continue;
        try self.messages.append(item); // valid as next-turn input
        const itype = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (std.mem.eql(u8, itype, "message")) {
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
            const call_id = if (item.object.get("call_id")) |c| (if (c == .string) c.string else continue) else continue;
            const args = if (item.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
            const input: Value = if (args.len == 0)
                .{ .object = .empty }
            else
                std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), args, .{ .allocate = .alloc_always }) catch .{ .object = .empty }; // #124: execution-only, same contract as the openai site below
            try calls.append(self.gpa, .{ .id = call_id, .name = name, .input = input });
        }
    }
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
        if (eval_control.shouldStopAfterBatch(calls.items, self.eval_repair_pending)) return eval_control.verifier_hard_stop;
        if (self.completed) |result| return result;
        return null;
    }
    return final_text;
}

pub fn stepAnthropic(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
    const content = root.get("content") orelse {
        try self.say("[api error: response had no content]\n", .{});
        return error.ApiError;
    };
    if (content != .array) {
        try self.say("[api error: malformed content block]\n", .{});
        return error.ApiError;
    }
    const stop_reason = if (root.get("stop_reason")) |s| (if (s == .string) s.string else "") else "";

    var assistant: std.json.ObjectMap = .empty;
    try assistant.put(self.arena, "role", .{ .string = "assistant" });
    try assistant.put(self.arena, "content", content);
    try self.messages.append(.{ .object = assistant });

    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    var final_text: []const u8 = "";
    for (content.array.items) |block| {
        if (block != .object) continue;
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
            const input = block.object.get("input") orelse Value{ .object = .empty };
            try calls.append(self.gpa, .{ .id = id, .name = name, .input = input });
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

        if (eval_control.shouldStopAfterBatch(calls.items, self.eval_repair_pending)) return eval_control.verifier_hard_stop;
        if (self.completed) |result| return result;
        return null; // loop again
    }

    if (std.mem.eql(u8, stop_reason, "pause_turn")) return null;
    if (!std.mem.eql(u8, stop_reason, "end_turn")) try self.say("[stopped: {s}]\n", .{stop_reason});
    return final_text;
}

pub fn stepOpenAI(self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
    const choices = root.get("choices");
    if (choices == null or choices.? != .array or choices.?.array.items.len == 0 or choices.?.array.items[0] != .object) {
        try self.say("[api error: response had no choices]\n", .{});
        return error.ApiError;
    }
    const choice = choices.?.array.items[0].object;
    const message = choice.get("message") orelse {
        try self.say("[api error: choice had no message]\n", .{});
        return error.ApiError;
    };
    const msg_obj = tools_mod.json_args.object(message) orelse {
        try self.say("[api error: choice message was not an object]\n", .{});
        return error.ApiError;
    };
    try self.messages.append(message); // echo verbatim (content may be null)

    var final_text: []const u8 = "";
    if (msg_obj.get("content")) |c| if (c == .string and c.string.len > 0) {
        final_text = c.string;
        try surfaceUnstreamedText(self, c.string);
    };

    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    if (msg_obj.get("tool_calls")) |tcs| if (tcs == .array) {
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            const function = tc.object.get("function") orelse continue;
            if (function != .object) continue;
            const args_str = if (function.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
            const input: Value = if (args_str.len == 0)
                .{ .object = .empty }
            else
                (std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), args_str, .{ .allocate = .alloc_always }) catch .{ .object = .empty }); // #124: execution-only — every consumer (runTools, gate prompts, emits) finishes before the next request()'s scratch reset; the history message carries the arguments STRING, not this tree
            const name = if (function.object.get("name")) |n| (if (n == .string) n.string else "") else "";
            if (name.len == 0) continue; // can't dispatch a nameless call
            const id = if (tc.object.get("id")) |x| (if (x == .string) x.string else "") else "";
            try calls.append(self.gpa, .{ .id = id, .name = name, .input = input });
        }
    };
    self.pairContextMeterWithCurrentLocal();

    if (calls.items.len > 0) {
        const results = try self.runTools(calls.items);
        for (calls.items, results) |call, r| {
            const tool_msg = try toolResultMessage(self.arena, .openai, call.id, r.text, r.is_error);
            try self.messages.append(tool_msg);
        }
        if (eval_control.shouldStopAfterBatch(calls.items, self.eval_repair_pending)) return eval_control.verifier_hard_stop;
        if (self.completed) |result| return result;
        return null;
    }

    // finish_reason is optional on raw provider JSON — some gateways omit it,
    // and the non-streaming subagent path runs stepOpenAI on that raw JSON
    // (the reassembled stream always fills it in, but a subagent/plain body may
    // not). An unconditional `.?` here panicked the whole harness on that input;
    // null-guard it like every other field read in this file (#134 audit P0).
    if (choice.get("finish_reason")) |finish| {
        if (finish == .string and !std.mem.eql(u8, finish.string, "stop")) try self.say("[stopped: {s}]\n", .{finish.string});
    }
    return final_text;
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
    };
}

/// One in-flight content block while reassembling an Anthropic stream.
const BlockAcc = struct {
    obj: std.json.ObjectMap = .empty,
    text: std.ArrayList(u8) = .empty,
    json: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
};

/// message_start carries the message skeleton (role, model, input-token
/// usage); content blocks open with content_block_start and accumulate
/// via content_block_delta (text / partial_json / thinking / signature);
/// message_delta carries stop_reason and output-token usage.
pub fn assembleAnthropic(self: *Agent, body: []const u8) !?std.json.ObjectMap {
    // #124 slice 2b: the whole assembly — per-event parse trees, delta
    // accumulators, the stitched message — lives on the per-request scratch
    // arena; the finished message is deep-copied onto the session arena once
    // at return (it becomes the assistant history message, so it must survive
    // the next request's scratch reset). Previously every event's parse tree
    // landed on the session arena for the life of the process.
    const scratch = self.scratchAlloc();
    const result_arena = self.messageMutationAlloc();
    var root: ?std.json.ObjectMap = null;
    var blocks: std.ArrayList(BlockAcc) = .empty;
    var stop_reason: ?Value = null;
    var usage_delta: ?Value = null;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const payload = ssePayload(raw_line) orelse continue;
        const v = std.json.parseFromSliceLeaky(Value, scratch, payload, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        const t = v.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "message_start")) {
            if (v.object.get("message")) |m| if (m == .object) {
                root = m.object;
            };
        } else if (std.mem.eql(u8, t.string, "content_block_start")) {
            const idx = sseIndex(v.object) orelse continue;
            while (blocks.items.len <= idx) try blocks.append(scratch, .{});
            if (v.object.get("content_block")) |cb| if (cb == .object) {
                blocks.items[idx].obj = cb.object;
            };
        } else if (std.mem.eql(u8, t.string, "content_block_delta")) {
            const idx = sseIndex(v.object) orelse continue;
            if (idx >= blocks.items.len) continue;
            const d = v.object.get("delta") orelse continue;
            if (d != .object) continue;
            const b = &blocks.items[idx];
            if (d.object.get("text")) |x| if (x == .string) try b.text.appendSlice(scratch, x.string);
            if (d.object.get("partial_json")) |x| if (x == .string) try b.json.appendSlice(scratch, x.string);
            if (d.object.get("thinking")) |x| if (x == .string) try b.thinking.appendSlice(scratch, x.string);
            if (d.object.get("signature")) |x| if (x == .string) try b.signature.appendSlice(scratch, x.string);
        } else if (std.mem.eql(u8, t.string, "message_delta")) {
            if (v.object.get("delta")) |d| if (d == .object) {
                if (d.object.get("stop_reason")) |sr| if (sr == .string) {
                    stop_reason = sr;
                };
            };
            if (v.object.get("usage")) |u| if (u == .object) {
                usage_delta = u;
            };
        } else if (std.mem.eql(u8, t.string, "error")) {
            // Hand the envelope back as the root: request()'s existing
            // type=="error" check reports it. Detached from scratch — the
            // rebuild loop can reset the scratch arena before the message
            // is done being read.
            return (try util.dupeJsonValue(result_arena, v)).object;
        }
    }
    var r = root orelse return null;
    var content = std.json.Array.init(scratch);
    for (blocks.items) |*b| {
        if (b.obj.get("type") == null) continue; // never started
        if (b.text.items.len > 0) try b.obj.put(scratch, "text", .{ .string = b.text.items });
        if (b.thinking.items.len > 0) try b.obj.put(scratch, "thinking", .{ .string = b.thinking.items });
        if (b.signature.items.len > 0) try b.obj.put(scratch, "signature", .{ .string = b.signature.items });
        if (b.json.items.len > 0) {
            const input = std.json.parseFromSliceLeaky(Value, scratch, b.json.items, .{ .allocate = .alloc_always }) catch Value{ .object = .empty };
            try b.obj.put(scratch, "input", input);
        }
        try content.append(.{ .object = b.obj });
    }
    try r.put(scratch, "content", .{ .array = content });
    try r.put(scratch, "stop_reason", stop_reason orelse Value{ .string = "end_turn" });
    if (stop_reason == null) try r.put(scratch, "incomplete", .{ .bool = true });
    if (usage_delta) |ud| {
        var usage: std.json.ObjectMap = .empty;
        if (r.get("usage")) |base| if (base == .object) {
            var e = base.object.iterator();
            while (e.next()) |kv| try usage.put(scratch, kv.key_ptr.*, kv.value_ptr.*);
        };
        var e = ud.object.iterator();
        while (e.next()) |kv| try usage.put(scratch, kv.key_ptr.*, kv.value_ptr.*);
        try r.put(scratch, "usage", .{ .object = usage });
    }
    return (try util.dupeJsonValue(result_arena, .{ .object = r })).object;
}

/// One in-flight tool call while reassembling an OpenAI chat stream;
/// id and function.name arrive on the first fragment, arguments
/// accumulate across fragments keyed by index.
const CallAcc = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
};

pub fn assembleOpenAI(self: *Agent, body: []const u8) !?std.json.ObjectMap {
    const result_arena = self.messageMutationAlloc();
    var content: std.ArrayList(u8) = .empty;
    var reasoning_content: std.ArrayList(u8) = .empty;
    var reasoning: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(CallAcc) = .empty;
    var role: []const u8 = "assistant";
    var finish: ?Value = null;
    var usage: ?Value = null;
    var saw_chunk = false;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const payload = ssePayload(raw_line) orelse continue;
        const v = std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), payload, .{ .allocate = .alloc_always }) catch continue; // #124: per-event parse tree is transient (deltas are appendSlice'd into session accumulators)
        if (v != .object) continue;
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
        const d = c0.object.get("delta") orelse continue;
        if (d != .object) continue;
        if (d.object.get("role")) |x| if (x == .string) {
            role = x.string;
        };
        if (d.object.get("content")) |x| if (x == .string) try content.appendSlice(result_arena, x.string);
        if (d.object.get("reasoning_content")) |x| if (x == .string) try reasoning_content.appendSlice(result_arena, x.string);
        if (d.object.get("reasoning")) |x| if (x == .string) try reasoning.appendSlice(result_arena, x.string);
        if (d.object.get("tool_calls")) |tcs| if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const idx: usize = blk: {
                    if (tc.object.get("index")) |ix| if (ix == .integer and ix.integer >= 0) break :blk @intCast(ix.integer);
                    // No index: a fresh id opens a new call, otherwise
                    // the fragment continues the latest one.
                    break :blk if (tc.object.get("id") != null or calls.items.len == 0) calls.items.len else calls.items.len - 1;
                };
                while (calls.items.len <= idx) try calls.append(result_arena, .{});
                const acc = &calls.items[idx];
                if (tc.object.get("id")) |x| if (x == .string and x.string.len > 0) {
                    acc.id = x.string;
                };
                if (tc.object.get("function")) |f| if (f == .object) {
                    if (f.object.get("name")) |x| if (x == .string and x.string.len > 0) {
                        acc.name = x.string;
                    };
                    if (f.object.get("arguments")) |x| if (x == .string) try acc.args.appendSlice(result_arena, x.string);
                };
            }
        };
    }
    if (!saw_chunk) return null;

    var message: std.json.ObjectMap = .empty;
    try message.put(result_arena, "role", .{ .string = try result_arena.dupe(u8, role) }); // #124: role slices the scratch parse tree; dupe so it survives the per-request scratch reset
    try message.put(result_arena, "content", if (content.items.len > 0) Value{ .string = content.items } else .null);
    if (reasoning_content.items.len > 0) try message.put(result_arena, "reasoning_content", .{ .string = reasoning_content.items });
    if (reasoning.items.len > 0) try message.put(result_arena, "reasoning", .{ .string = reasoning.items });
    if (calls.items.len > 0) {
        var tcs = std.json.Array.init(result_arena);
        for (calls.items) |c| {
            if (c.id.len == 0 and c.name.len == 0) continue;
            var function: std.json.ObjectMap = .empty;
            try function.put(result_arena, "name", .{ .string = try result_arena.dupe(u8, c.name) }); // #124: dupe off the scratch parse tree
            try function.put(result_arena, "arguments", .{ .string = c.args.items });
            var tc: std.json.ObjectMap = .empty;
            try tc.put(result_arena, "id", .{ .string = try result_arena.dupe(u8, c.id) }); // #124: dupe off the scratch parse tree
            try tc.put(result_arena, "type", .{ .string = "function" });
            try tc.put(result_arena, "function", .{ .object = function });
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

test "assembleOpenAI preserves streamed reasoning history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };

    const root = (try agent.assembleOpenAI(
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"deep\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning\":\"alt \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning\":\"path\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n" ++
            "data: [DONE]\n",
    )).?;
    const choices = root.get("choices").?;
    const message = choices.array.items[0].object.get("message").?.object;
    try std.testing.expectEqualStrings("assistant", message.get("role").?.string);
    try std.testing.expectEqualStrings("done", message.get("content").?.string);
    try std.testing.expectEqualStrings("think deep", message.get("reasoning_content").?.string);
    try std.testing.expectEqualStrings("alt path", message.get("reasoning").?.string);
}
