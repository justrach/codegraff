//! Built-in HTTP GET text fetcher for the `webfetch` tool.
//!
//! Uses a dedicated `std.http.Client` with a bounded 64 KiB response-header and
//! redirect buffer ceiling so public pages with large CSP/cookie headers do not
//! fail at stdlib's 8 KiB default (`HttpHeadersOversize`, #1911), while keeping
//! memory bounded and returning actionable diagnostics when a limit is exceeded.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolOutput = tools.ToolOutput;
const harness_version = @import("main.zig").harness_version;

/// Explicit bounded ceiling for HTTP response headers (and redirect headers).
pub const header_cap: usize = 64 * 1024;
/// Capture ceiling for raw HTML/text response bodies.
pub const body_cap: usize = 256 * 1024;

/// Format a transport error from `webfetch` into an actionable diagnostic.
pub fn formatFetchError(gpa: Allocator, url: []const u8, err: anyerror) ToolOutput {
    return switch (err) {
        error.HttpHeadersOversize => .{
            .text = std.fmt.allocPrint(
                gpa,
                "webfetch failed for {s}: HTTP response headers exceeded the {d} KiB header limit (HttpHeadersOversize). Use shell (e.g. curl) if you need to inspect this URL.",
                .{ url, header_cap / 1024 },
            ) catch return .{ .is_error = true },
            .is_error = true,
        },
        error.TooManyHttpRedirects => .{
            .text = std.fmt.allocPrint(
                gpa,
                "webfetch failed for {s}: too many HTTP redirects (TooManyHttpRedirects).",
                .{url},
            ) catch return .{ .is_error = true },
            .is_error = true,
        },
        error.HttpConnectionClosing, error.EndOfStream, error.ReadFailed => .{
            .text = std.fmt.allocPrint(
                gpa,
                "webfetch failed for {s}: connection closed while reading response ({s}). Retry or use shell (e.g. curl).",
                .{ url, @errorName(err) },
            ) catch return .{ .is_error = true },
            .is_error = true,
        },
        else => tools.failure(gpa, err),
    };
}

/// Fetch `url` with a bounded response-header policy (`header_cap`) and body
/// ceiling (`body_cap`). Uses an isolated `std.http.Client` sharing `client.io`
/// and proxy config so enlarged header buffers never bloat the pooled inference
/// client or race its active connections.
pub fn fetch(gpa: Allocator, client: *std.http.Client, url: []const u8) ToolOutput {
    const buf = gpa.alloc(u8, body_cap) catch return .{ .is_error = true };
    defer gpa.free(buf);
    const redirect_buf = gpa.alloc(u8, header_cap) catch return .{ .is_error = true };
    defer gpa.free(redirect_buf);

    var wf_client: std.http.Client = .{
        .allocator = gpa,
        .io = client.io,
        .read_buffer_size = header_cap,
        .http_proxy = client.http_proxy,
        .https_proxy = client.https_proxy,
    };
    defer wf_client.deinit();

    var w: Io.Writer = .fixed(buf);
    var truncated = false;
    var status: ?std.http.Status = null;
    if (wf_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &w,
        .redirect_buffer = redirect_buf,
        .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
    })) |res| {
        status = res.status;
    } else |err| switch (err) {
        error.WriteFailed => truncated = true, // body hit the cap: keep what we have
        else => return formatFetchError(gpa, url, err),
    }

    const body = w.buffered();
    if (status) |st| {
        const code = @backingInt(st);
        if (code < 200 or code >= 300) return .{
            .text = std.fmt.allocPrint(gpa, "HTTP {d} {s}", .{ code, st.phrase() orelse "" }) catch return .{ .is_error = true },
            .is_error = true,
        };
    }
    if (std.mem.indexOfScalar(u8, body[0..@min(body.len, 4096)], 0) != null) return .{
        .text = std.fmt.allocPrint(gpa, "{s} returned binary content ({d} bytes) — webfetch only handles text; use bash (e.g. curl -o) to download it", .{ url, body.len }) catch return .{ .is_error = true },
        .is_error = true,
    };
    if (tools.blankText(body)) return .{ .text = gpa.dupe(u8, "(empty response body)") catch return .{ .is_error = true } };
    var aw: Io.Writer.Allocating = .init(gpa);
    aw.writer.writeAll(body) catch {
        aw.deinit();
        return .{ .is_error = true };
    };
    if (truncated) aw.writer.print("\n[truncated at {d} KB]", .{body_cap / 1024}) catch {};
    return .{ .text = aw.toOwnedSlice() catch return .{ .is_error = true } };
}

fn readRequestPath(input: *Io.Reader, path_buf: []u8) ?[]const u8 {
    const req_line = (input.takeDelimiter('\n') catch return null) orelse return null;
    var parts = std.mem.tokenizeAny(u8, req_line, " \r");
    _ = parts.next() orelse return null; // method
    const raw_path = parts.next() orelse return null;
    if (raw_path.len > path_buf.len) return null;
    @memcpy(path_buf[0..raw_path.len], raw_path);
    while (true) {
        const line = (input.takeDelimiter('\n') catch return null) orelse break;
        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
    }
    return path_buf[0..raw_path.len];
}

fn writePaddedHeaders(out: *Io.Writer, count: usize) !void {
    const val = @as([240]u8, @splat('v'));
    for (0..count) |i| {
        try out.print("X-Pad-{d:0>4}: {s}\r\n", .{ i, val });
    }
}

const SyntheticServer = struct {
    const Mode = enum { large_ok, large_redirect, oversize };

    fn serve(io: Io, listener: *Io.net.Server, mode: Mode) void {
        const conns: usize = if (mode == .large_redirect) 2 else 1;
        for (0..conns) |_| {
            const conn = listener.accept(io) catch return;
            defer conn.close(io);
            var rbuf: [4096]u8 = undefined;
            var reader = Io.net.Stream.Reader.init(conn, io, &rbuf);
            var pbuf: [256]u8 = undefined;
            const path = readRequestPath(&reader.interface, &pbuf) orelse return;

            var wbuf: [4096]u8 = undefined;
            var writer = Io.net.Stream.Writer.init(conn, io, &wbuf);
            switch (mode) {
                .large_ok => {
                    const body = "Public document body with large headers.";
                    writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n", .{body.len}) catch return;
                    // ~16 KiB of headers (> stdlib's 8 KiB default, < header_cap)
                    writePaddedHeaders(&writer.interface, 64) catch return;
                    writer.interface.writeAll("\r\n") catch return;
                    writer.interface.writeAll(body) catch return;
                },
                .large_redirect => {
                    if (std.mem.eql(u8, path, "/start")) {
                        writer.interface.writeAll("HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n") catch return;
                        writePaddedHeaders(&writer.interface, 64) catch return;
                        writer.interface.writeAll("\r\n") catch return;
                    } else {
                        const body = "Redirected document body after large headers.";
                        writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n", .{body.len}) catch return;
                        writePaddedHeaders(&writer.interface, 64) catch return;
                        writer.interface.writeAll("\r\n") catch return;
                        writer.interface.writeAll(body) catch return;
                    }
                },
                .oversize => {
                    const body = "Too many headers.";
                    writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n", .{body.len}) catch return;
                    // ~72 KiB of headers (> header_cap)
                    writePaddedHeaders(&writer.interface, 290) catch return;
                    writer.interface.writeAll("\r\n") catch return;
                    writer.interface.writeAll(body) catch return;
                },
            }
            writer.interface.flush() catch return;
        }
    }
};

test "#1911: webfetch handles large response headers, redirects, and reports header limit clearly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // 1) Small body + ~16 KiB response headers succeeds.
    {
        var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        var listener = try Io.net.IpAddress.listen(&addr, io, .{});
        defer listener.deinit(io);
        var srv = try io.concurrent(SyntheticServer.serve, .{ io, &listener, SyntheticServer.Mode.large_ok });
        defer srv.await(io);

        var shared: std.http.Client = .{ .allocator = gpa, .io = io };
        defer shared.deinit();
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/doc", .{listener.socket.address.getPort()});
        defer gpa.free(url);

        const out = fetch(gpa, &shared, url);
        defer gpa.free(out.text);
        try std.testing.expect(!out.is_error);
        try std.testing.expectEqualStrings("Public document body with large headers.", out.text);
    }

    // 2) Redirect with ~16 KiB headers on both hops succeeds.
    {
        var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        var listener = try Io.net.IpAddress.listen(&addr, io, .{});
        defer listener.deinit(io);
        var srv = try io.concurrent(SyntheticServer.serve, .{ io, &listener, SyntheticServer.Mode.large_redirect });
        defer srv.await(io);

        var shared: std.http.Client = .{ .allocator = gpa, .io = io };
        defer shared.deinit();
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/start", .{listener.socket.address.getPort()});
        defer gpa.free(url);

        const out = fetch(gpa, &shared, url);
        defer gpa.free(out.text);
        try std.testing.expect(!out.is_error);
        try std.testing.expectEqualStrings("Redirected document body after large headers.", out.text);
    }

    // 3) Headers exceeding the 64 KiB policy produce an actionable diagnostic naming the limit.
    {
        var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        var listener = try Io.net.IpAddress.listen(&addr, io, .{});
        defer listener.deinit(io);
        var srv = try io.concurrent(SyntheticServer.serve, .{ io, &listener, SyntheticServer.Mode.oversize });
        defer srv.await(io);

        var shared: std.http.Client = .{ .allocator = gpa, .io = io };
        defer shared.deinit();
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/huge", .{listener.socket.address.getPort()});
        defer gpa.free(url);

        const out = fetch(gpa, &shared, url);
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "64 KiB") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "HttpHeadersOversize") != null);
    }
}
