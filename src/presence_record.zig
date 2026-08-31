//! On-disk presence record: JSON shape, format, parse (#469 / #700).
//!
//! Older/newer graffs tolerate each other via ignore_unknown_fields both
//! ways (a superset write parses down). Missing title/session_base stay
//! empty so pre-#700 files still resolve by id/pid/goal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const worktree_lease = @import("worktree_lease.zig");

const Owner = worktree_lease.Owner;

const RecordJson = struct {
    pid: i32 = 0,
    start_id: u64 = 0,
    session_id: []const u8 = "",
    identity: []const u8 = "",
    goal: []const u8 = "",
    last_seen_ms: i64 = 0,
    title: []const u8 = "",
    session_base: []const u8 = "",
};

pub fn formatRecord(arena: Allocator, owner: Owner) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(RecordJson{
        .pid = owner.pid,
        .start_id = owner.start_id,
        .session_id = owner.session_id,
        .identity = owner.identity,
        .goal = owner.goal,
        .last_seen_ms = owner.last_seen_ms,
        .title = owner.title,
        .session_base = owner.session_base,
    });
    return aw.writer.buffered();
}

pub fn parseRecord(arena: Allocator, text: []const u8) ?Owner {
    const rec = std.json.parseFromSliceLeaky(RecordJson, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    if (rec.pid == 0) return null;
    return .{
        .pid = rec.pid,
        .start_id = rec.start_id,
        .session_id = rec.session_id,
        .identity = rec.identity,
        .goal = rec.goal,
        .last_seen_ms = rec.last_seen_ms,
        .title = rec.title,
        .session_base = rec.session_base,
    };
}

test "presence record round-trips pid, identity, goal, title, and base" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const owner: Owner = .{
        .pid = 4242,
        .start_id = 0xdeadbeef,
        .session_id = "session-1",
        .identity = "/repo/.git",
        .goal = "agent-inbox redesign",
        .last_seen_ms = 123456,
        .title = "Fixing login recovery",
        .session_base = "fixing-login-recovery",
    };
    const text = try formatRecord(arena, owner);
    const back = parseRecord(arena, text) orelse return error.ExpectedRecord;
    try std.testing.expectEqual(owner.pid, back.pid);
    try std.testing.expectEqual(owner.start_id, back.start_id);
    try std.testing.expectEqualStrings(owner.session_id, back.session_id);
    try std.testing.expectEqualStrings(owner.identity, back.identity);
    try std.testing.expectEqualStrings(owner.goal, back.goal);
    try std.testing.expectEqual(owner.last_seen_ms, back.last_seen_ms);
    try std.testing.expectEqualStrings(owner.title, back.title);
    try std.testing.expectEqualStrings(owner.session_base, back.session_base);
}

test "parseRecord: rejects garbage and pid-less records, tolerates extra fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(parseRecord(arena, "not json") == null);
    try std.testing.expect(parseRecord(arena, "{\"goal\":\"x\"}") == null);
    const forward = parseRecord(arena, "{\"pid\":7,\"start_id\":3,\"future\":\"field\"}") orelse return error.ExpectedRecord;
    try std.testing.expectEqual(7, forward.pid);
    try std.testing.expectEqualStrings("", forward.title);
    try std.testing.expectEqualStrings("", forward.session_base);
}
