//! Input pacing for the fullscreen loop: wheel coalescing and the frame budget.
//!
//! Trackpad momentum delivers wheel reports far faster than a frame can be
//! composed and painted. Serviced one report per paint, the loop queues work it
//! can never catch up on — the scroll trails the fingers and then jumps to the
//! end when the backlog drains. Two rules fix that, and both live here as pure
//! decisions so they can be pinned without a tty.
//!
//! 1. COALESCE. Consecutive wheel reports fold into ONE accumulated notch
//!    delta. Order is preserved and any non-wheel event BREAKS the run at that
//!    point, so a keystroke typed mid-storm keeps its exact place in the
//!    stream and is never starved behind the flood. Folding is not only
//!    cheaper, it is more faithful: `scroll` saturates at the bottom edge, so
//!    applying a down-down-up run one report at a time latches `follow` back on
//!    and lands somewhere the net delta never asked for.
//!
//! 2. BUDGET. At most one composed frame per `frame_budget_ms`, and only while
//!    input is still arriving. Idle — which includes a single wheel tick — the
//!    frame is immediate, so the budget can never add latency to a scroll the
//!    user is not actually storming.

const std = @import("std");

const key_mod = @import("key.zig");
const Key = key_mod.Key;

/// ~120fps. Long enough that a momentum burst folds into one frame, short
/// enough that no eye reads the frame as late.
pub const frame_budget_ms: u64 = 8;

/// Lines per wheel notch — the xterm convention keys.mouseKey already used.
pub const lines_per_notch: i32 = 3;

/// How many distinct items one tick applies before the loop drains and reopens
/// the batch. A run of wheel reports folds into the trailing item and costs
/// nothing, so this bounds INTERLEAVING, not storm size.
pub const batch_cap: usize = 64;

/// SGR buttons 64/65 are the wheel reported as a button (?1006h). +1 scrolls
/// back through the transcript, -1 forward — the sign keys.scrollBy takes.
pub fn wheelNotch(k: Key) ?i32 {
    if (k != .mouse) return null;
    return switch (k.mouse.btn) {
        64 => 1,
        65 => -1,
        else => null,
    };
}

/// One unit of dispatch: an ordinary key, or a folded run of wheel reports
/// carrying their accumulated notch delta.
pub const Item = union(enum) {
    key: Key,
    wheel: i32,
};

pub const Push = enum { ok, full };

/// Events drained from one tick, with consecutive wheel reports folded.
pub const Batch = struct {
    buf: [batch_cap]Item = undefined,
    len: usize = 0,
    /// Raw wheel reports folded in (for the paint-stats counter).
    folded: usize = 0,

    pub fn push(self: *Batch, k: Key) Push {
        if (wheelNotch(k)) |d| {
            // Folding into the trailing run never needs a slot, which is what
            // lets a 500-report storm fit in a 64-item batch.
            if (self.len > 0 and self.buf[self.len - 1] == .wheel) {
                self.buf[self.len - 1].wheel += d;
                self.folded += 1;
                return .ok;
            }
            if (self.len == self.buf.len) return .full;
            self.buf[self.len] = .{ .wheel = d };
            self.len += 1;
            self.folded += 1;
            return .ok;
        }
        if (self.len == self.buf.len) return .full;
        self.buf[self.len] = .{ .key = k };
        self.len += 1;
        return .ok;
    }

    pub fn items(self: *const Batch) []const Item {
        return self.buf[0..self.len];
    }

    pub fn reset(self: *Batch) void {
        self.len = 0;
        self.folded = 0;
    }
};

/// Input still arriving faster than two frames apart. Momentum reports land
/// every millisecond or two; a second flick a tenth of a second later, or a
/// human typing at 20Hz, or a key repeating at 30Hz, are all comfortably
/// OUTSIDE this window and are never treated as a storm.
///
/// This, not "are there bytes queued right now", is the signal that matters:
/// on a fast loop each momentum report is read the instant it lands and finds
/// the queue empty behind it, so a queue check alone would happily paint 500
/// times for 500 reports.
pub const storm_gap_ms: u64 = 2 * frame_budget_ms;

pub fn storming(now_ms: u64, last_input_ms: u64) bool {
    return last_input_ms != 0 and now_ms -| last_input_ms < storm_gap_ms;
}

/// May the loop compose and paint a frame this tick?
///
/// Quiet — no backlog and no recent stream — the answer is always yes: one
/// wheel tick paints on the spot with nothing added to its latency. Under a
/// storm the frame waits out the budget, which bounds paints at
/// ~1/frame_budget_ms instead of one per report; and because a skipped tick
/// goes straight back to draining, the frame that does land shows the LATEST
/// scroll position and never an intermediate one.
pub fn shouldPaint(now_ms: u64, last_frame_ms: u64, last_input_ms: u64, more_pending: bool) bool {
    if (!more_pending and !storming(now_ms, last_input_ms)) return true;
    return now_ms -| last_frame_ms >= frame_budget_ms;
}

/// Cap a poll timeout at the frame the loop already OWES. Called only on the
/// tick after a deferred frame, so an idle loop keeps its long, cheap waits
/// instead of spinning at 125Hz for nothing.
pub fn waitCap(now_ms: u64, last_frame_ms: u64, wait_ms: i32) i32 {
    const used = now_ms -| last_frame_ms;
    if (used >= frame_budget_ms) return 0;
    const left: i32 = @intCast(frame_budget_ms - used);
    return @min(wait_ms, left);
}

/// Has this tick's drain used up the budget? Without this a genuinely endless
/// flood would be drained forever and never painted at all.
pub fn drainExpired(now_ms: u64, tick_start_ms: u64) bool {
    return now_ms -| tick_start_ms >= frame_budget_ms;
}

// --- local-only instrumentation (GRAFF_TUI_PAINT_STATS=1) ------------------
// Off by default and never wired to telemetry: this exists so a pty storm test
// can assert the paint count is BUDGETED rather than one-per-report.

pub var stats_on: bool = false;
pub var ticks: u64 = 0;
pub var frames: u64 = 0;
pub var paints: u64 = 0;
pub var frames_skipped: u64 = 0;
pub var reads: u64 = 0;
pub var events: u64 = 0;
pub var wheel_events: u64 = 0;
pub var wheel_batches: u64 = 0;

pub fn resetStats() void {
    ticks = 0;
    frames = 0;
    paints = 0;
    frames_skipped = 0;
    reads = 0;
    events = 0;
    wheel_events = 0;
    wheel_batches = 0;
}

/// One line, written after the terminal has been handed back so it lands on
/// the normal screen instead of inside the alt-screen frame.
pub fn report(w: *std.Io.Writer) void {
    if (!stats_on) return;
    w.print(
        "tui-paint-stats: paints={d} frames={d} skipped={d} ticks={d} reads={d} events={d} wheel_events={d} wheel_batches={d}\n",
        .{ paints, frames, frames_skipped, ticks, reads, events, wheel_events, wheel_batches },
    ) catch {};
    w.flush() catch {};
}

fn wheel(btn: u8) Key {
    return .{ .mouse = .{ .btn = btn, .x = 1, .y = 1, .down = true } };
}

test "consecutive wheel reports fold; a key breaks the run and keeps its place" {
    var b: Batch = .{};
    for (0..5) |_| try std.testing.expectEqual(Push.ok, b.push(wheel(64)));
    try std.testing.expectEqual(Push.ok, b.push(.{ .char = 'x' }));
    for (0..3) |_| try std.testing.expectEqual(Push.ok, b.push(wheel(65)));

    const it = b.items();
    try std.testing.expectEqual(@as(usize, 3), it.len);
    try std.testing.expectEqual(@as(i32, 5), it[0].wheel);
    try std.testing.expectEqual(@as(u8, 'x'), it[1].key.char);
    try std.testing.expectEqual(@as(i32, -3), it[2].wheel);
    // 9 reports arrived, 3 units of work come out.
    try std.testing.expectEqual(@as(usize, 8), b.folded);
}

test "a mixed run nets out instead of clamping at the bottom edge" {
    // down-down-up is a NET one notch back. Applied report by report it hits
    // scroll==0 halfway, re-latches follow, and ends a notch further along than
    // the fingers asked for.
    var b: Batch = .{};
    _ = b.push(wheel(65));
    _ = b.push(wheel(65));
    _ = b.push(wheel(64));
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqual(@as(i32, -1), b.items()[0].wheel);
}

test "a storm of wheel reports never overflows the batch" {
    var b: Batch = .{};
    for (0..5000) |_| try std.testing.expectEqual(Push.ok, b.push(wheel(65)));
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqual(@as(i32, -5000), b.items()[0].wheel);
}

test "interleaving fills the batch and reports full so the loop can drain" {
    var b: Batch = .{};
    var i: usize = 0;
    while (i < batch_cap) : (i += 1) {
        try std.testing.expectEqual(Push.ok, b.push(.{ .char = 'a' }));
    }
    try std.testing.expectEqual(Push.full, b.push(.{ .char = 'a' }));
    // ...but a wheel report still folds if the tail is a wheel run, so the
    // full-batch path can never be reached by scrolling alone.
    b.reset();
    _ = b.push(wheel(64));
    i = 1;
    while (i < batch_cap) : (i += 1) _ = b.push(.{ .char = 'a' });
    try std.testing.expectEqual(Push.full, b.push(.{ .char = 'a' }));
    try std.testing.expectEqual(Push.full, b.push(wheel(64)));
}

test "non-wheel mouse events are not coalesced" {
    var b: Batch = .{};
    _ = b.push(.{ .mouse = .{ .btn = 0, .x = 2, .y = 3, .down = true } });
    _ = b.push(.{ .mouse = .{ .btn = 0, .x = 2, .y = 4, .down = false } });
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqual(@as(?i32, null), wheelNotch(.{ .mouse = .{ .btn = 0, .x = 1, .y = 1, .down = true } }));
    try std.testing.expectEqual(@as(?i32, null), wheelNotch(.{ .char = 'k' }));
}

test "the budget is free for one flick and bounds paints under a flood" {
    // Nothing queued and nothing recent: paint now. This is the single-wheel-
    // tick case, and it must not pay one millisecond for the budget...
    try std.testing.expect(shouldPaint(1000, 1000, 0, false));
    try std.testing.expect(shouldPaint(1000, 999, 900, false));
    // ...including a second flick a tenth of a second after the first.
    try std.testing.expect(shouldPaint(1000, 1000, 900, false));
    // Backlog waiting: wait out the budget, then paint.
    try std.testing.expect(!shouldPaint(1000, 1000, 0, true));
    try std.testing.expect(!shouldPaint(1007, 1000, 0, true));
    try std.testing.expect(shouldPaint(1008, 1000, 0, true));
    try std.testing.expect(shouldPaint(9000, 1000, 0, true));
    // ...and a stream arriving faster than the loop can back up is a storm all
    // the same. Without this, momentum reports that each find an empty queue
    // behind them paint one frame per report — the whole bug.
    try std.testing.expect(!shouldPaint(1002, 1000, 1001, false));
    try std.testing.expect(shouldPaint(1008, 1000, 1007, false));
}

test "storming is a rate, not a backlog" {
    try std.testing.expect(storming(1001, 1000));
    try std.testing.expect(storming(1015, 1000));
    // 16ms of silence ends it: typing at 20Hz and key repeat at 30Hz are both
    // outside, so neither ever costs a frame of latency.
    try std.testing.expect(!storming(1016, 1000));
    try std.testing.expect(!storming(1050, 1000));
    // A session that has taken no input at all is not storming.
    try std.testing.expect(!storming(9999, 0));
}

test "the owed-frame wait never outlives the budget and never spins" {
    // A long idle wait is capped to what is left of the budget...
    try std.testing.expectEqual(@as(i32, 8), waitCap(1000, 1000, 200));
    try std.testing.expectEqual(@as(i32, 3), waitCap(1005, 1000, 200));
    // ...but a shorter wait the loop already wanted still wins.
    try std.testing.expectEqual(@as(i32, 2), waitCap(1005, 1000, 2));
    // Budget spent: return immediately and paint. Returning a positive value
    // here would be a spin at 125Hz that never owed a frame in the first place.
    try std.testing.expectEqual(@as(i32, 0), waitCap(1008, 1000, 200));
    try std.testing.expectEqual(@as(i32, 0), waitCap(9000, 1000, 200));
}

test "the drain has a deadline so an endless flood still paints" {
    try std.testing.expect(!drainExpired(1000, 1000));
    try std.testing.expect(!drainExpired(1007, 1000));
    try std.testing.expect(drainExpired(1008, 1000));
    try std.testing.expect(frame_budget_ms > 0 and frame_budget_ms <= 16);
}
