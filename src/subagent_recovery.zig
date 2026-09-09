//! Evidence for a parent's summary when a child cannot finish its report.
const std = @import("std");
const util = @import("util.zig");
const Value = std.json.Value;
const A = std.mem.Allocator;
pub const marker = "\n\nPartial work recovered (task failed; claims require verification):\n";
const cap = 8192;

const Evidence = struct {
    a: A,
    text: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    fn add(self: *Evidence, label: []const u8, raw: []const u8) !void {
        const body = std.mem.trim(u8, raw, " \t\r\n");
        if (body.len == 0) return;
        const room = cap -| self.text.items.len;
        if (room <= label.len + 2) {
            self.truncated = true;
            return;
        }
        const head = util.utf8Prefix(body, @min(2048, room - label.len - 2));
        try self.text.appendSlice(self.a, label);
        try self.text.appendSlice(self.a, head);
        try self.text.appendSlice(self.a, "\n\n");
        self.truncated = self.truncated or head.len < body.len;
    }
    fn blocks(self: *Evidence, value: Value, label: []const u8) !void {
        if (value == .string) return self.add(label, value.string);
        if (value != .array) return;
        for (value.array.items) |block| {
            if (block != .object) continue;
            const ty = str(block, "type");
            if (std.mem.eql(u8, ty, "text") or std.mem.eql(u8, ty, "output_text")) try self.add(label, str(block, "text"));
        }
    }
    fn message(self: *Evidence, msg: Value) !void {
        if (msg != .object) return;
        const ty = str(msg, "type");
        const role = str(msg, "role");
        if (std.mem.eql(u8, ty, "function_call_output")) {
            if (msg.object.get("output")) |output| try self.blocks(output, "Tool result: ");
        } else if (std.mem.eql(u8, role, "assistant") or std.mem.eql(u8, ty, "model_output")) {
            if (msg.object.get("content")) |content| try self.blocks(content, "Reported finding: ");
        } else if (std.mem.eql(u8, role, "tool")) {
            if (msg.object.get("content")) |content| try self.blocks(content, "Tool result: ");
        } else if (std.mem.eql(u8, role, "user")) {
            const content = msg.object.get("content") orelse return;
            if (content != .array) return;
            for (content.array.items) |block| {
                if (!std.mem.eql(u8, str(block, "type"), "tool_result")) continue;
                if (block.object.get("content")) |result| try self.blocks(result, "Tool result: ");
            }
        }
    }
};
fn str(value: Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const field = value.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

/// No extra model call: return evidence, never fabricate a successful summary.
pub fn append(a: A, failure: []const u8, history: []const Value, partial: []const u8) ![]u8 {
    var evidence: Evidence = .{ .a = a };
    defer evidence.text.deinit(a);
    try evidence.add("Interrupted response: ", partial);
    // Favor recent evidence when the child has a long history.
    var i = history.len;
    while (i > 0) {
        i -= 1;
        try evidence.message(history[i]);
    }
    if (evidence.text.items.len == 0) return a.dupe(u8, failure);
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}\nSummarize useful findings, cite observed tool evidence, and state what remains unfinished. Do not infer success from partial output.", .{ failure, marker, evidence.text.items, if (evidence.truncated) "[Partial evidence truncated.]\n" else "" });
}

/// Workflow failure excerpts retain a small evidence section for synthesis.
pub fn excerpt(a: A, failure: []const u8, cause: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, failure, marker) orelse return cause;
    return std.fmt.allocPrint(a, "{s}{s}", .{ cause, util.utf8Prefix(failure[start..], 2048) }) catch cause;
}

test "failed subagent recovery preserves findings and tool evidence but excludes instructions and reasoning" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Value, a,
        \\[{"role":"user","content":"private task"},{"role":"assistant","content":[{"type":"thinking","text":"hidden reasoning"},{"type":"text","text":"Found the faulty branch"}]},{"type":"function_call_output","output":"check passed"},{"role":"tool","content":"file updated"},{"role":"user","content":[{"type":"tool_result","content":"test failed"}]}]
    , .{});
    defer parsed.deinit();
    const report = try append(a, "transport failure", parsed.value.array.items, "Still checking");
    defer a.free(report);
    for ([_][]const u8{ "transport failure", "Found the faulty branch", "check passed", "file updated", "test failed", "Still checking", "task failed" }) |text| try std.testing.expect(std.mem.indexOf(u8, report, text) != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "private task") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "hidden reasoning") == null);
}

test "failed subagent recovery leaves empty evidence honest" {
    const a = std.testing.allocator;
    const report = try append(a, "authentication failed", &.{}, " \n\t");
    defer a.free(report);
    try std.testing.expectEqualStrings("authentication failed", report);
}

test "failed subagent recovery caps evidence and retains it in workflow excerpts" {
    const a = std.testing.allocator;
    const raw = try a.alloc(u8, 20000);
    defer a.free(raw);
    @memset(raw, 'x');
    const report = try append(a, "transport failure", &.{}, raw);
    defer a.free(report);
    try std.testing.expect(report.len < 9000);
    try std.testing.expect(std.mem.indexOf(u8, report, "truncated") != null);
    const short = excerpt(a, report, "transport failure");
    defer a.free(short);
    try std.testing.expect(short.len <= 2065);
    try std.testing.expect(std.mem.indexOf(u8, short, "task failed") != null);
}
