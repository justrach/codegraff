//! Chat tool-result construction shared by the native and capability-backed core.
const std = @import("std");

pub fn toolResult(arena: std.mem.Allocator, call_id: []const u8, raw: []const u8, is_error: bool) !std.json.Value {
    const messages = @import("messages.zig");
    const text = if (raw.len == 0) messages.empty_result else messages.sanitizeUtf8(arena, raw);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = "tool" });
    try obj.put(arena, "tool_call_id", .{ .string = call_id });
    const body = if (is_error) try std.fmt.allocPrint(arena, "[error] {s}", .{text}) else text;
    try obj.put(arena, "content", .{ .string = body });
    return .{ .object = obj };
}
