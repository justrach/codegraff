//! #1639: reconnecting a response stream that died before its terminal event.
//!
//! A stall (no bytes for the between-lines budget) and a drop (the peer closed
//! or reset the connection) each re-send the whole request on a fresh stream.
//! They get separate budgets: a drop says nothing about the model, and a link
//! that kills long-lived streams intermittently would otherwise end a healthy
//! turn after three cuts. Drops therefore get more attempts and a pause that
//! doubles, so a flapping connection has time to recover.
//!
//! Whichever budget runs out, the turn keeps its partial reply tagged with why
//! it ended — the same row on the REPL and over ACP.

const std = @import("std");

pub const max_stall_retries: usize = 2;
pub const max_drop_retries: usize = 5;

const base_backoff_ms: u64 = 750;
const max_backoff_ms: u64 = 8_000;

/// Pause before reconnect `attempt` (1-based, counted per kind). Stalls keep
/// the flat pause; drops double it per attempt up to `max_backoff_ms`.
pub fn backoffMs(stalled: bool, attempt: usize) u64 {
    if (stalled or attempt <= 1) return base_backoff_ms;
    const shift: u6 = @intCast(@min(attempt - 1, 4));
    return @min(base_backoff_ms << shift, max_backoff_ms);
}

pub fn maxRetries(stalled: bool) usize {
    return if (stalled) max_stall_retries else max_drop_retries;
}

/// The assistant row for a turn the transport ended: the partial reply (if
/// any), then a marker saying it was cut short and why — never a user cancel.
pub fn endedEarlyText(arena: std.mem.Allocator, partial_raw: []const u8, stalled: bool) ![]const u8 {
    const marker = if (stalled)
        "[response ended early: stream stalled]"
    else
        "[response ended early: connection dropped]";
    const partial = std.mem.trim(u8, partial_raw, " \t\r\n");
    if (partial.len == 0) return marker;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ partial, marker });
}

test "drops get a larger, growing reconnect budget than stalls" {
    try std.testing.expect(max_drop_retries > max_stall_retries);
    try std.testing.expectEqual(@as(u64, 750), backoffMs(true, 1));
    try std.testing.expectEqual(@as(u64, 750), backoffMs(true, 2));
    try std.testing.expectEqual(@as(u64, 750), backoffMs(false, 1));
    try std.testing.expectEqual(@as(u64, 1500), backoffMs(false, 2));
    try std.testing.expectEqual(@as(u64, 3000), backoffMs(false, 3));
    try std.testing.expectEqual(@as(u64, 6000), backoffMs(false, 4));
    try std.testing.expectEqual(@as(u64, 8000), backoffMs(false, 5));
    try std.testing.expectEqual(@as(u64, 8000), backoffMs(false, 50));
}

test "a transport-ended turn keeps its partial and says why it ended" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "half a reply\n\n[response ended early: connection dropped]",
        try endedEarlyText(arena, "  half a reply \n", false),
    );
    try std.testing.expectEqualStrings(
        "[response ended early: stream stalled]",
        try endedEarlyText(arena, " \n", true),
    );
}
