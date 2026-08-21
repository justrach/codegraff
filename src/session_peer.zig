//! Durable peer-channel state on the session file (ADR 0014).
//!
//! Codex keeps a thread cursor and reuses `prompt_cache_key` across compact
//! and resume. OpenCode pages session parts from a cursor and does not replay
//! side-channel chatter into the next request. Claude Code's SendMessage inbox
//! lives on disk so resume can pull. Graff's room offsets and parked inbox
//! used to be process-local: `/resume` re-drained the last 10 JSONL lines,
//! re-injected a `[peer]` wake, and titled the session after the firehose.
//!
//! The session file now carries the byte cursors and the parked bodies.
//! History on disk drops the perishable wakes (ADR 0004). Resume restores
//! the mailbox; it does not replay the room.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const main_mod = @import("main.zig");
const peer_channel = @import("peer_channel.zig");
const peer_context = @import("peer_context.zig");
const peer_inbox = @import("peer_inbox.zig");
const presence = @import("presence.zig");
const session_writer = @import("session_writer.zig");

/// A human user turn — not a `[peer]` / `[presence]` inject. Title, meaningful-
/// state, and "first prompt" all use this so a wake cannot mint a session.
pub fn isHumanUserTurn(m: Value) bool {
    if (m != .object) return false;
    const role = m.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    return !peer_context.isPeerInject(m);
}

/// Messages written to `.session.json`: wakes stay out. The transcript still
/// recorded them when they first entered history; compact / resume must not
/// keep paying for them on every later request.
pub fn messagesForSave(arena: Allocator, items: []const Value) !std.json.Array {
    var out = std.json.Array.init(arena);
    for (items) |m| {
        if (peer_context.isPeerInject(m)) continue;
        try out.append(m);
    }
    return out;
}

pub fn dropAllInjects(msgs: *std.json.Array) void {
    var i: usize = 0;
    while (i < msgs.items.len) {
        if (peer_context.isPeerInject(msgs.items[i])) {
            _ = msgs.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn mixFingerprint(f: *session_writer.Fingerprint) void {
    const cur = presence.roomCursor();
    f.num(cur.chan);
    f.num(cur.device);
    peer_inbox.mixFingerprint(f);
}

pub fn writeFields(s: *std.json.Stringify) !void {
    const cur = presence.roomCursor();
    try s.objectField("chan_off");
    try s.write(cur.chan);
    try s.objectField("device_off");
    try s.write(cur.device);
    try s.objectField("peer_inbox");
    try peer_inbox.writeJson(s);
}

fn u64Field(obj: std.json.ObjectMap, name: []const u8) ?u64 {
    const v = obj.get(name) orelse return null;
    if (v != .integer or v.integer < 0) return null;
    return @intCast(v.integer);
}

fn injectWake(root: *Agent) void {
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = peer_context.capInject(peer_inbox.formatWake(root.arena)) }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
}

/// After messages are restored: drop leftover wakes, adopt the room cursor
/// (or seek to tail on a legacy file / `-p` one-shot), restore the mailbox,
/// and inject at most one wake when something is still unread.
pub fn restore(root: *Agent, obj: std.json.ObjectMap) void {
    dropAllInjects(&root.messages);
    // One-shots must not hear predating chatter (ADR 0004 measured ~4k tokens
    // of stale room on the first step). Inbox restore would re-surface it.
    if (main_mod.unattended) {
        presence.seekRoomsToTail(root.io, root.arena);
        peer_inbox.clear();
        return;
    }
    if (obj.get("chan_off") != null or obj.get("device_off") != null) {
        presence.adoptRoomCursor(.{
            .chan = u64Field(obj, "chan_off") orelse 0,
            .device = u64Field(obj, "device_off") orelse 0,
        });
        // Catch-up after downtime is live traffic, not a first-join backlog.
        // Without this, deliverInbound would drop everything past the last 10.
        peer_channel.markCaughtUp();
    } else {
        // Pre-0014 file: no cursor. Seek rather than replay the last 10 lines.
        presence.seekRoomsToTail(root.io, root.arena);
    }
    if (obj.get("peer_inbox")) |v| peer_inbox.restoreJson(v);
    if (peer_inbox.unread() > 0) injectWake(root);
}

const testing = std.testing;

fn userText(arena: Allocator, s: []const u8) !Value {
    const raw = try std.fmt.allocPrint(arena, "{{\"role\":\"user\",\"content\":\"{s}\"}}", .{s});
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{});
}

fn asstText(arena: Allocator, s: []const u8) !Value {
    const raw = try std.fmt.allocPrint(arena, "{{\"role\":\"assistant\",\"content\":\"{s}\"}}", .{s});
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{});
}

test "isHumanUserTurn: peer wakes are not a human prompt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(isHumanUserTurn(try userText(a, "keep going")));
    try testing.expect(!isHumanUserTurn(try userText(a, "[peer] 1 unread from s-2 — peer_message action=inbox")));
    try testing.expect(!isHumanUserTurn(try userText(a, "[peer message from a]: hold off")));
    try testing.expect(!isHumanUserTurn(try asstText(a, "keep going")));
}

test "messagesForSave / dropAllInjects: wakes leave the durable history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var live = std.json.Array.init(a);
    try live.append(try userText(a, "fix the parser"));
    try live.append(try userText(a, "[peer] 2 unread from s-a — peer_message action=inbox"));
    try live.append(try asstText(a, "on it"));
    try live.append(try userText(a, "[presence] 1 other live session"));
    const saved = try messagesForSave(a, live.items);
    try testing.expectEqual(@as(usize, 2), saved.items.len);
    try testing.expectEqualStrings("fix the parser", saved.items[0].object.get("content").?.string);
    try testing.expectEqualStrings("on it", saved.items[1].object.get("content").?.string);
    dropAllInjects(&live);
    try testing.expectEqual(@as(usize, 2), live.items.len);
}

test "writeFields / restoreJson: inbox bodies survive a process restart" {
    peer_inbox.clear();
    defer peer_inbox.clear();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const presence_chan = @import("presence_chan.zig");
    const local = [_]presence_chan.Message{.{ .from_session = "s-a", .text = "hold gui/src", .to = "" }};
    const device = [_]presence_chan.Message{.{ .from_session = "s-b", .text = "your turn", .to = "me" }};
    try testing.expectEqual(@as(usize, 2), peer_inbox.parkHeard(&local, &device));

    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try writeFields(&s);
    try s.endObject();
    const parsed = try std.json.parseFromSliceLeaky(Value, a, aw.writer.buffered(), .{});
    try testing.expect(parsed.object.get("chan_off") != null);
    try testing.expect(parsed.object.get("device_off") != null);

    peer_inbox.clear();
    try testing.expectEqual(@as(usize, 0), peer_inbox.unread());
    peer_inbox.restoreJson(parsed.object.get("peer_inbox").?);
    try testing.expectEqual(@as(usize, 2), peer_inbox.unread());
    const body = peer_inbox.takeAll(a);
    try testing.expect(std.mem.indexOf(u8, body, "hold gui/src") != null);
    try testing.expect(std.mem.indexOf(u8, body, "your turn") != null);
}

test "legacy session without cursor fields seeks rather than replaying (restore path)" {
    // restore() with no chan_off seeks; seek is a no-op without a registry.
    // What we can prove here: leftover wakes are stripped and an empty inbox
    // does not mint a new wake.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    peer_inbox.clear();
    defer peer_inbox.clear();
    presence.resetRoomCursorForTest();
    defer presence.resetRoomCursorForTest();
    var root: Agent = undefined;
    root.arena = a;
    root.io = testing.io;
    root.messages = std.json.Array.init(a);
    try root.messages.append(try userText(a, "real prompt"));
    try root.messages.append(try userText(a, "[peer] 3 unread from old — peer_message action=inbox"));
    const empty = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    restore(&root, empty.object);
    try testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try testing.expect(isHumanUserTurn(root.messages.items[0]));
}
