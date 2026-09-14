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

/// How many inbound bodies the process will hold. Evictions are counted;
/// the room still has the original messages on disk.
pub const inbox_cap: usize = 8;

// Owned independently of the delivery arena, which resets between steps.
var test_storage: Allocator = std.heap.page_allocator;
const storage = if (@import("builtin").is_test) &test_storage else &std.heap.page_allocator;

/// Clear with the previous allocator before changing ownership domains.
pub fn setStorageAllocatorForTest(allocator: Allocator) void {
    if (!@import("builtin").is_test) @compileError("test-only inbox allocator override");
    clear();
    test_storage = allocator;
}
const Parked = struct {
    from: []const u8,
    text: []const u8,
    dm: bool = false,
    device: bool = false,

    fn deinit(self: Parked) void {
        storage.free(self.from);
        storage.free(self.text);
    }
};

var g_items: [inbox_cap]Parked = undefined;
var g_head: usize = 0;
var g_len: usize = 0;
var g_dropped: usize = 0;

pub fn clear() void {
    for (0..g_len) |i| itemAt(i).deinit();
    g_head = 0;
    g_len = 0;
    g_dropped = 0;
}

pub fn resetForTest() void {
    clear();
}

pub fn unread() usize {
    return g_len;
}

pub fn dropped() usize {
    return g_dropped;
}

pub fn pending() bool {
    return g_len > 0 or g_dropped > 0;
}

/// Add saved loss after restoring the array, preserving any restore evictions.
pub fn restoreDropped(v: std.json.Value) void {
    const count = switch (v) {
        .integer => |n| if (n >= 0) (std.math.cast(usize, n) orelse std.math.maxInt(usize)) else return,
        // JSON stores unsigned counts above i64 as number strings.
        .number_string => |n| std.fmt.parseInt(usize, n, 10) catch return,
        else => return,
    };
    g_dropped +|= count;
}

fn parkOne(from: []const u8, text: []const u8, dm: bool, device: bool) void {
    const owned_from = storage.dupe(u8, from) catch {
        g_dropped +|= 1;
        return;
    };
    const owned_text = storage.dupe(u8, text) catch {
        storage.free(owned_from);
        g_dropped +|= 1;
        return;
    };
    // Allocate first: failure must not evict an otherwise readable message.
    if (g_len == inbox_cap) {
        itemAt(0).deinit();
        g_head = (g_head + 1) % inbox_cap;
        g_len -= 1;
        g_dropped +|= 1;
    }
    const i = (g_head + g_len) % inbox_cap;
    g_items[i] = .{ .from = owned_from, .text = owned_text, .dm = dm, .device = device };
    g_len += 1;
}

/// Copy heard room/device lines into the ring. Returns how many were heard
/// (including loss), so even an allocation failure prompts a loss-aware wake.
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

fn itemAt(i: usize) *const Parked {
    return &g_items[(g_head + i) % inbox_cap];
}

fn fromSlice(p: *const Parked) []const u8 {
    return p.from;
}

fn textSlice(p: *const Parked) []const u8 {
    return p.text;
}

/// One-line history wake. Cheap on purpose: the bodies wait in the ring.
/// Advisory on purpose (#708): an imperative `peer_message action=inbox`
/// made a greeting's first step look like tool work.
pub fn formatWake(arena: Allocator) []const u8 {
    // Advisory framing (#708): the wake states that messages are waiting and
    // how to read them, but must not read as a command that displaces the
    // user's actual request on a trivial turn. Prefix stays "[peer]" — every
    // compact/peek path detects injects by prefix, not by this wording.
    if (!pending()) return "[peer] 0 unread — nothing waiting; no inbox read needed";
    if (g_dropped > 0) return std.fmt.allocPrint(arena, "[peer] {d} unread; {d} dropped — parked; peer_message action=inbox when relevant", .{ g_len, g_dropped }) catch "[peer] messages dropped — peer_message action=inbox when relevant";
    const first = fromSlice(itemAt(0));
    // Only the wake is a preview. Keep it one line and within the history cap.
    const line_end = std.mem.indexOfAny(u8, first, "\r\n") orelse first.len;
    var end = @min(line_end, 48);
    while (end > 0 and end < first.len and first[end] & 0xc0 == 0x80) end -= 1;
    const shown = first[0..end];
    var extra: usize = 0;
    var i: usize = 1;
    while (i < g_len) : (i += 1) {
        if (!std.mem.eql(u8, fromSlice(itemAt(i)), first)) extra += 1;
    }
    const who = if (extra == 0)
        std.fmt.allocPrint(arena, "from {s}", .{shown}) catch "from a peer"
    else
        std.fmt.allocPrint(arena, "from {s} + {d} more", .{ shown, extra }) catch "from peers";
    return std.fmt.allocPrint(arena, "[peer] {d} unread {s} — parked; peer_message action=inbox when relevant", .{ g_len, who }) catch "[peer] unread — peer_message action=inbox when relevant";
}

/// Read+clear only after the complete tool result is allocated successfully.
pub fn takeAll(arena: Allocator) Allocator.Error![]const u8 {
    if (!pending()) return "inbox empty";
    var buf: std.Io.Writer.Allocating = .init(arena);
    defer buf.deinit();
    if (g_dropped > 0) buf.writer.print("[peer inbox: {d} dropped message(s) could not be retained; the room log keeps the originals]\n", .{g_dropped}) catch return error.OutOfMemory;
    for (0..g_len) |i| {
        const p = itemAt(i);
        const flag = if (p.device and p.dm) " · device DM" else if (p.device) " · device" else if (p.dm) " · DM" else "";
        buf.writer.print("[peer message from {s}{s}]: {s}\n", .{ fromSlice(p), flag, textSlice(p) }) catch return error.OutOfMemory;
    }
    buf.writer.writeAll("(inbox cleared — reply with peer_message; omit session for the room, or name one peer to DM)") catch return error.OutOfMemory;
    const result = try buf.toOwnedSlice();
    clear();
    return result;
}

/// Digest parked bodies so a save skips only when the mailbox is unchanged.
pub fn mixFingerprint(f: anytype) void {
    f.num(g_len);
    f.num(g_dropped);
    var i: usize = 0;
    while (i < g_len) : (i += 1) {
        const p = itemAt(i);
        f.text(fromSlice(p));
        f.text(textSlice(p));
        f.flag(p.dm);
        f.flag(p.device);
    }
}

/// The parked ring as a JSON array for `.session.json`.
pub fn writeJson(s: *std.json.Stringify) !void {
    try s.beginArray();
    var i: usize = 0;
    while (i < g_len) : (i += 1) {
        const p = itemAt(i);
        try s.beginObject();
        try s.objectField("from");
        try s.write(fromSlice(p));
        try s.objectField("text");
        try s.write(textSlice(p));
        try s.objectField("dm");
        try s.write(p.dm);
        try s.objectField("device");
        try s.write(p.device);
        try s.endObject();
    }
    try s.endArray();
}

/// Replace the ring from a saved `peer_inbox` array. Garbage is skipped.
pub fn restoreJson(v: std.json.Value) void {
    clear();
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const from = if (item.object.get("from")) |f| (if (f == .string) f.string else continue) else continue;
        const text = if (item.object.get("text")) |t| (if (t == .string) t.string else continue) else continue;
        const dm = if (item.object.get("dm")) |d| (d == .bool and d.bool) else false;
        const device = if (item.object.get("device")) |d| (d == .bool and d.bool) else false;
        parkOne(from, text, dm, device);
    }
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
        const shown = if (p.title.len > 0) p.title else p.session_id;
        const base = if (p.session_base.len > 0) p.session_base else p.session_id;
        const line = std.fmt.allocPrint(arena, "{s} [{s}] {s} pid {d} {s} · {s}\n", .{ shown, base, p.session_id, p.pid, where, goal }) catch continue;
        buf.appendSlice(arena, line) catch {};
    }
    buf.appendSlice(arena, "DM with session=<title|base|id|pid|goal>; omit session for this folder's room. Presence is device-local.") catch {};
    return buf.items;
}

test "wake framing is advisory: it never opens with the read command (#708)" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Empty inbox: no imperative read of an empty mailbox.
    const idle = formatWake(a);
    try testing.expect(std.mem.startsWith(u8, idle, "[peer] 0 unread"));
    try testing.expect(std.mem.indexOf(u8, idle, "action=inbox") == null);
    // Parked: the how-to-read hint stays, but the wake must not BE the
    // command — the user's turn outranks the mailbox.
    _ = parkHeard(&.{msg("s-a", "ping", "")}, &.{});
    const wake = formatWake(a);
    try testing.expect(wake.len <= peer_context.inject_byte_cap);
    try testing.expect(std.mem.indexOf(u8, wake, "peer_message action=inbox when relevant") != null);
    try testing.expect(!std.mem.endsWith(u8, wake, "action=inbox"));
}

const testing = std.testing;

fn msg(from: []const u8, text: []const u8, to: []const u8) Message {
    return .{ .from_session = from, .text = text, .to = to };
}

fn peer(id: []const u8, pid: i32, goal: []const u8, identity: []const u8) Owner {
    return .{ .session_id = id, .pid = pid, .goal = goal, .identity = identity };
}

test "inbox ring: park, one-line wake, overflow drops oldest, takeAll clears" {
    // One test owns the process-local ring so parallel suite threads cannot
    // interleave park/take on the same slots (ADR 0004 mailbox is per-process).
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const n = parkHeard(&.{msg("session-aaa", "hold gui/src", "")}, &.{msg("session-bbb", "your turn", "session-me")});
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 2), unread());
    const wake = formatWake(a);
    try testing.expect(std.mem.startsWith(u8, wake, "[peer] 2 unread from session-aaa + 1 more"));
    try testing.expect(std.mem.indexOf(u8, wake, "peer_message action=inbox when relevant") != null);
    try testing.expect(std.mem.indexOf(u8, wake, "parked") != null);
    try testing.expect(std.mem.indexOf(u8, wake, "when relevant") != null);
    try testing.expect(std.mem.indexOfScalar(u8, wake, '\n') == null);
    const body = try takeAll(a);
    try testing.expect(std.mem.indexOf(u8, body, "[peer message from session-aaa]: hold gui/src") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[peer message from session-bbb · device DM]: your turn") != null);
    try testing.expectEqual(@as(usize, 0), unread());
    try testing.expectEqualStrings("inbox empty", try takeAll(a));

    var i: usize = 0;
    while (i < inbox_cap + 2) : (i += 1) {
        const from = try std.fmt.allocPrint(a, "s-{d}", .{i});
        const text = try std.fmt.allocPrint(a, "line {d}", .{i});
        _ = parkHeard(&.{msg(from, text, "")}, &.{});
    }
    try testing.expectEqual(inbox_cap, unread());
    const overflow = try takeAll(a);
    try testing.expect(std.mem.indexOf(u8, overflow, "line 0") == null);
    try testing.expect(std.mem.indexOf(u8, overflow, "line 1") == null);
    try testing.expect(std.mem.indexOf(u8, overflow, try std.fmt.allocPrint(a, "line {d}", .{inbox_cap + 1})) != null);
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
    try testing.expect(std.mem.indexOf(u8, text, "session-aaa [session-aaa] session-aaa pid 11 this-folder · rewrite the targeting") != null);
    try testing.expect(std.mem.indexOf(u8, text, "session-bbb [session-bbb] session-bbb pid 22 /other/.git · paint chips") != null);
}

test "formatList: title and saved-session base lead the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const peers = [_]Owner{.{
        .session_id = "session--aaa",
        .pid = 11,
        .goal = "recover login",
        .identity = "here",
        .title = "Fixing login recovery",
        .session_base = "fixing-login-recovery",
    }};
    const text = formatList(a, &peers, "here");
    try testing.expect(std.mem.indexOf(u8, text, "Fixing login recovery [fixing-login-recovery] session--aaa pid 11 this-folder · recover login") != null);
    try testing.expect(std.mem.indexOf(u8, text, "device-local") != null);
}

test "inbox JSON round-trip: restoreJson rebuilds the ring" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = parkHeard(&.{msg("s-a", "hold the tree", "")}, &.{});
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeJson(&s);
    clear();
    try testing.expectEqual(@as(usize, 0), unread());
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.writer.buffered(), .{});
    restoreJson(parsed);
    try testing.expectEqual(@as(usize, 1), unread());
    try testing.expect(std.mem.indexOf(u8, try takeAll(a), "hold the tree") != null);
}
