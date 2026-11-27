//! Mid-turn mailbox for ACP `session/answer` while `ask_user` is blocked.
//!
//! ACP owns stdin, so json_inbox never starts. Cancel and answers have to
//! land on this slot from `acp_inbox.accept` without waiting for handleLine.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

var mutex: Io.Mutex = .init;
var ready: Io.Condition = .init;
var io_slot: ?Io = null;
var gpa_slot: ?Allocator = null;
var text: ?[]u8 = null;
var outcome: Outcome = .answered;
var pending = false;
var waiting = false;

/// How the question ended (#1322). Only `answered` carries text. A client
/// that returns the question with no reply is `unanswered`, not a refusal:
/// the user may never have seen it.
pub const Outcome = enum { answered, declined, dismissed, unanswered };

pub const Reply = struct {
    text: []const u8,
    outcome: Outcome,
    cancelled: bool,
};

pub fn attach(io: Io, gpa: Allocator) void {
    io_slot = io;
    gpa_slot = gpa;
    clearLocked();
    pending = false;
    outcome = .answered;
    waiting = false;
}

pub fn detach() void {
    if (io_slot) |io| {
        mutex.lockUncancelable(io);
        clearLocked();
        mutex.unlock(io);
    }
    io_slot = null;
    gpa_slot = null;
    pending = false;
    outcome = .answered;
    waiting = false;
}

fn clearLocked() void {
    if (text) |t| {
        if (gpa_slot) |gpa| gpa.free(t);
        text = null;
    }
}

pub fn wait(arena: Allocator) !Reply {
    const lock_io = io_slot orelse return .{ .text = "", .outcome = .dismissed, .cancelled = true };
    mutex.lockUncancelable(lock_io);
    defer mutex.unlock(lock_io);
    waiting = true;
    defer waiting = false;
    // A client can cancel after seeing the question but before this waiter
    // acquires the mutex. The inbox latches turn cancellation even if nobody
    // is waiting yet, so check it alongside the mailbox predicate.
    const cancelled = &@import("agent.zig").Agent.esc_cancel;
    while (!pending and !cancelled.load(.acquire)) ready.waitUncancelable(lock_io, &mutex);
    pending = false;
    const how: Outcome = if (cancelled.load(.acquire)) .dismissed else outcome;
    outcome = .answered;
    const src = text;
    text = null;
    defer if (src) |t| if (gpa_slot) |gpa| gpa.free(t);
    if (how != .answered) return .{ .text = "", .outcome = how, .cancelled = true };
    return .{ .text = try arena.dupe(u8, src orelse ""), .outcome = .answered, .cancelled = false };
}

/// An answer, or a user cancel. A blank non-cancelled answer is refused.
pub fn reply(answer: []const u8, cancel: bool) bool {
    if (!cancel and std.mem.trim(u8, answer, " \t\r\n").len == 0) return false;
    return post(if (cancel) .dismissed else .answered, answer);
}

/// The question ended without an answer (`declined`, `dismissed`, `unanswered`).
pub fn replyWithout(how: Outcome) bool {
    std.debug.assert(how != .answered);
    return post(how, "");
}

fn post(how: Outcome, answer: []const u8) bool {
    const io = io_slot orelse return false;
    const gpa = gpa_slot orelse return false;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    clearLocked();
    outcome = how;
    if (how == .answered) text = gpa.dupe(u8, answer) catch null;
    pending = true;
    ready.broadcast(io);
    return true;
}

/// session/cancel while ask_user is blocked: wake the waiter, ignore otherwise.
pub fn cancelIfWaiting() void {
    const io = io_slot orelse return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (!waiting) return;
    clearLocked();
    outcome = .dismissed;
    pending = true;
    ready.broadcast(io);
}

const testing = std.testing;

test "reply before wait is not lost" {
    attach(testing.io, testing.allocator);
    defer detach();
    try testing.expect(reply("yes", false));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try wait(arena_state.allocator());
    try testing.expectEqualStrings("yes", got.text);
    try testing.expect(!got.cancelled);
}

test "empty non-cancelled reply is rejected" {
    attach(testing.io, testing.allocator);
    defer detach();
    try testing.expect(!reply("", false));
    try testing.expect(!reply("   ", false));
    try testing.expect(reply("", true));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try wait(arena_state.allocator());
    try testing.expect(got.cancelled);
}

test "cancelIfWaiting is a no-op when nobody is blocked" {
    attach(testing.io, testing.allocator);
    defer detach();
    cancelIfWaiting();
    try testing.expect(reply("later", false));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try wait(arena_state.allocator());
    try testing.expectEqualStrings("later", got.text);
}

test "ACP question observes cancellation before wait and accepts the next turn's answer" {
    const cancel_source = @import("cancel_source.zig");
    cancel_source.clear();
    defer cancel_source.clear();
    attach(testing.io, testing.allocator);
    defer detach();

    cancel_source.cancel(.acp_cancel);
    cancelIfWaiting();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cancelled = try wait(arena.allocator());
    try testing.expect(cancelled.cancelled);
    try testing.expectEqual(Outcome.dismissed, cancelled.outcome);

    cancel_source.clear();
    try testing.expect(reply("next answer", false));
    const next = try wait(arena.allocator());
    try testing.expect(!next.cancelled);
    try testing.expectEqualStrings("next answer", next.text);
}
