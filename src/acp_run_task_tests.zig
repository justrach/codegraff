//! Offline propagation test for the `codegraff/runTask` bridge: a delegated
//! task's context/usage facts must reach the completed ACP
//! `tool_call_update` from a `--json` tool_result line, carrying only the five
//! declared fields — never the task's text or the caller's context.
//!
//! Lives beside acp_stream.zig rather than inside it: that file is already at
//! the 600-line cap, and this exercises its translateEvent boundary.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Value = std.json.Value;
const stream = @import("acp_stream.zig");

/// One `--json` tool_result line carrying a runTask mirror, translated to ACP.
fn translate(a: std.mem.Allocator, wire: []const u8, buf: []u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(Value, a, wire, .{});
    defer parsed.deinit();
    var w: Io.Writer = .fixed(buf);
    var id_buf: [64]u8 = @splat(0);
    var next: u32 = 0;
    _ = try stream.translateEvent(&w, "s1", parsed.value, &id_buf, &next);
    return w.buffered();
}

test "a delegated task's facts reach the ACP tool_call_update, and nothing else does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [8192]u8 = undefined;
    const out = try translate(a, "{\"type\":\"tool_result\",\"id\":\"call-9\",\"name\":\"mcp__codegraff__run_task\"," ++
        "\"is_error\":false,\"text\":\"the task answer\"," ++
        "\"run_task\":{\"context_chars\":40,\"context_used_chars\":7,\"context_summarized\":true," ++
        "\"usage_reported\":false,\"usage_unavailable_reason\":\"no settlement\"}}", &buf);

    try testing.expect(std.mem.indexOf(u8, out, "\"sessionUpdate\":\"tool_call_update\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"toolCallId\":\"call-9\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"completed\"") != null);
    // The five declared facts, verbatim.
    try testing.expect(std.mem.indexOf(u8, out, "\"codegraff/runTask\":{\"context_chars\":40,\"context_used_chars\":7," ++
        "\"context_summarized\":true,\"usage_reported\":false,\"usage_unavailable_reason\":\"no settlement\"}") != null);
    // The answer is the update's content, not smuggled into the metadata.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "the task answer"));
    const meta_at = std.mem.indexOf(u8, out, "\"codegraff/runTask\"").?;
    try testing.expect(std.mem.indexOf(u8, out[meta_at..], "the task answer") == null);
    // No view metadata when the result did not open one.
    try testing.expect(std.mem.indexOf(u8, out, "graff/view") == null);
}

test "an ordinary tool result grows no runTask metadata" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [4096]u8 = undefined;
    const out = try translate(a, "{\"type\":\"tool_result\",\"id\":\"call-1\",\"name\":\"read_file\",\"is_error\":false,\"text\":\"fn main\"}", &buf);
    try testing.expect(std.mem.indexOf(u8, out, "tool_call_update") != null);
    try testing.expect(std.mem.indexOf(u8, out, "codegraff/runTask") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"_meta\"") == null);
}

test "a view and the task facts coexist in one _meta object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [8192]u8 = undefined;
    const hex = "0123456789abcdef0123456789abcdef";
    const out = try translate(a, "{\"type\":\"tool_result\",\"id\":\"call-2\",\"name\":\"mcp__codegraff__run_task\"," ++
        "\"is_error\":false,\"text\":\"[MCP app](/h/.graff/mcp-apps/" ++ hex ++ ".html)\"," ++
        "\"run_task\":{\"context_chars\":5,\"usage_reported\":false,\"usage_unavailable_reason\":\"r\"}}", &buf);
    try testing.expect(std.mem.indexOf(u8, out, "\"graff/view\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"codegraff/runTask\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"_meta\":{\"graff/view\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"context_chars\":5") != null);
}
