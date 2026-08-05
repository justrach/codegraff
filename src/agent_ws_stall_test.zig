//! (#401) End-to-end transport tests for the codex WebSocket turn, driven by a
//! loopback WebSocket server that can misbehave on demand. These exercise the
//! REAL production entry point (agent_ws.postResponsesWs) rather than the guard
//! helpers in isolation, because #401's whole lesson was that the call sites and
//! the budgets — not the helpers — were where the turn went silent.
//!
//! The mock is a WS server in the same spirit as the GRAFF_CODEX_URL/lmstudio
//! HTTP mocks: `provider.url` is pointed at 127.0.0.1, wssUrl rewrites it to
//! ws://, and no network, key or provider is involved.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const trace = @import("trace.zig");
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");
const Agent = @import("agent.zig").Agent;

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

const delta_event = "{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}";
const completed_event = "{\"type\":\"response.completed\"}";

/// A loopback WebSocket peer with a scripted failure mode.
const Mock = struct {
    const Mode = enum {
        /// Accept the TCP connection and never answer the upgrade — the dial
        /// that hangs before the 101 status line.
        no_upgrade,
        /// Upgrade, then never read again: the client's frame fills the socket
        /// buffers and its write parks in the kernel.
        never_drain,
        /// Upgrade, take the client's frame, answer with ONE delta frame and
        /// then go permanently silent. This is #401's reported signature: the
        /// turn is under way, data flowed, and the server stopped.
        frame_then_silence,
        /// The healthy control: delta, then response.completed.
        frame_then_complete,
    };

    fn run(io: Io, server: *std.Io.net.Server, mode: Mode, done: *std.atomic.Value(bool)) void {
        const c = server.accept(io) catch return;
        defer c.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
        var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
        if (mode == .no_upgrade) return idle(io, done);

        while (true) {
            const line = sr.interface.takeDelimiterInclusive('\n') catch return idle(io, done);
            if (line.len <= 2) break; // the blank line ends the upgrade request
        }
        sw.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") catch return idle(io, done);
        sw.interface.flush() catch return idle(io, done);

        switch (mode) {
            .no_upgrade, .never_drain => {},
            .frame_then_silence, .frame_then_complete => {
                readClientFrame(&sr.interface) catch return idle(io, done);
                writeTextFrame(&sw.interface, delta_event) catch return idle(io, done);
                if (mode == .frame_then_complete)
                    writeTextFrame(&sw.interface, completed_event) catch return idle(io, done);
            },
        }
        idle(io, done);
    }

    /// Hold the connection open (and, for never_drain, undrained) until the
    /// test releases it. Closing early would hand the client a clean EOF, which
    /// is a different failure than the silence being reproduced.
    fn idle(io: Io, done: *std.atomic.Value(bool)) void {
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch break;
    }

    /// Consume one masked client frame (RFC 6455 §5.2); the payload is ignored.
    fn readClientFrame(r: *Io.Reader) !void {
        const h = try r.takeArray(2);
        var len: u64 = h[1] & 0x7f;
        if (len == 126) {
            len = std.mem.readInt(u16, try r.takeArray(2), .big);
        } else if (len == 127) {
            len = std.mem.readInt(u64, try r.takeArray(8), .big);
        }
        if ((h[1] & 0x80) != 0) _ = try r.takeArray(4); // mask key
        try r.discardAll(@intCast(len));
    }

    /// One unmasked server->client text frame (payloads here are all < 126 B).
    fn writeTextFrame(w: *Io.Writer, payload: []const u8) !void {
        try w.writeAll(&[_]u8{ 0x81, @intCast(payload.len) });
        try w.writeAll(payload);
        try w.flush();
    }
};

/// A root-shaped Agent pointed at the mock. `out`/`in` stay null: no TTY means
/// no spinner, no Esc poll and no user-facing stall line, so the test observes
/// the transport alone.
fn mockAgent(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, url: []const u8) Agent {
    return .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = undefined, // the WS path never touches the HTTP client
        .provider = .{
            .id = "codex",
            .kind = .responses,
            .auth = .bearer,
            .url = url,
            .api_key = "k",
            .model = "gpt-5",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
    };
}

fn traced(tw: *Io.Writer.Allocating, needle: []const u8) bool {
    return std.mem.indexOf(u8, tw.written(), needle) != null;
}

// ── the #401 read-side stall ─────────────────────────────────────────────────

// THE #401 regression test.
//
// The reported turn sent a delta over a reused codex WS after a tool result and
// then sat on the thinking indicator until the user interrupted, with a trace
// that stopped dead at "ws reuse (delta)". The read loop WAS watchdogged — but
// it armed http.streamStallTask, which hardcodes tokens_flowing=false, so it
// re-armed the FULL pre-first-token budget (stream_stall_ms, 120s by default) on
// every single frame and never tightened once data was flowing. The SSE reader
// has always passed a real signal (agent_stream.zig: partial_text.items.len
// != 0) and tightens to a quarter. So a server that went quiet mid-response cost
// 120s per attempt — ~4 minutes before the SSE latch — against successful turns
// of 3.6-11.6s, and left nothing in the trace to tell the two halves apart.
//
// Here the mock answers with one delta frame and then goes silent forever. The
// read must give up on the TIGHTENED budget, emit the notes that make the
// signature diagnosable, and tear the session down so request()'s rebuild loop
// re-anchors on a fresh socket.
test "#401: silence after frames trips the tightened read budget, not the full pre-first-token one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io); // registered first → torn down LAST, after the task is joined
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.frame_then_silence, &done });
    defer fut.await(io);
    defer done.store(true, .release); // …so the LIFO order is: signal, join, close

    // Scale both regimes down: 2000ms pre-first-token, a quarter (500ms) once
    // frames flow. The 15s floor exists so a small GRAFF_STREAM_STALL_SECS can't
    // kill healthy streams; without shrinking it the two regimes are identical
    // at every duration a test can afford to wait. Both are process-wide.
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

    // The exact state #401 was reported from: a socket already held across the
    // tool call, so this request takes the reuse (delta) path.
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

    try std.testing.expectError(error.StreamStalled, r);
    // The tightened budget: comfortably past 500ms (so the watchdog really ran,
    // rather than an unrelated instant failure) and comfortably short of the
    // 2000ms pre-first-token budget the reader used to re-arm on every frame.
    try std.testing.expect(ms >= 400);
    try std.testing.expect(ms < 1500);

    // …and the trace now names both halves of the turn, so a recurrence is
    // diagnosable instead of being an unexplained gap after "reuse (delta)".
    try std.testing.expect(traced(&tw, "\"detail\":\"reuse (delta)\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"sent "));
    try std.testing.expect(traced(&tw, "\"detail\":\"first frame\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"stall\""));

    // The session is torn down, which is what lets request()'s rebuild loop
    // reconnect with FULL input and no previous_response_id (agent_request.zig).
    try std.testing.expect(agent.codex_ws == null);
    try std.testing.expect(agent.codex_prev_id == null);
    try std.testing.expectEqual(@as(usize, 0), agent.codex_sent_upto);
}

// The control for the test above: the same harness, the same tightened budgets,
// a server that actually finishes. Proves the stall is the SERVER's silence and
// not an artifact of the mock or of the frames_seen wiring — and pins the happy
// path's notes, so a future change that stops emitting them is caught here too.
test "#401 control: a mock that completes the response still finishes the turn cleanly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.frame_then_complete, &done });
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

    // No held socket: this exercises the fresh-dial path through connectWatched.
    const body = "{\"model\":\"gpt-5\",\"input\":[]}";
    const out = try agent_ws.postResponsesWs(&agent, body);
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, delta_event) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, completed_event) != null);
    try std.testing.expect(traced(&tw, "\"detail\":\"connected\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"sent "));
    try std.testing.expect(traced(&tw, "\"detail\":\"first frame\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"completed\""));
    try std.testing.expect(!traced(&tw, "\"detail\":\"stall\""));
    try std.testing.expect(agent.codex_ws != null); // held for the next delta
}

// ── the outbound half: production wiring, not the helper ─────────────────────

// The guard the previous round left untested where it matters. `sendText` is a
// blocking socket write; against a peer that stops draining, a large enough
// frame parks in the kernel until TCP gives up. This drives postResponsesWs
// itself, so it covers the CALL SITE and the errdefer, not just the helper:
// reverting agent_ws.zig's `sendFrameWatched(...)` to a bare
// `try client.sendText(frame)` makes this test hang rather than fail fast.
//
// Note the error: HungRequest, the SSE send+head guard's error, NOT
// StreamStalled. StreamStalled would spend a slot of request()'s 2-slot stall
// budget and PERMANENTLY latch ws_off on the second occurrence; a frame that
// never left the harness is a transport failure, which postLive retries on a
// fresh socket and only then falls back to SSE.
test "#401: a peer that stops draining fails the send fast, tears down, and does not latch the stall budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // loopback buffer sizing is not deterministic there
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.never_drain, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    // sendDeadlineMs scales with the frame, clamped to the read budget — so the
    // read budget is what bounds this 16MB frame's deadline. Shrink both.
    const saved_head = http.head_stall_ms;
    const saved_stream = http.stream_stall_ms;
    http.head_stall_ms = 400;
    http.stream_stall_ms = 1000;
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
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    // Larger than any plausible loopback send+receive buffer pair, so the write
    // genuinely blocks instead of slipping through. postResponsesWs never parses
    // the body — it only splices it into the response.create envelope.
    const body = try gpa.alloc(u8, 16 * 1024 * 1024);
    defer gpa.free(body);
    @memset(body, 'x');
    @memcpy(body[0.."{\"input\":\"".len], "{\"input\":\"");
    body[body.len - 2] = '"';
    body[body.len - 1] = '}';

    const t0 = nowMs(io);
    const r = agent_ws.postResponsesWs(&agent, body);
    const ms = nowMs(io) - t0;
    if (r) |ok| gpa.free(ok) else |_| {}

    try std.testing.expectError(error.HungRequest, r);
    // Whole call, INCLUDING the errdefer's teardown: `dead` is what keeps
    // ws.WsClient.deinit from spending another blocking close-frame write on
    // the same wedged socket and re-hanging the recovery.
    try std.testing.expect(ms < 15_000); // unguarded, this never returned at all
    try std.testing.expect(ms >= 300); // the watchdog fired, not the pool-exhausted shortcut
    try std.testing.expect(traced(&tw, "\"detail\":\"send stall\""));
    try std.testing.expect(agent.codex_ws == null);
}

// Once the send is guarded, the retry it triggers redials — and the dial is
// unbounded too: DNS + TCP + TLS + a blocking read of the 101 status line. A
// host that accepts the connection and never upgrades would swallow the very
// recovery the other guards trigger, hanging at the "connecting" note.
test "#401: a host that accepts but never upgrades fails the dial instead of hanging" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.no_upgrade, &done });
    defer fut.await(io);
    defer done.store(true, .release);

    const saved = http.head_stall_ms;
    http.head_stall_ms = 300;
    defer http.head_stall_ms = saved;

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/x", .{server.socket.address.getPort()});

    const t0 = nowMs(io);
    const dialed = agent_ws.connectWatched(gpa, io, url, &.{}, false);
    const ms = nowMs(io) - t0;
    if (dialed) |c| {
        c.dead = true;
        c.deinit(gpa);
    } else |_| {}

    try std.testing.expectError(error.HungRequest, dialed);
    try std.testing.expect(ms < 10_000);
    try std.testing.expect(ms >= 200); // the watchdog, not the pool-exhausted shortcut
}

// ── reference parity: liveness before reuse ──────────────────────────────────

// openai/codex checks `is_closed()` on a pooled WS before reusing it. graff's
// only pre-reuse gate was a 4-minute wall clock, which cannot see a socket the
// peer or an LB blackholed 30 seconds into a tool call — squarely inside the
// window, and squarely #401's shape. `dead` is the synchronous equivalent, and
// this pins that the gate consults it: a condemned socket is re-anchored, never
// sent into. Removing the `or !wsReusable(held)` clause makes this test fail
// with StreamStalled (the turn proceeds and dies in the read loop) instead.
test "#401 parity: a held socket already marked dead is re-anchored, never reused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
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

    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;

    var ws_url_buf: [64]u8 = undefined;
    const ws_url = try std.fmt.bufPrint(&ws_url_buf, "ws://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    const held = try ws.WsClient.connect(gpa, io, ws_url, false, &.{});
    held.dead = true; // some earlier path condemned it
    agent.codex_ws = held;
    agent.codex_ws_used_ms = nowMs(io); // …and the IDLE branch must NOT be what fires
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

    // A delta body is useless on a fresh connection, so the caller is asked to
    // rebuild full input — the same contract as the idle-expiry branch.
    try std.testing.expectError(error.CodexWsReanchor, r);
    try std.testing.expect(agent.codex_ws == null);
    try std.testing.expect(ms < 1000); // decided up front; no frame was ever sent
    try std.testing.expect(traced(&tw, "\"detail\":\"held socket marked dead"));
    try std.testing.expect(!traced(&tw, "\"detail\":\"idle >"));
    try std.testing.expect(!traced(&tw, "\"detail\":\"sent "));
}

// ── the send-deadline policy ─────────────────────────────────────────────────

// A flat head-sized send deadline is a false-positive generator on exactly the
// frame most likely to sit under it: every recovery re-anchors with the FULL
// conversation, so the retried frame is hundreds of KB where the delta was a
// few. Two such false positives latch SSE for the session, so the budget grows
// with the payload — while still never outlasting the read watchdog.
test "sendDeadlineMs (#401): head budget for a delta, transmit room for a full re-anchor, capped by the read budget" {
    const head: u64 = 30 * 1000;
    const stream: u64 = 120 * 1000;

    // A delta frame keeps the flat head budget: it must be on the wire fast.
    try std.testing.expectEqual(head, agent_ws.sendDeadlineMs(0, head, stream));
    try std.testing.expectEqual(head, agent_ws.sendDeadlineMs(4 * 1024, head, stream));
    try std.testing.expectEqual(head, agent_ws.sendDeadlineMs(64 * 1024 - 1, head, stream));

    // One second per 64KB (~512 kbit/s, far below any link that can carry a
    // codex session): a ~1MB full re-anchor gets 16 extra seconds.
    try std.testing.expectEqual(head + 1000, agent_ws.sendDeadlineMs(64 * 1024, head, stream));
    try std.testing.expectEqual(head + 16_000, agent_ws.sendDeadlineMs(1024 * 1024, head, stream));

    // …but never past the watchdog that covers the reply, however large.
    try std.testing.expectEqual(stream, agent_ws.sendDeadlineMs(64 * 1024 * 1024, head, stream));
    try std.testing.expectEqual(stream, agent_ws.sendDeadlineMs(std.math.maxInt(usize), head, stream));

    // A shrunken read budget (a test, or a low GRAFF_STREAM_STALL_SECS) can
    // never clamp the send below the head budget.
    try std.testing.expectEqual(head, agent_ws.sendDeadlineMs(1024 * 1024, head, 500));
}
