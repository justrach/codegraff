//! (#401) End-to-end transport tests for the codex WebSocket turn, driven by a
//! loopback WebSocket server that can misbehave on demand. These exercise the
//! REAL production entry point (agent_ws.postResponsesWs) rather than the guard
//! helpers in isolation, because #401's whole lesson was that the call sites and
//! the budgets — not the helpers — were where the turn went silent. The mock is
//! in the same spirit as the GRAFF_CODEX_URL/lmstudio HTTP mocks: `provider.url`
//! points at 127.0.0.1, and no network, key or provider is used.

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

/// What the backend actually puts on the socket in the first milliseconds after
/// a send, before the model has produced anything: the two protocol events, then
/// a reasoning delta. None of these grows partial_text on the SSE path, so none
/// may tighten the WS read budget either.
const protocol_events = [_][]const u8{
    "{\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}",
    "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"r1\"}}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking\"}",
};

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
        /// Upgrade, take the client's frame, answer with `protocol_events` and
        /// then go quiet while the model "thinks". Frames flow, none of them is
        /// output text — so the budget must stay at the pre-first-token value.
        protocol_then_silence,
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
            .protocol_then_silence => {
                readClientFrame(&sr.interface) catch return idle(io, done);
                for (protocol_events) |ev|
                    writeTextFrame(&sw.interface, ev) catch return idle(io, done);
            },
        }
        idle(io, done);
    }

    /// Hold the connection open (and, for never_drain, undrained) until the test
    /// releases it. Closing early hands the client a clean EOF, a different
    /// failure than the silence being reproduced.
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

/// A root-shaped Agent pointed at the mock. `out`/`in` stay null: no TTY means no
/// spinner, no Esc poll and no user-facing stall line — the transport alone.
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
// The reported turn sent a delta over a reused codex WS after a tool result, sat
// on the thinking indicator until the user interrupted, and left a trace that
// stopped dead at "ws reuse (delta)". The read loop WAS watchdogged — but it
// armed a hardcoded tokens_flowing=false, so it re-armed the FULL
// pre-first-token budget (120s) on every frame and never tightened once VISIBLE
// OUTPUT TEXT flowed; the SSE reader has always passed a real signal
// (agent_stream.zig: partial_text.items.len != 0) and tightens to a quarter.
// Here the mock answers one output_text delta and then goes silent forever: the
// read must give up on the TIGHTENED budget, emit the notes that make the
// signature diagnosable, and tear the session down so request() re-anchors.
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

// The control: same harness, same tightened budgets, a server that finishes.
// Proves the stall is the SERVER's silence, not the mock — and pins the notes.
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

// The other half of the budget signal, and the round-2 regression it pins.
//
// `frames_seen != 0` was not SSE parity: the backend answers a send with
// response.created / response.in_progress within milliseconds, tightening the
// budget to a quarter before the model has thought — so a silent reasoning phase
// longer than that became a stall, a full re-anchor, a second stall, and a
// permanent ws_off latch, while the identical turn survives on SSE. This mock
// sends exactly those events plus a reasoning delta and then goes quiet: at
// 500ms tightened vs 2000ms pre-first-token, the turn must outlive the tightened
// budget. Reverting the watchdog arg to `frames_seen != 0` fails this at
// `ms >= 1500`. The FIRST test in this file is the paired positive case.
test "#401: protocol and reasoning frames do NOT tighten the read budget (SSE parity)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(Mock.run, .{ io, &server, Mock.Mode.protocol_then_silence, &done });
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

    const body = "{\"model\":\"gpt-5\",\"input\":[]}";
    const t0 = nowMs(io);
    const r = agent_ws.postResponsesWs(&agent, body);
    const ms = nowMs(io) - t0;
    if (r) |ok| gpa.free(ok) else |_| {}

    // It still ends as a stall — nothing here is unbounded — but on the FULL
    // pre-first-token budget, which is what a thinking model is entitled to.
    try std.testing.expectError(error.StreamStalled, r);
    try std.testing.expect(ms >= 1500); // the tightened 500ms budget was NOT used
    try std.testing.expect(ms < 6000); // …and the full one still bounds it
    // Frames DID arrive (so this is a budget decision, not a dead mock) and none
    // of them counted as output text.
    try std.testing.expect(traced(&tw, "\"detail\":\"first frame\""));
    try std.testing.expect(!traced(&tw, "\"detail\":\"first output text"));
}

// ── the outbound half: production wiring, not the helper ─────────────────────

// `sendText` is a blocking socket write; against a peer that stops draining, a
// large enough frame parks in the kernel until TCP gives up. This drives
// postResponsesWs, so it covers the CALL SITE and the errdefer, not just the
// helper: reverting it to a bare `try client.sendText(frame)` hangs. The error
// is HungRequest, the SSE send+head guard's error, NOT StreamStalled — which
// would spend a slot of request()'s 2-slot stall budget and PERMANENTLY latch
// ws_off on the second occurrence. A frame that never left is a transport
// failure: postLive retries a fresh socket and only then falls back to SSE.
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

// The dial is unbounded too: DNS + TCP + TLS + a blocking read of the 101 status
// line. A host that accepts and never upgrades would swallow the very recovery
// the other guards trigger, hanging at the "connecting" note. This drives
// postResponsesWs, so it covers the CALL SITE and its trace note — which was
// wrong: it matched error.StreamStalled, which connectWatched no longer returns,
// so a stalled dial traced a bare "HungRequest". A bare connect hangs this test.
test "#401: a stalled dial fails the turn fast and traces `connect stall` (production call site)" {
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

    // No held socket and a self-contained body: this turn has to dial.
    const body = "{\"model\":\"gpt-5\",\"input\":[]}";
    const t0 = nowMs(io);
    const r = agent_ws.postResponsesWs(&agent, body);
    const ms = nowMs(io) - t0;
    if (r) |ok| gpa.free(ok) else |_| {}

    // HungRequest, not StreamStalled: a dial that never upgraded is a transport
    // failure, so postLive retries one fresh socket and only then latches SSE,
    // rather than spending a slot of request()'s 2-slot stall budget.
    try std.testing.expectError(error.HungRequest, r);
    try std.testing.expect(ms < 10_000); // unguarded, this never returned at all
    try std.testing.expect(ms >= 200); // the watchdog, not the pool-exhausted shortcut
    try std.testing.expect(traced(&tw, "\"detail\":\"connecting\""));
    try std.testing.expect(traced(&tw, "\"detail\":\"connect stall\""));
    try std.testing.expect(agent.codex_ws == null);
}

// ── teardown: a suspect socket gets a FIN, not a courtesy close frame ────────

// How the client ended the connection, as seen from the other side.
const saw_nothing: u8 = 0;
const saw_close_frame: u8 = 1;
const saw_fin: u8 = 2;

/// Complete the upgrade, then classify the next thing the client does: a ws close
/// frame (opcode 0x8) or EOF. `deinit` normally writes a courtesy close frame —
/// one more BLOCKING write on a socket that may be what wedged us.
fn closeObserver(io: Io, server: *std.Io.net.Server, seen: *std.atomic.Value(u8), done: *std.atomic.Value(bool)) void {
    const c = server.accept(io) catch return;
    defer c.close(io);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
    var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
    while (true) {
        const line = sr.interface.takeDelimiterInclusive('\n') catch return Mock.idle(io, done);
        if (line.len <= 2) break;
    }
    sw.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") catch return Mock.idle(io, done);
    sw.interface.flush() catch return Mock.idle(io, done);
    const h = sr.interface.takeArray(2) catch {
        seen.store(saw_fin, .release); // stream ended: a plain TCP FIN
        return Mock.idle(io, done);
    };
    seen.store(if ((h[0] & 0x0f) == 0x8) saw_close_frame else saw_nothing, .release);
    Mock.idle(io, done);
}

// The idle-expiry branch's own comment says the server has "likely already
// killed" that socket, so it must not spend deinit's blocking courtesy close
// frame on it. Watching the wire is the only way to test this: closeCodexWs
// frees the client before a caller could read its `dead` flag. Deleting
// `held.dead = true` there makes the server see a close frame, not a FIN.
test "#401: the idle-expiry teardown FINs a suspect socket instead of writing a close frame" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var done: std.atomic.Value(bool) = .init(false);
    var seen: std.atomic.Value(u8) = .init(saw_nothing);
    var fut = io.async(closeObserver, .{ io, &server, &seen, &done });
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

    var ws_url_buf: [64]u8 = undefined;
    const ws_url = try std.fmt.bufPrint(&ws_url_buf, "ws://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    agent.codex_ws = try ws.WsClient.connect(gpa, io, ws_url, false, &.{});
    agent.codex_ws_used_ms = nowMs(io) - agent_ws.codex_ws_idle_ms - 1000; // aged out
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    const body = "{\"model\":\"gpt-5\",\"previous_response_id\":\"resp_1\",\"input\":[]}";
    const r = agent_ws.postResponsesWs(&agent, body);
    if (r) |ok| gpa.free(ok) else |_| {}
    try std.testing.expectError(error.CodexWsReanchor, r);
    try std.testing.expect(traced(&tw, "\"detail\":\"idle >"));
    try std.testing.expect(agent.codex_ws == null);

    var waited: usize = 0;
    while (seen.load(.acquire) == saw_nothing and waited < 3000) : (waited += 20)
        try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expectEqual(saw_fin, seen.load(.acquire));
}
