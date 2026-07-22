//! User-facing tool-call UX and ask_user handling, split from agent_tools.zig
//! to keep the dispatcher focused and within the repository line limit.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const tools = @import("tools.zig");
const ToolCall = tools.ToolCall;
const ExecResult = tools.ExecResult;
const answerParseError = tools.answerParseError;
const parseAnswerRequest = tools.parseAnswerRequest;
const isMetaName = @import("schema.zig").isMetaName;
const style = &@import("ansi.zig").style;

/// The "user message as a tool" half of the loop: block for a typed reply and
/// return it as the tool result. Only the root agent has stdin.
pub fn askUser(self: *Agent, call: ToolCall) !ExecResult {
    const in = self.in orelse return .{
        .text = "no human is attached — make a reasonable assumption and continue",
        .is_error = true,
    };
    const w = self.out.?;
    const question = if (call.input.object.get("question")) |q| q.string else "(no question)";
    if (main_mod.json_mode) {
        const call_id = if (call.id.len > 0) call.id else blk: {
            const id = try std.fmt.allocPrint(self.arena, "ask_user-{d}", .{self.next_ask_id});
            self.next_ask_id += 1;
            break :blk id;
        };
        try self.emitAskUser(call_id, question, call.input);
        const raw = (try in.takeDelimiter('\n')) orelse return .{ .text = "user ended input without answering", .is_error = true };
        const parsed = std.json.parseFromSliceLeaky(Value, self.arena, std.mem.trim(u8, raw, " \t\r"), .{ .allocate = .alloc_always }) catch return .{
            .text = "invalid answer JSON for ask_user",
            .is_error = true,
        };
        const answer = parseAnswerRequest(parsed, call_id) catch |err| return .{ .text = answerParseError(err), .is_error = true };
        if (answer.cancelled) return .{ .text = "user cancelled the follow-up", .is_error = true };
        return .{ .text = try self.arena.dupe(u8, answer.text), .is_error = false };
    }
    if (!self.argStreamedFully(call)) try w.print("\n❓ {s}\n", .{question});
    if (call.input.object.get("options")) |opts| if (opts == .array) {
        for (opts.array.items, 1..) |opt, n| try w.print("   {d}) {s}\n", .{ n, opt.string });
    };
    try w.writeAll("   your answer › ");
    try w.flush();
    const raw = (try in.takeDelimiter('\n')) orelse return .{ .text = "user ended input without answering", .is_error = true };
    return .{ .text = try self.arena.dupe(u8, std.mem.trim(u8, raw, " \t\r")), .is_error = false };
}

pub fn emitAskUser(self: *Agent, call_id: []const u8, question: []const u8, input: Value) !void {
    const w = self.out orelse return;
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("ask_user");
    try s.objectField("call_id");
    try s.write(call_id);
    try s.objectField("question");
    try s.write(question);
    try s.objectField("input");
    try s.write(input);
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();
}

pub fn sayToolUse(self: *Agent, call: ToolCall) !void {
    if (main_mod.json_mode) {
        if (std.mem.eql(u8, call.name, "ask_user")) return;
        self.emit(.{ .type = "tool_call", .name = call.name, .input = call.input });
        self.emit(.{ .type = "tool_call_started", .name = call.name, .input = call.input });
        return;
    }
    if (self.argStreamedFully(call)) return;
    var aw: Io.Writer.Allocating = .init(self.gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(call.input);
    const full = aw.writer.buffered();
    const shown = if (full.len > 160) full[0..160] else full;
    try self.say("{s}⚙{s} {s}{s} {s}{s}{s}{s}\n", .{
        style.dim,   style.reset, style.accent, call.name, style.dim, shown,
        if (full.len > 160) "…" else "",
        style.reset,
    });
}

/// Compact result feedback for one finished tool call.
pub fn sayToolResult(self: *Agent, name: []const u8, r: ExecResult) void {
    const w = self.out orelse return;
    if (main_mod.json_mode) {
        if (isMetaName(name) and !std.mem.eql(u8, name, "ask_user")) return;
        self.emit(.{ .type = "tool_result", .name = name, .is_error = r.is_error, .text = r.text });
        self.emit(.{ .type = "tool_call_finished", .name = name, .is_error = r.is_error, .ms = r.ms });
        return;
    }
    if (isMetaName(name)) return;
    const all = std.mem.trim(u8, r.text, " \t\r\n");
    var preview = all;
    if (std.mem.indexOfScalar(u8, preview, '\n')) |nl| preview = preview[0..nl];
    preview = std.mem.trim(u8, preview, " \t\r");
    const shown = if (preview.len > 100) preview[0..100] else preview;
    const mark = if (r.cancelled) "⊘" else if (r.is_error) "✗" else "✓";
    const mc = if (r.cancelled) style.yellow else if (r.is_error) style.red else style.green;
    var tbuf: [24]u8 = undefined;
    const timing = if (main_mod.show_timing and r.ms > 0) (std.fmt.bufPrint(&tbuf, " ({d}ms)", .{r.ms}) catch "") else "";
    w.print("  {s}{s}{s}{s}{s}{s} {s}{s}{s}{s}\n", .{
        mc,          mark, style.reset, style.dim, timing, style.reset, style.dim, shown,
        if (shown.len < all.len) "…" else "",
        style.reset,
    }) catch return;
    w.flush() catch return;
}

/// One terminal line closes a parallel group so the UI cannot remain visually
/// stuck on its earlier "running" state after every future has joined.
pub fn sayParallelSummary(self: *Agent, indices: []const usize, results: []const ExecResult) void {
    var completed: usize = 0;
    var failed: usize = 0;
    var cancelled: usize = 0;
    for (indices) |i| {
        if (results[i].cancelled) cancelled += 1 else if (results[i].is_error) failed += 1 else completed += 1;
    }
    if (main_mod.json_mode) return; // each JSON tool_result already carries its terminal text
    self.say("  {s}↯ parallel tools finished: {d} completed, {d} failed, {d} cancelled{s}\n", .{
        style.dim, completed, failed, cancelled, style.reset,
    }) catch {};
}
