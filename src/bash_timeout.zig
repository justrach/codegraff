//! Foreground `bash` deadline. Root stays Esc-only when `timeout_ms` is
//! omitted or 0 (a human may want a long build). A positive `timeout_ms`
//! kills the process group. Subagents still default to 120s (#93) when the
//! model does not ask. Background jobs ignore this — `bash_kill` owns them.

const std = @import("std");

pub const subagent_default_ms: u64 = 120 * 1000;
pub const max_ms: u64 = 10 * 60 * 60 * 1000; // same 10h cap as bash_output wait_ms

pub const invalid = "timeout_ms must be >= 0";

/// `asked == null` or `0` → root unbounded, subagent 120s.
/// Positive values clamp to `max_ms`. Caller has already rejected negatives.
pub fn resolve(from_sub: bool, asked: ?i64) u64 {
    const raw = asked orelse 0;
    if (raw <= 0) return if (from_sub) subagent_default_ms else 0;
    return @min(@as(u64, @intCast(raw)), max_ms);
}

pub fn killedNote(buf: *[256]u8, deadline_ms: u64, from_sub: bool, explicit: bool) []const u8 {
    const secs = @max(deadline_ms / 1000, 1);
    if (from_sub and !explicit) {
        return std.fmt.bufPrint(buf, "\n[timed out after {d}s and was killed — too long for a subagent. Don't retry as-is: scope it to specific paths or globs instead of scanning the whole directory, or report back what you need run.]", .{secs}) catch "\n[timed out and was killed]";
    }
    return std.fmt.bufPrint(buf, "\n[timed out after {d}s and was killed — raise timeout_ms, set run_in_background, or scope the command]", .{secs}) catch "\n[timed out and was killed]";
}

test "resolve: root omit/0 is unbounded; subagent omit/0 is 120s" {
    try std.testing.expectEqual(@as(u64, 0), resolve(false, null));
    try std.testing.expectEqual(@as(u64, 0), resolve(false, 0));
    try std.testing.expectEqual(subagent_default_ms, resolve(true, null));
    try std.testing.expectEqual(subagent_default_ms, resolve(true, 0));
}

test "resolve: a positive ask clamps to 10h and can shorten a subagent" {
    try std.testing.expectEqual(@as(u64, 500), resolve(false, 500));
    try std.testing.expectEqual(@as(u64, 500), resolve(true, 500));
    try std.testing.expectEqual(max_ms, resolve(false, 99_999_999));
    try std.testing.expectEqual(max_ms, resolve(true, 99_999_999));
}

test "killedNote: subagent default keeps the #93 recovery; explicit is generic" {
    var buf: [256]u8 = undefined;
    const sub = killedNote(&buf, subagent_default_ms, true, false);
    try std.testing.expect(std.mem.indexOf(u8, sub, "too long for a subagent") != null);
    const root = killedNote(&buf, 2000, false, true);
    try std.testing.expect(std.mem.indexOf(u8, root, "timeout_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "2s") != null);
}
