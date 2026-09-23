//! Bounded HTTPS JSON POST. HTTP/2 streams hold an exclusive pool lease;
//! HTTP/1.1 is used only before an HTTP/2 request was sent (dial/ALPN).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const h2 = @import("http_zig");
const pool = @import("http2_pool.zig");

pub const max_body = 64 * 1024;
pub const Response = struct { status: u16, body: []u8 };

fn authority(url: []const u8) []const u8 {
    const rest = url["https://".len..]; // caller already passed parseHttpsUrl
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

const Exchange = struct {
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    bearer: []const u8,
    body: []const u8,
    limit: usize,
    status: u16 = 0,
    len: usize = 0,
    bytes: [max_body]u8 = undefined,
    test_task: ?*const fn (*Exchange) anyerror!void = null,

    fn append(self: *Exchange, chunk: []const u8) !void {
        if (chunk.len > self.limit - self.len) return error.ResponseTooLarge;
        @memcpy(self.bytes[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    fn run(self: *Exchange) !void {
        if (self.test_task) |task| return task(self);
        if (pool.want(self.url)) {
            const origin = try pool.parseOrigin(self.url);
            if (!pool.knownH1(self.io, origin.host, origin.port)) {
                if (try self.tryH2(origin)) return;
            }
        }
        try self.runH1();
    }

    /// Returns false only before startLines has been called. Errors after it
    /// may follow a complete upload and must never silently resend on H1.
    fn tryH2(self: *Exchange, origin: pool.Origin) !bool {
        const lease = pool.acquire(self.gpa, self.io, origin.host, origin.port) catch |err| {
            if (h2.session.handshakeFallback(err)) return false; // pre-send TLS failure
            return err;
        };
        var keep = false;
        defer lease.release(keep);
        if (lease.session.h1_only) {
            pool.noteH1(self.io, origin.host, origin.port);
            return false; // ALPN did not select h2
        }
        const headers = [_]h2.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "authorization", .value = self.bearer },
        };
        var stream = try lease.session.startLines(.{
            .method = "POST",
            .scheme = "https",
            .authority = authority(self.url),
            .path = origin.path,
            .extra = &headers,
            .body = self.body,
        });
        defer stream.deinit();
        try self.consume(&stream);
        keep = stream.ended and lease.session.reusable();
        return true;
    }

    fn consume(self: *Exchange, stream: *h2.LineStream) !void {
        self.status = try stream.waitStatus();
        if (self.status != 200) return; // no error body crosses this boundary
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try stream.readChunk(&chunk);
            if (n == 0) break;
            try self.append(chunk[0..n]);
        }
    }

    fn runH1(self: *Exchange) !void {
        var req = try self.client.request(.POST, try std.Uri.parse(self.url), .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.bearer },
            },
        });
        defer req.deinit();
        errdefer {
            if (req.connection) |conn| conn.closing = true;
        }
        var response: std.http.Client.Response = undefined;
        try @import("http.zig").sendHeadTask(&req, self.body, &response);
        self.status = @intFromEnum(response.head.status);
        if (self.status != 200) {
            // Error bodies may contain private details. Close without reading.
            if (req.connection) |conn| conn.closing = true;
            return;
        }
        const dbuf: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (dbuf.len != 0) self.gpa.free(dbuf);
        var tbuf: [64]u8 = undefined;
        var dec: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&tbuf, &dec, dbuf);
        var writer = Io.Writer.fixed(self.bytes[0..self.limit]);
        _ = try reader.streamRemaining(&writer);
        self.len = writer.buffered().len;
    }
};

fn deadline(io: Io, ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), .awake) catch {};
}

/// Both select arms are cancelled and joined before this returns, so the
/// exchange's credential and buffers cannot outlive their owner.
fn watched(ex: *Exchange, deadline_ms: u64) !void {
    const Done = union(enum) { task: anyerror!void, timeout: void };
    var done: [2]Done = undefined;
    var select: Io.Select(Done) = .init(ex.io, &done);
    select.concurrent(.timeout, deadline, .{ ex.io, deadline_ms }) catch return error.DeadlineUnavailable;
    select.concurrent(.task, Exchange.run, .{ex}) catch {
        select.cancelDiscard();
        return error.TransportUnavailable;
    };
    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.cancelDiscard();
    switch (first) {
        .task => |result| try result,
        .timeout => return error.DeadlineExceeded,
    }
}

pub fn post(gpa: Allocator, io: Io, client: *std.http.Client, url: []const u8, bearer: []const u8, body: []const u8, deadline_ms: u64) !Response {
    var ex: Exchange = .{ .gpa = gpa, .io = io, .client = client, .url = url, .bearer = bearer, .body = body, .limit = max_body };
    try watched(&ex, deadline_ms);
    return .{ .status = ex.status, .body = try gpa.dupe(u8, ex.bytes[0..ex.len]) };
}

test "buffered response rejects growth past limit before copying" {
    var client: std.http.Client = undefined;
    var ex: Exchange = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .url = "", .bearer = "", .body = "", .limit = 4 };
    try ex.append("abcd");
    try std.testing.expectError(error.ResponseTooLarge, ex.append("e"));
    try std.testing.expectEqualStrings("abcd", ex.bytes[0..ex.len]);
}

test "HTTP2 authority retains nondefault port" {
    try std.testing.expectEqualStrings("localhost:8443", authority("https://localhost:8443/v1/systemone"));
    try std.testing.expectEqualStrings("gateway.example", authority("https://gateway.example/v1/systemone"));
}

test "buffered exchange deadline cancels and joins its worker" {
    const Fake = struct {
        fn run(ex: *Exchange) anyerror!void {
            ex.io.sleep(.fromSeconds(10), .awake) catch return;
            ex.status = 200;
        }
    };
    var client: std.http.Client = undefined;
    var ex: Exchange = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .url = "", .bearer = "", .body = "", .limit = max_body, .test_task = Fake.run };
    try std.testing.expectError(error.DeadlineExceeded, watched(&ex, 1));
    try std.testing.expectEqual(@as(u16, 0), ex.status);
}

test "ambiguous send failure returns once without replay" {
    const Fake = struct {
        var calls: usize = 0;
        fn run(_: *Exchange) anyerror!void {
            calls += 1;
            return error.WriteFailed;
        }
    };
    Fake.calls = 0;
    var client: std.http.Client = undefined;
    var ex: Exchange = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .url = "", .bearer = "", .body = "", .limit = max_body, .test_task = Fake.run };
    try std.testing.expectError(error.WriteFailed, watched(&ex, 100));
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "buffered HTTP2 JSON succeeds across frames without newlines" {
    const frame = h2.frame;
    var srv: Io.Writer.Allocating = .init(std.testing.allocator);
    defer srv.deinit();
    try frame.write(&srv.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    const ok = [_]u8{0x88};
    try frame.write(&srv.writer, .{ .typ = .headers, .flags = frame.flags.end_headers, .stream_id = 1, .payload = &ok });
    try frame.write(&srv.writer, .{ .typ = .data, .flags = 0, .stream_id = 1, .payload = "{\"ok\":" });
    try frame.write(&srv.writer, .{ .typ = .data, .flags = frame.flags.end_stream, .stream_id = 1, .payload = "true}" });
    var reader: Io.Reader = .fixed(srv.written());
    var writer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var conn = h2.Conn.init(std.testing.allocator, &reader, &writer.writer);
    defer conn.deinit();
    var stream = try conn.startLines(.{ .method = "GET", .scheme = "https", .authority = "localhost", .path = "/" });
    defer stream.deinit();
    var client: std.http.Client = undefined;
    var ex: Exchange = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .url = "", .bearer = "", .body = "", .limit = max_body };
    try ex.consume(&stream);
    try std.testing.expectEqual(@as(u16, 200), ex.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", ex.bytes[0..ex.len]);
    try std.testing.expect(stream.ended);
}

test "buffered HTTP2 rejects newline-free multi-frame oversize before output growth" {
    const frame = h2.frame;
    var srv: Io.Writer.Allocating = .init(std.testing.allocator);
    defer srv.deinit();
    try frame.write(&srv.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    const ok = [_]u8{0x88};
    try frame.write(&srv.writer, .{ .typ = .headers, .flags = frame.flags.end_headers, .stream_id = 1, .payload = &ok });
    const part: [16_384]u8 = @splat('x');
    for (0..5) |i| try frame.write(&srv.writer, .{ .typ = .data, .flags = if (i == 4) frame.flags.end_stream else 0, .stream_id = 1, .payload = &part });
    var reader: Io.Reader = .fixed(srv.written());
    var writer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var conn = h2.Conn.init(std.testing.allocator, &reader, &writer.writer);
    defer conn.deinit();
    var stream = try conn.startLines(.{ .method = "GET", .scheme = "https", .authority = "localhost", .path = "/" });
    defer stream.deinit();
    var client: std.http.Client = undefined;
    var ex: Exchange = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .url = "", .bearer = "", .body = "", .limit = max_body };
    try std.testing.expectError(error.ResponseTooLarge, ex.consume(&stream));
    try std.testing.expectEqual(@as(usize, max_body), ex.len);
    try std.testing.expect(stream.pending.items.len <= 16_384);
}

test "buffered HTTP2 preserves non-success status without reading its body" {
    const frame = h2.frame;
    var srv: Io.Writer.Allocating = .init(std.testing.allocator);
    defer srv.deinit();
    try frame.write(&srv.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    // Literal :status 401, HPACK name index 8 and a three-byte value.
    const unauthorized = [_]u8{ 0x08, 0x03, '4', '0', '1' };
    try frame.write(&srv.writer, .{ .typ = .headers, .flags = frame.flags.end_headers, .stream_id = 1, .payload = &unauthorized });
    try frame.write(&srv.writer, .{ .typ = .data, .flags = frame.flags.end_stream, .stream_id = 1, .payload = "private error body" });
    var reader: Io.Reader = .fixed(srv.written());
    var writer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var conn = h2.Conn.init(std.testing.allocator, &reader, &writer.writer);
    defer conn.deinit();
    var stream = try conn.startLines(.{ .method = "GET", .scheme = "https", .authority = "localhost", .path = "/" });
    defer stream.deinit();
    var client: std.http.Client = undefined;
    var ex: Exchange = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .url = "", .bearer = "", .body = "", .limit = max_body };
    try ex.consume(&stream);
    try std.testing.expectEqual(@as(u16, 401), ex.status);
    try std.testing.expectEqual(@as(usize, 0), ex.len);
}

test "loopback HTTPS stalled body cancels and releases the exchange" {
    const value = std.c.getenv("GRAFF_JEV_HTTP2_STALL_URL") orelse return error.SkipZigTest;
    const url = std.mem.span(value);
    const io = std.testing.io;
    const saved = @import("main.zig").g_http2;
    defer @import("main.zig").g_http2 = saved;
    @import("main.zig").g_http2 = true;
    defer pool.shutdown(io);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    try std.testing.expectError(error.DeadlineExceeded, post(std.testing.allocator, io, &client, url, "Bearer fixture", "{}", 100));
    const elapsed = Io.Timestamp.now(io, .awake).nanoseconds - started;
    try std.testing.expect(elapsed < 2 * std.time.ns_per_s);
}

test "loopback HTTP2 ambiguous post-send drop is never replayed" {
    const value = std.c.getenv("GRAFF_JEV_HTTP2_DROP_URL") orelse return error.SkipZigTest;
    const io = std.testing.io;
    const saved = @import("main.zig").g_http2;
    defer @import("main.zig").g_http2 = saved;
    @import("main.zig").g_http2 = true;
    defer pool.shutdown(io);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    const response = post(std.testing.allocator, io, &client, std.mem.span(value), "Bearer fixture", "{}", 1000) catch |err| {
        try std.testing.expect(err == error.RstStream or err == error.ReadFailed or err == error.EndOfStream);
        return;
    };
    std.testing.allocator.free(response.body);
    return error.ExpectedAmbiguousFailure;
}
