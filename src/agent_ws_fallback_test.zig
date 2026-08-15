//! (#427) The WS→SSE ladder's ROUTING decisions, end to end through
//! agent_ws.postLive on the agent_ws_mock loopback peer — which serves the
//! refused handshake AND the SSE turn graff falls back to on one port, so a
//! test can watch the whole ladder rather than one leg of it.
//!
//! ws.zig has always distinguished a 426 handshake ("this endpoint will not
//! upgrade, ever") from a generic handshake failure, but until #427 nothing
//! consumed error.UpgradeRequired: a 426 spent the ladder's free retry on a
//! redial the server had already answered, and only the SECOND 426 latched.
//! Pinned here: the fast path, the unchanged two-failure ladder beside it, and
//! that a transport CHOICE is not a stream cut on the event stream.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const main_mod = @import("main.zig");
const trace = @import("trace.zig");
const agent_ws = @import("agent_ws.zig");
const engine_sink = @import("engine_sink.zig");

const mock = @import("agent_ws_mock.zig");
const mockAgent = mock.mockAgent;
const traced = mock.traced;

fn record(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const rec: *std.ArrayList(engine_sink.Stamped) = @ptrCast(@alignCast(ctx));
    rec.append(std.testing.allocator, ev) catch @panic("OOM");
}

/// A ⚠ notice for the user (TuiSink) / nothing on the wire (JsonSink). Choosing
/// a transport must emit none: no stream was cut, so there is nothing to report.
fn sawTransportAbort(rec: []const engine_sink.Stamped) bool {
    for (rec) |ev| if (std.meta.activeTag(ev.event) == .transport_aborted) return true;
    return false;
}

// THE #427 regression test.
//
// A 426 is the server answering authoritatively, so the ladder's free retry can
// only redial the same refusal: one full rebuild plus a fresh dial burned before
// ws_failures_before_fallback finally latches. Reverting postLive's `declined`
// term fails this on `dials == 1` — the second handshake is the wasted work.
test "#427: a 426 latches SSE at once — no retry burned, and the turn is served over SSE" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const saved_ws = main_mod.g_codex_ws;
    main_mod.g_codex_ws = true; // wsEligible: pin it, a sibling test may have cleared it
    defer main_mod.g_codex_ws = saved_ws;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io); // registered first → torn down LAST, after the task is joined
    var dials: std.atomic.Value(u8) = .init(0);
    var sse: std.atomic.Value(u8) = .init(0);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(mock.refuseUpgrade, .{
        io, &server, @as([]const u8, "426 Upgrade Required"), @as(u8, 1), &dials, &sse, &done,
    });
    defer fut.await(io);
    // LIFO: done, then this, then the join — an assertion that fails before the
    // ladder reaches its last leg must FAIL, not hang in the mock's accept.
    defer mock.releaseAccept(io, &server);
    defer done.store(true, .release);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    // postLive's SSE leg is a REAL request, so the fallback needs a real client.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var rec: std.ArrayList(engine_sink.Stamped) = .empty;
    defer rec.deinit(gpa);
    const vt: engine_sink.VTable = .{ .emit = record, .durable = false };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;
    agent.client = &client;
    agent.out = &aw.writer; // wsEligible wants a live root stream…
    agent.sink = .{ .ctx = &rec, .vt = &vt }; // …and the recording sink keeps it off any terminal
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    const body = "{\"model\":\"gpt-5\",\"input\":[]}";
    const out = try agent_ws.postLive(&agent, body);
    defer gpa.free(out);

    // ONE dial. The retry the ladder would have spent never happened, and no
    // error.CodexWsReanchor asked request() to rebuild the body first.
    try std.testing.expectEqual(@as(u8, 1), dials.load(.acquire));
    try std.testing.expect(agent.ws_off); // latched for the rest of the session
    try std.testing.expect(agent.codex_ws == null);
    // …and THIS attempt already came back over the other transport.
    try std.testing.expectEqual(@as(u8, 1), sse.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, out, mock.delta_event) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, mock.completed_event) != null);
    try std.testing.expect(traced(&tw, "\"detail\":\"426 upgrade required"));
    try std.testing.expect(!traced(&tw, "\"detail\":\"transport error — retrying one fresh WS\""));
    try std.testing.expect(!traced(&tw, "\"detail\":\"transport failed twice"));
    // Picking a transport is not a cut stream: no ⚠ notice, nothing on the wire.
    try std.testing.expect(!sawTransportAbort(rec.items));
}

// The other side of the boundary, unchanged by #427: a handshake that failed
// for any reason the server did NOT declare permanent still gets its one free
// retry on a fresh socket, and only the second failure latches. Widening the
// fast path to every handshake error fails this at `dials == 1` on the first
// call, and at the missing "retrying one fresh WS" note.
test "#427: a non-426 handshake failure keeps the ladder's free retry, then latches" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const saved_ws = main_mod.g_codex_ws;
    main_mod.g_codex_ws = true;
    defer main_mod.g_codex_ws = saved_ws;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    var dials: std.atomic.Value(u8) = .init(0);
    var sse: std.atomic.Value(u8) = .init(0);
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(mock.refuseUpgrade, .{
        io, &server, @as([]const u8, "500 Internal Server Error"), @as(u8, 2), &dials, &sse, &done,
    });
    defer fut.await(io);
    // LIFO: done, then this, then the join — an assertion that fails before the
    // ladder reaches its last leg must FAIL, not hang in the mock's accept.
    defer mock.releaseAccept(io, &server);
    defer done.store(true, .release);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tw: Io.Writer.Allocating = .init(gpa);
    defer tw.deinit();
    var tracer: trace.Tracer = .{ .io = io, .gpa = gpa, .out = &tw.writer, .start = Io.Timestamp.now(io, .awake) };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var rec: std.ArrayList(engine_sink.Stamped) = .empty;
    defer rec.deinit(gpa);
    const vt: engine_sink.VTable = .{ .emit = record, .durable = false };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{server.socket.address.getPort()});
    var agent = mockAgent(gpa, arena, io, url);
    agent.tracer = &tracer;
    agent.client = &client;
    agent.out = &aw.writer;
    agent.sink = .{ .ctx = &rec, .vt = &vt };
    defer if (agent.codex_ws) |c| {
        c.dead = true;
        c.deinit(gpa);
        agent.codex_ws = null;
    };

    const body = "{\"model\":\"gpt-5\",\"input\":[]}";

    // Attempt 1: rebuild full input and retry a fresh WS — no latch, no SSE.
    try std.testing.expectError(error.CodexWsReanchor, agent_ws.postLive(&agent, body));
    try std.testing.expect(!agent.ws_off);
    try std.testing.expectEqual(@as(u8, 1), agent.ws_transport_failures);
    try std.testing.expectEqual(@as(u8, 1), dials.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), sse.load(.acquire));
    try std.testing.expect(traced(&tw, "\"detail\":\"transport error — retrying one fresh WS\""));

    // Attempt 2: the fresh socket is refused too, so now it latches and serves
    // this attempt over SSE — the two-failure ladder, exactly as before.
    const out = try agent_ws.postLive(&agent, body);
    defer gpa.free(out);
    try std.testing.expect(agent.ws_off);
    try std.testing.expectEqual(@as(u8, 2), agent.ws_transport_failures);
    try std.testing.expectEqual(@as(u8, 2), dials.load(.acquire));
    try std.testing.expectEqual(@as(u8, 1), sse.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, out, mock.completed_event) != null);
    try std.testing.expect(traced(&tw, "\"detail\":\"transport failed twice"));
    try std.testing.expect(!traced(&tw, "\"detail\":\"426 upgrade required"));
    try std.testing.expect(!sawTransportAbort(rec.items));
}

// #502 regression: the codex-only gate (correct for Platform OpenAI, which has
// no WS server to probe) must not swallow xAI — both serve a real WS endpoint,
// and the v0.0.25x release line's gate silently killed xAI WS turns once.
test "wsEligible: codex and xai qualify; Platform OpenAI and chat wires never do" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const saved_ws = main_mod.g_codex_ws;
    main_mod.g_codex_ws = true;
    defer main_mod.g_codex_ws = saved_ws;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var agent = mockAgent(gpa, arena_state.allocator(), io, "https://chatgpt.com/x");
    agent.out = &aw.writer;
    try std.testing.expect(agent_ws.wsEligible(&agent)); // codex baseline

    agent.provider.id = "xai";
    try std.testing.expect(agent_ws.wsEligible(&agent)); // #502: xai rides WS

    agent.provider.id = "openai";
    try std.testing.expect(!agent_ws.wsEligible(&agent)); // Platform: no WS server

    agent.provider.id = "xai";
    agent.provider.kind = .openai;
    try std.testing.expect(!agent_ws.wsEligible(&agent)); // chat wire: never WS
}
