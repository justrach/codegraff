//! Fake-recipient tests for the bounded peer wake (#1718). Each recipient is
//! a real Unix socket in a scratch dir: one the kernel accepts but nobody
//! answers, one that answers the preface and then stops reading, one that
//! reads our preface and never replies, and a healthy Accord server. Short
//! deadlines keep them fast; the bound asserted is generous for slow CI.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const accord = @import("accord");
const peer_wake = @import("peer_wake.zig");
const peer_cli = @import("peer_cli.zig");

const deadline_ms: u32 = 200;
/// Wall-clock ceiling for one fan-out: the deadline plus scheduling slack.
const bound_ms: i64 = 1500;

fn elapsedMs(io: Io, t0: Io.Timestamp) i64 {
    return @max(0, t0.untilNow(io, .awake).toMilliseconds());
}

/// Accept, send a valid preface, then hold the socket open without reading.
fn answerThenStall(io: Io, listener: *Io.net.Server) !Io.net.Stream {
    const conn = try listener.accept(io);
    var pre: [accord.preface_size]u8 = undefined;
    accord.encodePreface(&pre);
    var wb: [16]u8 = undefined;
    var w = conn.writer(io, &wb);
    try w.interface.writeAll(&pre);
    try w.interface.flush();
    return conn;
}

/// Accept and read the client's preface, then never answer.
fn readThenStall(io: Io, listener: *Io.net.Server) !Io.net.Stream {
    const conn = try listener.accept(io);
    var rb: [accord.preface_size]u8 = undefined;
    var r = conn.reader(io, &rb);
    _ = try r.interface.takeArray(accord.preface_size);
    return conn;
}

/// A live graff's side: a server Session that takes one frame on stream 1.
fn healthy(io: Io, gpa: std.mem.Allocator, listener: *Io.net.Server, got: *[64]u8) !usize {
    const sess = try gpa.create(accord.Session);
    defer gpa.destroy(sess);
    sess.* = .{ .io = io, .gpa = gpa, .role = .server, .stream = try listener.accept(io) };
    try sess.start();
    defer sess.shutdown();
    const in = try sess.recv(1);
    defer in.deinit(gpa);
    const n = @min(in.payload.len, got.len);
    @memcpy(got[0..n], in.payload[0..n]);
    return n;
}

const Scratch = struct {
    name: []const u8,
    fn init(io: Io, comptime name: []const u8) !Scratch {
        Io.Dir.cwd().deleteTree(io, name) catch {};
        try Io.Dir.cwd().createDirPath(io, name);
        return .{ .name = name };
    }
    fn deinit(s: Scratch, io: Io) void {
        Io.Dir.cwd().deleteTree(io, s.name) catch {};
    }
};

test "wakeAll: stalled recipients time out together and a healthy one is still woken" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    const scratch = try Scratch.init(io, "graff-wake-fanout");
    defer scratch.deinit(io);
    const silent_path = "graff-wake-fanout/1-a.accord.sock";
    const answer_path = "graff-wake-fanout/2-b.accord.sock";
    const read_path = "graff-wake-fanout/3-c.accord.sock";
    const ok_path = "graff-wake-fanout/4-d.accord.sock";
    // Listening but never accepted: the kernel completes the connect, nobody answers.
    var silent = try accord.listenUnix(io, silent_path);
    defer silent.deinit(io);
    var answer = try accord.listenUnix(io, answer_path);
    defer answer.deinit(io);
    var reads = try accord.listenUnix(io, read_path);
    defer reads.deinit(io);
    var ok = try accord.listenUnix(io, ok_path);
    defer ok.deinit(io);

    var answer_fut = try io.concurrent(answerThenStall, .{ io, &answer });
    var read_fut = try io.concurrent(readThenStall, .{ io, &reads });
    var got: [64]u8 = undefined;
    var ok_fut = try io.concurrent(healthy, .{ io, gpa, &ok, &got });

    const t0 = Io.Timestamp.now(io, .awake);
    // The healthy recipient comes last, behind every stalled one.
    const out = peer_wake.wakeAll(io, gpa, &.{ silent_path, answer_path, read_path, ok_path }, "{\"text\":\"hi\"}", deadline_ms);
    const took = elapsedMs(io, t0);

    const answered = try answer_fut.await(io);
    defer answered.close(io);
    const read_conn = try read_fut.await(io);
    defer read_conn.close(io);
    const n = try ok_fut.await(io);

    try testing.expect(took < bound_ms);
    // The preface-then-stall recipient takes the small frame into its socket
    // buffer unread, so it counts as woken; the silent and never-answering
    // recipients are the misses.
    try testing.expectEqual(peer_wake.Outcome{ .woke = 2, .missed = 2 }, out);
    try testing.expectEqualStrings("{\"text\":\"hi\"}", got[0..n]);
}

test "wakeAll: a recipient that stops reading mid-frame cannot hold the send" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    const scratch = try Scratch.init(io, "graff-wake-midframe");
    defer scratch.deinit(io);
    const path = "graff-wake-midframe/5-e.accord.sock";
    var listener = try accord.listenUnix(io, path);
    defer listener.deinit(io);
    var fut = try io.concurrent(answerThenStall, .{ io, &listener });
    // A full-size frame outgrows a small socket buffer, so the write stalls
    // where the old Session.send blocked forever.
    const big = try gpa.alloc(u8, accord.max_payload);
    defer gpa.free(big);
    @memset(big, 'x');
    const t0 = Io.Timestamp.now(io, .awake);
    const out = peer_wake.wakeAll(io, gpa, &.{path}, big, deadline_ms);
    const took = elapsedMs(io, t0);
    const conn = try fut.await(io);
    defer conn.close(io);
    try testing.expect(took < bound_ms);
    try testing.expectEqual(@as(usize, 1), out.woke + out.missed);
}

test "wakeAll: silent and never-answering recipients are missed within the deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    const scratch = try Scratch.init(io, "graff-wake-silent");
    defer scratch.deinit(io);
    const silent_path = "graff-wake-silent/6-f.accord.sock";
    const read_path = "graff-wake-silent/7-a.accord.sock";
    var silent = try accord.listenUnix(io, silent_path);
    defer silent.deinit(io);
    var reads = try accord.listenUnix(io, read_path);
    defer reads.deinit(io);
    var read_fut = try io.concurrent(readThenStall, .{ io, &reads });
    const t0 = Io.Timestamp.now(io, .awake);
    const out = peer_wake.wakeAll(io, gpa, &.{ silent_path, read_path }, "{}", deadline_ms);
    const took = elapsedMs(io, t0);
    const conn = try read_fut.await(io);
    defer conn.close(io);
    try testing.expect(took >= deadline_ms - 50); // it really waited, then gave up
    try testing.expect(took < bound_ms);
    try testing.expectEqual(peer_wake.Outcome{ .woke = 0, .missed = 2 }, out);
}

test "wakeAll: a missing socket is missed at once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const t0 = Io.Timestamp.now(io, .awake);
    const out = peer_wake.wakeAll(io, testing.allocator, &.{"graff-wake-none/8-b.accord.sock"}, "{}", 5000);
    try testing.expect(elapsedMs(io, t0) < bound_ms);
    try testing.expectEqual(peer_wake.Outcome{ .woke = 0, .missed = 1 }, out);
    try testing.expectEqual(peer_wake.Outcome{}, peer_wake.wakeAll(io, testing.allocator, &.{}, "{}", 5000));
}

test "send: a stalled recipient leaves the message posted and the command returns" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const presence_accord = @import("presence_accord.zig");
    const presence_chan = @import("presence_chan.zig");
    presence_accord.test_enabled = true;
    defer presence_accord.test_enabled = false;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scratch = try Scratch.init(io, "graff-wake-send");
    defer scratch.deinit(io);
    var dir = try Io.Dir.cwd().openDir(io, scratch.name, .{ .iterate = true });
    defer dir.close(io);
    const identity = "/work/repo/.git";
    // The recipient record is this test process, so the registry keeps it live.
    const self = @import("proc_identity.zig").selfRecord(io);
    const rec = try @import("presence_record.zig").formatRecord(arena, .{ .pid = self.pid, .start_id = self.start_id, .session_id = "graff-a", .identity = identity });
    try dir.writeFile(io, .{ .sub_path = "graff-a.json", .data = rec });
    // Its Accord socket accepts at the kernel and never answers.
    const sock = try std.fmt.allocPrint(arena, "{s}/{d}-{x}.accord.sock", .{ scratch.name, self.pid, self.start_id });
    var listener = try accord.listenUnix(io, sock);
    defer listener.deinit(io);

    const ctx: peer_cli.Ctx = .{ .dir = dir, .name = "claude@repo", .owner = .{ .pid = 52, .start_id = 1 }, .identity = identity, .wake_deadline_ms = deadline_ms };
    var cur = peer_cli.tailCursor(io, arena, ctx);
    const t0 = Io.Timestamp.now(io, .awake);
    const res = peer_cli.send(io, testing.allocator, arena, scratch.name, ctx, &cur, null, "verification passed", false);
    try testing.expect(elapsedMs(io, t0) < bound_ms);
    switch (res) {
        .posted => |p| {
            try testing.expectEqual(@as(usize, 0), p.woke);
            try testing.expectEqual(@as(usize, 1), p.missed);
        },
        else => return error.ExpectedPosted,
    }
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    var off: u64 = 0;
    const log = presence_chan.readNewMessages(io, arena, dir, presence_chan.chanName(&tb, identity), &off);
    try testing.expectEqualStrings("verification passed", log[log.len - 1].text);
}
