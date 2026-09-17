//! Opt-in Accord Unix 0600 live path behind presence_chan.postMessage.
//! JSONL stays the durable room (ADR 0134). Off unless GRAFF_ACCORD=1
//! (or test_enabled). Lost live frames are never errors — the log remains.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const accord = @import("accord");

pub const env_var = "GRAFF_ACCORD";
pub const sock_env = "GRAFF_ACCORD_SOCK";

/// Tests flip this instead of mutating process env.
pub var test_enabled: bool = false;
pub var test_sock: ?[]const u8 = null;

pub fn enabled() bool {
    if (builtin.is_test) return test_enabled;
    const v = std.c.getenv(env_var) orelse return false;
    const s = std.mem.span(v);
    if (s.len == 0) return false;
    return !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "off") and !std.mem.eql(u8, s, "false");
}

fn sockPath(buf: []u8, chan_name: []const u8) ?[]const u8 {
    if (builtin.is_test) {
        if (test_sock) |p| return p;
    } else if (std.c.getenv(sock_env)) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return s;
    }
    const stem = if (std.mem.endsWith(u8, chan_name, ".jsonl"))
        chan_name[0 .. chan_name.len - ".jsonl".len]
    else
        chan_name;
    return std.fmt.bufPrint(buf, "{s}.sock", .{stem}) catch null;
}

/// Best-effort live send of the same JSONL line already appended to the room.
/// Never fails the durable write.
pub fn livePost(io: Io, gpa: std.mem.Allocator, chan_name: []const u8, json_line: []const u8) void {
    if (!enabled()) return;
    if (builtin.os.tag == .windows) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = sockPath(&path_buf, chan_name) orelse return;
    sendLine(io, gpa, path, json_line) catch {};
}

fn sendLine(io: Io, gpa: std.mem.Allocator, path: []const u8, json_line: []const u8) !void {
    const addr = try net.UnixAddress.init(path);
    const stream = addr.connect(io) catch return;
    const sess = try gpa.create(accord.Session);
    sess.* = .{ .io = io, .gpa = gpa, .role = .client, .stream = stream };
    defer {
        sess.shutdown();
        gpa.destroy(sess);
    }
    try sess.start();
    try sess.send(1, .msg, .none, json_line);
}

fn connectPath(io: Io, path: []const u8) !net.Stream {
    const addr = try net.UnixAddress.init(path);
    return addr.connect(io);
}

fn startSess(s: *accord.Session) !void {
    try s.start();
}

const Pair = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: net.Server,
    server: *accord.Session,
    client: *accord.Session,
    path: []const u8,

    fn init(p: *Pair, io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
        Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var listener = try accord.listenUnix(io, path);
        errdefer listener.deinit(io);
        var cfut = try Io.concurrent(io, connectPath, .{ io, path });
        const server_sock = try listener.accept(io);
        const client_sock = try cfut.await(io);
        const server = try gpa.create(accord.Session);
        errdefer gpa.destroy(server);
        const client = try gpa.create(accord.Session);
        errdefer gpa.destroy(client);
        server.* = .{ .io = io, .gpa = gpa, .role = .server, .stream = server_sock };
        client.* = .{ .io = io, .gpa = gpa, .role = .client, .stream = client_sock };
        p.* = .{
            .io = io,
            .gpa = gpa,
            .listener = listener,
            .server = server,
            .client = client,
            .path = path,
        };
        var cstart = try Io.concurrent(io, startSess, .{p.client});
        try p.server.start();
        try cstart.await(io);
    }

    fn deinit(p: *Pair) void {
        p.client.shutdown();
        p.server.shutdown();
        p.gpa.destroy(p.client);
        p.gpa.destroy(p.server);
        p.listener.deinit(p.io);
        Io.Dir.cwd().deleteFile(p.io, p.path) catch {};
    }
};

test "Accord live path is off by default" {
    try std.testing.expect(!test_enabled);
    try std.testing.expect(!enabled());
}

test "listenUnix socket is 0600" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const path = "graff-accord-mode.sock";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    var listener = try accord.listenUnix(io, path);
    defer {
        listener.deinit(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    var tmp: [107:0]u8 = undefined;
    @memcpy(tmp[0..path.len], path);
    tmp[path.len] = 0;
    var st: std.c.Stat = undefined;
    try std.testing.expect(std.c.stat(tmp[0..path.len :0], &st) == 0);
    try std.testing.expectEqual(@as(std.c.mode_t, 0o600), st.mode & 0o777);
}

test "Unix 0600 round-trips the JSONL line" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "graff-accord-roundtrip.sock";
    var pair: Pair = undefined;
    try pair.init(io, gpa, path);
    defer pair.deinit();
    const line = "{\"from_pid\":1,\"text\":\"hold gui/src\"}\n";
    try pair.client.send(1, .msg, .none, line);
    const got = try pair.server.recv(1);
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings(line, got.payload);
}
