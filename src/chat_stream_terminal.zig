//! Chat completion recognition shared by HTTP/1 and HTTP/2 SSE readers.
const std = @import("std");

/// Reject common null-marker delta chunks without allocating a JSON tree.
fn stringCandidate(payload: []const u8) bool {
    const key = "\"finish_reason\"";
    var rest = payload;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        rest = rest[at + key.len ..];
        const suffix = std.mem.trimStart(u8, rest, " \t\r\n");
        if (suffix.len == 0 or suffix[0] != ':') continue;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, suffix[1..], " \t\r\n"), "\"")) return true;
    }
    return false;
}

/// Only a structurally valid first choice marks completion. This does not
/// stop the reader: separate usage trailers must still have time to arrive.
pub fn complete(raw_line: []const u8) bool {
    const payload = @import("agent_interrupt.zig").ssePayload(raw_line) orelse return false;
    if (!stringCandidate(payload)) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const choices = parsed.value.object.get("choices") orelse return false;
    if (choices != .array or choices.array.items.len == 0) return false;
    const choice = choices.array.items[0];
    if (choice != .object) return false;
    const reason = choice.object.get("finish_reason") orelse return false;
    return reason == .string and reason.string.len != 0;
}
