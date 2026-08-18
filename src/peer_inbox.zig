//! Process-local parked inbound for `peer_message` (Claude-style pull).
//!
//! The JSONL room is the log. `deliverInbound` does not copy bodies into
//! history — it parks a small ring here and injects a one-line `[peer]` wake.
//! `action=inbox` reads+clears; `action=list` is who is live. Bodies never
//! ride every later request unless the model asked. A standing liaison is
//! still the wrong shape (ADR 0004): this is a mailbox, not another model.

const std = @import("std");
const Allocator = std.mem.Allocator;

const peer_context = @import("peer_context.zig");
const presence_chan = @import("presence_chan.zig");
const worktree_lease = @import("worktree_lease.zig");

const Message = presence_chan.Message;
const Owner = worktree_lease.Owner;

/// How many inbound bodies the process will hold. Older ones fall out; the
/// room still has them on disk.
pub const inbox_cap: usize = 8;

const from_cap: usize = 48;
const text_cap: usize = 200;

const Parked = struct {
    from: [from_cap]u8 = undefined,
    from_len: u8 = 0,
    text: [text_cap]u8 = undefined,
    text_len: u8 = 0,
    dm: bool = false,
    device: bool = false,
};

var g_items: [inbox_cap]Parked = undefined;
var g_head: usize = 0;
var g_len: usize = 0;

pub fn resetForTest() void {
    g_head = 0;
    g_len = 0;
}

pub fn unread() usize {
    return g_len;
}

fn copyInto(dest: []u8, src: []const u8) u8 {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return @intCast(n);
}

fn parkOne(from: []const u8, text: []const u8, dm: bool, device: bool) void {
    if (g_len == inbox_cap) {
        g_head = (g_head + 1) % inbox_cap;
        g_len -= 1;
    }
    const i = (g_head + g_len) % inbox_cap;
    var item: Parked = .{ .dm = dm, .device = device };
    item.from_len = copyInto(&item.from, from);
    item.text_len = copyInto(&item.text, peer_context.clip(text, text_cap));
    g_items[i] = item;
    g_len += 1;
}

/// Copy heard room/device lines into the ring. Returns how many we parked
/// (overflow still counts as parked — the newest stay). Pointers are copied
/// into static buffers because the drain's arena may reset next step.
pub fn parkHeard(local: []const Message, device: []const Message) usize {
    var n: usize = 0;
    for (local) |m| {
        parkOne(m.from_session, m.text, m.to.len > 0, false);
        n += 1;
    }
    for (device) |m| {
        parkOne(m.from_session, m.text, m.to.len > 0, true);
        n += 1;
    }
    return n;
}

fn itemAt(i: usize) Parked {
    return g_items[(g_head + i) % inbox_cap];
}

fn fromSlice(p: Parked) []const u8 {
    return p.from[0..p.from_len];
}

fn textSlice(p: Parked) []const u8 {
    return p.text[0..p.text_len];
}

/// One-line history wake. Cheap on purpose: the bodies wait in the ring.
pub fn formatWake(arena: Allocator) []const u8 {
    if (g_len == 0) return "[peer] 0 unread — peer_message action=inbox";
    const first = fromSlice(itemAt(0));
    var extra: usize = 0;
    var i: usize = 1;
    while (i < g_len) : (i += 1) {
        if (!std.mem.eql(u8, fromSlice(itemAt(i)), first)) extra += 1;
    }
    const who = if (extra == 0)
        std.fmt.allocPrint(arena, "from {s}", .{first}) catch "from a peer"
    else
        std.fmt.allocPrint(arena, "from {s} + {d} more", .{ first, extra }) catch "from peers";
    return std.fmt.allocPrint(arena, "[peer] {d} unread {s} — peer_message action=inbox", .{ g_len, who }) catch "[peer] unread — peer_message action=inbox";
}

/// Read+clear. Tool result only — does not re-enter history.
pub fn takeAll(arena: Allocator) []const u8 {
    if (g_len == 0) return "inbox empty";
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < g_len) : (i += 1) {
        const p = itemAt(i);
        const flag = if (p.device and p.dm) " · device DM" else if (p.device) " · device" else if (p.dm) " · DM" else "";
        const line = std.fmt.allocPrint(arena, "[peer message from {s}{s}]: {s}\n", .{ fromSlice(p), flag, textSlice(p) }) catch continue;
        buf.appendSlice(arena, line) catch {};
    }
    buf.appendSlice(arena, "(inbox cleared — reply with peer_message; omit session for the room, or name one peer to DM)") catch {};
    g_head = 0;
    g_len = 0;
    return buf.items;
}

/// Claude ListAgents: who is live, one short line each. Pull, not a push.
pub fn formatList(arena: Allocator, peers: []const Owner, mine: []const u8) []const u8 {
    if (peers.len == 0) return "no other live graff sessions";
    var buf: std.ArrayList(u8) = .empty;
    const head = std.fmt.allocPrint(arena, "{d} live:\n", .{peers.len}) catch "live:\n";
    buf.appendSlice(arena, head) catch {};
    for (peers) |p| {
        const where: []const u8 = if (std.mem.eql(u8, p.identity, mine)) "this-folder" else if (p.identity.len > 0) p.identity else "?";
        const goal = peer_context.clip(if (p.goal.len > 0) p.goal else "?", 40);
        const line = std.fmt.allocPrint(arena, "{s} pid {d} {s} · {s}\n", .{ p.session_id, p.pid, where, goal }) catch continue;
        buf.appendSlice(arena, line) catch {};
    }
    buf.appendSlice(arena, "DM with session=<id|pid|goal fragment>; omit session for this folder's room.") catch {};
    return buf.items;
}

const testing = std.testing;

fn msg(from: []const u8, text: []const u8, to: []const u8) Message {
    return .{ .from_session = from, .text = text, .to = to };
}

fn peer(id: []const u8, pid: i32, goal: []const u8, identity: []const u8) Owner {
    return .{ .session_id = id, .pid = pid, .goal = goal, .identity = identity };
}

test "parkHeard then takeAll formats bodies and clears the ring" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n = parkHeard(&.{msg("session-aaa", "hold gui/src", "")}, &.{msg("session-bbb", "your turn", "session-me")});
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 2), unread());
    const body = takeAll(a);
    try testing.expect(std.mem.indexOf(u8, body, "[peer message from session-aaa]: hold gui/src") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[peer message from session-bbb · device DM]: your turn") != null);
    try testing.expectEqual(@as(usize, 0), unread());
    try testing.expectEqualStrings("inbox empty", takeAll(a));
}

test "parkHeard: the ring drops the oldest when it overflows inbox_cap" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var i: usize = 0;
    while (i < inbox_cap + 2) : (i += 1) {
        const from = try std.fmt.allocPrint(a, "s-{d}", .{i});
        const text = try std.fmt.allocPrint(a, "line {d}", .{i});
        _ = parkHeard(&.{msg(from, text, "")}, &.{});
    }
    try testing.expectEqual(inbox_cap, unread());
    const body = takeAll(a);
    try testing.expect(std.mem.indexOf(u8, body, "line 0") == null);
    try testing.expect(std.mem.indexOf(u8, body, "line 1") == null);
    try testing.expect(std.mem.indexOf(u8, body, try std.fmt.allocPrint(a, "line {d}", .{inbox_cap + 1})) != null);
}

test "formatWake names the first sender and stays one line" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = parkHeard(&.{msg("session-aaa", "hold", "")}, &.{});
    const one = formatWake(a);
    try testing.expect(std.mem.startsWith(u8, one, "[peer] 1 unread from session-aaa"));
    try testing.expect(std.mem.indexOf(u8, one, "action=inbox") != null);
    try testing.expect(std.mem.indexOfScalar(u8, one, '\n') == null);
    _ = parkHeard(&.{msg("session-bbb", "go", "")}, &.{});
    const two = formatWake(a);
    try testing.expect(std.mem.startsWith(u8, two, "[peer] 2 unread from session-aaa + 1 more"));
}

test "formatList: one short line per peer; empty is honest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("no other live graff sessions", formatList(a, &.{}, "here"));
    const peers = [_]Owner{
        peer("session-aaa", 11, "rewrite the targeting", "here"),
        peer("session-bbb", 22, "paint chips", "/other/.git"),
    };
    const text = formatList(a, &peers, "here");
    try testing.expect(std.mem.startsWith(u8, text, "2 live:\n"));
    try testing.expect(std.mem.indexOf(u8, text, "session-aaa pid 11 this-folder · rewrite the targeting") != null);
    try testing.expect(std.mem.indexOf(u8, text, "session-bbb pid 22 /other/.git · paint chips") != null);
}
