//! #398: annotate provider retry advice with a human duration. "Please try
//! again in 350000 seconds" reads like a bug; "(~4d 1h)" reads like advice.
//! Display-only by contract — callers append the hint and never rewrite the
//! provider's words, because failure classifiers keyword-match the original
//! text (see subagent classifyFailure).

const std = @import("std");

pub const Human = struct { buf: [24]u8, len: u8 };

/// A compact human duration ("4d 1h", "5m 50s") when `msg` names a wait of at
/// least a minute in seconds; null otherwise (sub-minute waits already read).
pub fn humanizeRetrySeconds(msg: []const u8) ?Human {
    const secs = findSeconds(msg) orelse return null;
    if (secs < 60) return null;
    var h: Human = .{ .buf = undefined, .len = 0 };
    var w: std.Io.Writer = .fixed(&h.buf);
    const d = secs / 86400;
    const hr = (secs / 3600) % 24;
    const m = (secs / 60) % 60;
    const s = secs % 60;
    (if (d > 0) w.print("{d}d {d}h", .{ d, hr }) else if (hr > 0) w.print("{d}h {d}m", .{ hr, m }) else w.print("{d}m {d}s", .{ m, s })) catch return null;
    h.len = @intCast(w.buffered().len);
    return h;
}

/// Finds the first "<number> second(s)" in `msg` and returns the whole-second
/// count. Tolerates a fractional part ("3599.548 seconds"), which providers
/// emit; the fraction is dropped, not rounded.
fn findSeconds(msg: []const u8) ?u64 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, msg, i, " second")) |pos| : (i = pos + 7) {
        var start = pos;
        var saw_dot = false;
        while (start > 0 and (std.ascii.isDigit(msg[start - 1]) or (!saw_dot and msg[start - 1] == '.'))) : (start -= 1) {
            if (msg[start - 1] == '.') saw_dot = true;
        }
        var end = pos;
        if (saw_dot) end = std.mem.indexOfScalarPos(u8, msg, start, '.').?;
        if (end > start and std.ascii.isDigit(msg[start]))
            return std.fmt.parseInt(u64, msg[start..end], 10) catch null;
    }
    return null;
}

test "humanizeRetrySeconds (#398): big waits annotate, small and absent do not" {
    const big = humanizeRetrySeconds("Please try again in 350000 seconds.").?;
    try std.testing.expectEqualStrings("4d 1h", big.buf[0..big.len]);
    const mid = humanizeRetrySeconds("rate limited; retry in 350 seconds").?;
    try std.testing.expectEqualStrings("5m 50s", mid.buf[0..mid.len]);
    const hrs = humanizeRetrySeconds("available again in 7250 seconds").?;
    try std.testing.expectEqualStrings("2h 0m", hrs.buf[0..hrs.len]);
    const frac = humanizeRetrySeconds("Expected available in 3599.548 seconds").?;
    try std.testing.expectEqualStrings("59m 59s", frac.buf[0..frac.len]);
    try std.testing.expect(humanizeRetrySeconds("try again in 30 seconds") == null);
    try std.testing.expect(humanizeRetrySeconds("quota exceeded, no numbers") == null);
    try std.testing.expect(humanizeRetrySeconds("in a second or two") == null);
}
