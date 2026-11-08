//! A body still draining to the peer is not a hung request (#1785).
//! Synthetic loopback peer drives the production HTTP/1 SSE entry point.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const agent_stream = @import("agent_stream.zig");

const head_ms: u64 = 150; // not 30_000: the loopback head exception stays off
const paced_len: usize = 2 * 1024 * 1024;

const Peer = struct {
    const Mode = enum { paced, stopped };

    fn run(io: Io, listener: *Io.net.Server, mode: Mode, got: *std.atomic.Value(usize), done: *std.atomic.Value(bool)) void {
        const conn = listener.accept(io) catch return;
        defer conn.close(io);
        if (mode == .stopped) {
            while (!done.load(.acquire)) io.sleep(.fromMilliseconds(10), .awake) catch return;
            return;
        }
        var input_buf: [8192]u8 = undefined;
        var input = Io.net.Stream.Reader.init(conn, io, &input_buf);
        var len: usize = 0;
        while (true) {
            const line = (input.interface.takeDelimiter('\n') catch return) orelse return;
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
            const name = "content-length:";
            if (line.len > name.len and std.ascii.eqlIgnoreCase(line[0..name.len], name))
                len = std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \r"), 10) catch return;
        }
        // 32 KiB per 10 ms: the whole body takes several head budgets.
        var since_pause: usize = 0;
        while (got.load(.monotonic) < len) {
            const n = @min(len - got.load(.monotonic), 8192);
            input.interface.discardAll(n) catch return;
            _ = got.fetchAdd(n, .monotonic);
            since_pause += n;
            if (since_pause >= 32 * 1024) {
                since_pause = 0;
                io.sleep(.fromMilliseconds(10), .awake) catch return;
            }
        }
        var output_buf: [1024]u8 = undefined;
        var output = Io.net.Stream.Writer.init(conn, io, &output_buf);
        output.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n") catch return;
        output.interface.flush() catch return;
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn exercise(mode: Peer.Mode, body_len: usize) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // loopback buffer sizing is not deterministic there
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try Io.net.IpAddress.listen(&addr, io, .{});
    defer listener.deinit(io);
    // A small receive buffer keeps the peer's pace, not the kernel, in charge.
    const rcvbuf: c_int = 16 * 1024;
    if (builtin.os.tag != .windows) std.posix.setsockopt(listener.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&rcvbuf)) catch {};
    var got: std.atomic.Value(usize) = .init(0);
    var done: std.atomic.Value(bool) = .init(false);
    var peer = try io.concurrent(Peer.run, .{ io, &listener, mode, &got, &done });
    defer peer.await(io);
    defer done.store(true, .release);

    const saved_head = http.head_stall_ms;
    const saved_stream = http.stream_stall_ms;
    http.head_stall_ms = head_ms;
    http.stream_stall_ms = 1000;
    defer http.head_stall_ms = saved_head;
    defer http.stream_stall_ms = saved_stream;

    const body = try gpa.alloc(u8, body_len);
    defer gpa.free(body);
    @memset(body, ' ');
    body[0] = '{';
    body[body.len - 1] = '}';

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{listener.socket.address.getPort()});
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .io = io,
        .client = &client,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = url, .api_key = "synthetic", .model = "fixture", .context = 0 },
        .messages = std.json.Array.init(arena_state.allocator()),
        .sub = true,
        .label = "fixture",
        .out = null,
    };
    const t0 = nowMs(io);
    const response = agent_stream.postStreamWithClient(&agent, &client, body);
    const ms: u64 = @intCast(nowMs(io) - t0);
    switch (mode) {
        .paced => {
            const reply = try response;
            defer gpa.free(reply);
            try std.testing.expect(std.mem.indexOf(u8, reply, "data: [DONE]") != null);
            try std.testing.expectEqual(body_len, got.load(.monotonic));
            try std.testing.expect(ms > 2 * head_ms); // the old flat head deadline would have fired
        },
        .stopped => {
            if (response) |reply| gpa.free(reply) else |_| {}
            try std.testing.expectError(error.HungRequest, response);
            try std.testing.expect(ms >= head_ms);
            try std.testing.expect(ms < 3000);
        },
    }
}

test "#1785: a paced upload longer than the head budget completes" {
    try exercise(.paced, paced_len);
}

test "#1785: a peer that stops reading the body still fails within a bound" {
    // Larger than any plausible loopback send+receive buffer pair, so the
    // write genuinely blocks.
    try exercise(.stopped, 16 * 1024 * 1024);
}
