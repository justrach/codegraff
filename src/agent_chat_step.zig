//! Shared chat-completions step for the native Agent and capability-backed hosts.
//! Host adapters own I/O, repair policy, checkpointing and surface events; message
//! replay, executable-call parsing and the tool/continue decision stay here.
const std = @import("std");
const ToolCall = @import("tools.zig").ToolCall;
const tool_call_args = @import("tool_call_args.zig");
const tool_call_repair = @import("tool_call_repair.zig");

pub fn limited(root: std.json.ObjectMap) bool {
    const choices = root.get("choices") orelse return false;
    if (choices != .array or choices.array.items.len == 0 or choices.array.items[0] != .object) return false;
    const finish = choices.array.items[0].object.get("finish_reason") orelse return false;
    return finish == .string and std.mem.eql(u8, finish.string, "length");
}

fn callCut(gpa: std.mem.Allocator, response_limited: bool, object: std.json.ObjectMap, raw: []const u8) bool {
    const status = object.get("status");
    return (if (status) |v| v == .string and std.mem.eql(u8, v.string, "incomplete") else false) or
        (response_limited and !tool_call_args.isObjectString(gpa, raw));
}

pub fn stripEosSuffix(text: []const u8) []const u8 {
    var t = std.mem.trimEnd(u8, text, " \t\r\n");
    for ([_][]const u8{ "<|eos|>", "<|eot|>", "<|endoftext|>" }) |marker| {
        if (std.mem.endsWith(u8, t, marker)) {
            t = std.mem.trimEnd(u8, t[0 .. t.len - marker.len], " \t\r\n");
            break;
        }
    }
    return t;
}

pub fn step(comptime Host: type, self: anytype, root: std.json.ObjectMap) !?[]const u8 {
    const choices = root.get("choices");
    // #287/#299: same as the anthropic step — the parent only ever sees what
    // sayApiError records, so these three shapes must name themselves.
    if (choices == null or choices.? != .array or choices.?.array.items.len == 0 or choices.?.array.items[0] != .object) {
        try Host.apiError(self, "api error: response had no choices");
        return error.ApiError;
    }
    const choice = choices.?.array.items[0].object;
    var message = choice.get("message") orelse {
        try Host.apiError(self, "api error: choice had no message");
        return error.ApiError;
    };
    try Host.repair(self, &message, limited(root));
    const msg_obj = (if (message == .object) message.object else null) orelse {
        try Host.apiError(self, "api error: choice message was not an object");
        return error.ApiError;
    };
    // A length stop may spend its entire budget reasoning. Chat rejects
    // replaying an assistant with neither content nor tool calls (#1646).
    // Keep real partial answers and tool-call reasoning verbatim; only this
    // empty reply stays out of history, including on budget/cancel exits.
    const has_content = if (msg_obj.get("content")) |c| switch (c) {
        .string => std.mem.trim(u8, c.string, " \t\r\n").len > 0,
        .array => c.array.items.len > 0,
        else => false,
    } else false;
    const has_calls = if (msg_obj.get("tool_calls")) |t| t == .array and t.array.items.len > 0 else false;
    if (limited(root) and !has_content and !has_calls) {
        self.pairContextMeterWithCurrentLocal();
        return "";
    }
    try self.messages.append(message); // echo verbatim (content may be null)

    var final_text: []const u8 = "";
    if (msg_obj.get("content")) |c| if (c == .string and c.string.len > 0) {
        // grok-4.6 structured outputs (response_format) leak a literal
        // sampler end marker after the JSON on the chat wire (#502) — a
        // trailing `<|eos|>` is never legitimate answer text.
        final_text = stripEosSuffix(c.string);
        try Host.surfaceText(self, final_text);
    };

    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    if (msg_obj.get("tool_calls")) |tcs| if (tcs == .array) {
        for (tcs.array.items) |*tc| { // by pointer: the cut marker is removed in place
            if (tc.* != .object) continue;
            const why = tool_call_args.takeInvalidMark(&tc.object);
            const function = tc.object.get("function") orelse continue;
            if (function != .object) continue;
            const args_str = if (function.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
            const parsed = tool_call_args.parse(self.scratchAlloc(), args_str); // #124: execution-only tree
            const name = if (function.object.get("name")) |n| (if (n == .string) n.string else "") else "";
            if (name.len == 0) continue; // can't dispatch a nameless call
            const id = if (tc.object.get("id")) |x| (if (x == .string) x.string else "") else "";
            const cut = why == .cut or callCut(self.gpa, limited(root), tc.object, args_str);
            try calls.append(self.gpa, .{ .id = id, .name = name, .input = parsed.input, .args_ok = parsed.valid and why == .none and !cut, .cut = cut });
        }
    };
    tool_call_args.repairMessage(self.gpa, self.arena, &self.messages.items[self.messages.items.len - 1]);
    self.pairContextMeterWithCurrentLocal();

    if (calls.items.len > 0) {
        const results = try self.runTools(calls.items);
        for (calls.items, results) |call, r| {
            const tool_msg = try @import("chat_message.zig").toolResult(self.arena, call.id, r.text, r.is_error);
            try self.messages.append(tool_msg);
        }
        // Judged before the checkpoint, which may append queued images.
        const stuck = tool_call_repair.brokenCallLoop(self.messages.items);
        return Host.afterTools(self, calls.items, stuck);
    }

    // finish_reason is optional on raw provider JSON — some gateways omit it,
    // and the non-streaming subagent path runs stepOpenAI on that raw JSON
    // (the reassembled stream always fills it in, but a subagent/plain body may
    // not). An unconditional `.?` here panicked the whole harness on that input;
    // null-guard it like every other field read in this file (#134 audit P0).
    if (choice.get("finish_reason")) |finish| {
        if (finish == .string and !std.mem.eql(u8, finish.string, "stop") and !limited(root)) try Host.stopped(self, finish.string);
    }
    return final_text;
}
