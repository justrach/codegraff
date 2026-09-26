//! The wire format half of the #469 channel: ONE append-only JSONL log per
//! worktree, shared by every co-resident session. Named from a hash of the
//! worktree identity so two checkouts never cross-hear. Appends use the
//! read+write positional pattern from session_transcript (#462: write-only
//! handles break appends on Windows). Delivery is queued — a sender never
//! blocks on a receiver (#417). Every reader keeps its own byte offset and
//! skips only its OWN messages.
//!
//! `to` is a delivery rule for the working set (peer_target.zig): a bare
//! worktree line is a room, a named `to` is a DM. The log still stores every
//! line. The device room stays addressed-only (plus the user's /tell all).
//!
//! Everything here is parameterized and pure-ish (dir + name + allocator in,
//! bytes out) so tests need no process registry; the wired layer that knows
//! WHICH dir/name/offset a live session uses is presence.zig
//! (postTo/drainChannel), split out under the 600-line ceiling.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const presence_accord = @import("presence_accord.zig");

pub const chan_name_max = 96;

/// One channel line. `from_*` identify the sender's presence record at send
/// time; the harness writes them, never the model. `to` is a session-name
/// substring naming who the message is FOR — the worktree room delivers every
/// line, but the device room is folder-scoped: only addressed lines and the
/// user's own posts (`from_user`, set by /tell) cross folders.
pub const Message = struct {
    from_pid: i32 = 0,
    from_start: u64 = 0,
    from_session: []const u8 = "",
    from_goal: []const u8 = "",
    to: []const u8 = "",
    ts_ms: i64 = 0,
    text: []const u8 = "",
    from_user: bool = false,
    kind: []const u8 = "message",
};

/// The channel file for a worktree identity: content-hash, so it is stable
/// across sessions and carries no path separators.
pub fn chanName(buf: *[chan_name_max]u8, identity: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "chan-{x}.jsonl", .{std.hash.Wyhash.hash(0, identity)}) catch unreachable;
}

/// Whether this message is our own echo — the one thing a drain skips.
pub fn isOwn(msg: Message, self_pid: i32, self_start: u64) bool {
    return msg.from_pid == self_pid and msg.from_start == self_start;
}

/// Append one message to the channel named `name` under `dir`. Best-effort:
/// false on any I/O or serialization failure — a lost message is reported by
/// the caller, never thrown into a tool call.
pub fn postMessage(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8, msg: Message) bool {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(msg) catch return false;
    aw.writer.writeAll("\n") catch return false;
    const f = dir.createFile(io, name, .{ .truncate = false, .read = true }) catch return false;
    defer f.close(io);
    const end: u64 = if (f.stat(io)) |st| st.size else |_| blk: {
        const st = dir.statFile(io, name, .{}) catch return false;
        break :blk st.size;
    };
    f.writePositionalAll(io, aw.writer.buffered(), end) catch return false;
    presence_accord.livePost(io, arena, name, aw.writer.buffered());
    return true;
}

/// Most bytes one drain reads. A drain reads only what follows its offset, so
/// a long-lived room costs the new lines, not the whole log.
pub const drain_window: usize = 1024 * 1024;

/// Current byte length of a room, or 0 when it does not exist yet. Joining at
/// the tail needs only this, never the bytes.
pub fn roomSize(io: Io, dir: Io.Dir, name: []const u8) u64 {
    const st = dir.statFile(io, name, .{}) catch return 0;
    return st.size;
}

/// Read complete channel lines after `offset`, advancing it past everything
/// parsed. A trailing partial line stays for the next drain — a writer
/// mid-append never yields a torn message. A file shorter than the offset was
/// recreated; restart from the top rather than skip it forever. Reads at most
/// `drain_window` bytes from the offset; the rest waits for the next drain.
pub fn readNewMessages(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8, offset: *u64) []const Message {
    return readNewMessagesWindow(io, arena, dir, name, offset, drain_window);
}

pub fn readNewMessagesWindow(io: Io, arena: Allocator, dir: Io.Dir, name: []const u8, offset: *u64, window: usize) []const Message {
    const f = dir.openFile(io, name, .{}) catch return &.{};
    defer f.close(io);
    const size = (f.stat(io) catch return &.{}).size;
    if (size < offset.*) offset.* = 0;
    if (size == offset.*) return &.{};
    const want: usize = @intCast(@min(size - offset.*, window));
    const buf = arena.alloc(u8, want) catch return &.{};
    const text = buf[0 .. f.readPositionalAll(io, buf, offset.*) catch return &.{}];
    var msgs: std.ArrayList(Message) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |nl| {
        const line = text[pos..nl];
        pos = nl + 1;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (m.from_pid == 0 or m.text.len == 0) continue;
        msgs.append(arena, m) catch break;
    }
    // A single line longer than the window can never complete inside it; skip
    // it rather than re-read the same bytes forever.
    if (pos == 0 and text.len == window) pos = text.len;
    offset.* += pos;
    return msgs.items;
}

/// A late joiner hears only the room's recent tail: more than `max` backlogged
/// messages would bury live coordination under hours of roll-call from dead
/// sessions (and the dump rides every later request as durable history).
/// Returns how many leading messages to drop; the caller renders the marker.
pub fn backlogDrop(count: usize, max: usize) usize {
    return if (count > max) count - max else 0;
}

test "backlogDrop: only the overflow beyond the tail cap drops" {
    try std.testing.expectEqual(@as(usize, 0), backlogDrop(0, 10));
    try std.testing.expectEqual(@as(usize, 0), backlogDrop(10, 10));
    try std.testing.expectEqual(@as(usize, 21), backlogDrop(31, 10));
}

test "channel: every reader hears every message once; only the sender's own echo drops" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [chan_name_max]u8 = undefined;
    const name = chanName(&name_buf, "/repo/.git");
    const msg: Message = .{ .from_pid = 1, .from_start = 11, .from_session = "s-a", .from_goal = "agent-inbox redesign", .to = "s-b", .ts_ms = 7, .text = "hold off gui/src until I land the move" };
    try std.testing.expect(postMessage(io, arena, tmp.dir, name, msg));
    try std.testing.expect(postMessage(io, arena, tmp.dir, name, .{ .from_pid = 2, .from_start = 22, .from_session = "s-c", .ts_ms = 8, .text = "second note" }));
    var off: u64 = 0;
    const first = readNewMessages(io, arena, tmp.dir, name, &off);
    try std.testing.expectEqual(2, first.len);
    try std.testing.expectEqualStrings("s-a", first[0].from_session);
    try std.testing.expectEqualStrings("agent-inbox redesign", first[0].from_goal);
    try std.testing.expectEqualStrings("s-b", first[0].to);
    try std.testing.expectEqualStrings("hold off gui/src until I land the move", first[0].text);
    try std.testing.expectEqualStrings("second note", first[1].text);
    // A second drain at the same offset is empty: delivery is exactly-once per reader.
    try std.testing.expectEqual(0, readNewMessages(io, arena, tmp.dir, name, &off).len);
    // The room model: self-echo is the ONLY thing a drain drops.
    try std.testing.expect(isOwn(first[0], 1, 11));
    try std.testing.expect(!isOwn(first[0], 2, 22));
    try std.testing.expect(!isOwn(first[0], 1, 12)); // same pid, new boot: a new voice
}

test "readNewMessages: a torn trailing line waits for the next drain" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [chan_name_max]u8 = undefined;
    const name = chanName(&name_buf, "/repo/.git");
    try std.testing.expect(postMessage(io, arena, tmp.dir, name, .{ .from_pid = 2, .from_start = 1, .from_session = "s-x", .ts_ms = 1, .text = "whole" }));
    // Simulate a writer mid-append: half a JSON line, no newline yet.
    const f = try tmp.dir.createFile(io, name, .{ .truncate = false, .read = true });
    const st = try f.stat(io);
    try f.writePositionalAll(io, "{\"from_pid\":2,\"tex", st.size);
    f.close(io);
    var off: u64 = 0;
    const first = readNewMessages(io, arena, tmp.dir, name, &off);
    try std.testing.expectEqual(1, first.len); // only the complete line
    try std.testing.expectEqualStrings("whole", first[0].text);
    // Finish the torn line; the next drain picks it up.
    const f2 = try tmp.dir.createFile(io, name, .{ .truncate = false, .read = true });
    const st2 = try f2.stat(io);
    try f2.writePositionalAll(io, "t\":\"rest\"}\n", st2.size);
    f2.close(io);
    const second = readNewMessages(io, arena, tmp.dir, name, &off);
    try std.testing.expectEqual(1, second.len);
    try std.testing.expectEqualStrings("rest", second[0].text);
}

test "readNewMessages: a room past the old 256 KiB read cap still delivers new lines" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var big: std.ArrayList(u8) = .empty;
    for (0..1500) |_| {
        try big.appendSlice(arena, "{\"from_pid\":9,\"from_start\":1,\"text\":\"");
        try big.appendNTimes(arena, 'x', 200);
        try big.appendSlice(arena, "\"}\n");
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "room.jsonl", .data = big.items });
    var off: u64 = roomSize(io, tmp.dir, "room.jsonl");
    try std.testing.expect(off > 256 * 1024);
    try std.testing.expect(postMessage(io, arena, tmp.dir, "room.jsonl", .{ .from_pid = 2, .from_start = 1, .ts_ms = 1, .text = "after the cap" }));
    const got = readNewMessages(io, arena, tmp.dir, "room.jsonl", &off);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("after the cap", got[0].text);
    try std.testing.expectEqual(roomSize(io, tmp.dir, "room.jsonl"), off);
}

test "readNewMessagesWindow: a line longer than the window is skipped, not re-read forever" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const long_line: [301]u8 = @as([300]u8, @splat('y')) ++ "\n".*;
    try tmp.dir.writeFile(io, .{ .sub_path = "room.jsonl", .data = &long_line });
    try std.testing.expect(postMessage(io, arena, tmp.dir, "room.jsonl", .{ .from_pid = 2, .from_start = 1, .ts_ms = 1, .text = "ok" }));
    var off: u64 = 0;
    var heard: usize = 0;
    var drains: usize = 0;
    while (off < roomSize(io, tmp.dir, "room.jsonl") and drains < 32) : (drains += 1) {
        const got = readNewMessagesWindow(io, arena, tmp.dir, "room.jsonl", &off, 128);
        for (got) |m| {
            if (std.mem.eql(u8, m.text, "ok")) heard += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), heard);
    try std.testing.expect(drains < 32);
}

test "postMessage dual-writes JSONL when Accord live is on" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    presence_accord.test_enabled = true;
    defer presence_accord.test_enabled = false;
    // No listener: live send is best-effort and must not fail the durable write.
    presence_accord.test_sock = "graff-accord-missing.sock";
    defer presence_accord.test_sock = null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [chan_name_max]u8 = undefined;
    const name = chanName(&name_buf, "/repo/.git");
    try std.testing.expect(postMessage(io, arena, tmp.dir, name, .{
        .from_pid = 3,
        .from_start = 1,
        .from_session = "s-a",
        .ts_ms = 1,
        .text = "durable stays",
    }));
    var off: u64 = 0;
    const got = readNewMessages(io, arena, tmp.dir, name, &off);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("durable stays", got[0].text);
}
