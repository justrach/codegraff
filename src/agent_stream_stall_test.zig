//! (#680) The SSE reader's stall ladder, end to end against a loopback HTTP
//! server: one chat-completions prose delta, then silence. Drives the REAL
//! production entry point (agent_stream.postStreamWithClient) three times the
//! way request() does across its two stall reconnects, and asserts each
//! attempt waited ITS OWN budget — a quarter, a half, then all of the
//! configured total — rather than the same tightened wait three times.
//!
//! Same spirit as agent_ws_mock.zig: `provider.url` points at 127.0.0.1, and
//! no network, key or provider is used.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const agent_stream = @import("agent_stream.zig");
const Agent = @import("agent.zig").Agent;
const deinitMarkdown = @import("agent_render.zig").deinitMarkdown;
const nowMs = @import("agent_ws_mock.zig").nowMs;

/// One chat-completions delta with visible prose: the reader grows
/// partial_text on it, which is the tokens-flowing signal that tightens the
/// between-lines budget. After it, the socket stays open and silent.
const prose_line = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n";

/// The provider's terminal event: with it the response is complete and the
/// reader returns; without it the socket is a stream that went quiet.
const done_line = "data: [DONE]\n\n";

const Srv = struct {
    /// Drain the request head, send the SSE head plus one prose delta (plus
    /// the terminal event when `finish`). The socket then stays open with no
    /// further byte, so a client that gives up sees silence (a stall), never
    /// EOF (a drop).
    fn answer(io: Io, c: std.Io.net.Stream, finish: bool) void {
        var rbuf: [8192]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
        while (true) {
            const l = (sr.interface.takeDelimiter('\n') catch return) orelse return;
            if (l.len == 0 or (l.len == 1 and l[0] == '\r')) break; // end of headers
        }
        var wbuf: [1024]u8 = undefined;
        var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
        sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" ++ prose_line) catch return;
        if (finish) sw.interface.writeAll(done_line) catch return;
        sw.interface.flush() catch return;
    }

    /// `conns` streams that go quiet, in turn (the #680 ladder). Every
    /// accepted socket is kept until the test is over.
    fn run(io: Io, server: *std.Io.net.Server, conns: usize, done: *std.atomic.Value(bool)) void {
        var held: [3]?std.Io.net.Stream = @splat(null);
        defer for (held) |h| if (h) |c| c.close(io);
        var i: usize = 0;
        while (i < conns) : (i += 1) {
            const c = server.accept(io) catch return;
            held[i] = c;
            answer(io, c, false);
        }
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch return;
    }

    /// One complete stream, then one that goes quiet (#682).
    fn runTwo(io: Io, server: *std.Io.net.Server, done: *std.atomic.Value(bool)) void {
        var held: [2]?std.Io.net.Stream = @splat(null);
        defer for (held) |h| if (h) |c| c.close(io);
        for (0..2) |i| {
            const c = server.accept(io) catch return;
            held[i] = c;
            answer(io, c, i == 0);
        }
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch return;
    }
};

fn testProvider(url: []const u8) @import("provider.zig").Provider {
    return .{ .id = "test", .kind = .openai, .auth = .bearer, .url = url, .api_key = "k", .model = "m", .context = 0 };
}

// #682: a subagent (`sub`, no paint) used to take the buffered 5-minute POST,
// so a provider that goes quiet — or an edge that times a long non-streaming
// generation out — cost it 250s+ per attempt. It now streams like the root:
// a complete stream returns, and a silent one trips the stream watchdog at
// the pre-prose budget (nothing grows partial_text with no frontend), not
// post_deadline_ms.
test "#682: a subagent-shaped agent streams — completes on the terminal event, stalls on the stream budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    // Connection 1 finishes its stream; connection 2 goes quiet after the prose.
    var fut = io.async(Srv.runTwo, .{ io, &server, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    const saved_stream = http.stream_stall_ms;
    const saved_post = http.post_deadline_ms;
    http.stream_stall_ms = 1200; // protocol-seen budget: what a no-paint stream arms after its first line
    http.post_deadline_ms = 60 * 1000; // the buffered path's ceiling — must NOT be what bounds this
    defer http.stream_stall_ms = saved_stream;
    defer http.post_deadline_ms = saved_post;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
    var child: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = testProvider(url),
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = "child",
        .out = null,
    };
    try std.testing.expect(child.usesLiveTransport());

    const t0 = nowMs(io);
    const first = agent_stream.postStreamWithClient(&child, &client, "{}");
    const t1 = nowMs(io);
    const second = agent_stream.postStreamWithClient(&child, &client, "{}");
    const t2 = nowMs(io);

    const body = try first;
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[DONE]") != null);
    try std.testing.expect(t1 - t0 < 1000); // returned on the terminal event, no wait
    try std.testing.expectError(error.StreamStalled, second);
    try std.testing.expect(t2 - t1 >= 1150 and t2 - t1 < 2400); // the stream budget, not the 60s POST deadline
    try std.testing.expectEqual(@as(u64, 1200), child.stall.tripped_ms);
}

test "#680: each stall reconnect widens the between-lines wait the SSE reader arms" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io); // registered first → torn down LAST, after the task is joined
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Srv.run, .{ io, &server, @as(usize, 3), &done });
    defer fut.await(io);
    defer done.store(true, .release); // …so the LIFO order is: signal, join, close

    // Scale the budget down so the ladder fits a test: base 1200ms, so the
    // three attempts arm 300 / 600 / 1200ms once prose has flowed. The 15s
    // floor would otherwise make every rung identical; both are process-wide.
    const saved_stream = http.stream_stall_ms;
    const saved_floor = http_stall.idle_floor_ms;
    http.stream_stall_ms = 1200;
    http_stall.idle_floor_ms = 100;
    defer http.stream_stall_ms = saved_stream;
    defer http_stall.idle_floor_ms = saved_floor;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Io.Writer.Allocating = .init(gpa); // a writer: printDelta only grows partial_text for an agent with a frontend
    defer out.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = url, .api_key = "k", .model = "m", .context = 0 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = &out.writer,
    };
    defer deinitMarkdown(&agent);

    // All three attempts run before any assertion, so a failure can never
    // leave the server blocked in accept() with the join waiting on it.
    var waits: [3]i64 = undefined;
    var errs: [3]?anyerror = @splat(null);
    for (0..3) |i| {
        if (i > 0) agent_stream.noteStallRetry(&agent, i); // what request() does before each reconnect
        const t0 = nowMs(io);
        const r = agent_stream.postStreamWithClient(&agent, &client, "{}");
        waits[i] = nowMs(io) - t0;
        if (r) |ok| gpa.free(ok) else |e| errs[i] = e;
    }
    for (errs) |e| try std.testing.expectEqual(@as(?anyerror, error.StreamStalled), e);
    // Each attempt waited its own rung — comfortably past its budget (so the
    // watchdog really ran) and comfortably short of the next rung's.
    try std.testing.expect(waits[0] >= 250 and waits[0] < 550);
    try std.testing.expect(waits[1] >= 550 and waits[1] < 1100);
    try std.testing.expect(waits[2] >= 1150 and waits[2] < 2200);
    // The give-up message reports the wait that actually tripped.
    try std.testing.expectEqual(@as(u64, 1200), agent.stall.tripped_ms);
    const msg = agent_stream.stallGiveUpMessage(&agent, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, msg, "for 1s") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "after 2 reconnect attempts") != null);
}
