//! #1001 / #1007: idle roots start a turn when the durable room has unread
//! peer mail. Same latch on line REPL, TUI, and graff acp (GUI). JSONL drain
//! is the source of truth; Accord Unix (ADR 0134) is the standing live wake.
//! One auto-turn per new unread batch — inbox consume resets.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const peer_inbox = @import("peer_inbox.zig");
const peer_target = @import("peer_target.zig");
const presence = @import("presence.zig");
const presence_chan = @import("presence_chan.zig");

var last_woken_unread: usize = 0;

pub fn resetForTest() void {
    last_woken_unread = 0;
}

fn ingest(io: Io, arena: Allocator) void {
    const local = presence.drainChannel(io, arena);
    const device = presence.drainDevice(io, arena);
    const own = presence.ownSession();
    var tree: std.ArrayList(presence.Message) = .empty;
    for (local) |m| {
        if (peer_target.treeHears(m, own)) tree.append(arena, m) catch break;
    }
    var heard: std.ArrayList(presence.Message) = .empty;
    for (device) |m| {
        if (peer_target.deviceHears(m, own)) heard.append(arena, m) catch break;
    }
    _ = peer_inbox.parkHeard(tree.items, heard.items);
}

/// Idle TUI auto-turn. Null when nothing new is parked. Uses a scratch
/// buffer so a spent Agent arena cannot hide new JSONL. Does not inject
/// history — `runTurn`'s deliverInbound handles leftover room bytes.
pub fn takeIdleWake(io: Io, buf: []u8) ?[]const u8 {
    var scratch: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const arena = fba.allocator();
    ingest(io, arena);
    const n = peer_inbox.unread();
    if (n == 0 or n <= last_woken_unread) return null;
    last_woken_unread = n;
    const wake = peer_inbox.formatWake(arena);
    if (wake.len == 0) return null;
    const copy = @min(wake.len, buf.len);
    @memcpy(buf[0..copy], wake[0..copy]);
    return buf[0..copy];
}

/// `action=inbox` consumed the batch — a later peer can wake again.
pub fn noteInboxConsumed() void {
    last_woken_unread = 0;
}

test "#1001 idle wake fires once per new unread batch" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [256]u8 = undefined;
    try std.testing.expect(takeIdleWake(io, &buf) == null);

    const msg: presence_chan.Message = .{
        .from_pid = 2,
        .from_start = 1,
        .from_session = "s-peer",
        .text = "hold gui/src",
        .to = "s-me",
    };
    try std.testing.expectEqual(@as(usize, 1), peer_inbox.parkHeard(&.{msg}, &.{}));
    const first = takeIdleWake(io, &buf) orelse return error.ExpectedWake;
    try std.testing.expect(std.mem.indexOf(u8, first, "[peer]") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "inbox") != null);
    try std.testing.expectEqual(@as(usize, 1), peer_inbox.unread());
    try std.testing.expect(takeIdleWake(io, &buf) == null);

    _ = try peer_inbox.takeAll(arena);
    noteInboxConsumed();
    try std.testing.expect(takeIdleWake(io, &buf) == null);
}

test "#1001 more mail after a wake can fire again" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    const io = std.testing.io;
    var buf: [256]u8 = undefined;
    const a: presence_chan.Message = .{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "one" };
    const b: presence_chan.Message = .{ .from_pid = 3, .from_start = 1, .from_session = "s-b", .text = "two" };
    _ = peer_inbox.parkHeard(&.{a}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) != null);
    try std.testing.expect(takeIdleWake(io, &buf) == null);
    _ = peer_inbox.parkHeard(&.{b}, &.{});
    const again = takeIdleWake(io, &buf) orelse return error.ExpectedSecond;
    try std.testing.expect(std.mem.indexOf(u8, again, "[peer]") != null);
}
