//! #1686: an automatic compaction that leaves the context over the compaction
//! point fires again on the very next step. When the provider's compacted
//! state, or a summary that must keep a long live turn verbatim, cannot get
//! under the line, every step paid a compaction and the model reread what it
//! had just lost. A compaction that bought no room holds the next one until
//! the context grows by a twentieth of the window, or reaches the 95% wall
//! where recovery may trim. The in-stream server directive follows the hold.

const std = @import("std");

pub const Backoff = struct {
    rewrites: u32 = 0, // history_rewrites at the previous step
    steps: u32 = std.math.maxInt(u32), // model steps since history was last rewritten
    resume_at: u64 = 0, // context that ends the hold; 0 when not holding
};

pub const Gate = enum { compact, hold, hold_started };

/// Once per model step, before the pre-send gate. `over`: the context is at or
/// past the compaction point.
pub fn step(b: *Backoff, rewrites: u32, over: bool) void {
    if (rewrites != b.rewrites) {
        b.rewrites = rewrites;
        b.steps = 0;
    } else b.steps +|= 1;
    if (!over) b.resume_at = 0; // real room: compaction worked
}

/// The pre-send gate found `context` over the compaction point.
pub fn gate(b: *Backoff, context: u64, window: u64, near_limit: bool) Gate {
    if (near_limit) {
        b.resume_at = 0;
        return .compact;
    }
    if (b.resume_at != 0) {
        if (context < b.resume_at) return .hold;
        b.resume_at = 0;
        return .compact;
    }
    // History was rewritten this step or the one before and is still over.
    if (b.steps > 1) return .compact;
    b.resume_at = context +| @max(window / 20, 1);
    return .hold_started;
}

/// The in-stream compaction threshold while holding: the server must not
/// compact on every request either. Never past the 95% wall.
pub fn threshold(b: Backoff, base: u64, window: u64) u64 {
    if (b.resume_at <= base) return base;
    return @max(base, @min(b.resume_at, window - window / 20));
}

test "a compaction that leaves the context over the line holds the next one" {
    var b: Backoff = .{};
    const window: u64 = 800_000;
    // Long-running session: no recent rewrite, so the first trip compacts.
    b.steps = 10;
    step(&b, 0, true);
    try std.testing.expectEqual(Gate.compact, gate(&b, 645_000, window, false));
    // The compaction rewrote history, and the next step is still over.
    step(&b, 1, true);
    try std.testing.expectEqual(Gate.hold_started, gate(&b, 641_000, window, false));
    try std.testing.expectEqual(@as(u64, 681_000), b.resume_at);
    try std.testing.expectEqual(@as(u64, 681_000), threshold(b, 640_000, window));
    step(&b, 1, true);
    try std.testing.expectEqual(Gate.hold, gate(&b, 660_000, window, false));
    // Grown by a twentieth of the window: compact once more.
    step(&b, 1, true);
    try std.testing.expectEqual(Gate.compact, gate(&b, 682_000, window, false));
    try std.testing.expectEqual(@as(u64, 640_000), threshold(b, 640_000, window));
}

test "the wall and real relief both end a hold" {
    var b: Backoff = .{};
    const window: u64 = 800_000;
    step(&b, 1, true);
    try std.testing.expectEqual(Gate.hold_started, gate(&b, 750_000, window, false));
    try std.testing.expectEqual(@as(u64, 760_000), threshold(b, 640_000, window)); // capped at 95%
    step(&b, 1, true);
    try std.testing.expectEqual(Gate.compact, gate(&b, 765_000, window, true));

    step(&b, 2, true);
    try std.testing.expectEqual(Gate.hold_started, gate(&b, 650_000, window, false));
    step(&b, 2, false);
    try std.testing.expectEqual(@as(u64, 0), b.resume_at);
    try std.testing.expectEqual(@as(u64, 640_000), threshold(b, 640_000, window));
}

test "a compaction that bought several steps is not a stall" {
    var b: Backoff = .{};
    step(&b, 1, false);
    step(&b, 1, false);
    step(&b, 1, true);
    try std.testing.expectEqual(Gate.compact, gate(&b, 641_000, 800_000, false));
}
