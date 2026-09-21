//! #1137: ambient peer wakes are mailbox state, not a new task.
//!
//! `deliverInbound` used to append a user-role `[peer]` wake at every root
//! step, including tool-result continuations and after `attempt_completion`.
//! The model then treated coordination traffic as the newest instruction.
//!
//! Rules:
//!   - one inject per mailbox generation (unread + bodies)
//!   - no inject while tools are being continued
//!   - no idle auto-turn after a completed attempt until a human prompt
//!   - `action=inbox` retires stale `[peer]` injects
//!
//! Daddy directives (`daddy.zig`) are explicit control and use a separate
//! path; they are not these ambient wakes.

const std = @import("std");
const Value = std.json.Value;

const peer_context = @import("peer_context.zig");
const peer_inbox = @import("peer_inbox.zig");
const session_wake = @import("session_wake.zig");

pub const Decision = enum { skip_empty, skip_coalesced, skip_continuation, inject };

var last_injected_gen: u64 = 0;
var suppress_idle: bool = false;

pub fn resetForTest() void {
    last_injected_gen = 0;
    suppress_idle = false;
}

pub fn lastInjected() u64 {
    return last_injected_gen;
}

pub fn markInjected(generation: u64) void {
    last_injected_gen = generation;
}

pub fn noteCompleted() void {
    suppress_idle = true;
}

pub fn idlePeerAllowed() bool {
    return !suppress_idle;
}

fn isHumanUserTurn(m: Value) bool {
    if (m != .object) return false;
    const role = m.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    return !session_wake.isNotice(m) and !peer_context.isPeerInject(m);
}

/// A later human prompt lifts the post-completion idle latch.
pub fn noteTurnStart(messages: []const Value) void {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const m = messages[i];
        if (session_wake.isNotice(m) or peer_context.isPeerInject(m)) continue;
        if (isHumanUserTurn(m)) suppress_idle = false;
        return;
    }
}

/// Last non-wake message is a tool result or an assistant tool-call batch.
pub fn isMidToolContinuation(messages: []const Value) bool {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const m = messages[i];
        if (session_wake.isNotice(m) or peer_context.isPeerInject(m)) continue;
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role != .string) continue;
        if (std.mem.eql(u8, role.string, "tool")) return true;
        if (std.mem.eql(u8, role.string, "assistant")) {
            if (m.object.get("tool_calls")) |tc| {
                if (tc == .array and tc.array.items.len > 0) return true;
            }
        }
        return false;
    }
    return false;
}

pub fn decide(messages: []const Value, generation: u64) Decision {
    if (generation == 0 or !peer_inbox.pending()) return .skip_empty;
    if (generation == last_injected_gen) return .skip_coalesced;
    if (isMidToolContinuation(messages)) return .skip_continuation;
    return .inject;
}

/// Keep the human task as the newest authoritative user turn.
pub fn insertWake(messages: *std.json.Array, wake: Value) !void {
    if (messages.items.len > 0 and isHumanUserTurn(messages.items[messages.items.len - 1])) {
        try messages.insert(messages.items.len - 1, wake);
    } else {
        try messages.append(wake);
    }
}

/// Inbox consume retires the stale `[peer]` lines for this mailbox generation.
pub fn retireInjects(messages: *std.json.Array) void {
    var i: usize = 0;
    while (i < messages.items.len) {
        if (peer_context.isPeerInject(messages.items[i])) {
            _ = messages.orderedRemove(i);
            continue;
        }
        i += 1;
    }
    last_injected_gen = 0;
}

fn userText(arena: std.mem.Allocator, s: []const u8) !Value {
    return try @import("messages.zig").textMessage(arena, "user", s);
}

fn asstTools(arena: std.mem.Allocator) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"function\":{\"name\":\"read_file\"}}]}", .{});
}

fn toolResult(arena: std.mem.Allocator) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, "{\"role\":\"tool\",\"name\":\"read_file\",\"content\":\"ok\"}", .{});
}

test "#1137 mid-tool continuation is not an authoritative user turn" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    peer_inbox.resetForTest();
    defer peer_inbox.resetForTest();
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-peer", .text = "hold the tree" }}, &.{});

    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "inspect src/peer_channel.zig"));
    try msgs.append(try asstTools(a));
    try msgs.append(try toolResult(a));
    try std.testing.expect(isMidToolContinuation(msgs.items));
    const gen = peer_inbox.generation();
    try std.testing.expectEqual(Decision.skip_continuation, decide(msgs.items, gen));
    try std.testing.expectEqualStrings("inspect src/peer_channel.zig", @import("messages.zig").latestUserText(msgs.items));
}

test "#1137 same mailbox generation is idempotent" {
    resetForTest();
    defer resetForTest();
    peer_inbox.resetForTest();
    defer peer_inbox.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-a", .text = "one" }}, &.{});
    const gen = peer_inbox.generation();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "keep going"));
    try std.testing.expectEqual(Decision.inject, decide(msgs.items, gen));
    markInjected(gen);
    try std.testing.expectEqual(Decision.skip_coalesced, decide(msgs.items, gen));
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-a", .text = "one" }}, &.{});
    try std.testing.expectEqual(Decision.skip_coalesced, decide(msgs.items, peer_inbox.generation()));
}

test "#1137 completed turn does not idle-wake on ambient mail" {
    resetForTest();
    defer resetForTest();
    peer_inbox.resetForTest();
    defer peer_inbox.resetForTest();
    try std.testing.expect(idlePeerAllowed());
    noteCompleted();
    try std.testing.expect(!idlePeerAllowed());
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-b", .text = "ping" }}, &.{});
    try std.testing.expect(!idlePeerAllowed());
}

test "#1137 a later human turn lifts the latch and can see parked mail" {
    resetForTest();
    defer resetForTest();
    peer_inbox.resetForTest();
    defer peer_inbox.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    noteCompleted();
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-c", .text = "waiting" }}, &.{});
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "what is left in the inbox?"));
    noteTurnStart(msgs.items);
    try std.testing.expect(idlePeerAllowed());
    try std.testing.expect(peer_inbox.pending());
    const wake = peer_inbox.formatWake(a);
    try std.testing.expect(std.mem.indexOf(u8, wake, "unread") != null);
    try std.testing.expectEqual(Decision.inject, decide(msgs.items, peer_inbox.generation()));
}

test "#1137 insertWake keeps the human as the newest user turn" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "do the refactor"));
    const wake = try session_wake.message(a, "[peer] 1 unread from s-x — parked; peer_message action=inbox when relevant");
    try insertWake(&msgs, wake);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expect(peer_context.isPeerInject(msgs.items[0]));
    try std.testing.expect(isHumanUserTurn(msgs.items[1]));
    try std.testing.expectEqualStrings("do the refactor", @import("messages.zig").latestUserText(msgs.items));
}

test "#1137 inbox consume retires stale wakes" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try userText(a, "task"));
    try msgs.append(try session_wake.message(a, "[peer] 1 unread from s-x — parked; peer_message action=inbox when relevant"));
    markInjected(42);
    retireInjects(&msgs);
    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);
    try std.testing.expectEqual(@as(u64, 0), lastInjected());
    try std.testing.expectEqualStrings("task", msgs.items[0].object.get("content").?.string);
}

test "empty mailbox does not inject" {
    resetForTest();
    defer resetForTest();
    peer_inbox.resetForTest();
    defer peer_inbox.resetForTest();
    try std.testing.expectEqual(Decision.skip_empty, decide(&.{}, 0));
}
