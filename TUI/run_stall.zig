//! Input-stall policy for run.zig's read loop, parked here under the 600-line
//! ceiling.
//!
//! Everything in this file is a PURE decision about bytes that are stuck
//! mid-sequence, plus the clocks that bound how long the loop is allowed to
//! hold on to them.

const std = @import("std");

pub const StallVerdict = enum { wait, escape_key, drop };

pub const StallCtx = struct {
    /// A turn is streaming. A phantom Escape here CANCELS it, and this is
    /// precisely when the 1003 motion flood makes a split sequence likely, so
    /// the lone-ESC grace stretches. Idle, #94's snappy Escape is untouched.
    turn_live: bool = false,
    /// Inside a bracketed paste: a lone ESC is far more likely to be the head
    /// of the closing `CSI 201~` than the Escape key, and giving up on that
    /// marker wedges the composer.
    in_paste: bool = false,
};

/// ~25ms a stall: 2 polls idle, 8 (~200ms) while a turn streams.
const esc_grace_idle: u8 = 2;
const esc_grace_live: u8 = 8;
/// A paste marker is worth ~2s before we conclude it is never coming.
const paste_marker_stalls: u8 = 80;
/// ...but a LONE ESC inside that window gets ~300ms, not the full 2s: see
/// `stallVerdict`.
const esc_grace_paste: u8 = 12;
/// Input silence that ends a bracketed paste nothing else can close.
pub const paste_idle_ms: u64 = 2000;
/// How long a given-up head stays eligible to rejoin its tail. A sequence cut
/// by ssh/tmux jitter finishes within a few hundred ms of the give-up; past
/// that the next bytes are a human typing, and `\x1b[` + `Hello` would eat the
/// H (`CSI H` is a legal Home).
const carry_window_ms: u64 = 400;
/// How long the orphan-debris sweeper stays armed. The arm says "the loop
/// really did drop a head just now", and that claim goes stale: latched with no
/// clock at all it ate the first token of whatever the user typed NEXT, at any
/// later time (`3u apples` -> ` apples` twelve seconds after the drop). Slightly
/// longer than the carry window, because a `.partial` fragment legitimately
/// spans a read boundary or two before it completes.
const arm_window_ms: u64 = 1000;

/// What to do with input bytes stuck mid-sequence after quiet polls (~25ms
/// each). Exactly one pending ESC byte is the Escape key after the #94 grace.
/// A longer prefix is a truncated CSI/OSC split by link latency (ssh/tmux):
/// delivering Escape cancelled live turns and typing the late tail sprayed
/// "2;39M"-style debris into the transcript — wait for the tail instead, and
/// only silently drop once it is clearly never coming.
pub fn stallVerdict(pending: []const u8, stalls: u8, ctx: StallCtx) StallVerdict {
    if (pending.len == 0) return .wait;
    const lone_esc = pending.len == 1 and pending[0] == 0x1b;
    if (ctx.in_paste and isPasteMarkerPrefix(pending)) {
        // ESC is a proper prefix of `CSI 201~`, so the marker budget also
        // swallowed the ONE in-band way out of a wedged paste for ~2s on every
        // terminal that does not send kitty CSI-u (where Escape arrives as
        // `CSI 27 u` and never looked like a marker). A lone ESC that has sat
        // there through several quiet polls without growing a body is the user
        // reaching for that hatch, not a terminator in flight; an ESC with
        // bytes behind it still gets the full marker wait.
        if (lone_esc and stalls >= esc_grace_paste) return .escape_key;
        return if (stalls >= paste_marker_stalls) .drop else .wait;
    }
    if (lone_esc) {
        const grace = if (ctx.turn_live) esc_grace_live else esc_grace_idle;
        return if (stalls >= grace) .escape_key else .wait;
    }
    return if (stalls >= 20) .drop else .wait;
}

/// A proper prefix of either bracketed-paste marker.
pub fn isPasteMarkerPrefix(pending: []const u8) bool {
    return std.mem.startsWith(u8, "\x1b[201~", pending) or
        std.mem.startsWith(u8, "\x1b[200~", pending);
}

pub fn carryExpired(now_ms: u64, stash_ms: u64) bool {
    return now_ms -| stash_ms > carry_window_ms;
}

pub fn armExpired(now_ms: u64, arm_ms: u64) bool {
    return now_ms -| arm_ms > arm_window_ms;
}

/// Is this read nothing but complete SGR mouse reports?
///
/// ?1003h is on by default for image-chip hover, and a pointer merely RESTING
/// over the window makes the terminal emit a motion report roughly twice a
/// second. Those bytes are not paste content and must not count as paste
/// activity: while they did, a mouse sitting still over the terminal postponed
/// the #548 idle recovery indefinitely and an unterminated paste NEVER
/// released. Deliberately strict — only whole `CSI < params M|m` reports, so a
/// read that carries any real pasted byte keeps the latch alive.
pub fn onlyMouseReports(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 3 > bytes.len or bytes[i] != 0x1b or bytes[i + 1] != '[' or bytes[i + 2] != '<') return false;
        var j = i + 3;
        while (j < bytes.len and ((bytes[j] >= '0' and bytes[j] <= '9') or bytes[j] == ';')) : (j += 1) {}
        if (j >= bytes.len or (bytes[j] != 'M' and bytes[j] != 'm')) return false;
        i = j + 1;
    }
    return true;
}

test "a truncated CSI never becomes Escape or typed debris; a lone ESC still does (#94)" {
    const idle: StallCtx = .{};
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 1, idle));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 2, idle));
    // Split SGR mouse / kitty CSI-u: never Escape, wait for the tail...
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[<65;2;3", 2, idle));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[5744", 19, idle));
    // ...and silently drop once it is clearly lost, so it is never typed.
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("\x1b[<65;2;3", 20, idle));
    // Half-arrived shapes from 1003 hover tracking — never the Escape key.
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("\x1b[", 20, idle));
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("\x1bO", 20, idle));
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("39;7", 20, idle));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("", 5, idle));
}

test "the lone-ESC grace stretches while a turn streams (#530)" {
    // ssh/tmux jitter during a 1003 motion flood cuts right after an ESC. At
    // 2 polls that became a phantom Escape and cancelled the live turn; the
    // body then typed itself. Idle, #94's latency is unchanged.
    const live: StallCtx = .{ .turn_live = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 2, live));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 7, live));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 8, live));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 2, .{}));
}

test "the carried head expires before it can reach a human keystroke (#530)" {
    // A tail split off by link jitter lands within a few hundred ms of the
    // give-up; anything later is somebody typing and must arrive untouched.
    try std.testing.expect(!carryExpired(1000, 1000));
    try std.testing.expect(!carryExpired(1400, 1000));
    try std.testing.expect(carryExpired(1401, 1000));
    try std.testing.expect(carryExpired(9000, 1000));
    // A clock that never ran (no stash yet) is expired, not live.
    try std.testing.expect(carryExpired(100_000, 0));
}

test "the debris arm expires too, so it can never eat a later keystroke" {
    // Unbounded, the arm swallowed the first token of whatever was typed next
    // at ANY later time — `3u apples` reached the composer as ` apples` twelve
    // seconds after the head was dropped.
    try std.testing.expect(!armExpired(1000, 1000));
    try std.testing.expect(!armExpired(2000, 1000));
    try std.testing.expect(armExpired(2001, 1000));
    try std.testing.expect(armExpired(13_000, 1000));
    // Outlives the carry window: a `.partial` fragment may span a read or two.
    try std.testing.expect(carryExpired(1600, 1000) and !armExpired(1600, 1000));
}

test "a paste marker is never abandoned on the #94 timescale (#532)" {
    // Both give-up routes strand `in_paste` forever, so every prefix of either
    // marker gets ~2s — including a lone ESC on the #94 timescale.
    const p: StallCtx = .{ .in_paste = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 2, p));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[201", 20, p));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[20", 79, p));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[200", 79, p));
    // Then give up for real — run.zig synthesizes the paste_end on that drop.
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("\x1b[201", 80, p));
    // Anything that is not a marker prefix keeps the ordinary budget.
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("\x1b[<65;2;3", 20, p));
    try std.testing.expect(isPasteMarkerPrefix("\x1b[201~"));
    try std.testing.expect(!isPasteMarkerPrefix("\x1b[202"));
}

test "a resting mouse is not paste activity (#548 starvation)" {
    // Hover reports under ?1003h arrive while the pointer does not move at all.
    try std.testing.expect(onlyMouseReports("\x1b[<35;80;24M"));
    try std.testing.expect(onlyMouseReports("\x1b[<35;80;24M\x1b[<35;80;24M"));
    try std.testing.expect(onlyMouseReports("\x1b[<0;4;9m"));
    // Anything that could be paste content keeps the latch's clock running.
    try std.testing.expect(!onlyMouseReports(""));
    try std.testing.expect(!onlyMouseReports("hello"));
    try std.testing.expect(!onlyMouseReports("\x1b[<35;80;24Mhello"));
    try std.testing.expect(!onlyMouseReports("hello\x1b[<35;80;24M"));
    try std.testing.expect(!onlyMouseReports("\x1b[<35;80;24")); // split: not complete
    try std.testing.expect(!onlyMouseReports("\x1b[201~"));
    try std.testing.expect(!onlyMouseReports("\x1b[A"));
}

test "a lone ESC inside a latched paste is the escape hatch, not a 2s wait" {
    // On a non-kitty terminal Escape IS `\x1b`, which is a prefix of the
    // terminator — so the hatch out of a wedged paste was dead for ~2s.
    const p: StallCtx = .{ .in_paste = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 11, p));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 12, p));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 79, p));
    // An ESC with a body behind it is still a terminator in flight: full wait.
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[", 12, p));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[201", 79, p));
    // Outside a paste nothing moved: #94's 2-stall Escape still fires.
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 2, .{}));
}
