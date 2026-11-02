//! #1137: peer inbox wakes stay ambient. They must not become the newest
//! authoritative user turn, interrupt tool-result continuation, or restart
//! a completed turn. Bodies stay in the inbox until `action=inbox`.

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const peer_context = @import("peer_context.zig");
const peer_inbox = @import("peer_inbox.zig");
const peer_idle = @import("peer_idle.zig");
const session_peer = @import("session_peer.zig");
const session_wake = @import("session_wake.zig");

/// Mid-turn mail only parks. A history wake waits for idle (#1136) and is
/// never placed after a human prompt (that would steal authority). After a
/// final answer, room mail is held for the next human prompt.
pub fn shouldInjectAuthoritative(busy: bool, newly_parked: usize) bool {
    return !busy and newly_parked > 0 and !peer_idle.idleWakeSuppressed() and
        !peer_idle.ambientHeld(peer_inbox.unread() -| newly_parked);
}

/// Same unread generation is exposed at most once. Busy does not block a
/// place *before* the current human prompt — that keeps the human newest.
pub fn shouldPlaceWaiting(_: bool, last_is_human: bool) bool {
    if (!last_is_human or !peer_inbox.pending()) return false;
    return peer_inbox.generation() != peer_idle.placedGeneration();
}

fn lastIsHuman(root: *Agent) bool {
    const items = root.messages.items;
    if (items.len == 0) return false;
    return session_peer.isHumanUserTurn(items[items.len - 1]);
}

/// Keep the human prompt newest. If mail is waiting, put one wake *before*
/// that prompt. If the inbox was cleared, drop a leftover wake the model was
/// never sent; wakes already in the sent history stay put.
pub fn placeWaitingBeforeHuman(root: *Agent) void {
    if (root.sub) return;
    if (lastIsHuman(root)) peer_idle.noteHumanPrompt();
    if (!peer_inbox.pending()) {
        session_peer.dropUnsentInjects(&root.messages);
        peer_idle.markPlaced(peer_inbox.generation());
        return;
    }
    if (!shouldPlaceWaiting(peer_idle.isBusy(), lastIsHuman(root))) return;
    const wake = session_wake.message(root.arena, peer_context.capInject(peer_inbox.formatWake(root.arena))) catch return;
    root.messages.append(wake) catch return;
    const n = root.messages.items.len;
    if (n >= 2) std.mem.swap(std.json.Value, &root.messages.items[n - 1], &root.messages.items[n - 2]);
    peer_idle.markPlaced(peer_inbox.generation());
}

fn dummyRoot(arena: std.mem.Allocator, msgs: std.json.Array) Agent {
    const drop = struct {
        fn emit(_: *anyopaque, _: @import("engine_sink.zig").Stamped) void {}
    };
    const vt = @import("engine_sink.zig").VTable{ .emit = drop.emit, .durable = false };
    var root: Agent = undefined;
    root.sub = false;
    root.arena = arena;
    root.messages = msgs;
    root.sink = .{ .ctx = undefined, .vt = &vt };
    return root;
}

fn userText(arena: std.mem.Allocator, s: []const u8) !std.json.Value {
    return @import("messages.zig").textMessage(arena, "user", s);
}

test "#1137 peer arrival between tool batches is not an authoritative user turn" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "inspect the parser"));
    try msgs.append(try @import("messages.zig").textMessage(a, "assistant", "running tools"));
    var root = dummyRoot(a, msgs);
    peer_idle.noteTurnStart();
    try std.testing.expect(!shouldInjectAuthoritative(peer_idle.isBusy(), 2));
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-peer", .text = "hold gui" }}, &.{});
    placeWaitingBeforeHuman(&root);
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);
    try std.testing.expect(session_peer.isHumanUserTurn(root.messages.items[0]));
    peer_idle.noteTurnEnd();
}

fn humanTurns(msgs: []const std.json.Value) usize {
    var n: usize = 0;
    for (msgs) |m| {
        if (session_peer.isHumanUserTurn(m)) n += 1;
    }
    return n;
}

test "#1137 peer batches during tool work, then a final answer: no new turn, no reopened task" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "inspect the parser"));
    var root = dummyRoot(a, msgs);
    var buf: [256]u8 = undefined;

    // Multi-step tool work: room mail lands at two step boundaries.
    peer_idle.noteTurnStart();
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-a", .text = "I only touch gui/src" }}, &.{});
    try std.testing.expect(!shouldInjectAuthoritative(peer_idle.isBusy(), 1));
    placeWaitingBeforeHuman(&root);
    try root.messages.append(try @import("messages.zig").textMessage(a, "assistant", "reading the lexer"));
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 3, .from_start = 1, .from_session = "s-b", .text = "docs are mine this hour" }}, &.{});
    try std.testing.expect(!shouldInjectAuthoritative(peer_idle.isBusy(), 1));
    placeWaitingBeforeHuman(&root);
    // The human prompt is still the only authoritative user turn.
    try std.testing.expectEqual(@as(usize, 1), humanTurns(root.messages.items));
    try std.testing.expect(!session_peer.isHumanUserTurn(root.messages.items[root.messages.items.len - 1]));

    // The turn ends with an ordinary final answer. The parked room mail must
    // not reopen it, by idle wake or by a history inject.
    try root.messages.append(try @import("messages.zig").textMessage(a, "assistant", "The parser is fine."));
    peer_idle.noteFinalAnswer();
    peer_idle.noteTurnEnd();
    try std.testing.expect(peer_idle.takeIdleWake(std.testing.io, &buf) == null);
    try std.testing.expect(!shouldInjectAuthoritative(false, 1));
    try std.testing.expectEqual(@as(usize, 2), peer_inbox.unread());

    // A later human turn still sees the waiting mail, ahead of its prompt.
    try root.messages.append(try userText(a, "next task"));
    placeWaitingBeforeHuman(&root);
    const items = root.messages.items;
    try std.testing.expect(session_peer.isHumanUserTurn(items[items.len - 1]));
    try std.testing.expect(peer_context.isPeerInject(items[items.len - 2]));
}

test "#1137 duplicate unread state is idempotent" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "inspect the parser"));
    var root = dummyRoot(a, msgs);
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-peer", .text = "hold gui" }}, &.{});
    placeWaitingBeforeHuman(&root);
    const after_first = root.messages.items.len;
    try std.testing.expect(after_first == 2);
    try std.testing.expect(peer_context.isPeerInject(root.messages.items[0]));
    try std.testing.expect(session_peer.isHumanUserTurn(root.messages.items[1]));
    placeWaitingBeforeHuman(&root);
    try std.testing.expectEqual(after_first, root.messages.items.len);
}

test "#1137 peer arrival after attempt_completion does not auto-run" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-peer", .text = "hold gui" }}, &.{});
    peer_idle.noteCompletion();
    try std.testing.expect(peer_idle.isSettled());
    try std.testing.expect(!shouldInjectAuthoritative(false, 1));
    var buf: [256]u8 = undefined;
    try std.testing.expect(peer_idle.takeIdleWake(std.testing.io, &buf) == null);
    try std.testing.expectEqual(@as(usize, 1), peer_inbox.unread());
}

test "#1137 later human turn still sees waiting peer mail" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "next task"));
    var root = dummyRoot(a, msgs);
    _ = peer_inbox.parkHeard(&.{.{ .from_pid = 2, .from_start = 1, .from_session = "s-peer", .text = "hold gui" }}, &.{});
    peer_idle.noteCompletion();
    var wake_buf: [256]u8 = undefined;
    try std.testing.expect(peer_idle.takeIdleWake(std.testing.io, &wake_buf) == null);
    placeWaitingBeforeHuman(&root);
    try std.testing.expect(!peer_idle.idleWakeSuppressed());
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);
    try std.testing.expect(peer_context.isPeerInject(root.messages.items[0]));
    try std.testing.expect(session_peer.isHumanUserTurn(root.messages.items[1]));
    try std.testing.expectEqual(@as(usize, 1), peer_inbox.unread());
    const body = try peer_inbox.takeAll(a);
    peer_idle.noteInboxConsumed();
    try std.testing.expect(std.mem.indexOf(u8, body, "hold gui") != null);
    placeWaitingBeforeHuman(&root);
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try std.testing.expect(session_peer.isHumanUserTurn(root.messages.items[0]));
}

test "a wake the model already answered stays in history after the inbox is read" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sent = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"role":"user","content":"fix the parser"},
        \\ {"role":"assistant","content":"done"},
        \\ {"role":"user","content":"[peer] 1 unread from lead — parked; peer_message action=inbox when relevant"},
        \\ {"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"peer_message","input":{"action":"inbox"}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"[peer message from lead]: also handle lowercase"}]}]
    , .{});
    var root = dummyRoot(a, sent.array);
    // The inbox is empty again: the next step must not rewrite what was sent.
    placeWaitingBeforeHuman(&root);
    try std.testing.expectEqual(@as(usize, 5), root.messages.items.len);
    try std.testing.expect(peer_context.isPeerInject(root.messages.items[2]));
}
