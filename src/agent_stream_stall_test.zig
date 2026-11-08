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
    /// EOF (a drop). False, with nothing sent, for anything but a POST.
    fn answer(io: Io, c: std.Io.net.Stream, finish: bool) bool {
        if (!takePostHead(io, c)) return false;
        var wbuf: [1024]u8 = undefined;
        var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
        sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" ++ prose_line) catch return true;
        if (finish) sw.interface.writeAll(done_line) catch return true;
        sw.interface.flush() catch return true;
        return true;
    }

    /// `conns` streams that go quiet, in turn (the #680 ladder). Every
    /// accepted socket is kept until the test is over.
    fn run(io: Io, server: *std.Io.net.Server, conns: usize, done: *std.atomic.Value(bool)) void {
        var held: [3]?std.Io.net.Stream = @splat(null);
        defer for (held) |h| if (h) |c| c.close(io);
        var i: usize = 0;
        while (i < conns) {
            const c = server.accept(io) catch return;
            if (!answer(io, c, false)) {
                c.close(io);
                continue;
            }
            held[i] = c;
            i += 1;
        }
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch return;
    }

    /// One complete stream, then one that goes quiet (#682).
    fn runTwo(io: Io, server: *std.Io.net.Server, done: *std.atomic.Value(bool)) void {
        var held: [2]?std.Io.net.Stream = @splat(null);
        defer for (held) |h| if (h) |c| c.close(io);
        var i: usize = 0;
        while (i < 2) {
            const c = server.accept(io) catch return;
            if (!answer(io, c, i == 0)) {
                c.close(io);
                continue;
            }
            held[i] = c;
            i += 1;
        }
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch return;
    }
};

/// Drain one request head; true when it is the agent's POST. Another local
/// process can probe any fresh loopback listener (#1303: `HEAD /` for
/// `localhost`), and serving it would spend a connection the test counts on.
fn takePostHead(io: Io, c: std.Io.net.Stream) bool {
    var rbuf: [8192]u8 = undefined;
    var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
    var post: ?bool = null;
    while (true) {
        const l = (sr.interface.takeDelimiter('\n') catch return false) orelse return false;
        if (post == null) post = std.mem.startsWith(u8, l, "POST ");
        if (l.len == 0 or (l.len == 1 and l[0] == '\r')) break; // end of headers
    }
    return post orelse false;
}

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
    var fut = try io.concurrent(Srv.runTwo, .{ io, &server, &done });
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
    var fut = try io.concurrent(Srv.run, .{ io, &server, @as(usize, 3), &done });
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

const TrailerSrv = struct {
    const Mode = enum { usage, missing, empty, unterminated };
    const finish_line = "data: {\"choices\": [{\"index\":0, \"delta\": {}, \"finish_reason\": \"stop\"}]}\n\n";
    const usage_line = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":2,\"total_tokens\":22}}\n\n";
    fn run(io: Io, server: *std.Io.net.Server, mode: Mode, done: *std.atomic.Value(bool)) void {
        const c = while (true) {
            const conn = server.accept(io) catch return;
            if (takePostHead(io, conn)) break conn;
            conn.close(io);
        };
        defer c.close(io);
        var wbuf: [1024]u8 = undefined;
        var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
        sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n") catch return;
        if (mode != .empty) sw.interface.writeAll(prose_line) catch return;
        if (mode != .unterminated) sw.interface.writeAll(finish_line) catch return;
        sw.interface.flush() catch return;
        if (mode == .usage) {
            io.sleep(.fromMilliseconds(100), .awake) catch return;
            sw.interface.writeAll(usage_line) catch return;
            sw.interface.flush() catch return;
        }
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
};

test "Chat terminal marker keeps delayed usage and completes silent trailer; nonterminal still stalls" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const saved = http.stream_stall_ms;
    http.stream_stall_ms = 250;
    defer http.stream_stall_ms = saved;
    for ([_]TrailerSrv.Mode{ .usage, .missing, .empty, .unterminated }) |mode| {
        var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
        defer server.deinit(io);
        var done: std.atomic.Value(bool) = .init(false);
        var fut = try io.concurrent(TrailerSrv.run, .{ io, &server, mode, &done });
        defer fut.await(io);
        defer done.store(true, .release);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
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
        const start = nowMs(io);
        const result = agent_stream.postStreamWithClient(&child, &client, "{}");
        if (mode == .unterminated) {
            try std.testing.expectError(error.StreamStalled, result);
            continue;
        }
        const body = try result;
        defer gpa.free(body);
        const object = (try child.assembleOpenAI(body)).?;
        try std.testing.expectEqual(mode == .usage, object.contains("usage"));
        if (mode == .usage) try std.testing.expectEqual(@as(i64, 20), object.get("usage").?.object.get("prompt_tokens").?.integer);
        try std.testing.expect(nowMs(io) - start >= 240);
        try std.testing.expectEqual(@as(u64, 0), child.stall.tripped_ms);
    }
}

/// ADR 0241 on SSE: a Responses stream whose prose item closes, then thinks in
/// silence past the tightened budget before it completes. ADR 0248 reuses it
/// with a commentary heads-up the server holds open through the think.
const ResponsesSrv = struct {
    const delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n";
    const item_done = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\"}}\n\n";
    const commentary_added = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"phase\":\"commentary\"}}\n\n";
    const completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"output\":[]}}\n\n";
    const think_ms = 1000;
    var head: []const u8 = delta ++ item_done;
    var tail: []const u8 = completed;
    fn run(io: Io, server: *std.Io.net.Server, done: *std.atomic.Value(bool)) void {
        const c = while (true) {
            const conn = server.accept(io) catch return;
            if (takePostHead(io, conn)) break conn;
            conn.close(io);
        };
        defer c.close(io);
        var wbuf: [1024]u8 = undefined;
        var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
        sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n") catch return;
        sw.interface.writeAll(head) catch return;
        sw.interface.flush() catch return;
        io.sleep(.fromMilliseconds(think_ms), .awake) catch return;
        sw.interface.writeAll(tail) catch return;
        sw.interface.flush() catch return;
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
};

fn thinkPastTightenedBudget(head: []const u8, tail: []const u8) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    ResponsesSrv.head = head;
    ResponsesSrv.tail = tail;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = try io.concurrent(ResponsesSrv.run, .{ io, &server, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    // 2000ms full, 500ms tightened: the think sits between the two.
    const saved_stream = http.stream_stall_ms;
    const saved_floor = http_stall.idle_floor_ms;
    http.stream_stall_ms = 2000;
    http_stall.idle_floor_ms = 100;
    defer http.stream_stall_ms = saved_stream;
    defer http_stall.idle_floor_ms = saved_floor;
    try std.testing.expect(ResponsesSrv.think_ms > http_stall.budgetMs(http.stream_stall_ms, true));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Io.Writer.Allocating = .init(gpa); // printDelta grows partial_text only with a frontend
    defer out.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/responses", .{server.socket.address.getPort()});
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = url, .api_key = "k", .model = "m", .context = 0 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = &out.writer,
    };
    defer deinitMarkdown(&agent);

    const t0 = nowMs(io);
    const body = try agent_stream.postStreamWithClient(&agent, &client, "{}");
    defer gpa.free(body);
    try std.testing.expect(nowMs(io) - t0 >= ResponsesSrv.think_ms - 100); // the think really happened
    try std.testing.expect(std.mem.indexOf(u8, body, "response.completed") != null);
    try std.testing.expect(agent.partial_text.items.len != 0); // prose did flow
}

test "ADR 0241: on the Responses SSE wire a closed prose item gets the full budget back" {
    try thinkPastTightenedBudget(ResponsesSrv.delta ++ ResponsesSrv.item_done, ResponsesSrv.completed);
}

// ADR 0248 on SSE: the server holds a commentary heads-up open through the
// compose; commentary prose must not tighten, so the think finishes.
test "ADR 0248: on the Responses SSE wire a commentary heads-up held open keeps the full budget" {
    try thinkPastTightenedBudget(ResponsesSrv.commentary_added ++ ResponsesSrv.delta, ResponsesSrv.item_done ++ ResponsesSrv.completed);
}
