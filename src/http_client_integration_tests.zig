//! End-to-end model-transport regressions for request-construction TLS recovery.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const deinitMarkdown = @import("agent_render.zig").deinitMarkdown;
const http = @import("http.zig");
const http_client = @import("http_client.zig");
const mock = @import("agent_ws_mock.zig");
const trace = @import("trace.zig");
const Provider = @import("provider.zig").Provider;
const Approvals = @import("approvals.zig").Approvals;
const repl_turn = @import("repl_turn.zig");
const subagent_run = @import("subagent_run.zig");
const tools = @import("tools.zig");

pub const Reply = struct {
    status: []const u8 = "200 OK",
    content_type: []const u8 = "application/json",
    body: []const u8,
};

pub const chat_body =
    \\{"choices":[{"index":0,"message":{"role":"assistant","content":"child-ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
;
const sse_body =
    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"root-ok\"}\n\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
const chat_sse_body =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"root-ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

fn readRequest(reader: *std.Io.net.Stream.Reader) !void {
    var content_length: usize = 0;
    while (true) {
        const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t\r"), 10);
        }
    }
    try reader.interface.discardAll(content_length);
}

pub fn serveReplies(io: Io, server: *std.Io.net.Server, replies: []const Reply, accepted: *std.atomic.Value(usize)) void {
    for (replies) |reply| {
        const conn = server.accept(io) catch return;
        {
            defer conn.close(io);
            _ = accepted.fetchAdd(1, .acq_rel);
            var read_buf: [16 * 1024]u8 = undefined;
            var reader = std.Io.net.Stream.Reader.init(conn, io, &read_buf);
            readRequest(&reader) catch return;
            var head_buf: [256]u8 = undefined;
            const head = std.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                .{ reply.status, reply.content_type, reply.body.len },
            ) catch return;
            var write_buf: [4096]u8 = undefined;
            var writer = std.Io.net.Stream.Writer.init(conn, io, &write_buf);
            writer.interface.writeAll(head) catch return;
            writer.interface.writeAll(reply.body) catch return;
            writer.interface.flush() catch return;
        }
    }
}

fn serveInvalidTls(io: Io, server: *std.Io.net.Server, count: usize, accepted: *std.atomic.Value(usize)) void {
    for (0..count) |_| {
        const conn = server.accept(io) catch return;
        defer conn.close(io);
        _ = accepted.fetchAdd(1, .acq_rel);
        var write_buf: [128]u8 = undefined;
        var writer = std.Io.net.Stream.Writer.init(conn, io, &write_buf);
        writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n") catch continue;
        writer.interface.flush() catch continue;
    }
}

pub fn releaseAccept(io: Io, server: *std.Io.net.Server) void {
    const address = server.socket.address;
    if (std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
}

pub fn provider(url: []const u8) Provider {
    return .{
        .id = "test",
        .kind = .openai,
        .auth = .x_api_key,
        .url = url,
        .api_key = "test",
        .model = "test",
        .context = 100_000,
    };
}

fn childAgent(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, client: *std.http.Client, p: Provider) Agent {
    return .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = client,
        .provider = p,
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = "test-child",
        .out = null,
    };
}

fn postTask(gpa: std.mem.Allocator, client: *std.http.Client, p: Provider) anyerror![]u8 {
    return http.postWithConv(gpa, client, p, "{}", null);
}

fn postWatchedTask(gpa: std.mem.Allocator, io: Io, client: *std.http.Client, p: Provider) anyerror![]u8 {
    return http.postWatched(gpa, io, client, p, "{}", null);
}

test "real malformed TLS handshakes traverse both production constructor catches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveInvalidTls, .{ io, &server, 2, &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    try std.testing.expectError(
        error.TlsRequestConstructionFailed,
        http.postWithConv(gpa, &runtime.client, provider(url), "{}", null),
    );
    try std.testing.expectEqual(@as(u64, 1), runtime.recovery.stats().active_id);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var root = childAgent(gpa, arena_state.allocator(), io, &runtime.client, provider(url));
    root.sub = false;
    try std.testing.expectError(error.TlsRequestConstructionFailed, root.postStreamWithClient(&runtime.client, "{}"));
    try std.testing.expectEqual(@as(u64, 2), runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 2), accepted.load(.acquire));
}

test "TUI turn agent and actual runSub child share the recovered generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{
        .{ .content_type = "text/event-stream", .body = chat_sse_body },
        .{ .body = chat_body },
    };
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    const p = provider(url);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var approvals: Approvals = .{ .yolo = true };
    var ctx = repl_turn.testCtx(&runtime.client);
    ctx.provider = p;
    var root = try repl_turn.turnAgent(&ctx, gpa, arena_state.allocator(), .{}, &output.writer, &approvals);
    defer root.tools_used.deinit(gpa);
    defer deinitMarkdown(&root);

    http_client.injectConstructionTlsForTest(0);
    _ = try root.request(null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "root-ok") != null);
    try std.testing.expectEqual(@as(u64, 1), runtime.recovery.stats().active_id);

    const tool_ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &runtime.client,
        .provider = p,
        .registry = null,
        .from_sub = false,
        .approvals = &approvals,
        .tracer = null,
    };
    const child = try subagent_run.runSub(tool_ctx, "subagent", "tls-test-child", "reply once", "test child", "", .shared_cwd, false, p, null);
    defer gpa.free(child.output.text);
    try std.testing.expect(!child.output.is_error);
    try std.testing.expect(std.mem.indexOf(u8, child.output.text, "child-ok") != null);
    try std.testing.expectEqual(@as(usize, 2), accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
}

test "failed streaming root generation recovers later root and child requests" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{
        .{ .content_type = "text/event-stream", .body = sse_body },
        .{ .body = chat_body },
    };
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = mock.mockAgent(gpa, arena, io, url);
    root.client = &runtime.client;
    http_client.injectConstructionTlsForTest(0);
    try std.testing.expectError(error.TlsRequestConstructionFailed, root.postStreamWithClient(root.client, "{}"));

    const streamed = try root.postStreamWithClient(root.client, "{}");
    defer gpa.free(streamed);
    try std.testing.expect(std.mem.indexOf(u8, streamed, "response.completed") != null);

    var child = childAgent(gpa, arena, io, &runtime.client, provider(url));
    _ = try child.request(null);
    try std.testing.expectEqual(@as(usize, 2), accepted.load(.acquire));
    const stats = runtime.recovery.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.active_id);
    try std.testing.expectEqual(@as(usize, 0), stats.active_refs);
    try std.testing.expectEqual(@as(usize, 0), stats.retired);
}

test "child retry ladder recovers within the same request" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{.{ .body = chat_body }};
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var child = childAgent(gpa, arena_state.allocator(), io, &runtime.client, provider(url));

    http_client.injectConstructionTlsForTest(0);
    _ = try child.request(null);
    try std.testing.expectEqual(@as(usize, 1), accepted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
}

test "later root and child recover after the retry ladder exhausts TLS generations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{
        .{ .content_type = "text/event-stream", .body = chat_sse_body },
        .{ .body = chat_body },
    };
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var trace_output: Io.Writer.Allocating = .init(gpa);
    defer trace_output.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &trace_output.writer, .start = Io.Timestamp.now(io, .awake) };

    var root = childAgent(gpa, arena, io, &runtime.client, provider(url));
    defer deinitMarkdown(&root);
    root.sub = false;
    root.label = "test-root";
    root.out = &output.writer;
    root.tracer = &tracer;
    http_client.injectConstructionTlsThroughGenerationForTest(5);
    try std.testing.expectError(error.ApiError, root.request(null));
    try std.testing.expectEqual(@as(usize, 0), accepted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 6), runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, trace_output.written(), "\"ev\":\"tls_request_construction\""));
    try std.testing.expect(std.mem.indexOf(u8, root.last_api_error.?, "gave up after 6 attempts") != null);

    _ = try root.request(null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "root-ok") != null);
    var child = childAgent(gpa, arena, io, &runtime.client, provider(url));
    const child_response = try child.request(null);
    const choices = child_response.get("choices").?.array.items;
    const content = choices[0].object.get("message").?.object.get("content").?.string;
    try std.testing.expectEqualStrings("child-ok", content);
    try std.testing.expectEqual(@as(usize, 2), accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().retired);
}

test "repeated TLS failures rotate multiple generations before recovery" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{.{ .body = "ok" }};
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    const p = provider(url);
    http_client.injectConstructionTlsForTest(0);
    try std.testing.expectError(error.TlsRequestConstructionFailed, http.postWithConv(gpa, &runtime.client, p, "{}", null));
    http_client.injectConstructionTlsForTest(1);
    try std.testing.expectError(error.TlsRequestConstructionFailed, http.postWithConv(gpa, &runtime.client, p, "{}", null));
    const recovered = try http.postWithConv(gpa, &runtime.client, p, "{}", null);
    defer gpa.free(recovered);
    try std.testing.expectEqualStrings("ok", recovered);
    try std.testing.expectEqual(@as(u64, 2), runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().retired);
}

test "simultaneous callers survive one shared generation failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{.{ .body = "ok" }};
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    const p = provider(url);
    var arrivals: std.atomic.Value(usize) = .init(0);
    var all_arrived: Io.Event = .unset;
    var release: Io.Event = .unset;
    http_client.installConstructionTlsBarrierForTest(&arrivals, &all_arrived, &release);
    http_client.injectConstructionTlsThroughGenerationForTest(0);
    var first = io.async(postTask, .{ gpa, &runtime.client, p });
    var second = io.async(postTask, .{ gpa, &runtime.client, p });
    all_arrived.waitUncancelable(io);
    try std.testing.expectEqual(@as(usize, 2), runtime.recovery.stats().active_refs);
    release.set(io);
    const results = [_]anyerror![]u8{ first.await(io), second.await(io) };
    for (results) |result| {
        if (result) |body| {
            gpa.free(body);
            return error.UnexpectedSuccess;
        } else |err| try std.testing.expectEqual(error.TlsRequestConstructionFailed, err);
    }
    try std.testing.expectEqual(@as(u64, 1), runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().retired);

    const recovered = try http.postWithConv(gpa, &runtime.client, p, "{}", null);
    defer gpa.free(recovered);
    try std.testing.expectEqualStrings("ok", recovered);
    try std.testing.expectEqual(@as(usize, 1), accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
}

test "direct model POST waits for CA readiness before dialing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: http_client.Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();
    var ready: Io.Event = .unset;
    var wait_entered: Io.Event = .unset;
    http_client.installForTest(&recovery, &ready, &wait_entered);
    defer http_client.uninstallForTest();

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{.{ .body = "ok" }};
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/compact", .{server.socket.address.getPort()});
    var posted = io.async(postWatchedTask, .{ gpa, io, &original, provider(url) });
    wait_entered.waitUncancelable(io);
    try std.testing.expectEqual(@as(usize, 0), accepted.load(.acquire));
    ready.set(io);
    const body = try posted.await(io);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("ok", body);
    try std.testing.expectEqual(@as(usize, 1), accepted.load(.acquire));
}

test "launch CA failure trace is consumed once and does not block model requests" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{ .{ .body = chat_body }, .{ .body = chat_body } };
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var trace_output: Io.Writer.Allocating = .init(gpa);
    defer trace_output.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &trace_output.writer, .start = Io.Timestamp.now(io, .awake) };
    var child = childAgent(gpa, arena_state.allocator(), io, &runtime.client, provider(url));
    child.tracer = &tracer;

    http_client.injectLaunchCaWarmFailureForTest();
    _ = try child.request(null);
    _ = try child.request(null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace_output.written(), "\"ev\":\"ca_prewarm_failed\""));
    try std.testing.expectEqual(@as(usize, 2), accepted.load(.acquire));
}

test "Agent request traces replacement CA failure and recovers in the same retry ladder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{ .{ .body = chat_body }, .{ .body = chat_body } };
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var trace_output: Io.Writer.Allocating = .init(gpa);
    defer trace_output.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &trace_output.writer, .start = Io.Timestamp.now(io, .awake) };
    var child = childAgent(gpa, arena_state.allocator(), io, &runtime.client, provider(url));
    child.tracer = &tracer;

    http_client.injectReplacementCaWarmFailureForTest();
    http_client.injectConstructionTlsForTest(0);
    _ = try child.request(null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        trace_output.written(),
        "rotated shared HTTP client generation; replacement CA prewarm failed",
    ) != null);
    _ = try child.request(null);
    try std.testing.expectEqual(@as(usize, 2), accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
}

test "HTTP response error releases its generation lease" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    defer runtime.deinit(io);
    http.waitForClientReady(io);

    var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    const replies = [_]Reply{.{ .status = "500 Internal Server Error", .body = "upstream failed\n" }};
    var accepted: std.atomic.Value(usize) = .init(0);
    var server_future = io.async(serveReplies, .{ io, &server, @as([]const Reply, &replies), &accepted });
    defer server_future.await(io);
    defer releaseAccept(io, &server);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/test", .{server.socket.address.getPort()});
    try std.testing.expectError(error.ServerError, http.postWithConv(gpa, &runtime.client, provider(url), "{}", null));
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().active_refs);
    try std.testing.expectEqual(@as(usize, 0), runtime.recovery.stats().retired);
}
