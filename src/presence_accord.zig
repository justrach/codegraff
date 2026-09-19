//! Accord Unix 0600 live path behind presence_chan.postMessage.
//! JSONL stays the durable room (ADR 0134). On by default except Windows;
//! GRAFF_ACCORD=0 opts out. Lost live frames are never errors — the log remains.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const accord = @import("accord");
const proc_identity = @import("proc_identity.zig");

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
var g_mu: Io.Mutex = .init;
var g_outs: std.ArrayList(OutLink) = .empty;
var g_ins: std.ArrayList(*accord.Session) = .empty;
var g_connects: std.atomic.Value(u32) = .init(0);

const OutLink = struct {
    path: []u8,
    sess: *accord.Session,
};

pub fn takePing() bool {
    return g_ping.swap(false, .acq_rel);
}

pub const Stats = struct {
    on: bool,
    inbound: usize = 0,
    outbound: usize = 0,
    connects: u32 = 0,
    session_bytes: usize = 0,
    proc_rss_bytes: usize = 0,
};

/// Accord-held Sessions plus process RSS (for /debug). Session bytes are the
/// standing duplex cost; proc RSS is the whole process, just in case.
pub fn stats() Stats {
    if (!enabled()) return .{ .on = false, .proc_rss_bytes = processRssBytes() };
    var inbound: usize = 0;
    var outbound: usize = 0;
    if (g_io) |io| {
        g_mu.lockUncancelable(io);
        inbound = g_ins.items.len;
        outbound = g_outs.items.len;
        g_mu.unlock(io);
    }
    const n = inbound + outbound;
    return .{
        .on = true,
        .inbound = inbound,
        .outbound = outbound,
        .connects = g_connects.load(.monotonic),
        .session_bytes = n * @sizeOf(accord.Session),
        .proc_rss_bytes = processRssBytes(),
    };
}

pub fn renderLine(w: *Io.Writer) !void {
    const s = stats();
    if (!s.on) {
        try w.writeAll("  accord     off\n");
        return;
    }
    try w.print(
        "  accord     {d} in · {d} out · {d} connects · ~{d} KB sessions · rss {d} KB\n",
        .{
            s.inbound,
            s.outbound,
            s.connects,
            s.session_bytes / 1024,
            s.proc_rss_bytes / 1024,
        },
    );
}

fn processRssBytes() usize {
    if (builtin.os.tag == .windows) return 0;
    var ru: std.c.rusage = std.mem.zeroes(std.c.rusage);
    if (std.c.getrusage(std.c.rusage.SELF, &ru) != 0) return 0;
    const rss: usize = @intCast(@max(ru.maxrss, 0));
    return if (builtin.os.tag == .linux) rss * 1024 else rss;
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
        if (dropDeadSock(io, dir_path, entry.name)) continue;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        sendLine(io, gpa, path, json_line) catch {};
    }
}

fn parseSockName(name: []const u8) ?proc_identity.Record {
    const suffix = ".accord.sock";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const stem = name[0 .. name.len - suffix.len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null;
    if (dash == 0 or dash + 1 >= stem.len) return null;
    const pid = std.fmt.parseInt(i32, stem[0..dash], 10) catch return null;
    const start_id = std.fmt.parseInt(u64, stem[dash + 1 ..], 16) catch return null;
    if (pid <= 0) return null;
    return .{ .pid = pid, .start_id = start_id };
}

/// Unlink only when the recorded owner is provably gone (#413). Unknown stays.
fn dropDeadSock(io: Io, dir_path: []const u8, name: []const u8) bool {
    const rec = parseSockName(name) orelse return false;
    if (proc_identity.stateOf(io, rec) != .reclaimable) return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return false;
    Io.Dir.cwd().deleteFile(io, path) catch return false;
    return true;
}

fn sweepDead(io: Io, dir_path: []const u8) void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".accord.sock")) continue;
        _ = dropDeadSock(io, dir_path, entry.name);
    }
}

/// Bind `{live_dir}/{pid}-{start}.accord.sock` and accept live posts.
pub fn listen(io: Io, gpa: std.mem.Allocator, dir_path: ?[]const u8) void {
    if (!enabled()) return;
    if (builtin.os.tag == .windows) return;
    if (g_listener != null) return;
    const dir = dir_path orelse return;
    sweepDead(io, dir);
    const self = proc_identity.selfRecord(io);
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
    if (g_gpa) |gpa| {
        g_mu.lockUncancelable(io);
        for (g_outs.items) |link| {
            link.sess.shutdown();
            gpa.destroy(link.sess);
            gpa.free(link.path);
        }
        g_outs.clearRetainingCapacity();
        for (g_ins.items) |sess| sess.shutdown();
        g_ins.clearRetainingCapacity();
        g_mu.unlock(io);
        g_outs.deinit(gpa);
        g_ins.deinit(gpa);
        g_outs = .empty;
        g_ins = .empty;
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
    g_connects.store(0, .release);
}

fn acceptLoop() void {
    const io = g_io orelse return;
    const gpa = g_gpa orelse return;
    const listener = &(g_listener orelse return);
    while (true) {
        const stream = listener.accept(io) catch break;
        const sess = gpa.create(accord.Session) catch {
            stream.close(io);
            continue;
        };
        sess.* = .{ .io = io, .gpa = gpa, .role = .server, .stream = stream };
        _ = io.concurrent(holdInbound, .{sess}) catch {
            sess.shutdown();
            gpa.destroy(sess);
            continue;
        };
    }
}

fn holdInbound(sess: *accord.Session) void {
    const io = sess.io;
    const gpa = sess.gpa;
    sess.start() catch {
        sess.shutdown();
        gpa.destroy(sess);
        return;
    };
    g_mu.lockUncancelable(io);
    g_ins.append(gpa, sess) catch {
        g_mu.unlock(io);
        sess.shutdown();
        gpa.destroy(sess);
        return;
    };
    g_mu.unlock(io);
    while (true) {
        const got = sess.recv(1) catch break;
        defer got.deinit(gpa);
        switch (got.kind) {
            .msg, .progress, .stop => g_ping.store(true, .release),
            else => {},
        }
    }
    dropInbound(sess);
}

fn dropInbound(sess: *accord.Session) void {
    const io = sess.io;
    const gpa = sess.gpa;
    g_mu.lockUncancelable(io);
    for (g_ins.items, 0..) |item, i| {
        if (item == sess) {
            _ = g_ins.orderedRemove(i);
            break;
        }
    }
    g_mu.unlock(io);
    sess.shutdown();
    gpa.destroy(sess);
}

fn sendLine(io: Io, gpa: std.mem.Allocator, path: []const u8, json_line: []const u8) !void {
    const sess = ensureOut(io, gpa, path) orelse return;
    sess.send(1, .msg, .none, json_line) catch {
        dropOut(io, gpa, path);
        const retry = ensureOut(io, gpa, path) orelse return;
        retry.send(1, .msg, .none, json_line) catch {};
    };
}

fn ensureOut(io: Io, gpa: std.mem.Allocator, path: []const u8) ?*accord.Session {
    g_mu.lockUncancelable(io);
    for (g_outs.items) |link| {
        if (std.mem.eql(u8, link.path, path)) {
            g_mu.unlock(io);
            return link.sess;
        }
    }
    g_mu.unlock(io);
    const addr = net.UnixAddress.init(path) catch return null;
    const stream = addr.connect(io) catch return null;
    const sess = gpa.create(accord.Session) catch {
        stream.close(io);
        return null;
    };
    sess.* = .{ .io = io, .gpa = gpa, .role = .client, .stream = stream };
    sess.start() catch {
        sess.shutdown();
        gpa.destroy(sess);
        return null;
    };
    const owned = gpa.dupe(u8, path) catch {
        sess.shutdown();
        gpa.destroy(sess);
        return null;
    };
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (g_outs.items) |link| {
        if (std.mem.eql(u8, link.path, path)) {
            sess.shutdown();
            gpa.destroy(sess);
            gpa.free(owned);
            return link.sess;
        }
    }
    g_outs.append(gpa, .{ .path = owned, .sess = sess }) catch {
        gpa.free(owned);
        sess.shutdown();
        gpa.destroy(sess);
        return null;
    };
    _ = g_connects.fetchAdd(1, .monotonic);
    return sess;
}

fn dropOut(io: Io, gpa: std.mem.Allocator, path: []const u8) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    for (g_outs.items, 0..) |link, i| {
        if (!std.mem.eql(u8, link.path, path)) continue;
        link.sess.shutdown();
        gpa.destroy(link.sess);
        gpa.free(link.path);
        _ = g_outs.orderedRemove(i);
        return;
    }
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
    const s = stats();
    try std.testing.expect(!s.on);
}

test "Accord stats report session RSS when enabled" {
    if (builtin.os.tag == .windows) return; // enabled() is hard-false there
    test_enabled = true;
    defer test_enabled = false;
    const s = stats();
    try std.testing.expect(s.on);
    try std.testing.expectEqual(@as(usize, 0), s.inbound);
    try std.testing.expectEqual(@as(usize, 0), s.outbound);
}

test "parseSockName reads pid-start names and rejects junk" {
    const rec = parseSockName("42-2a.accord.sock") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(i32, 42), rec.pid);
    try std.testing.expectEqual(@as(u64, 0x2a), rec.start_id);
    try std.testing.expect(parseSockName("not-a-sock") == null);
    try std.testing.expect(parseSockName("x-yy.accord.sock") == null);
    try std.testing.expect(parseSockName("-1-1.accord.sock") == null);
    try std.testing.expect(parseSockName("0-1.accord.sock") == null);
}

test "livePost unlinks a reclaimable peer sock" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    test_enabled = true;
    defer {
        stop(io);
        test_enabled = false;
    }
    const dir = "graff-accord-dead";
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    listen(io, gpa, dir);
    const dead = "999999-1.accord.sock";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, dead });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "stale" });
    livePost(io, gpa, "chan", "{\"text\":\"hi\"}\n");
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
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
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    listen(io, gpa, dir);
    const name = g_own_name orelse return error.NoSock;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    stop(io);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
}

test "listenUnix socket is 0600" {
    if (builtin.os.tag != .macos) return;
    const io = std.testing.io;
    const path = "graff-accord-mode.sock";
    Io.Dir.cwd().deleteFile(io, path) catch {};
    var listener = try accord.listenUnix(io, path);
    defer {
        listener.deinit(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
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

test "standing link carries msg, progress, and a reply on one session" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "graff-accord-standing.sock";
    var pair: Pair = undefined;
    try pair.init(io, gpa, path);
    defer pair.deinit();
    try pair.client.send(1, .msg, .none, "hold gui/src");
    const first = try pair.server.recv(1);
    defer first.deinit(gpa);
    try std.testing.expectEqual(accord.Kind.msg, first.kind);
    try pair.client.send(1, .progress, .none, "working");
    const mid = try pair.server.recv(1);
    defer mid.deinit(gpa);
    try std.testing.expectEqual(accord.Kind.progress, mid.kind);
    try pair.server.send(1, .msg, .none, "acked");
    const back = try pair.client.recv(1);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("acked", back.payload);
    try pair.client.send(1, .stop, .none, &.{});
    const halt = try pair.server.recv(1);
    defer halt.deinit(gpa);
    try std.testing.expectEqual(accord.Kind.stop, halt.kind);
}
