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
var last_placed_gen: u64 = 0;
var suppress_idle_wake: bool = false;
var waiting_for_input: bool = false;
var settled: bool = false;
var turn_busy: std.atomic.Value(bool) = .init(false);

pub fn resetForTest() void {
    last_woken_unread = 0;
    last_placed_gen = 0;
    suppress_idle_wake = false;
    waiting_for_input = false;
    settled = false;
    turn_busy.store(false, .release);
}

/// Root `runTurn` latch. Idle auto-turn (#1001 / #1007) and mid-turn
/// `deliverInbound` injects stay off while a prompt is in flight (#1136).
pub fn noteTurnStart() void {
    turn_busy.store(true, .release);
}

pub fn noteTurnEnd() void {
    turn_busy.store(false, .release);
}

pub fn isBusy() bool {
    return turn_busy.load(.acquire);
}

/// Accepted `attempt_completion` ends the task the same way a final answer
/// does (ADR 0311): room mail stays parked for the next human prompt, and
/// only mail addressed to this session can start a turn. Which of the two a
/// model happens to end with must not decide whether a peer's follow-up is
/// heard.
pub fn noteCompletion() void {
    settled = true;
}

/// A root turn ended with an ordinary final answer (#1137). The human task
/// is done: mail posted to the folder's room is ambient coordination and no
/// longer starts a turn on its own. It stays parked and readable, and the
/// next human prompt sees it. Mail addressed to this session (a DM, or the
/// user's own `/tell`) is an explicit request and still wakes, so peers can
/// still hand work over.
pub fn noteFinalAnswer() void {
    settled = true;
}

/// The last task ended (final answer or attempt_completion) and no human
/// prompt has come since.
pub fn isSettled() bool {
    return settled;
}

/// Whether the parked mail at or after `from` may start a turn by itself.
fn mayStartTurn(from: usize) bool {
    if (settled) return peer_inbox.anyAddressedNeedsTurnFrom(from);
    return peer_inbox.anyNeedsTurnFrom(from);
}

/// Mail at or after `from` is held for the next human prompt: the last task
/// ended with an answer and none of it is addressed to this session.
pub fn ambientHeld(from: usize) bool {
    return settled and !peer_inbox.anyAddressedNeedsTurnFrom(from);
}

/// A handoff waits for human input without completing a goal. Peer mail
/// stays readable, but cannot immediately reopen the yielded turn.
pub fn noteHandoff() void {
    suppress_idle_wake = true;
    waiting_for_input = true;
}

pub fn waitingForInput() bool {
    return waiting_for_input;
}

/// A later human prompt re-opens idle auto-turn.
pub fn noteHumanPrompt() void {
    suppress_idle_wake = false;
    waiting_for_input = false;
    settled = false;
}

pub fn idleWakeSuppressed() bool {
    return suppress_idle_wake;
}

pub fn markPlaced(gen: u64) void {
    last_placed_gen = gen;
    last_woken_unread = peer_inbox.unread();
}

pub fn placedGeneration() u64 {
    return last_placed_gen;
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
    if (isBusy()) return null;
    var scratch: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const arena = fba.allocator();
    ingest(io, arena);
    if (@import("daddy.zig").takeIdleText(arena, buf)) |t| {
        last_woken_unread = peer_inbox.unread();
        return t;
    }
    if (suppress_idle_wake) return null;
    const n = peer_inbox.unread();
    if (n == 0 or n <= last_woken_unread) return null;
    // #1137: fyi-only news stays parked for the next turn; it starts none.
    // After a final answer only mail addressed to this session does.
    if (!mayStartTurn(last_woken_unread)) return null;
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
    last_placed_gen = 0;
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

test "ADR 0311: after attempt_completion only mail addressed to this session wakes" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    var buf: [256]u8 = undefined;
    noteCompletion();
    try std.testing.expect(isSettled() and !idleWakeSuppressed());
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-peer", .text = "room chatter" }}, &.{});
    try std.testing.expect(takeIdleWake(std.testing.io, &buf) == null);
    const msg: presence_chan.Message = .{
        .from_pid = 2,
        .from_start = 1,
        .from_session = "s-peer",
        .text = "hold the tree",
        .to = "s-me",
    };
    _ = peer_inbox.parkHeard(&.{msg}, &.{});
    const wake = takeIdleWake(std.testing.io, &buf) orelse return error.ExpectedAddressedWake;
    try std.testing.expect(std.mem.indexOf(u8, wake, "[peer]") != null);
}

test "#1136 idle wake is silent while a root turn is in flight" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    var buf: [256]u8 = undefined;
    const msg: presence_chan.Message = .{
        .from_pid = 2,
        .from_start = 1,
        .from_session = "s-peer",
        .text = "hold the tree",
        .to = "s-me",
    };
    _ = peer_inbox.parkHeard(&.{msg}, &.{});
    noteTurnStart();
    try std.testing.expect(isBusy());
    try std.testing.expect(takeIdleWake(std.testing.io, &buf) == null);
    noteTurnEnd();
    const wake = takeIdleWake(std.testing.io, &buf) orelse return error.ExpectedWakeAfterIdle;
    try std.testing.expect(std.mem.indexOf(u8, wake, "[peer]") != null);
}

test "#1137 same unread generation does not idle-wake twice" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    var buf: [256]u8 = undefined;
    const msg: presence_chan.Message = .{
        .from_pid = 2,
        .from_start = 1,
        .from_session = "s-peer",
        .text = "hold the tree",
        .to = "s-me",
    };
    _ = peer_inbox.parkHeard(&.{msg}, &.{});
    try std.testing.expect(takeIdleWake(std.testing.io, &buf) != null);
    try std.testing.expect(takeIdleWake(std.testing.io, &buf) == null);
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

test "#1137 fyi mail stays parked without a turn; a request after it wakes" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    const fyi: presence_chan.Message = .{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "[fyi] I only touch gui/src" };
    const fyi2: presence_chan.Message = .{ .from_pid = 3, .from_start = 1, .from_session = "s-b", .text = "  [fyi] docs done" };
    _ = peer_inbox.parkHeard(&.{ fyi, fyi2 }, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) == null);
    try std.testing.expectEqual(@as(usize, 2), peer_inbox.unread()); // still readable
    const ask: presence_chan.Message = .{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "can you rerun the tests?" };
    _ = peer_inbox.parkHeard(&.{ask}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) != null);
    // An fyi after the woken batch does not wake again.
    _ = peer_inbox.parkHeard(&.{fyi}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) == null);
    const read = try peer_inbox.takeAll(arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, read, "[fyi] updates need no reply") != null);
}

test "#1137 room mail after an ordinary final answer stays parked; a DM still wakes" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    // The human's task ended with an ordinary answer, not attempt_completion.
    noteTurnStart();
    noteFinalAnswer();
    noteTurnEnd();
    try std.testing.expect(!idleWakeSuppressed());
    // Two unmarked scope updates posted to the folder's room, read in between.
    const scope: presence_chan.Message = .{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "I only touch gui/src" };
    _ = peer_inbox.parkHeard(&.{scope}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) == null);
    try std.testing.expectEqual(@as(usize, 1), peer_inbox.unread()); // still readable
    _ = try peer_inbox.takeAll(arena_state.allocator());
    noteInboxConsumed();
    const other: presence_chan.Message = .{ .from_pid = 3, .from_start = 1, .from_session = "s-b", .text = "docs are mine this hour" };
    _ = peer_inbox.parkHeard(&.{other}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) == null);
    // A request addressed to this session is explicit: it starts a turn.
    const ask: presence_chan.Message = .{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "can you rerun the parser tests?", .to = "s-me" };
    _ = peer_inbox.parkHeard(&.{ask}, &.{});
    const wake = takeIdleWake(io, &buf) orelse return error.ExpectedDirectWake;
    try std.testing.expect(std.mem.indexOf(u8, wake, "[peer]") != null);
    // An fyi DM never does.
    _ = peer_inbox.takeAll(arena_state.allocator()) catch unreachable;
    noteInboxConsumed();
    const fyi_dm: presence_chan.Message = .{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "[fyi] done with the parser", .to = "s-me" };
    _ = peer_inbox.parkHeard(&.{fyi_dm}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) == null);
    // The next human prompt starts a new task: room mail can wake again.
    noteHumanPrompt();
    _ = peer_inbox.parkHeard(&.{scope}, &.{});
    try std.testing.expect(takeIdleWake(io, &buf) != null);
}

test "#1137 a turn that ended without an answer still wakes on room mail" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    var buf: [256]u8 = undefined;
    // Interrupted or failed: no final answer, nothing settled.
    noteTurnStart();
    noteTurnEnd();
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "can someone rerun the tests?" }}, &.{});
    try std.testing.expect(takeIdleWake(std.testing.io, &buf) != null);
}

test "#1137 every root final answer settles the turn" {
    const src = @embedFile("agent_turn.zig");
    const start = std.mem.indexOf(u8, src, "if (done) |final_text| {") orelse return error.MissingPin;
    const body = src[start..];
    // The ordinary final settles once, right before it returns the answer.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "settleFinal(self);"));
    const settle = std.mem.indexOf(u8, body, "settleFinal(self);").?;
    try std.testing.expect(std.mem.indexOfPos(u8, body, settle, "return review_deadline.finish(text);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "noteFinalAnswer()") != null);
}

test "daddy idle wake fires after attempt_completion" {
    peer_inbox.resetForTest();
    resetForTest();
    defer {
        peer_inbox.resetForTest();
        resetForTest();
    }
    var buf: [256]u8 = undefined;
    noteCompletion();
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-dad", .text = "[daddy] switch to the tests" }}, &.{});
    const wake = takeIdleWake(std.testing.io, &buf) orelse return error.ExpectedDaddyAfterCompletion;
    try std.testing.expect(std.mem.indexOf(u8, wake, "[daddy]") != null);
}
