//! (#401 round 4) What a codex WS turn is allowed to WAIT for, end-to-end
//! through agent_ws.postResponsesWs on the agent_ws_mock loopback peer.
//!
//! Two invariants the round-3 fix did not have:
//!   * a REUSED socket that answers nothing is a dead socket, bounded by the
//!     head budget and reported to the transport ladder — not 120s of dead air
//!     charged to the turn's 2-slot stall budget;
//!   * a FRESH connect keeps the full pre-first-token budget, because its
//!     handshake just proved the peer is there;
//!   * and the tokens-flowing signal covers tool-argument prose, which is the
//!     ONLY visible output an attempt_completion turn produces.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const trace = @import("trace.zig");
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");

const mock = @import("agent_ws_mock.zig");
const Mock = mock.Mock;
const nowMs = mock.nowMs;
const mockAgent = mock.mockAgent;
const traced = mock.traced;

// The arg-prose half of the tokens-flowing signal, at the call site.
//
// A codex turn whose whole visible answer is attempt_completion's `result`
// streams `response.function_call_arguments.delta` and never one
// `response.output_text.delta`. On SSE that prose grows partial_text
// (argLiveDelta → emitArgText), so the SSE reader tightens to a quarter from the
// first byte; the round-3 WS signal saw none of it and held the FULL
// pre-first-token budget for exactly the turn shape #401 was reported from.
// Keying only on output_text fails this at `ms < 1500`.
test "#401: silence after streamed tool-argument prose trips the tightened budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.arg_prose_then_silence, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    const saved_stream = http.stream_stall_ms;
    const saved_floor = http_stall.idle_floor_ms;
    http.stream_stall_ms = 2000;
    http_stall.idle_floor_ms = 100;
    defer http.stream_stall_ms = saved_stream;
    defer http_stall.idle_floor_ms = saved_floor;
    try std.testing.expectEqual(@as(u64, 500), http_stall.budgetMs(http.stream_stall_ms, true));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    // A FRESH dial, so the head budget below is not what bounds this: the only
    // thing that can end the turn early is the tightened inter-frame budget.
    const body = "{\"model\":\"gpt-5\",\"input\":[]}";
    const t0 = nowMs(io);
    const r = agent_ws.postResponsesWs(&agent, body);
    const ms = nowMs(io) - t0;
    if (r) |ok| gpa.free(ok) else |_| {}

    try std.testing.expectError(error.StreamStalled, r);
    try std.testing.expect(ms >= 400);
    try std.testing.expect(ms < 1500); // NOT the 2000ms pre-first-token budget
    // …and it was the ARGUMENT prose that did it: not one output_text delta
    // was sent, yet the reader reports prose flowing.
    try std.testing.expect(traced(&tw, "\"detail\":\"first output text"));
    try std.testing.expect(traced(&tw, "\"detail\":\"stall\""));
}

// The reused-socket first-frame budget.
//
// The branch's own reasoning says response.created / in_progress land within
// milliseconds of a send — which is why frame ARRIVAL is a bad tokens-flowing
// signal, and equally why ZERO frames on a socket held since the last request is
// a dead-socket signature rather than a thinking model. Before this, that case
// armed the full 120s pre-first-token budget and surfaced as StreamStalled,
// spending a slot of request()'s 2-slot stall budget; SSE bounds the same
// condition at head_stall_ms and returns HungRequest. Forcing `head_wait = false`
// fails this on the error type and on `ms < 2000`.
test "#401: a reused socket that answers nothing fails on the head budget as a transport error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.read_then_silence, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    // A head budget an order of magnitude under the pre-first-token budget, so
    // which one fired is unambiguous from the elapsed time alone.
    const saved_head = http.head_stall_ms;
    const saved_stream = http.stream_stall_ms;
    http.head_stall_ms = 400;
    http.stream_stall_ms = 4000;
    defer http.head_stall_ms = saved_head;
    defer http.stream_stall_ms = saved_stream;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;

    // #401's reported state: a socket held across the tool call, reused for the
    // delta. The peer takes the frame and never speaks again.
    var ws_url_buf: [64]u8 = undefined;
    const ws_url = try std.fmt.bufPrint(&ws_url_buf, "ws://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    agent.codex_ws = try ws.WsClient.connect(gpa, io, ws_url, false, &.{});
    agent.codex_ws_used_ms = nowMs(io); // fresh: the idle re-anchor must not fire
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    const body = "{\"model\":\"gpt-5\",\"previous_response_id\":\"resp_1\",\"input\":[]}";
    const t0 = nowMs(io);
    const r = agent_ws.postResponsesWs(&agent, body);
    const ms = nowMs(io) - t0;
    if (r) |ok| gpa.free(ok) else |_| {}

    // HungRequest, not StreamStalled: postLive re-anchors on a fresh socket and
    // only latches SSE on a second failure, instead of spending the turn's
    // stall budget on a socket that was already dead when we wrote to it.
    try std.testing.expectError(error.HungRequest, r);
    try std.testing.expect(ms >= 300); // the watchdog ran
    try std.testing.expect(ms < 2000); // …on the head budget, not the 4000ms one
    try std.testing.expect(traced(&tw, "\"detail\":\"reuse (delta)\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"sent "));
    try std.testing.expect(traced(&tw, "\"detail\":\"reuse dead — no first frame\""));
    try std.testing.expect(!traced(&tw, "\"detail\":\"first frame\""));
    // Torn down, so request()'s rebuild loop re-anchors with FULL input.
    try std.testing.expect(agent.codex_ws == null);
    try std.testing.expect(agent.codex_prev_id == null);
    try std.testing.expectEqual(@as(usize, 0), agent.codex_sent_upto);
}

// …and the other side of that boundary, which is what makes the head budget
// safe to apply at all: a FRESH connect just completed a TCP + upgrade
// handshake, so its silence is a model thinking, not a dead peer. It keeps the
// full pre-first-token budget. Dropping the `reused` term (`head_wait =
// frames_seen == 0`) fails this: the first token arrives after the head budget,
// so a legitimate high-effort turn would die as a transport error.
test "#401: a fresh connect keeps the full pre-first-token budget for a slow first token" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.slow_first_frame, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    const saved_head = http.head_stall_ms;
    const saved_stream = http.stream_stall_ms;
    const saved_think = mock.slow_first_frame_ms;
    http.head_stall_ms = 300; // …which the dial still fits inside
    http.stream_stall_ms = 4000;
    mock.slow_first_frame_ms = 700; // > the head budget, << the full one
    defer http.head_stall_ms = saved_head;
    defer http.stream_stall_ms = saved_stream;
    defer mock.slow_first_frame_ms = saved_think;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    // No held socket: this turn dials, so `reused` is false.
    const body = "{\"model\":\"gpt-5\",\"input\":[]}";
    const t0 = nowMs(io);
    const out = try agent_ws.postResponsesWs(&agent, body);
    defer gpa.free(out);
    const ms = nowMs(io) - t0;

    try std.testing.expect(std.mem.indexOf(u8, out, mock.delta_event) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, mock.completed_event) != null);
    try std.testing.expect(ms >= 600); // the first token really did outlast the head budget
    try std.testing.expect(traced(&tw, "\"detail\":\"connected\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"completed\""));
    try std.testing.expect(!traced(&tw, "\"detail\":\"reuse dead"));
    try std.testing.expect(!traced(&tw, "\"detail\":\"stall\""));
    try std.testing.expect(agent.codex_ws != null); // held for the next delta
}

test "#692: a generic error frame is returned as the terminal API body before peer close" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.generic_error_then_close, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    const out = try agent_ws.postResponsesWs(&agent, "{\"model\":\"gpt-5\",\"input\":[]}");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, mock.generic_error_event) != null);
    try std.testing.expect(traced(&tw, "\"detail\":\"terminal API error frame\""));
    try std.testing.expect(!traced(&tw, "transport error"));
    try std.testing.expect(agent.codex_ws != null);
    try std.testing.expect(agent.codex_ws.?.dead);
}
