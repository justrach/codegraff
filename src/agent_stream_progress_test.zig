//! Partial SSE events are active reads, not silent sockets (#1686).
//! Synthetic loopback traffic drives the production HTTP/1 SSE entry point.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const agent_stream = @import("agent_stream.zig");

const Server = struct {
    const Mode = enum { flowing, stopped };

    fn run(io: Io, listener: *Io.net.Server, mode: Mode, done: *std.atomic.Value(bool)) void {
        const conn = listener.accept(io) catch return;
        defer conn.close(io);
        var input_buf: [8192]u8 = undefined;
        var input = Io.net.Stream.Reader.init(conn, io, &input_buf);
        while (true) {
            const line = (input.interface.takeDelimiter('\n') catch return) orelse return;
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
        }
        var output_buf: [1024]u8 = undefined;
        var output = Io.net.Stream.Writer.init(conn, io, &output_buf);
        output.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" ++
            ": ready\n\ndata: {\"choices\":[],\"padding\":\"") catch return;
        output.interface.flush() catch return;
        const fragment: [1]u8 = @splat('A');
        for (0..18) |_| {
            if (done.load(.acquire)) return;
            output.interface.writeAll(&fragment) catch return;
            output.interface.flush() catch return;
            if (mode == .stopped) break;
            io.sleep(.fromMilliseconds(40), .awake) catch return;
        }
        if (mode == .flowing) {
            output.interface.writeAll("\"}\n\ndata: [DONE]\n\n") catch return;
            output.interface.flush() catch return;
        }
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
};

fn exercise(mode: Server.Mode) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var addr = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var listener = try Io.net.IpAddress.listen(&addr, io, .{});
    defer listener.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var server = io.async(Server.run, .{ io, &listener, mode, &done });
    defer server.await(io);
    defer done.store(true, .release);

    const saved_budget = http.stream_stall_ms;
    http.stream_stall_ms = 150;
    defer http.stream_stall_ms = saved_budget;
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
    const response = agent_stream.postStreamWithClient(&agent, &client, "{}");
    if (mode == .stopped) {
        try std.testing.expectError(error.StreamStalled, response);
        try std.testing.expectEqual(@as(u64, 150), agent.stall.tripped_ms);
    } else {
        const body = try response;
        defer gpa.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "data: [DONE]") != null);
        try std.testing.expectEqual(@as(usize, 18), std.mem.count(u8, body, "A"));
    }
}

test "SSE byte progress keeps an unfinished event alive beyond its idle budget" {
    try exercise(.flowing);
}

test "SSE byte progress does not hide a stopped partial event" {
    try exercise(.stopped);
}
