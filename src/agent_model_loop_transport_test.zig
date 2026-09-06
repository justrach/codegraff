//! Real loopback transports: a never-completing peer must be cut, not retried.
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const Kind = @import("provider.zig").Provider.Kind;
const mock = @import("agent_ws_mock.zig");
const loop = @import("agent_model_loop.zig");

const Peer = struct {
    fn run(io: Io, server: *Io.net.Server, kind: Kind, websocket: bool, done: *std.atomic.Value(bool)) void {
        const conn = server.accept(io) catch return;
        defer conn.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var sr = Io.net.Stream.Reader.init(conn, io, &rbuf);
        var sw = Io.net.Stream.Writer.init(conn, io, &wbuf);
        while (true) {
            const line = sr.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len <= 2) break;
        }
        const head = if (websocket)
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        else
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n";
        sw.interface.writeAll(head) catch return;
        sw.interface.flush() catch return;
        if (websocket) mock.Mock.readClientFrame(&sr.interface) catch return;
        const raw = switch (kind) {
            .openai => "{\"choices\":[{\"delta\":{\"content\":\"I will wait for your reply.\\n\"}}]}",
            .anthropic => "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"I will wait for your reply.\\n\"}}",
            .responses => "{\"type\":\"response.output_text.delta\",\"delta\":\"I will wait for your reply.\\n\"}",
            .interactions => "{\"delta\":{\"type\":\"text\",\"text\":\"I will wait for your reply.\\n\"}}",
        };
        for (0..1000) |_| {
            if (websocket) {
                mock.Mock.writeTextFrame(&sw.interface, raw) catch return;
            } else {
                sw.interface.print("data: {s}\n\n", .{raw}) catch return;
                sw.interface.flush() catch return;
            }
            io.sleep(.fromMilliseconds(2), .awake) catch return;
        }
        // No terminal event. A missing guard would wait for the stall budget.
        mock.Mock.idle(io, done);
    }
};

fn exercise(kind: Kind, websocket: bool) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var future = io.async(Peer.run, .{ io, &server, kind, websocket, &done });
    defer future.await(io);
    defer done.store(true, .release);
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/v1/responses", .{server.socket.address.getPort()});
    var agent = mock.mockAgent(gpa, arena, io, url);
    agent.client = &client;
    agent.provider.kind = kind;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Use the transport selector too, proving a WS guard isn't a fallback.
    agent.out = &out.writer;
    defer @import("agent_render.zig").deinitMarkdown(&agent);
    const saved_ws = @import("main.zig").g_codex_ws;
    @import("main.zig").g_codex_ws = websocket;
    defer @import("main.zig").g_codex_ws = saved_ws;
    @import("cancel_source.zig").clear();
    const started = mock.nowMs(io);
    try std.testing.expectError(error.ModelLoop, agent.postLive("{}"));
    try std.testing.expect(mock.nowMs(io) - started < 2000);
    try std.testing.expect(agent.partial_text.items.len > 0 and agent.partial_text.items.len < 600);
    try std.testing.expectEqual(@as(u8, 0), agent.ws_transport_failures);
    try std.testing.expect(!agent.ws_off);
    try std.testing.expect(agent.codex_ws == null);
    const final = try loop.finish(&agent);
    try std.testing.expect(std.mem.endsWith(u8, final, loop.marker));
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
}

test "model loop cuts live SSE on all three delivery wires" {
    try exercise(.openai, false);
    try exercise(.anthropic, false);
    try exercise(.responses, false);
}

test "model loop cuts live websocket without transport retry or fallback" {
    try exercise(.responses, true);
}
