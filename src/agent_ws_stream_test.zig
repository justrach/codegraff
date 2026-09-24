//! Codex WS turns surface deltas as they arrive, through the same per-line
//! hook (printDelta) as the SSE reader. Before, a WS turn buffered every frame
//! and only rendered the answer after response.completed: ACP clients got the
//! whole reply as one chunk at the end, and a turn that stalled mid-answer had
//! shown nothing at all.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");

const mock = @import("agent_ws_mock.zig");
const Mock = mock.Mock;
const nowMs = mock.nowMs;
const mockAgent = mock.mockAgent;

test "a WS text delta reaches the UI before the response completes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    // One output_text delta ("hi"), then silence: the response never completes,
    // so anything the UI shows must have been streamed.
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.frame_then_silence, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    const saved_stream = http.stream_stall_ms;
    const saved_floor = http_stall.idle_floor_ms;
    http.stream_stall_ms = 2000;
    http_stall.idle_floor_ms = 100;
    defer http.stream_stall_ms = saved_stream;
    defer http_stall.idle_floor_ms = saved_floor;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.out = &out.writer;
    defer agent.partial_text.deinit(arena);
    defer agent.md_buf.deinit(gpa);
    defer agent.md_word.deinit(gpa);

    var ws_url_buf: [64]u8 = undefined;
    const ws_url = try std.fmt.bufPrint(&ws_url_buf, "ws://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    agent.codex_ws = try ws.WsClient.connect(gpa, io, ws_url, false, &.{});
    agent.codex_ws_used_ms = nowMs(io);
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    const r = agent_ws.postResponsesWs(&agent, "{\"model\":\"gpt-5\",\"previous_response_id\":\"resp_1\",\"input\":[]}");
    if (r) |ok| gpa.free(ok) else |_| {}
    try std.testing.expectError(error.StreamStalled, r);

    try std.testing.expect(agent.streamed_text);
    try std.testing.expectEqualStrings("hi", agent.partial_text.items);
    // The markdown renderer holds an unterminated line until its tail flush.
    agent.flushStreamTail();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hi") != null);
}
