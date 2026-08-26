//! ask_user: block the root agent for a human reply (#580).
//!
//! The TUI answer uses the same readline as the main prompt, so Ctrl-V / drop
//! stage images on the agent. Those pixels used to stay in `pending_image`
//! while the tool result was literal `[Image]` placeholders. We leave the
//! queue staged for `vision_queue.flushPending` after the tool result, and
//! promote GUI `@[path]` markers the same way the main prompt does.

const std = @import("std");
const Value = std.json.Value;

const main_mod = @import("main.zig");
const json_inbox = @import("json_inbox.zig");
const Agent = @import("agent.zig").Agent;
const tools_mod = @import("tools.zig");
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const answerParseError = tools_mod.answerParseError;
const parseAnswerRequest = tools_mod.parseAnswerRequest;
const readline = @import("readline.zig");
const protocol_seq = @import("protocol_seq.zig");
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");

/// Block the root agent for an ask_user reply; subagents have no stdin.
pub fn askUser(self: *Agent, call: ToolCall) !ExecResult {
    const in = self.in orelse return .{
        .text = "no human is attached — make a reasonable assumption and continue",
        .is_error = true,
    };
    const w = self.out.?;
    const question = if (tools_mod.json_args.object(call.input)) |o| (tools_mod.json_args.str(o, "question") orelse "(no question)") else "(no question)";
    if (main_mod.json_mode) {
        const call_id = if (call.id.len > 0) call.id else blk: {
            const id = try std.fmt.allocPrint(self.arena, "ask_user-{d}", .{self.next_ask_id});
            self.next_ask_id += 1;
            break :blk id;
        };
        try emitAskUser(self, call_id, question, call.input);
        const raw = (try json_inbox.reply(self.arena, in)) orelse return .{
            .text = "user ended input without answering",
            .is_error = true,
        };
        const parsed = std.json.parseFromSliceLeaky(Value, self.arena, std.mem.trim(u8, raw, " \t\r"), .{ .allocate = .alloc_always }) catch return .{
            .text = "invalid answer JSON for ask_user",
            .is_error = true,
        };
        const answer = parseAnswerRequest(parsed, call_id) catch |err| return .{
            .text = answerParseError(err),
            .is_error = true,
        };
        if (answer.cancelled) return .{ .text = "user cancelled the follow-up", .is_error = true };
        return finishAnswer(self, answer.text);
    }
    // Skip the re-print only when the question streamed live in full.
    if (!self.argStreamedFully(call)) try w.print("\n❓ {s}\n", .{question});
    if (tools_mod.json_args.object(call.input)) |o| if (tools_mod.json_args.arrayOf(o, "options")) |opts| {
        for (opts, 1..) |opt, n| try w.print("   {d}) {s}\n", .{ n, tools_mod.json_args.text(opt) orelse "(non-text option)" });
    };
    // Route the reply through the same full-line editor as the main prompt:
    // cursor editing, bracketed paste, the `@` file picker, and Ctrl-V
    // clipboard images. A bare takeDelimiter here stripped all of that from
    // ask_user. Answers get a scratch history so they never pollute the main
    // prompt's up-arrow recall.
    var answer_history: std.ArrayList([]const u8) = .empty;
    defer answer_history.deinit(self.arena);
    var answer_buf: std.ArrayList(u8) = .empty;
    defer answer_buf.deinit(self.arena);
    const raw = (try readline.readLine(self, in, w, self.arena, &answer_history, &answer_buf, "   your answer › ")) orelse return .{
        .text = "user ended input without answering",
        .is_error = true,
    };
    return finishAnswer(self, std.mem.trim(u8, raw, " \t\r"));
}

fn finishAnswer(self: *Agent, raw: []const u8) !ExecResult {
    const answer = try self.arena.dupe(u8, raw);
    vision.stageGuiImageAttachment(self, answer);
    vision_queue.retainReferenced(self, answer);
    // Pixels stay queued for flushPending after the text tool result. If the
    // reply only has `[Image]` markers and nothing staged, say so instead of
    // letting the model treat placeholders as screenshots.
    const text = if (self.pending_image_len == 0)
        try vision_queue.withUnsupportedNote(self.arena, answer)
    else
        answer;
    return .{ .text = text, .is_error = false };
}

pub fn emitAskUser(self: *Agent, call_id: []const u8, question: []const u8, input: Value) !void {
    const w = self.out orelse return;
    // Same envelope as Agent.emit — hand-rolled only because `input` is a
    // std.json.Value; #330's `seq` must ride this line too or a supervisor
    // would see a hole exactly where it is asked to answer.
    const ev = .{ .type = "ask_user", .call_id = call_id, .question = question, .input = input };
    if (main_mod.json_mode) {
        try protocol_seq.writeEvent(w, ev);
    } else {
        var s: std.json.Stringify = .{ .writer = w };
        try s.write(ev);
    }
    try w.writeByte('\n');
    try w.flush();
}
