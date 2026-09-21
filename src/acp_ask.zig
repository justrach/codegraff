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
var cancelled = false;
var pending = false;
var waiting = false;

pub const Reply = struct {
    text: []const u8,
    cancelled: bool,
};

pub fn attach(io: Io, gpa: Allocator) void {
    io_slot = io;
    gpa_slot = gpa;
    clearLocked();
    pending = false;
    cancelled = false;
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
    cancelled = false;
    waiting = false;
}

fn clearLocked() void {
    if (text) |t| {
        if (gpa_slot) |gpa| gpa.free(t);
        text = null;
    }
}

pub fn wait(arena: Allocator) !Reply {
    const lock_io = io_slot orelse return .{ .text = "", .cancelled = true };
    mutex.lockUncancelable(lock_io);
    defer mutex.unlock(lock_io);
    waiting = true;
    defer waiting = false;
    while (!pending) ready.waitUncancelable(lock_io, &mutex);
    pending = false;
    const was = cancelled;
    cancelled = false;
    const src = text;
    text = null;
    defer if (src) |t| if (gpa_slot) |gpa| gpa.free(t);
    if (was) return .{ .text = "", .cancelled = true };
    return .{ .text = try arena.dupe(u8, src orelse ""), .cancelled = false };
}

pub fn reply(answer: []const u8, cancel: bool) bool {
    if (!cancel and std.mem.trim(u8, answer, " \t\r\n").len == 0) return false;
    const io = io_slot orelse return false;
    const gpa = gpa_slot orelse return false;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    clearLocked();
    cancelled = cancel;
    if (!cancel) text = gpa.dupe(u8, answer) catch null;
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
    cancelled = true;
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
