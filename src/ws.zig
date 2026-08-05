//! Minimal WebSocket client (RFC 6455) for the codex/ChatGPT Responses API
//! over WebSocket (`wss://chatgpt.com/backend-api/codex/responses`) — OpenAI's
//! codex prefers ws and falls back to SSE, and a persistent ws connection also
//! sidesteps the keep-alive `HttpConnectionClosing` retries the SSE path hits.
//! Ported from the mobile-relay daemon's client (src/relay.zig on the
//! mobile-relay branch), with two additions for this use: custom handshake
//! headers (Authorization / OpenAI-Beta / chatgpt-account-id / …) and an
//! upgrade-failure signal (error.UpgradeRequired) so the caller can fall back
//! to SSE. Just what a request/response turn needs: text frames, client
//! masking, ping/pong, close, fragmentation reassembly, one message in / one
//! stream of events out.
//!
//! Observability: set `g_debug = true` (GRAFF_WS_DEBUG=1) to trace the
//! handshake + every frame to stderr; the transport layer additionally routes
//! structured ws lifecycle events to the run's file under .graff/traces so an
//! agent can debug a ws turn after the fact.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const HostName = net.HostName;
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

/// GRAFF_WS_DEBUG=1 → dump the handshake + frame headers to stderr.
pub var g_debug: bool = false;
/// Deterministic integration-test seam: fail the next WS connect so the live
/// binary can prove its clean retry against the real endpoint.
pub var g_force_connect_failure_once: bool = false;
/// Counted sibling used to prove the second consecutive failure latches SSE.
pub var g_force_connect_failure_count: u8 = 0;

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (g_debug) std.debug.print("[ws] " ++ fmt ++ "\n", args);
}

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Opcode = enum(u4) {
    cont = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Error = error{
    BadUrl,
    HandshakeFailed,
    /// Server declined the upgrade (e.g. 426) — the caller should fall back to SSE.
    UpgradeRequired,
    PeerClosed,
    MessageTooLong,
    StreamTooLong,
} || Allocator.Error || Io.Reader.Error || Io.Writer.Error;

// Encrypted/raw socket buffers (TLS asserts these are >= tls min_buffer_len).
const sock_buf_cap = 64 * 1024;
// Plaintext TLS buffers.
const tls_buf_cap = 64 * 1024;
/// Hard cap on one reassembled inbound message (a single Responses event).
const message_cap = 4 * 1024 * 1024;

comptime {
    if (sock_buf_cap < tls.max_ciphertext_record_len) @compileError("sock_buf_cap < tls min_buffer_len");
}

pub const WsClient = struct {
    io: Io,
    stream: net.Stream,
    rd: net.Stream.Reader,
    wr: net.Stream.Writer,
    // Active plaintext interfaces: raw stream for ws://, TLS plaintext for wss://.
    r: *Io.Reader = undefined,
    w: *Io.Writer = undefined,
    tls_client: ?tls.Client = null,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_lock: Io.RwLock = .init,
    gpa: Allocator,
    /// (#401) The peer is wedged or gone — tear down with a plain FIN instead
    /// of deinit's courtesy close frame, which is another blocking write on the
    /// very socket that just proved it won't drain (it would re-hang the
    /// recovery path that is trying to abandon this connection).
    dead: bool = false,
    sock_rbuf: [sock_buf_cap]u8 = undefined,
    sock_wbuf: [sock_buf_cap]u8 = undefined,
    tls_rbuf: [tls_buf_cap]u8 = undefined,
    tls_wbuf: [tls_buf_cap]u8 = undefined,

    /// Connect + (for wss) TLS handshake + the HTTP Upgrade handshake, sending
    /// `headers` as extra request headers. Heap-allocated and stable (the
    /// Reader/Writer interfaces and the TLS client reference its inline buffers
    /// and each other).
    pub fn connect(gpa: Allocator, io: Io, url: []const u8, insecure: bool, headers: []const Header) Error!*WsClient {
        if (g_force_connect_failure_count > 0) {
            g_force_connect_failure_count -= 1;
            dbg("forced connect failure (GRAFF_WS_FORCE_FAIL_COUNT)", .{});
            return error.HandshakeFailed;
        }
        if (g_force_connect_failure_once) {
            g_force_connect_failure_once = false;
            dbg("forced connect failure (GRAFF_WS_FORCE_FAIL_ONCE)", .{});
            return error.HandshakeFailed;
        }
        const u = parseUrl(url) orelse return error.BadUrl;
        dbg("connect {s} host={s} port={d} path={s} tls={}", .{ url, u.host, u.port, u.path, u.tls });

        // DNS + connect. IpAddress.resolve only parses IP literals, so a
        // hostname (chatgpt.com) needs HostName.connect, which looks it up.
        const host_name = HostName.init(u.host) catch |e| {
            dbg("bad host {s}: {s}", .{ u.host, @errorName(e) });
            return error.BadUrl;
        };
        const stream = host_name.connect(io, u.port, .{ .mode = .stream }) catch |e| {
            dbg("connect {s}:{d} failed: {s}", .{ u.host, u.port, @errorName(e) });
            return error.HandshakeFailed;
        };

        const self = try gpa.create(WsClient);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .stream = stream, .rd = undefined, .wr = undefined, .gpa = gpa };
        self.rd = net.Stream.Reader.init(stream, io, &self.sock_rbuf);
        self.wr = net.Stream.Writer.init(stream, io, &self.sock_wbuf);
        // From here the client owns the socket (and, for wss, the CA bundle):
        // release both if the TLS or upgrade handshake fails, or every failed
        // dial leaks an fd — which #401's reconnect ladder now retries into.
        errdefer {
            self.ca_bundle.deinit(gpa);
            self.stream.close(io);
        }

        if (u.tls) {
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            if (!insecure) self.ca_bundle.rescan(gpa, io, Io.Clock.real.now(io)) catch |e| {
                dbg("ca rescan failed: {s}", .{@errorName(e)});
                return error.HandshakeFailed;
            };
            self.tls_client = tls.Client.init(&self.rd.interface, &self.wr.interface, .{
                .host = if (insecure) .no_verification else .{ .explicit = u.host },
                .ca = if (insecure) .no_verification else .{ .bundle = .{
                    .gpa = gpa,
                    .io = io,
                    .lock = &self.ca_lock,
                    .bundle = &self.ca_bundle,
                } },
                .write_buffer = &self.tls_wbuf,
                .read_buffer = &self.tls_rbuf,
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(io),
            }) catch |e| {
                dbg("tls init failed: {s}", .{@errorName(e)});
                return error.HandshakeFailed;
            };
            self.r = &self.tls_client.?.reader;
            self.w = &self.tls_client.?.writer;
        } else {
            self.r = &self.rd.interface;
            self.w = &self.wr.interface;
        }

        try self.handshake(u, headers);
        return self;
    }

    pub fn deinit(self: *WsClient, gpa: Allocator) void {
        if (!self.dead) self.sendFrame(.close, "") catch {}; // (#401) see `dead`
        self.ca_bundle.deinit(gpa);
        self.stream.close(self.io);
        gpa.destroy(self);
    }

    /// Send one text message.
    pub fn sendText(self: *WsClient, payload: []const u8) Error!void {
        dbg("send text {d}b", .{payload.len});
        return self.sendFrame(.text, payload);
    }

    /// Read one complete (re-assembled) message into `out`. Control frames
    /// (ping/pong/close) are handled internally; a peer close → error.PeerClosed.
    /// Returns the message opcode (.text or .binary).
    pub fn readMessage(self: *WsClient, gpa: Allocator, out: *std.ArrayList(u8)) Error!Opcode {
        out.clearRetainingCapacity();
        var msg_op: ?Opcode = null;
        const r = self.r;
        while (true) {
            const h = try r.takeArray(2);
            const fin = (h[0] & 0x80) != 0;
            const op: Opcode = @enumFromInt(@as(u4, @truncate(h[0] & 0x0f)));
            const masked = (h[1] & 0x80) != 0;
            var len: u64 = @as(u64, h[1] & 0x7f);
            if (len == 126) {
                len = std.mem.readInt(u16, try r.takeArray(2), .big);
            } else if (len == 127) {
                len = std.mem.readInt(u64, try r.takeArray(8), .big);
            }
            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) mask = (try r.takeArray(4)).*;

            switch (op) {
                .ping => {
                    const p = try r.take(@intCast(len));
                    if (masked) unmask(p, mask);
                    try self.sendFrame(.pong, p);
                    continue;
                },
                .pong => {
                    try r.discardAll(@intCast(len));
                    continue;
                },
                .close => {
                    try r.discardAll(@intCast(len));
                    self.sendFrame(.close, "") catch {};
                    return error.PeerClosed;
                },
                .text, .binary, .cont => {
                    if (out.items.len + len > message_cap) return error.MessageTooLong;
                    const start = out.items.len;
                    try out.resize(gpa, start + @as(usize, @intCast(len)));
                    try r.readSliceAll(out.items[start..]);
                    if (masked) unmask(out.items[start..], mask);
                    if (msg_op == null and op != .cont) msg_op = op;
                    if (fin) {
                        dbg("recv msg {d}b op={s}", .{ out.items.len, @tagName(msg_op orelse .text) });
                        return msg_op orelse .text;
                    }
                },
                else => return error.HandshakeFailed, // unknown opcode
            }
        }
    }

    // ── internals ────────────────────────────────────────────────────────────

    fn handshake(self: *WsClient, u: Url, headers: []const Header) Error!void {
        var key_raw: [16]u8 = undefined;
        self.io.random(&key_raw);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);

        try self.w.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n",
            .{ u.path, u.host, &key_b64 },
        );
        for (headers) |hd| try self.w.print("{s}: {s}\r\n", .{ hd.name, hd.value });
        try self.w.writeAll("\r\n");
        try self.flushTransport();

        // status line: expect "HTTP/1.1 101 ..."; anything else is a rejection.
        const status = try self.r.takeDelimiterInclusive('\n');
        dbg("handshake <- {s}", .{std.mem.trimEnd(u8, status, "\r\n")});
        if (std.mem.indexOf(u8, status, " 101 ") == null) {
            // A 426 (or any non-101) means the server won't upgrade — fall back to SSE.
            return if (std.mem.indexOf(u8, status, " 426 ") != null) error.UpgradeRequired else error.HandshakeFailed;
        }
        // drain headers until the blank line
        while (true) {
            const line = try self.r.takeDelimiterInclusive('\n');
            if (line.len <= 2) break; // "\r\n" or "\n"
        }
    }

    fn flushTransport(self: *WsClient) Error!void {
        try self.w.flush(); // for TLS this encrypts plaintext into the socket writer…
        if (self.tls_client != null) try self.wr.interface.flush(); // …then push the socket buffer
    }

    fn sendFrame(self: *WsClient, op: Opcode, payload: []const u8) Error!void {
        var hdr: [14]u8 = undefined;
        hdr[0] = 0x80 | @as(u8, @intFromEnum(op)); // FIN + opcode
        var n: usize = 2;
        if (payload.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            hdr[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            hdr[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
            n = 10;
        }
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        @memcpy(hdr[n .. n + 4], &mask);
        n += 4;

        try self.w.writeAll(hdr[0..n]);
        var i: usize = 0;
        var tmp: [4096]u8 = undefined;
        while (i < payload.len) {
            const chunk = @min(tmp.len, payload.len - i);
            for (0..chunk) |j| tmp[j] = payload[i + j] ^ mask[(i + j) & 3];
            try self.w.writeAll(tmp[0..chunk]);
            i += chunk;
        }
        try self.flushTransport();
    }
};

fn unmask(buf: []u8, mask: [4]u8) void {
    for (buf, 0..) |*b, i| b.* ^= mask[i & 3];
}

const Url = struct { tls: bool, host: []const u8, port: u16, path: []const u8 };

fn parseUrl(url: []const u8) ?Url {
    var rest = url;
    var is_tls = false;
    if (std.mem.startsWith(u8, rest, "wss://")) {
        is_tls = true;
        rest = rest["wss://".len..];
    } else if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest["ws://".len..];
    } else return null;

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |s| rest[0..s] else rest;
    const path = if (slash) |s| rest[s..] else "/";
    if (authority.len == 0) return null;

    var host = authority;
    var port: u16 = if (is_tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return null;
    }
    return .{ .tls = is_tls, .host = host, .port = port, .path = path };
}

test "parseUrl: wss/ws, default ports, path" {
    const a = parseUrl("wss://chatgpt.com/backend-api/codex/responses").?;
    try std.testing.expect(a.tls);
    try std.testing.expectEqualStrings("chatgpt.com", a.host);
    try std.testing.expectEqual(@as(u16, 443), a.port);
    try std.testing.expectEqualStrings("/backend-api/codex/responses", a.path);
    const b = parseUrl("ws://localhost:8080/x").?;
    try std.testing.expect(!b.tls);
    try std.testing.expectEqual(@as(u16, 8080), b.port);
    try std.testing.expect(parseUrl("https://nope") == null);
}

test "forced WS failure is one-shot for SSE fallback integration tests" {
    g_force_connect_failure_once = true;
    try std.testing.expectError(error.HandshakeFailed, WsClient.connect(
        std.testing.allocator,
        std.testing.io,
        "wss://unused.invalid/x",
        false,
        &.{},
    ));
    try std.testing.expect(!g_force_connect_failure_once);
}

test "counted forced WS failures exhaust exactly" {
    g_force_connect_failure_count = 2;
    inline for (0..2) |_| try std.testing.expectError(error.HandshakeFailed, WsClient.connect(
        std.testing.allocator,
        std.testing.io,
        "wss://unused.invalid/x",
        false,
        &.{},
    ));
    try std.testing.expectEqual(@as(u8, 0), g_force_connect_failure_count);
}
