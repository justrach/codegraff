//! Bounded HTTPS JSON requests. HTTP/2 streams hold an exclusive pool lease;
//! HTTP/1.1 is used only before an HTTP/2 request was sent (dial/ALPN).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const h2 = @import("http_zig");
const pool = @import("http2_pool.zig");

pub const max_body = 64 * 1024;
pub const Response = struct { status: u16, body: []u8 };
const Method = enum { post, get };

fn redirects(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

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
    method: Method = .post,
    headers: []const std.http.Header = &.{},
    redirected_headers: [4]std.http.Header = undefined,
    large_bytes: ?[]u8 = null,
    redirect_location: ?[]u8 = null,
    status: u16 = 0,
    len: usize = 0,
    bytes: [max_body]u8 = undefined,
    test_task: ?*const fn (*Exchange) anyerror!void = null,

    fn buffer(self: *Exchange) []u8 {
        return self.large_bytes orelse &self.bytes;
    }

    fn append(self: *Exchange, chunk: []const u8) !void {
        if (chunk.len > self.limit - self.len) return error.ResponseTooLarge;
        @memcpy(self.buffer()[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    fn run(self: *Exchange) !void {
        if (self.test_task) |task| return task(self);
        var owned_url: ?[]u8 = null;
        defer if (owned_url) |url| self.gpa.free(url);
        defer if (self.redirect_location) |location| self.gpa.free(location);
        for (0..4) |hops| {
            self.status = 0;
            self.len = 0;
            var sent_h2 = false;
            if (pool.want(self.url)) {
                const origin = try pool.parseOrigin(self.url);
                if (!pool.knownH1(self.io, origin.host, origin.port)) {
                    sent_h2 = try self.tryH2(origin);
                }
            }
            if (!sent_h2) try self.runH1();
            if (self.method != .get or !redirects(self.status) or self.redirect_location == null) return;
            if (hops == 3) return error.TooManyHttpRedirects;
            const next = try resolveLocation(self.gpa, self.url, self.redirect_location.?);
            self.gpa.free(self.redirect_location.?);
            self.redirect_location = null;
            if (!sameOrigin(self.url, next)) {
                var count: usize = 0;
                for (self.headers) |header| {
                    if (!std.ascii.eqlIgnoreCase(header.name, "accept")) continue;
                    self.redirected_headers[count] = header;
                    count += 1;
                }
                self.headers = self.redirected_headers[0..count];
            }
            if (owned_url) |old| self.gpa.free(old);
            owned_url = next;
            self.url = next;
        }
    }

    /// Returns false only before the request is sent. http-zig's H1NoStream
    /// exits before Conn.startLines; every other startLines error is final.
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
        const post_headers = [_]h2.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "authorization", .value = self.bearer },
        };
        var catalog_headers: [4]h2.Header = undefined;
        var names: [4][64]u8 = undefined;
        for (self.headers, 0..) |header, i| {
            if (i >= catalog_headers.len or header.name.len > names[i].len) return error.InvalidHeader;
            catalog_headers[i] = .{ .name = std.ascii.lowerString(&names[i], header.name), .value = header.value };
        }
        var stream = lease.session.startLines(.{
            .method = if (self.method == .post) "POST" else "GET",
            .scheme = "https",
            .authority = authority(self.url),
            .path = origin.path,
            .extra = if (self.method == .post) &post_headers else catalog_headers[0..self.headers.len],
            .body = self.body,
        }) catch |err| {
            if (err == error.H1NoStream) {
                pool.noteH1(self.io, origin.host, origin.port);
                return false;
            }
            return err;
        };
        defer stream.deinit();
        try self.consume(&stream);
        keep = stream.ended and lease.session.reusable();
        return true;
    }

    fn consume(self: *Exchange, stream: *h2.LineStream) !void {
        self.status = try stream.waitStatus();
        if (self.method == .get and redirects(self.status)) {
            if (stream.header("location")) |location| self.redirect_location = try self.gpa.dupe(u8, location);
        }
        if (self.status != 200) return; // no error body crosses this boundary
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try stream.readChunk(&chunk);
            if (n == 0) break;
            try self.append(chunk[0..n]);
        }
    }

    fn runH1(self: *Exchange) !void {
        if (self.method == .get) {
            var req = try self.client.request(.GET, try std.Uri.parse(self.url), .{
                .redirect_behavior = .unhandled,
                .extra_headers = self.headers,
            });
            defer req.deinit();
            errdefer if (req.connection) |conn| {
                conn.closing = true;
            };
            try req.sendBodiless();
            var response = try req.receiveHead(&.{});
            self.status = @intFromEnum(response.head.status);
            if (self.status != 200) {
                if (redirects(self.status)) {
                    if (response.head.location) |location|
                        self.redirect_location = try self.gpa.dupe(u8, location);
                }
                if (req.connection) |conn| conn.closing = true;
                return;
            }
            try self.readH1Body(&response);
            return;
        }
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
        try self.readH1Body(&response);
    }

    fn readH1Body(self: *Exchange, response: *std.http.Client.Response) !void {
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
        var writer = Io.Writer.fixed(self.buffer()[0..self.limit]);
        _ = reader.streamRemaining(&writer) catch |err| {
            if (err == error.WriteFailed) return error.ResponseTooLarge;
            return err;
        };
        self.len = writer.buffered().len;
    }
};

fn literalHost(uri: std.Uri) ?[]const u8 {
    const host = uri.host orelse return null;
    const bytes = switch (host) {
        .raw, .percent_encoded => |value| value,
    };
    // Treat encoded hosts as a changed origin instead of equating distinct
    // spellings without a canonical DNS name. That can only drop credentials.
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, '%') != null) return null;
    return bytes;
}

fn sameOrigin(a_url: []const u8, b_url: []const u8) bool {
    const a = std.Uri.parse(a_url) catch return false;
    const b = std.Uri.parse(b_url) catch return false;
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    const a_host = literalHost(a) orelse return false;
    const b_host = literalHost(b) orelse return false;
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(a.scheme, "https")) 443 else 80;
    return std.ascii.eqlIgnoreCase(a_host, b_host) and (a.port orelse default_port) == (b.port orelse default_port);
}

fn resolveLocation(gpa: Allocator, current: []const u8, location: []const u8) ![]u8 {
    const base = try std.Uri.parse(current);
    const capacity = current.len + location.len * 2 + 16;
    var buffer = try gpa.alloc(u8, capacity);
    defer gpa.free(buffer);
    @memcpy(buffer[0..location.len], location);
    var spare = buffer;
    const resolved = try base.resolveInPlace(location.len, &spare);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try resolved.format(&out.writer);
    return out.toOwnedSlice();
}

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

/// `transport_gpa` must outlive pooled sessions (until pool.shutdown).
/// `result_allocator` may be a request-scoped arena; no pooled allocation
/// or live I/O retains its output after this function returns.
pub fn post(transport_gpa: Allocator, result_allocator: Allocator, io: Io, client: *std.http.Client, url: []const u8, bearer: []const u8, body: []const u8, deadline_ms: u64) !Response {
    var ex: Exchange = .{ .gpa = transport_gpa, .io = io, .client = client, .url = url, .bearer = bearer, .body = body, .limit = max_body };
    try watched(&ex, deadline_ms);
    return .{ .status = ex.status, .body = try result_allocator.dupe(u8, ex.bytes[0..ex.len]) };
}

/// `transport_gpa` owns pooled connections. `result_allocator` may be a
/// request arena; the bounded body is copied into it after the worker joins.
pub fn get(transport_gpa: Allocator, result_allocator: Allocator, io: Io, client: *std.http.Client, url: []const u8, headers: []const std.http.Header, limit: usize, deadline_ms: u64) !Response {
    if (limit == 0) return error.EmptyBuffer;
    const buffer = try transport_gpa.alloc(u8, limit);
    defer transport_gpa.free(buffer);
    var ex: Exchange = .{ .gpa = transport_gpa, .io = io, .client = client, .url = url, .bearer = "", .body = "", .limit = limit, .method = .get, .headers = headers, .large_bytes = buffer };
    try watched(&ex, deadline_ms);
    return .{ .status = ex.status, .body = try result_allocator.dupe(u8, buffer[0..ex.len]) };
}

test "loopback catalog HTTP2 GET preserves headers, pages, status, size, and deadline" {
    const value = std.c.getenv("GRAFF_CATALOG_HTTP2_URL") orelse return error.SkipZigTest;
    const base = std.mem.span(value);
    const io = std.testing.io;
    const saved = @import("main.zig").g_http2;
    defer @import("main.zig").g_http2 = saved;
    @import("main.zig").g_http2 = true;
    defer pool.shutdown(io);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    const ca_value = std.c.getenv("GRAFF_CATALOG_CA_CERT") orelse return error.SkipZigTest;
    const now = Io.Clock.real.now(io);
    try client.ca_bundle.rescan(std.testing.allocator, io, now);
    try client.ca_bundle.addCertsFromFilePathAbsolute(std.testing.allocator, io, now, std.mem.span(ca_value));
    client.now = now;
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "x-api-key", .value = "fixture-key" },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first_url = try std.fmt.allocPrint(arena, "{s}/v1/models?limit=1000", .{base});
    const first = try get(std.testing.allocator, arena, io, &client, first_url, &headers, 2 * 1024 * 1024, 2000);
    try std.testing.expectEqual(@as(u16, 200), first.status);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"first\"") != null);
    const second_url = try std.fmt.allocPrint(arena, "{s}/v1/models?limit=1000&after_id=first", .{base});
    const second = try get(std.testing.allocator, arena, io, &client, second_url, &headers, 2 * 1024 * 1024, 2000);
    try std.testing.expectEqual(@as(u16, 200), second.status);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "\"second\"") != null);
    const redirect_url = try std.fmt.allocPrint(arena, "{s}/redirect", .{base});
    const redirected = try get(std.testing.allocator, arena, io, &client, redirect_url, &headers, 512, 2000);
    try std.testing.expectEqual(@as(u16, 200), redirected.status);
    try std.testing.expect(std.mem.indexOf(u8, redirected.body, "\"first\"") != null);
    const cross_url = try std.fmt.allocPrint(arena, "{s}/cross-redirect", .{base});
    const crossed = try get(std.testing.allocator, arena, io, &client, cross_url, &headers, 512, 2000);
    try std.testing.expectEqual(@as(u16, 200), crossed.status);
    const loop_url = try std.fmt.allocPrint(arena, "{s}/cross-loop", .{base});
    try std.testing.expectError(error.TooManyHttpRedirects, get(std.testing.allocator, arena, io, &client, loop_url, &headers, 512, 2000));
    const denied_url = try std.fmt.allocPrint(arena, "{s}/deny", .{base});
    const denied = try get(std.testing.allocator, arena, io, &client, denied_url, &headers, 512, 2000);
    try std.testing.expectEqual(@as(u16, 401), denied.status);
    try std.testing.expectEqual(@as(usize, 0), denied.body.len);
    const large_url = try std.fmt.allocPrint(arena, "{s}/oversize", .{base});
    try std.testing.expectError(error.ResponseTooLarge, get(std.testing.allocator, arena, io, &client, large_url, &headers, 512, 2000));
    const valid_url = try std.fmt.allocPrint(arena, "{s}/large-valid", .{base});
    const valid = try get(std.testing.allocator, arena, io, &client, valid_url, &headers, 16 * 1024 * 1024, 15_000);
    try std.testing.expect(valid.body.len > 2 * 1024 * 1024);
    const parsed = @import("router_catalog.zig").parseModels(arena, "anthropic", valid.body) orelse return error.ExpectedValidCatalog;
    try std.testing.expectEqual(@as(usize, 1), parsed.models.len);
    try std.testing.expectEqualStrings("large", parsed.models[0].name);
    const stall_url = try std.fmt.allocPrint(arena, "{s}/stall", .{base});
    try std.testing.expectError(error.DeadlineExceeded, get(std.testing.allocator, arena, io, &client, stall_url, &headers, 512, 100));
    const h1_value = std.c.getenv("GRAFF_CATALOG_H1_URL") orelse return error.SkipZigTest;
    const h1_url = try std.fmt.allocPrint(arena, "{s}/v1/models?limit=1000", .{std.mem.span(h1_value)});
    const h1_response = try get(std.testing.allocator, arena, io, &client, h1_url, &headers, 512, 2000);
    try std.testing.expectEqual(@as(u16, 200), h1_response.status);
    try std.testing.expect(std.mem.indexOf(u8, h1_response.body, "\"first\"") != null);
    const h1_redirect_url = try std.fmt.allocPrint(arena, "{s}/redirect", .{std.mem.span(h1_value)});
    const h1_redirected = try get(std.testing.allocator, arena, io, &client, h1_redirect_url, &headers, 512, 2000);
    try std.testing.expectEqual(@as(u16, 200), h1_redirected.status);
    const h1_cross_url = try std.fmt.allocPrint(arena, "{s}/cross-redirect", .{std.mem.span(h1_value)});
    const h1_crossed = try get(std.testing.allocator, arena, io, &client, h1_cross_url, &headers, 512, 2000);
    try std.testing.expectEqual(@as(u16, 200), h1_crossed.status);
    const h1_denied_url = try std.fmt.allocPrint(arena, "{s}/deny-stall", .{std.mem.span(h1_value)});
    const h1_denied = try get(std.testing.allocator, arena, io, &client, h1_denied_url, &headers, 512, 500);
    try std.testing.expectEqual(@as(u16, 401), h1_denied.status);
    try std.testing.expectEqual(@as(usize, 0), h1_denied.body.len);
    const h1_oversize_url = try std.fmt.allocPrint(arena, "{s}/oversize", .{std.mem.span(h1_value)});
    try std.testing.expectError(error.ResponseTooLarge, get(std.testing.allocator, arena, io, &client, h1_oversize_url, &headers, 512, 2000));
}

test "catalog redirect origin includes scheme, host, and port" {
    try std.testing.expect(sameOrigin("https://example.test/models", "https://EXAMPLE.test:443/next"));
    try std.testing.expect(!sameOrigin("https://example.test/models", "https://example.test:444/next"));
    try std.testing.expect(!sameOrigin("https://example.test/models", "http://example.test/next"));
    try std.testing.expect(!sameOrigin("https://example.test/models", "https://other.test/next"));
    try std.testing.expect(!sameOrigin("https://example.test/models", "https://%65xample.test/next"));
    try std.testing.expect(!redirects(304));
    try std.testing.expect(redirects(308));
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
    try std.testing.expectError(error.DeadlineExceeded, post(std.testing.allocator, std.testing.allocator, io, &client, url, "Bearer fixture", "{}", 100));
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
    const response = post(std.testing.allocator, std.testing.allocator, io, &client, std.mem.span(value), "Bearer fixture", "{}", 1000) catch |err| {
        try std.testing.expect(err == error.RstStream or err == error.ReadFailed or err == error.EndOfStream);
        return;
    };
    std.testing.allocator.free(response.body);
    return error.ExpectedAmbiguousFailure;
}

test "loopback HTTP2 reuses a pooled session after result arena destruction" {
    const value = std.c.getenv("GRAFF_JEV_HTTP2_REUSE_URL") orelse return error.SkipZigTest;
    const io = std.testing.io;
    const saved = @import("main.zig").g_http2;
    defer @import("main.zig").g_http2 = saved;
    @import("main.zig").g_http2 = true;
    defer pool.shutdown(io);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    for (0..2) |_| {
        var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer temp.deinit(); // response, bearer and body die before pool reuse
        const a = temp.allocator();
        const bearer = try a.dupe(u8, "Bearer fixture");
        const body = try a.dupe(u8, "{}");
        const response = try post(std.testing.allocator, a, io, &client, std.mem.span(value), bearer, body, 1000);
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    }
}
