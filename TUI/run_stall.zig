//! Input-stall policy for run.zig's read loop, parked here under the 600-line
//! ceiling.
//!
//! Everything in this file is a PURE decision about bytes that are stuck
//! mid-sequence, plus the clocks that bound how long the loop is allowed to
//! hold on to them. The rule throughout is grok-build's `XT_MAX_HOLD`: every
//! hold is bounded, because an unbounded latch is how a terminal hiccup turns
//! into a session that never accepts input again.

const std = @import("std");

pub const StallVerdict = enum { wait, escape_key, drop };

pub const StallCtx = struct {
    /// A model turn or background operation was live when this ESC head
    /// arrived. The read loop latches that fact: a fast completion between
    /// quiet polls must not shorten the head's ambiguity window.
    operation_live: bool = false,
    /// Inside a bracketed paste: a lone ESC is far more likely to be the head
    /// of the closing `CSI 201~` than the Escape key, and giving up on that
    /// marker wedges the composer.
    in_paste: bool = false,
};

/// ~25ms a stall. Twelve idle polls (~300ms) cover the reported 50–250ms
/// splits. A live operation waits the full bounded dropped-head recovery
/// window: cancelling sooner is irreversible if the bytes become `CSI 200~`.
const esc_grace_idle: u8 = 12;
pub const live_escape_stalls: u8 = 40; // 1s; Ctrl-C and CSI-u Esc bypass it
/// A paste marker is worth ~2s before we conclude it is never coming.
const paste_marker_stalls: u8 = 80;
/// ...but a LONE ESC inside that window gets ~300ms, not the full 2s: see
/// `stallVerdict`.
const esc_grace_paste: u8 = 12;
/// Input silence that ends a bracketed paste nothing else can close.
pub const paste_idle_ms: u64 = 2000;
/// Short exact-carry window after a lone ESC was delivered as a genuine key.
/// That ambiguity must not let the ESC glue itself onto human input for the
/// whole recovery interval. A non-lone sequence actually dropped after its
/// stall budget is stronger evidence: key_orphan retains and accumulates that
/// exact framing until `arm_window_ms`, bounded by its small head buffer.
const escape_carry_window_ms: u64 = 400;
/// How long the orphan-debris sweeper stays armed. The arm says "the loop
/// really did drop a head just now", and that claim goes stale: latched with no
/// clock at all it ate the first token of whatever the user typed NEXT, at any
/// later time (`3u apples` -> ` apples` twelve seconds after the drop). This is
/// also the full exact-head interval for a dropped non-lone sequence.
const arm_window_ms: u64 = 1000;

/// What to do with input bytes stuck mid-sequence after quiet polls (~25ms
/// each). Exactly one pending ESC byte is the Escape key after the #94 grace.
/// A longer prefix is a truncated CSI/OSC split by link latency (ssh/tmux):
/// delivering Escape cancelled live turns and typing the late tail sprayed
/// "2;39M"-style debris into the transcript — wait for the tail instead, and
/// only silently drop once it is clearly never coming.
pub fn stallVerdict(pending: []const u8, stalls: u8, ctx: StallCtx) StallVerdict {
    if (pending.len == 0) return .wait;
    const lone_esc = isLoneEscape(pending);
    if (ctx.in_paste and isPasteMarkerPrefix(pending)) {
        // ESC is a proper prefix of `CSI 201~`, so the marker budget also
        // swallowed the ONE in-band way out of a wedged paste for ~2s on every
        // terminal that does not send kitty CSI-u (where Escape arrives as
        // `CSI 27 u` and never looked like a marker). A lone ESC that has sat
        // there through several quiet polls without growing a body is the user
        // reaching for that hatch, not a terminator in flight; an ESC with
        // bytes behind it still gets the full marker wait.
        const grace = if (ctx.operation_live) live_escape_stalls else esc_grace_paste;
        if (lone_esc and stalls >= grace) return .escape_key;
        return if (stalls >= paste_marker_stalls) .drop else .wait;
    }
    if (lone_esc) {
        const grace = if (ctx.operation_live) live_escape_stalls else esc_grace_idle;
        return if (stalls >= grace) .escape_key else .wait;
    }
    return if (stalls >= 20) .drop else .wait;
}

pub fn isLoneEscape(pending: []const u8) bool {
    return pending.len == 1 and pending[0] == 0x1b;
}

/// A proper prefix of either bracketed-paste marker.
pub fn isPasteMarkerPrefix(pending: []const u8) bool {
    return std.mem.startsWith(u8, "\x1b[201~", pending) or
        std.mem.startsWith(u8, "\x1b[200~", pending);
}

pub fn escapeCarryExpired(now_ms: u64, stash_ms: u64) bool {
    return now_ms -| stash_ms > escape_carry_window_ms;
}

pub fn armExpired(now_ms: u64, arm_ms: u64) bool {
    return now_ms -| arm_ms > arm_window_ms;
}

/// A stuck CSI/OSC head that filled the read buffer is a parser wedge, not a
/// hangup. Drop it so the next `read` is not a zero-length "TTY gone" (#517).
pub fn clearFullWedge(pending_len: usize, buf_len: usize) usize {
    return if (pending_len == buf_len) 0 else pending_len;
}

/// Is this read nothing but complete SGR or X10 mouse reports?
///
/// ?1003h is on by default for image-chip hover, and a pointer merely RESTING
/// over the window makes the terminal emit a motion report roughly twice a
/// second. Those bytes are not paste content and must not count as paste
/// activity: while they did, a mouse sitting still over the terminal postponed
/// the #548 idle recovery indefinitely and an unterminated paste NEVER
/// released. Deliberately strict — only whole SGR or three-byte-body X10
/// reports, so a read carrying any real pasted byte keeps the latch alive.
pub fn onlyMouseReports(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 3 > bytes.len or bytes[i] != 0x1b or bytes[i + 1] != '[') return false;
        if (bytes[i + 2] == 'M') {
            if (i + 6 > bytes.len or std.mem.indexOfScalar(u8, bytes[i + 3 .. i + 6], 0x1b) != null) return false;
            i += 6;
            continue;
        }
        if (bytes[i + 2] != '<') return false;
        var j = i + 3;
        while (j < bytes.len and ((bytes[j] >= '0' and bytes[j] <= '9') or bytes[j] == ';')) : (j += 1) {}
        if (j >= bytes.len or (bytes[j] != 'M' and bytes[j] != 'm')) return false;
        i = j + 1;
    }
    return true;
}

test "a truncated CSI never becomes Escape or typed debris; a lone ESC still does (#94)" {
    const idle: StallCtx = .{};
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 11, idle));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 12, idle));
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

test "bounded lone-ESC grace covers splits without preempting live recovery (#537)" {
    // Idle Escape remains ~300ms; a live call gets the full documented 1s.
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 2, .{}));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 10, .{}));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 11, .{}));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 12, .{}));
    const live: StallCtx = .{ .operation_live = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 16, live));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", live_escape_stalls - 1, live));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", live_escape_stalls, live));
}

test "a late body stays a sequence, never a second Escape decision (#537)" {
    // Once a head has a body, the pure policy never classifies it as the
    // Escape key. This is the policy half of the orphan join: run.zig/key.zig
    // may carry the head until its tail arrives, but a late CSI body cannot
    // cancel a turn or become typed debris through this decision point.
    const live: StallCtx = .{ .operation_live = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[", 2, live));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[", 8, live));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[<35;80;24", 19, live));
    try std.testing.expectEqual(StallVerdict.drop, stallVerdict("\x1b[<35;80;24", 20, live));
    // The same invariant holds while an operation is cancellable in the
    // background, and while idle: only a lone ESC can become Escape.
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[", 2, .{ .operation_live = true }));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[", 2, .{}));
}

test "the genuine-Escape carry expires before it can reach a human keystroke (#530)" {
    // A delivered Escape is weak evidence: its exact carry stays short even
    // though narrow, self-identifying recovery remains armed for one second.
    try std.testing.expect(!escapeCarryExpired(1000, 1000));
    try std.testing.expect(!escapeCarryExpired(1400, 1000));
    try std.testing.expect(escapeCarryExpired(1401, 1000));
    try std.testing.expect(escapeCarryExpired(9000, 1000));
    // A clock that never ran (no stash yet) is expired, not live.
    try std.testing.expect(escapeCarryExpired(100_000, 0));
}

test "the debris arm expires too, so it can never eat a later keystroke" {
    // Unbounded, the arm swallowed the first token of whatever was typed next
    // at ANY later time — `3u apples` reached the composer as ` apples` twelve
    // seconds after the head was dropped.
    try std.testing.expect(!armExpired(1000, 1000));
    try std.testing.expect(!armExpired(2000, 1000));
    try std.testing.expect(armExpired(2001, 1000));
    try std.testing.expect(armExpired(13_000, 1000));
    // Outlives the genuine-Escape carry; dropped exact framing remains live.
    try std.testing.expect(escapeCarryExpired(1600, 1000) and !armExpired(1600, 1000));
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
    try std.testing.expect(onlyMouseReports("\x1b[M !!\x1b[M#%%"));
    // Anything that could be paste content keeps the latch's clock running.
    try std.testing.expect(!onlyMouseReports(""));
    try std.testing.expect(!onlyMouseReports("hello"));
    try std.testing.expect(!onlyMouseReports("\x1b[<35;80;24Mhello"));
    try std.testing.expect(!onlyMouseReports("hello\x1b[<35;80;24M"));
    try std.testing.expect(!onlyMouseReports("\x1b[<35;80;24")); // split: not complete
    try std.testing.expect(!onlyMouseReports("\x1b[M !"));
    try std.testing.expect(!onlyMouseReports("\x1b[M \x1b[201~"));
    try std.testing.expect(!onlyMouseReports("\x1b[201~"));
    try std.testing.expect(!onlyMouseReports("\x1b[A"));
}

test "a lone ESC inside a latched paste stays bounded" {
    // Idle paste hatch: ~300ms. With live work, marker ambiguity wins for 1s.
    const p: StallCtx = .{ .in_paste = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", 11, p));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 12, p));
    const live: StallCtx = .{ .in_paste = true, .operation_live = true };
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b", live_escape_stalls - 1, live));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", live_escape_stalls, live));
    // An ESC with a body behind it is still a terminator in flight: full wait.
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[", 12, p));
    try std.testing.expectEqual(StallVerdict.wait, stallVerdict("\x1b[201", 79, p));
    try std.testing.expectEqual(StallVerdict.escape_key, stallVerdict("\x1b", 12, .{}));
}

test "a buffer-filling parser wedge is dropped, not treated as hangup (#517)" {
    try std.testing.expectEqual(@as(usize, 0), clearFullWedge(4096, 4096));
    try std.testing.expectEqual(@as(usize, 12), clearFullWedge(12, 4096));
    try std.testing.expectEqual(@as(usize, 0), clearFullWedge(0, 4096));
    try std.testing.expectEqual(@as(usize, 1), clearFullWedge(1, 2));
}
