//! Measured hot-path checks for reuse on the networks graff already speaks:
//! process-warmed WSS CA, MCP Streamable HTTP keep-alive, and the source
//! guards that keep those clients from becoming throwaways again.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const http_warm = @import("http_warm.zig");
const mcp_http = @import("mcp_http.zig");
const mcp_lifecycle = @import("mcp_lifecycle.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_rpc = @import("mcp_rpc.zig");

test "WSS CA bundle is scanned from disk at most once per process" {
    const io = std.testing.io;
    const before = http_warm.process_ca_rescans;
    try http_warm.ensureProcessCa(io);
    const mid = http_warm.process_ca_rescans;
    try http_warm.ensureProcessCa(io);
    const after = http_warm.process_ca_rescans;
    try std.testing.expect(mid == before or mid == before + 1);
    try std.testing.expectEqual(mid, after);
    try std.testing.expect(http_warm.processCa().map.count() > 0);
}

test "MCP initialized notify reuses the persistent HTTP client" {
    const src = @embedFile("mcp_rpc.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "fn httpInitializedTask(http: *mcp_http.HttpTransport") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "http.client.io.concurrent(httpInitializedTask, .{ http,") != null);
    const throwaway = "var transport: " ++ "mcp_http.HttpTransport";
    try std.testing.expect(std.mem.indexOf(u8, src, throwaway) == null);
}

test "WS→SSE fallback latches the prewarmed Agent client, not a fresh pool" {
    const src = @embedFile("agent_ws.zig");
    const latch = std.mem.indexOf(u8, src, "return self.postStream(body);").?;
    try std.testing.expect(std.mem.indexOf(u8, src, "postStreamFresh") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "using persistent prewarmed SSE") != null);
    _ = latch;
}

const ListSrv = struct {
    accepts: *std.atomic.Value(u8),
    posts: *std.atomic.Value(u8),
    done: *std.atomic.Value(bool),

    fn run(self: *ListSrv, io: Io, listener: *std.Io.net.Server) void {
        while (!self.done.load(.acquire)) {
            const stream = listener.accept(io) catch {
                if (self.done.load(.acquire)) return;
                continue;
            };
            _ = self.accepts.fetchAdd(1, .monotonic);
            defer stream.close(io);
            self.serveConn(io, stream) catch {};
        }
    }

    fn serveConn(self: *ListSrv, io: Io, stream: std.Io.net.Stream) !void {
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var rd = std.Io.net.Stream.Reader.init(stream, io, &rbuf);
        var wr = std.Io.net.Stream.Writer.init(stream, io, &wbuf);
        const r = &rd.interface;
        const w = &wr.interface;
        while (self.posts.load(.acquire) < 2) {
            var content_len: usize = 0;
            while (true) {
                const line = (r.takeDelimiter('\n') catch return) orelse return;
                if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const raw = if (line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                    const v = std.mem.trim(u8, raw["content-length:".len..], " \t");
                    content_len = std.fmt.parseInt(usize, v, 10) catch 0;
                }
            }
            if (content_len > 0) _ = try r.take(content_len);
            const n = self.posts.fetchAdd(1, .monotonic) + 1;
            const body = if (n == 1)
                \\{"jsonrpc":"2.0","id":1,"result":{"tools":[],"supportedVersions":["2026-07-28"]}}
            else
                \\{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
            ;
            try w.print(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n{s}",
                .{ body.len, body },
            );
            try w.flush();
        }
    }
};

test "MCP modern connect + next list reuse one TCP connection" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer listener.deinit(io);

    var accepts: std.atomic.Value(u8) = .init(0);
    var posts: std.atomic.Value(u8) = .init(0);
    var done: std.atomic.Value(bool) = .init(false);
    var srv: ListSrv = .{ .accepts = &accepts, .posts = &posts, .done = &done };
    var fut = io.async(ListSrv.run, .{ &srv, io, &listener });
    defer fut.await(io);
    defer done.store(true, .release);
    defer if (std.Io.net.IpAddress.connect(&listener.socket.address, io, .{ .mode = .stream })) |s| s.close(io) else |_| {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server: mcp_rpc.Server = .{
        .name = "loop",
        .transport = .{ .http = .{
            .url = url,
            .client = .{ .allocator = gpa, .io = io },
        } },
    };
    defer server.transport.http.client.deinit();

    const first = try mcp_lifecycle.connectHttp(&server, arena, arena, .unknown);
    try std.testing.expect(first.object.get("result") != null);
    const second = try mcp_rpc.request(&server, arena, "{}", "tools/list", null);
    try std.testing.expect(second.object.get("result") != null);

    try std.testing.expectEqual(@as(u8, 1), accepts.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 2), posts.load(.monotonic));
}

test "MCP HTTP advertises gzip and decompresses a smaller wire body" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var plain_w: Io.Writer.Allocating = .init(gpa);
    defer plain_w.deinit();
    try plain_w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[");
    for (0..40) |i| {
        if (i != 0) try plain_w.writer.writeByte(',');
        try plain_w.writer.print(
            "{{\"name\":\"tool_{d}\",\"description\":\"search the workspace and return matching files\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"q\":{{\"type\":\"string\"}}}}}}}}",
            .{i},
        );
    }
    try plain_w.writer.writeAll("],\"supportedVersions\":[\"2026-07-28\"]}}");
    const plain = plain_w.writer.buffered();

    const gz = try gzipAlloc(gpa, plain);
    defer gpa.free(gz);
    try std.testing.expect(gz.len < plain.len);

    var saw_accept_gzip = std.atomic.Value(bool).init(false);
    var wire_len = std.atomic.Value(usize).init(0);

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer listener.deinit(io);
    const Srv = struct {
        fn run(
            io_: Io,
            listener_: *std.Io.net.Server,
            gz_: []const u8,
            saw: *std.atomic.Value(bool),
            wire: *std.atomic.Value(usize),
        ) void {
            const stream = listener_.accept(io_) catch return;
            defer stream.close(io_);
            var rbuf: [4096]u8 = undefined;
            var rd = std.Io.net.Stream.Reader.init(stream, io_, &rbuf);
            const r = &rd.interface;
            var content_len: usize = 0;
            var accept_enc: bool = false;
            while (true) {
                const line = (r.takeDelimiter('\n') catch return) orelse return;
                if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
                if (std.ascii.startsWithIgnoreCase(line, "accept-encoding:") and
                    std.mem.indexOf(u8, line, "gzip") != null) accept_enc = true;
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    const raw = if (line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                    content_len = std.fmt.parseInt(usize, std.mem.trim(u8, raw["content-length:".len..], " \t"), 10) catch 0;
                }
            }
            if (content_len > 0) _ = r.take(content_len) catch {};
            saw.store(accept_enc, .release);
            wire.store(gz_.len, .release);
            var wbuf: [1024]u8 = undefined;
            var wr = std.Io.net.Stream.Writer.init(stream, io_, &wbuf);
            wr.interface.print(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                .{gz_.len},
            ) catch return;
            wr.interface.writeAll(gz_) catch return;
            wr.interface.flush() catch {};
        }
    };
    var fut = io.async(Srv.run, .{ io, &listener, gz, &saw_accept_gzip, &wire_len });
    defer fut.await(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/mcp", .{listener.socket.address.getPort()});
    var http: mcp_http.HttpTransport = .{
        .url = url,
        .client = .{ .allocator = gpa, .io = io },
    };
    defer http.client.deinit();
    const body = (try mcp_http.post(&http, "{}", .{
        .protocol_version = mcp_protocol.modern_protocol,
        .method = "tools/list",
        .modern = true,
    }, 1)) orelse return error.TestUnexpectedResult;
    defer gpa.free(body);

    try std.testing.expect(saw_accept_gzip.load(.acquire));
    try std.testing.expectEqual(gz.len, wire_len.load(.acquire));
    try std.testing.expect(wire_len.load(.acquire) < plain.len);
    try std.testing.expectEqualStrings(plain, body);
}

test "MCP HTTP no longer omits Accept-Encoding" {
    const src = @embedFile("mcp_http.zig");
    const omit = "accept_encoding = " ++ ".omit";
    try std.testing.expect(std.mem.indexOf(u8, src, omit) == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "readerDecompressing") != null);
}

fn gzipAlloc(gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(std.compress.flate.Compress);
    defer gpa.destroy(c);
    c.* = try std.compress.flate.Compress.init(&out, window, .gzip, .default);
    try c.writer.writeAll(plain);
    try c.finish();
    return gpa.dupe(u8, out.buffered());
}
