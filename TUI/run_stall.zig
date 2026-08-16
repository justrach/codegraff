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
/// Input silence that ends a bracketed paste nothing else can close.
pub const paste_idle_ms: u64 = 2000;
/// How long a given-up head stays eligible to rejoin its tail. A sequence cut
/// by ssh/tmux jitter finishes within a few hundred ms of the give-up; past
/// that the next bytes are a human typing, and `\x1b[` + `Hello` would eat the
/// H (`CSI H` is a legal Home).
const carry_window_ms: u64 = 400;

/// What to do with input bytes stuck mid-sequence after quiet polls (~25ms
/// each). Exactly one pending ESC byte is the Escape key after the #94 grace.
/// A longer prefix is a truncated CSI/OSC split by link latency (ssh/tmux):
/// delivering Escape cancelled live turns and typing the late tail sprayed
/// "2;39M"-style debris into the transcript — wait for the tail instead, and
/// only silently drop once it is clearly never coming.
pub fn stallVerdict(pending: []const u8, stalls: u8, ctx: StallCtx) StallVerdict {
    if (pending.len == 0) return .wait;
    if (ctx.in_paste and isPasteMarkerPrefix(pending)) {
        return if (stalls >= paste_marker_stalls) .drop else .wait;
    }
    if (pending.len == 1 and pending[0] == 0x1b) {
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

test "a paste marker is never abandoned on the #94 timescale (#532)" {
    // Both give-up routes strand `in_paste` forever, so every prefix of either
    // marker gets ~2s — including the lone ESC, which must NOT become Escape.
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
