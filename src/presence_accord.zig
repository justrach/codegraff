//! Accord Unix 0600 live path behind presence_chan.postMessage.
//! JSONL stays the durable room (ADR 0134). On by default except Windows;
//! GRAFF_ACCORD=0 opts out. Lost live frames are never errors — the log remains.

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
    if (builtin.os.tag == .windows) return false;
    if (builtin.is_test) return test_enabled;
    const v = std.c.getenv(env_var) orelse return true;
    const s = std.mem.span(v);
    if (s.len == 0) return true;
    return !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "off") and !std.mem.eql(u8, s, "false");
}

var g_ping = std.atomic.Value(bool).init(false);
var g_io: ?Io = null;
var g_gpa: ?std.mem.Allocator = null;
var g_dir_path: ?[]u8 = null;
var g_own_name: ?[]u8 = null;
var g_listener: ?net.Server = null;
var g_future: ?Io.Future(void) = null;

pub fn takePing() bool {
    return g_ping.swap(false, .acq_rel);
}

fn sockPath(buf: []u8, chan_name: []const u8) ?[]const u8 {
    _ = chan_name;
    if (builtin.is_test) return test_sock;
    if (std.c.getenv(sock_env)) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) {
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return buf[0..n];
        }
    }
    return null;
}

/// Best-effort live send of the same JSONL line already appended to the room.
/// Never fails the durable write. Fans out to every peer sock in the live dir.
pub fn livePost(io: Io, gpa: std.mem.Allocator, chan_name: []const u8, json_line: []const u8) void {
    if (!enabled()) return;
    if (builtin.os.tag == .windows) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (sockPath(&path_buf, chan_name)) |path| {
        sendLine(io, gpa, path, json_line) catch {};
        return;
    }
    const dir_path = g_dir_path orelse return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".accord.sock")) continue;
        if (g_own_name) |own| if (std.mem.eql(u8, entry.name, own)) continue;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        sendLine(io, gpa, path, json_line) catch {};
    }
}

/// Bind `{live_dir}/{pid}-{start}.accord.sock` and accept live posts.
pub fn listen(io: Io, gpa: std.mem.Allocator, dir_path: ?[]const u8) void {
    if (!enabled()) return;
    if (builtin.os.tag == .windows) return;
    if (g_listener != null) return;
    const dir = dir_path orelse return;
    const self = @import("proc_identity.zig").selfRecord(io);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}-{x}.accord.sock", .{ self.pid, self.start_id }) catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    const owned_dir = gpa.dupe(u8, dir) catch return;
    const owned_name = gpa.dupe(u8, name) catch {
        gpa.free(owned_dir);
        return;
    };
    const listener = accord.listenUnix(io, path) catch {
        gpa.free(owned_dir);
        gpa.free(owned_name);
        return;
    };
    g_dir_path = owned_dir;
    g_own_name = owned_name;
    g_listener = listener;
    g_io = io;
    g_gpa = gpa;
    g_future = io.concurrent(acceptLoop, .{}) catch {
        stop(io);
        return;
    };
}

pub fn stop(io: Io) void {
    if (g_future) |*f| {
        f.cancel(io);
        g_future = null;
    }
    if (g_listener) |*l| {
        l.deinit(io);
        g_listener = null;
    }
    if (g_dir_path) |dir| if (g_own_name) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name })) |path| {
            Io.Dir.cwd().deleteFile(io, path) catch {};
        } else |_| {}
        if (g_gpa) |gpa| gpa.free(name);
        g_own_name = null;
    };
    if (g_dir_path) |dir| if (g_gpa) |gpa| gpa.free(dir);
    g_dir_path = null;
    g_gpa = null;
    g_io = null;
    g_ping.store(false, .release);
}

fn acceptLoop() void {
    const io = g_io orelse return;
    const gpa = g_gpa orelse return;
    const listener = &(g_listener orelse return);
    while (true) {
        const stream = listener.accept(io) catch break;
        serveOne(io, gpa, stream);
    }
}

fn serveOne(io: Io, gpa: std.mem.Allocator, stream: net.Stream) void {
    const sess = gpa.create(accord.Session) catch {
        stream.close(io);
        return;
    };
    sess.* = .{ .io = io, .gpa = gpa, .role = .server, .stream = stream };
    defer {
        sess.shutdown();
        gpa.destroy(sess);
    }
    sess.start() catch return;
    const got = sess.recv(1) catch return;
    defer got.deinit(gpa);
    g_ping.store(true, .release);
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

test "Accord live path is off in tests unless enabled" {
    try std.testing.expect(!test_enabled);
    try std.testing.expect(!enabled());
}

test "listen binds a 0600 sock and stop unlinks it" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    test_enabled = true;
    defer {
        stop(io);
        test_enabled = false;
    }
    const dir = "graff-accord-listen";
    Io.Dir.cwd().makeDir(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer Io.Dir.cwd().deleteDir(io, dir) catch {};
    listen(io, gpa, dir);
    const name = g_own_name orelse return error.NoSock;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    var tmp: [107:0]u8 = undefined;
    try std.testing.expect(path.len <= tmp.len);
    @memcpy(tmp[0..path.len], path);
    tmp[path.len] = 0;
    var st: std.c.Stat = undefined;
    try std.testing.expect(std.c.stat(tmp[0..path.len :0], &st) == 0);
    try std.testing.expectEqual(@as(std.c.mode_t, 0o600), st.mode & 0o777);
    stop(io);
    try std.testing.expect(std.c.stat(tmp[0..path.len :0], &st) != 0);
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
