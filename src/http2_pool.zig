//! Process-wide HTTP/2 session for HTTPS SSE (http-zig). GRAFF_HTTP2=0|off
//! latches HTTP/1.1. One session per origin; peer close redials inside Session.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http_zig = @import("http_zig");
const main_mod = @import("main.zig");

var mu: Io.Mutex = .init;
var session: ?*http_zig.Session = null;
var host_buf: [256]u8 = undefined;
var host_len: usize = 0;
var port: u16 = 0;

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

pub fn sessionFor(gpa: std.mem.Allocator, io: Io, host: []const u8, p: u16) !*http_zig.Session {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (session) |s| {
        if (p == port and host_len == host.len and std.mem.eql(u8, host_buf[0..host_len], host))
            return s;
        s.close();
        session = null;
    }
    if (host.len > host_buf.len) return error.NameTooLong;
    @memcpy(host_buf[0..host.len], host);
    host_len = host.len;
    port = p;
    const s = try http_zig.Session.open(gpa, io, host, p);
    session = s;
    return s;
}

/// Drop the process-wide session. Tests allocate it with `std.testing.allocator`.
pub fn resetForTest() void {
    if (!builtin.is_test) return;
    const live = session orelse return;
    const io = live.io;
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (session) |current| current.close();
    session = null;
    host_len = 0;
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
