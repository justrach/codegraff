//! One idle HTTP/2 session for HTTPS SSE (http-zig). Active requests own
//! exclusive leases: Conn is not a concurrent stream multiplexer.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http_zig = @import("http_zig");
const main_mod = @import("main.zig");

var mu: Io.Mutex = .init;
var session: ?*http_zig.Session = null;

pub fn enabled() bool {
    return main_mod.g_http2;
}

pub fn want(url: []const u8) bool {
    return enabled() and std.mem.startsWith(u8, url, "https://");
}

pub const Origin = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn parseOrigin(url: []const u8) !Origin {
    const u = try http_zig.https.parseHttpsUrl(url);
    return .{ .host = u.host, .port = u.port, .path = u.path };
}

pub const Lease = struct {
    session: *http_zig.Session,

    pub fn release(self: Lease, keep: bool) void {
        if (!keep) {
            self.session.close();
            return;
        }
        const io = self.session.io;
        mu.lockUncancelable(io);
        const occupied = session != null;
        if (!occupied) session = self.session;
        mu.unlock(io);
        if (occupied) self.session.close();
    }
};

fn takeIdle(io: Io, host: []const u8, p: u16) ?*http_zig.Session {
    mu.lockUncancelable(io);
    const idle = session;
    session = null;
    mu.unlock(io);
    if (idle) |s| {
        if (p == s.port and std.mem.eql(u8, s.host, host)) return s;
        s.close();
    }
    return null;
}

pub fn acquire(gpa: std.mem.Allocator, io: Io, host: []const u8, p: u16) !Lease {
    // Dial outside the mutex: concurrent root/child requests need separate
    // transports, and cancellation of one must not invalidate another.
    return .{ .session = takeIdle(io, host, p) orelse try http_zig.Session.open(gpa, io, host, p) };
}

/// Tests release every active lease before clearing the idle pool.
pub fn resetForTest() void {
    if (!builtin.is_test) return;
    mu.lockUncancelable(std.testing.io);
    const idle = session;
    session = null;
    mu.unlock(std.testing.io);
    if (idle) |s| s.close();
}

pub fn keepAfter(ended: bool) bool {
    return ended;
}

test "keep the pooled session only after END_STREAM" {
    try std.testing.expect(keepAfter(true));
    try std.testing.expect(!keepAfter(false));
}

test "http-zig credits DATA on the connection and the stream" {
    const gpa = std.testing.allocator;
    const frame = http_zig.frame;
    var srv_aw: std.Io.Writer.Allocating = .init(gpa);
    defer srv_aw.deinit();
    try frame.write(&srv_aw.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    const status_hpack = [_]u8{0x88};
    try frame.write(&srv_aw.writer, .{ .typ = .headers, .flags = frame.flags.end_headers, .stream_id = 1, .payload = &status_hpack });
    try frame.write(&srv_aw.writer, .{ .typ = .data, .flags = frame.flags.end_stream, .stream_id = 1, .payload = "ok" });
    const server_bytes = try gpa.dupe(u8, srv_aw.written());
    defer gpa.free(server_bytes);
    var reader: std.Io.Reader = .fixed(server_bytes);
    var client_aw: std.Io.Writer.Allocating = .init(gpa);
    defer client_aw.deinit();
    var c = http_zig.Conn.init(gpa, &reader, &client_aw.writer);
    defer c.deinit();
    var res = try c.request(.{ .method = "GET", .scheme = "https", .authority = "api.x.ai", .path = "/v1/models" });
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 2), countWindowUpdates(client_aw.written()));
}

fn countWindowUpdates(bytes: []const u8) usize {
    const frame = http_zig.frame;
    var i: usize = 0;
    if (std.mem.startsWith(u8, bytes, frame.preface)) i = frame.preface.len;
    var n: usize = 0;
    while (i + 9 <= bytes.len) {
        const len = (@as(usize, bytes[i]) << 16) | (@as(usize, bytes[i + 1]) << 8) | bytes[i + 2];
        if (i + 9 + len > bytes.len) break;
        if (bytes[i + 3] == @intFromEnum(frame.Type.window_update)) n += 1;
        i += 9 + len;
    }
    return n;
}

test "want is https-only" {
    const saved = main_mod.g_http2;
    defer main_mod.g_http2 = saved;
    main_mod.g_http2 = true;
    try std.testing.expect(want("https://api.x.ai/v1/responses"));
    try std.testing.expect(!want("http://127.0.0.1/"));
    main_mod.g_http2 = false;
    try std.testing.expect(!want("https://api.x.ai/v1/responses"));
}

fn testSession(host: []const u8) !*http_zig.Session {
    const gpa = std.testing.allocator;
    const s = try gpa.create(http_zig.Session);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .io = std.testing.io, .host = try gpa.dupe(u8, host), .port = 443 };
    return s;
}

test "HTTP2 leases exclusively own same-origin and different-origin sessions" {
    defer resetForTest();
    const root = try testSession("localhost");
    (Lease{ .session = root }).release(true);
    const active = try acquire(std.testing.allocator, std.testing.io, "localhost", 443);
    try std.testing.expectEqual(root, active.session);
    try std.testing.expect(takeIdle(std.testing.io, "localhost", 443) == null);
    try std.testing.expect(takeIdle(std.testing.io, "other.localhost", 443) == null);
    // Neither another checkout nor clearing the idle pool can close root.
    resetForTest();
    try std.testing.expectEqualStrings("localhost", active.session.host);
    active.release(true);
    const reused = try acquire(std.testing.allocator, std.testing.io, "localhost", 443);
    try std.testing.expectEqual(root, reused.session);
    reused.release(false);
}

test "HTTP2 cancellation closes only its lease while another session is idle" {
    defer resetForTest();
    const cancelled = Lease{ .session = try testSession("localhost") };
    const healthy = try testSession("other.localhost");
    (Lease{ .session = healthy }).release(true);
    cancelled.release(false);
    const reused = try acquire(std.testing.allocator, std.testing.io, "other.localhost", 443);
    try std.testing.expectEqual(healthy, reused.session);
    reused.release(true);
    // A concurrent completed request cannot replace or free the idle winner.
    (Lease{ .session = try testSession("localhost") }).release(true);
    const winner = try acquire(std.testing.allocator, std.testing.io, "other.localhost", 443);
    try std.testing.expectEqual(healthy, winner.session);
    winner.release(false);
}
