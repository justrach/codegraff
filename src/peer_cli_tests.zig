//! Tests for `graff peer` (peer_cli.zig), split out under the 600-line
//! ceiling. Every room operation runs against a tmp dir with a fixed owner,
//! so no process walking or real registry is involved.

const std = @import("std");
const testing = std.testing;
const peer_cli = @import("peer_cli.zig");
const presence = @import("presence.zig");
const presence_chan = @import("presence_chan.zig");

const tree_identity = "/work/repo/.git";

fn ctxFor(dir: std.Io.Dir, name: []const u8, pid: i32) peer_cli.Ctx {
    return .{ .dir = dir, .name = name, .owner = .{ .pid = pid, .start_id = 1 }, .identity = tree_identity };
}

fn post(arena: std.mem.Allocator, dir: std.Io.Dir, room: []const u8, from: []const u8, pid: i32, to: []const u8, text: []const u8) !void {
    try testing.expect(presence_chan.postMessage(testing.io, arena, dir, room, .{ .from_pid = pid, .from_start = 1, .from_session = from, .to = to, .ts_ms = 1, .text = text }));
}

test "wake: an external send lands one msg frame on a graff session's Accord socket" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    const accord = @import("accord");
    const presence_accord = @import("presence_accord.zig");
    presence_accord.test_enabled = true;
    defer presence_accord.test_enabled = false;
    const dir = "graff-peer-wake";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // The socket name a graff session with this pid/start would bind.
    var listener = try accord.listenUnix(io, dir ++ "/4242-abc.accord.sock");
    defer listener.deinit(io);
    var sender = try io.concurrent(peer_cli.wake, .{ io, gpa, dir, .{ .pid = 4242, .start_id = 0xabc }, "{\"text\":\"hi\"}" });
    const sess = try gpa.create(accord.Session);
    defer gpa.destroy(sess);
    sess.* = .{ .io = io, .gpa = gpa, .role = .server, .stream = try listener.accept(io) };
    try sess.start();
    defer sess.shutdown();
    const got = try sess.recv(1);
    defer got.deinit(gpa);
    try testing.expectEqual(accord.Kind.msg, got.kind);
    try testing.expectEqualStrings("{\"text\":\"hi\"}", got.payload);
    sender.await(io);
}

test "parseOpts: action, flags, and the rest joined as the message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const o = try peer_cli.parseOpts(arena_state.allocator(), &.{ "send", "--to", "graff-a", "hold", "off", "src/", "--anyway" });
    try testing.expectEqualStrings("send", o.action);
    try testing.expectEqualStrings("graff-a", o.to.?);
    try testing.expectEqualStrings("hold off src/", o.text);
    try testing.expect(o.anyway);
    try testing.expectError(error.Usage, peer_cli.parseOpts(arena_state.allocator(), &.{ "send", "--to" }));
    try testing.expectError(error.Usage, peer_cli.parseOpts(arena_state.allocator(), &.{ "inbox", "--bogus" }));
}

test "labelFromPath: a versioned install is named by its folder" {
    try testing.expectEqualStrings("claude", peer_cli.labelFromPath("/Users/u/.local/share/claude/versions/2.1.282").?);
    try testing.expectEqualStrings("codex", peer_cli.labelFromPath("/Applications/ChatGPT.app/Contents/Resources/codex").?);
    try testing.expectEqualStrings("node", peer_cli.labelFromPath("/usr/local/bin/node").?);
    try testing.expect(peer_cli.labelFromPath("/1/2") == null);
}

test "isShell and folderLabel" {
    try testing.expect(peer_cli.isShell("-zsh"));
    try testing.expect(peer_cli.isShell("bash"));
    try testing.expect(!peer_cli.isShell("claude"));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("repo", peer_cli.folderLabel("/work/repo/.git", &buf));
    try testing.expectEqualStrings("repo:wt1", peer_cli.folderLabel("/work/repo/.git/worktrees/wt1", &buf));
}

test "collect: worktree lines and device DMs are heard; own lines and other DMs are not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = ctxFor(tmp.dir, "claude@repo", 50);
    var cur = peer_cli.tailCursor(testing.io, arena, ctx);
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const tree = presence_chan.chanName(&tb, tree_identity);
    try post(arena, tmp.dir, tree, "graff-a", 10, "", "room note");
    try post(arena, tmp.dir, tree, "claude@repo", 50, "", "my own echo");
    try post(arena, tmp.dir, tree, "graff-a", 10, "graff-b", "dm for someone else");
    try post(arena, tmp.dir, presence.device_room, "graff-c", 11, "claude@repo", "device dm for me");
    try post(arena, tmp.dir, presence.device_room, "graff-c", 11, "", "unaddressed device chatter");
    const heard = peer_cli.collect(testing.io, arena, ctx, &cur);
    try testing.expectEqual(@as(usize, 2), heard.len);
    try testing.expectEqualStrings("room note", heard[0].m.text);
    try testing.expectEqual(peer_cli.Room.device, heard[1].room);
    try testing.expectEqualStrings("device dm for me", heard[1].m.text);
    try testing.expectEqual(@as(usize, 0), peer_cli.collect(testing.io, arena, ctx, &cur).len);
}

test "history: recent visible lines oldest first, other agents' DMs hidden, cursor untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = ctxFor(tmp.dir, "claude@repo", 50);
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const tree = presence_chan.chanName(&tb, tree_identity);
    try testing.expect(presence_chan.postMessage(testing.io, arena, tmp.dir, tree, .{ .from_pid = 10, .from_start = 1, .from_session = "graff-a", .ts_ms = 1, .text = "one" }));
    try testing.expect(presence_chan.postMessage(testing.io, arena, tmp.dir, tree, .{ .from_pid = 10, .from_start = 1, .from_session = "graff-a", .to = "graff-b", .ts_ms = 2, .text = "not mine" }));
    try testing.expect(presence_chan.postMessage(testing.io, arena, tmp.dir, presence.device_room, .{ .from_pid = 50, .from_start = 1, .from_session = "claude@repo", .to = "graff-c", .ts_ms = 3, .text = "my own dm" }));
    try testing.expect(presence_chan.postMessage(testing.io, arena, tmp.dir, tree, .{ .from_pid = 10, .from_start = 1, .from_session = "graff-a", .ts_ms = 4, .text = "four" }));
    const all = peer_cli.history(testing.io, arena, ctx, 20, 1 << 20);
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("one", all[0].m.text);
    try testing.expectEqualStrings("my own dm", all[1].m.text);
    try testing.expectEqualStrings("four", all[2].m.text);
    const last2 = peer_cli.history(testing.io, arena, ctx, 2, 1 << 20);
    try testing.expectEqualStrings("my own dm", last2[0].m.text);
    try testing.expect(peer_cli.loadCursor(testing.io, arena, ctx) == null);
}

test "cursor: saved position survives, and a first read joins at the tail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = ctxFor(tmp.dir, "codex@repo", 51);
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const tree = presence_chan.chanName(&tb, tree_identity);
    try post(arena, tmp.dir, tree, "graff-a", 10, "", "before joining");
    try testing.expect(peer_cli.loadCursor(testing.io, arena, ctx) == null);
    const t = peer_cli.tailCursor(testing.io, arena, ctx);
    peer_cli.saveCursor(testing.io, arena, ctx, t);
    try post(arena, tmp.dir, tree, "graff-a", 10, "", "after joining");
    var cur = peer_cli.loadCursor(testing.io, arena, ctx) orelse return error.ExpectedCursor;
    const heard = peer_cli.collect(testing.io, arena, ctx, &cur);
    try testing.expectEqual(@as(usize, 1), heard.len);
    try testing.expectEqualStrings("after joining", heard[0].m.text);
}

test "send: a DM to an agent that wrote since our last read is held, then goes through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    const self = @import("proc_identity.zig").selfRecord(testing.io);
    // The recipient is this test process, so the registry keeps its record live.
    const text = try @import("presence_record.zig").formatRecord(arena, .{ .pid = self.pid, .start_id = self.start_id, .session_id = "graff-a", .identity = tree_identity, .activity = "external" });
    try dir.writeFile(testing.io, .{ .sub_path = "graff-a.json", .data = text });
    const ctx: peer_cli.Ctx = .{ .dir = dir, .name = "claude@repo", .owner = .{ .pid = 52, .start_id = 1 }, .identity = tree_identity };
    var cur = peer_cli.tailCursor(testing.io, arena, ctx);
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const tree = presence_chan.chanName(&tb, tree_identity);
    try post(arena, dir, tree, "graff-a", self.pid, "claude@repo", "wait, I changed the plan");
    switch (peer_cli.send(testing.io, testing.allocator, arena, ".", ctx, &cur, "graff-a", "sounds good", false)) {
        .held => |heard| try testing.expectEqualStrings("wait, I changed the plan", heard[0].m.text),
        else => return error.ExpectedHeld,
    }
    switch (peer_cli.send(testing.io, testing.allocator, arena, ".", ctx, &cur, "graff-a", "ok, following the new plan", false)) {
        .posted => |p| try testing.expectEqual(peer_cli.Room.tree, p.room),
        else => return error.ExpectedPosted,
    }
    var off: u64 = 0;
    const log = presence_chan.readNewMessages(testing.io, arena, dir, tree, &off);
    try testing.expectEqualStrings("ok, following the new plan", log[log.len - 1].text);
    try testing.expectEqualStrings("graff-a", log[log.len - 1].to);
    try testing.expect(peer_cli.send(testing.io, testing.allocator, arena, ".", ctx, &cur, "nobody-here", "hi", false) == .no_target);
}
