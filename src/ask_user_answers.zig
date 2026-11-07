//! ask_user answers from the current turn, as sources for note_constraint
//! (#1342). A standing rule the user types into an ask_user answer is as
//! user-authored as one in their message, but the answer arrives as a tool
//! result, so the verbatim check never saw it. Answers are keyed to the user
//! message they were asked under; a later user turn makes them stale.

const std = @import("std");

const slots = 8;
const max_bytes = 4096;

const Entry = struct { turn: u64 = 0, len: usize = 0, buf: [max_bytes]u8 = undefined };
var ring: [slots]Entry = @splat(.{});
var next: usize = 0;
var lock: std.atomic.Value(bool) = .init(false);
/// Every answer ever recorded, never reset (#1520): an answer is a user scope
/// change that todo_write's cancel guard must see, like a newer user message.
var answered: std.atomic.Value(u64) = .init(0);

pub fn answeredCount() u64 {
    return answered.load(.acquire);
}

fn acquire() void {
    while (lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn release() void {
    lock.store(false, .release);
}

/// The turn an answer belongs to: the user message it was asked under.
pub fn turnKey(user_text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x1342, user_text);
}

/// Record a user's answer. Longer answers keep their first 4 KiB; a rule
/// past that point stays unrecordable rather than being accepted on a prefix.
pub fn record(turn: u64, answer: []const u8) void {
    acquire();
    defer release();
    const n = @min(answer.len, max_bytes);
    ring[next] = .{ .turn = turn, .len = n };
    @memcpy(ring[next].buf[0..n], answer[0..n]);
    next = (next + 1) % slots;
    _ = answered.fetchAdd(1, .acq_rel);
}

pub fn reset() void {
    acquire();
    defer release();
    ring = @splat(.{});
    next = 0;
}

/// Whether `accept(answer, text)` holds for any answer given this turn.
pub fn any(turn: u64, text: []const u8, accept: *const fn ([]const u8, []const u8) bool) bool {
    acquire();
    defer release();
    for (&ring) |*e| {
        if (e.len == 0 or e.turn != turn) continue;
        if (accept(e.buf[0..e.len], text)) return true;
    }
    return false;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "answers count only for the turn they were given in" {
    reset();
    defer reset();
    const turn = turnKey("set up the release");
    record(turn, "Always run the full suite before tagging. Skip it just this once.");
    try std.testing.expect(any(turn, "Always run the full suite", contains));
    try std.testing.expect(!any(turnKey("a later message"), "Always run the full suite", contains));
    try std.testing.expect(!any(turn, "never tag", contains));
}
