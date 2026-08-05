//! Regression tests for Codex WebSocket delta-session re-anchoring.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = @import("http.zig");
const Agent = @import("agent.zig").Agent;
const textMessage = @import("messages.zig").textMessage;
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");
const codex_chain = @import("codex_chain.zig");
const agent_compact = @import("agent_compact.zig");

test "closeCodexWs resets the delta session state + frees the response id (codex-ws)" {
    var agent: Agent = undefined;
    agent.gpa = std.testing.allocator;
    agent.codex_ws = null; // no live WsClient to deinit in a unit test
    agent.codex_prev_id = try std.testing.allocator.dupe(u8, "resp_abc123"); // must be freed (leak-checked)
    agent.codex_sent_upto = 5;
    agent.closeCodexWs();
    try std.testing.expect(agent.codex_prev_id == null); // freed + nulled
    try std.testing.expectEqual(@as(usize, 0), agent.codex_sent_upto); // delta boundary reset
    try std.testing.expect(agent.codex_ws == null);
}

// (#codex-ws) The delta-body detection string check in agent_ws.zig's
// postLive() gates the WS-reanchor path (never SSE-replay a delta): it
// looks for the literal `"previous_response_id"` key that buildBody's
// .responses branch emits. Pin the exact substring so the two stay in
// sync — a future rename of the JSON key on either side breaks this test
// instead of silently reopening the SSE-replay bug.
test "postLive's delta-body detection matches the key buildBody emits (codex-ws)" {
    const delta_body = "{\"model\":\"gpt-5\",\"previous_response_id\":\"resp_1\",\"input\":[]}";
    const full_body = "{\"model\":\"gpt-5\",\"input\":[]}";
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"previous_response_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_body, "\"previous_response_id\"") == null);
}

// (#codex-ws) The preemptive idle re-anchor decision (postResponsesWs closes a
// held WS the server has likely already killed instead of eating a failed
// round trip). Pure helper so no socket is needed: exactly-at-limit must NOT
// expire (only strictly past it), and a WS used moments ago must survive.
// opencode pools at 5 min; ours defaults to 4 (the backend killed a real
// session within 8.5 min idle).
test "codexWsIdleExpired: fires only strictly past the idle limit (codex-ws)" {
    const limit = agent_ws.codex_ws_idle_ms;
    try std.testing.expectEqual(@as(i64, 4 * std.time.ms_per_min), limit); // default: stay under the observed server kill
    try std.testing.expect(!agent_ws.codexWsIdleExpired(1_000_000, 1_000_000)); // just used
    try std.testing.expect(!agent_ws.codexWsIdleExpired(1_000_000 + limit, 1_000_000)); // exactly at the limit — keep
    try std.testing.expect(agent_ws.codexWsIdleExpired(1_000_000 + limit + 1, 1_000_000)); // past it — re-anchor
    try std.testing.expect(agent_ws.codexWsIdleExpired(1_000_000 + 510 * std.time.ms_per_s, 1_000_000)); // the real 8.5-min trace gap
}

test "WS fallback latches only after a retry" {
    try std.testing.expect(!agent_ws.wsShouldFallback(0));
    try std.testing.expect(!agent_ws.wsShouldFallback(1));
    try std.testing.expect(agent_ws.wsShouldFallback(2));
    try std.testing.expect(agent_ws.wsShouldFallback(255));
}

// (#codex-ws) End-to-end regression for the reanchor fix: buildBody's
// .responses branch must emit previous_response_id + a message-slice delta
// while a WS session + prev id are held, and after closeCodexWs (called by
// postLive on a delta transport error, and again by request()'s
// error.CodexWsReanchor handler) a rebuilt body must carry the FULL
// message history with no previous_response_id — never a stale delta
// replayed against a dead session.
test "buildBody (.responses): delta while WS live; full input after closeCodexWs (codex-ws)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "first"));
    try msgs.append(try textMessage(a, "assistant", "second"));
    try msgs.append(try textMessage(a, "user", "third — not yet sent"));

    var dummy_ws: ws.WsClient = undefined; // buildBody only checks != null, never dereferences
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io, // unused by buildBody
        .client = undefined, // unused by buildBody
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://x/responses", .api_key = "k", .model = "gpt-5", .context = 100_000 },
        .messages = msgs,
        .sub = false,
        .label = "",
        .out = null,
        .codex_ws = &dummy_ws,
        .codex_prev_id = try std.testing.allocator.dupe(u8, "resp_live"),
        .codex_sent_upto = 2, // server already holds messages[0..2]; delta = [2..]
    };
    // Anchor the chain the way codex_chain.record does after a response: the
    // delta is only sent when the request properties still match the ones the
    // server produced that response under.
    agent.codex_props_fp = codex_chain.propsFor(&agent);

    const delta_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(delta_body);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"previous_response_id\":\"resp_live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "third — not yet sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"first\"") == null); // NOT resent — already on the server
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "max_output_tokens") == null); // #codex: backend rejects a top-level max_output_tokens (gpt-5.6) — never emit it

    // Simulate closeCodexWs's effect (covered by its own unit test above)
    // without invoking it directly: it would call ws.WsClient.deinit on
    // codex_ws, which sends a real close frame over `dummy_ws`'s
    // uninitialized io/fd — fine for a live connection, unsafe for this
    // struct-literal stand-in. What matters here is buildBody's behavior
    // given the post-close state postLive/request() leave it in.
    std.testing.allocator.free(agent.codex_prev_id.?);
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.codex_sent_upto = 0;
    const rebuilt_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(rebuilt_body);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt_body, "\"previous_response_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt_body, "\"first\"") != null); // full history restored
    try std.testing.expect(std.mem.indexOf(u8, rebuilt_body, "third — not yet sent") != null);

    agent.compaction_request = true;
    const compact_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(compact_body);
    try std.testing.expect(std.mem.indexOf(u8, compact_body, "max_output_tokens") == null); // #codex: no top-level max_output_tokens even in compaction

    agent.compaction_request = false;
    agent.responses_output_limit = 64;
    const title_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(title_body);
    try std.testing.expect(std.mem.indexOf(u8, title_body, "max_output_tokens") == null); // #codex: no top-level max_output_tokens even for the bounded title task
}

// The chain now outlives runTurn, so buildBody is the last line of defence: a
// delta keyed to a history the server no longer mirrors would make it prepend
// a conversation that no longer exists. Each guard is exercised through the
// REAL body, not just the pure predicate.
test "buildBody (.responses): a cross-turn delta re-anchors when history or settings move" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "first"));
    try msgs.append(try textMessage(a, "assistant", "second"));

    var dummy_ws: ws.WsClient = undefined; // buildBody only checks != null
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://x/responses", .api_key = "k", .model = "gpt-5.6", .context = 270_000 },
        .messages = msgs,
        .sub = false,
        .label = "",
        .out = null,
        .codex_ws = &dummy_ws,
        .codex_prev_id = try std.testing.allocator.dupe(u8, "resp_turn1"),
    };
    defer std.testing.allocator.free(agent.codex_prev_id.?);
    codex_chain.record(&agent); // server holds all 2 messages after turn 1

    // The NEXT user turn appends a prompt. This is the whole point: before,
    // runTurn's teardown made this a full re-upload plus a fresh handshake.
    try agent.messages.append(try textMessage(a, "user", "second turn prompt"));
    const chained = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(chained);
    try std.testing.expect(std.mem.indexOf(u8, chained, "\"previous_response_id\":\"resp_turn1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chained, "second turn prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, chained, "\"first\"") == null); // the win: not re-uploaded

    // A compaction rewrote history in place. The length can still look fine, so
    // only the rewrite counter catches it.
    agent.history_rewrites += 1;
    const after_compact = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(after_compact);
    try std.testing.expect(std.mem.indexOf(u8, after_compact, "previous_response_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_compact, "\"first\"") != null); // full resend
    agent.history_rewrites -= 1;

    // /effort changed between turns: chaining would attribute turn 2 to a
    // response the server generated under a different reasoning budget.
    agent.reasoning = .high;
    const after_effort = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(after_effort);
    try std.testing.expect(std.mem.indexOf(u8, after_effort, "previous_response_id") == null);
    agent.reasoning = .medium;

    // /clear reinitializes messages, leaving the history SHORTER than the
    // watermark: the server's copy is no longer a prefix of ours.
    agent.messages = std.json.Array.init(a);
    const after_clear = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(after_clear);
    try std.testing.expect(std.mem.indexOf(u8, after_clear, "previous_response_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_clear, "second turn prompt") == null); // cleared, not resurrected
}

// #194: a response with no usable `id` must not leave a STALE previous_response_id
// paired with an ADVANCED delta boundary. That combination makes the next request
// send `previous_response_id: <old>` plus a delta starting after items the server
// never received, so those items vanish from the conversation with no error. The
// window used to be one turn (runTurn tore the session down); now that the chain
// spans turns, the anchor has to be dropped explicitly.
test "stepResponses (#194): a response with no id drops the anchor instead of advancing it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "first"));

    var dummy_ws: ws.WsClient = undefined;
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://x/responses", .api_key = "k", .model = "gpt-5.6", .context = 270_000 },
        .messages = msgs,
        .sub = true, // suppress the unstreamed-text surface; irrelevant here
        .label = "",
        .out = null,
        .codex_ws = &dummy_ws,
        .codex_prev_id = try std.testing.allocator.dupe(u8, "resp_old"),
    };
    codex_chain.record(&agent); // anchored: server holds messages[0..1] under resp_old
    try std.testing.expectEqual(@as(usize, 1), agent.codex_sent_upto);

    // A turn appends work, then a response arrives WITHOUT an id.
    try agent.messages.append(try textMessage(a, "user", "work the server must see"));
    var no_id: std.json.ObjectMap = .empty;
    try no_id.put(a, "output", .{ .array = std.json.Array.init(a) });
    _ = try agent.stepResponses(no_id);

    // The anchor is gone, so the next request re-sends everything. Before the
    // fix the watermark advanced to 2 while prev_id stayed "resp_old", and the
    // "work the server must see" message was never transmitted.
    try std.testing.expect(agent.codex_prev_id == null);
    try std.testing.expect(!codex_chain.chainUsable(&agent));

    // A response WITH an id anchors normally: id and watermark move together.
    var with_id: std.json.ObjectMap = .empty;
    try with_id.put(a, "output", .{ .array = std.json.Array.init(a) });
    try with_id.put(a, "id", .{ .string = "resp_new" });
    _ = try agent.stepResponses(with_id);
    defer std.testing.allocator.free(agent.codex_prev_id.?);
    try std.testing.expectEqualStrings("resp_new", agent.codex_prev_id.?);
    try std.testing.expectEqual(agent.messages.items.len, agent.codex_sent_upto);
}

// runTurn used to bracket every compaction with closeCodexWs, so compact()'s own
// summary request could never carry a delta. With the chain spanning user turns
// that bracket is gone from the BETWEEN-turn callers (mainloop's two
// compactOrRecover sites), and compact() sets stream_quiet -> its request goes
// over codex HTTP, which rejects previous_response_id outright. The length guard
// does not save it either: recentContextStart can leave the summary history
// LONGER than codex_sent_upto. compactPrelude drops the anchor instead.
test "compactPrelude drops the codex chain before compaction's own request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "first"));
    try msgs.append(try textMessage(a, "assistant", "second"));

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://x/responses", .api_key = "k", .model = "gpt-5.6", .context = 270_000 },
        .messages = msgs,
        .sub = false,
        .label = "",
        .out = null,
        .codex_ws = null, // no live socket to deinit; the anchor is what matters
        .codex_prev_id = try std.testing.allocator.dupe(u8, "resp_live"),
    };
    codex_chain.record(&agent);

    _ = agent_compact.compactPrelude(&agent);

    // Anchor gone, so compaction's summary request carries full input and no
    // previous_response_id - which the codex HTTP endpoint would reject anyway.
    try std.testing.expect(agent.codex_prev_id == null);
    try std.testing.expectEqual(@as(usize, 0), agent.codex_sent_upto);
    try std.testing.expect(!codex_chain.chainUsable(&agent));

    const body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "previous_response_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"first\"") != null);
}

// Regression (#codex gpt-5.6): the Codex Responses backend rejects a top-level
// `max_output_tokens` ("Unsupported parameter: max_output_tokens"), which hard-
// failed EVERY turn including the title task. openai/codex never sends it at the
// request top level — there it is only a tool argument (exec_command/wait output
// truncation). buildBody's .responses branch must never emit a top-level
// max_output_tokens in ANY mode (normal, compaction, or the bounded title task),
// while still carrying the required Responses fields. Pin it so a re-add fails here.
test "buildBody (.responses): never emits a top-level max_output_tokens (codex gpt-5.6)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "hello"));

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io, // unused by buildBody
        .client = undefined, // unused by buildBody
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://x/responses", .api_key = "k", .model = "gpt-5.6-sol", .context = 270_000 },
        .messages = msgs,
        .sub = false,
        .label = "",
        .out = null,
    };

    // Normal first-turn body: no max_output_tokens, but the required fields present.
    const body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);

    // Compaction mode must not reintroduce it.
    agent.compaction_request = true;
    const compact = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(compact);
    try std.testing.expect(std.mem.indexOf(u8, compact, "max_output_tokens") == null);

    // The bounded title task must not reintroduce it either.
    agent.compaction_request = false;
    agent.responses_output_limit = 64;
    const title = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(title);
    try std.testing.expect(std.mem.indexOf(u8, title, "max_output_tokens") == null);
}

// ── #401: the WS transport's outbound half ───────────────────────────────────

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

// A loopback listener that completes the upgrade and then stops reading. That
// is the half-open shape a held codex socket lands in while a tool call runs,
// and the one the #401 trace shows: "ws reuse (delta)" and then nothing.
const HalfOpenServer = struct {
    fn run(io: Io, server: *std.Io.net.Server, upgrade: bool, done: *std.atomic.Value(bool)) void {
        const c = server.accept(io) catch return;
        defer c.close(io);
        if (upgrade) {
            var rbuf: [4096]u8 = undefined;
            var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
            while (true) {
                const line = sr.interface.takeDelimiterInclusive('\n') catch break;
                if (line.len <= 2) break; // blank line: end of the upgrade request
            }
            var wbuf: [256]u8 = undefined;
            var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
            sw.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") catch {};
            sw.interface.flush() catch {};
        }
        // …and from here never read (or, with upgrade=false, never answer at
        // all): the socket stays open and undrained until the test releases it.
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch break;
    }
};

// #401 regression. A main-agent request sent over a REUSED codex WS right after
// a tool result hung forever: `sendText` was a bare blocking socket write with
// no deadline, no Esc poll and no trace note, so a peer that had silently
// stopped draining parked the turn inside the write syscall until TCP gave up
// (minutes to never). The read loop was already watchdogged, which is why the
// trace stopped dead at "reuse (delta)" with no stall/esc/completed note. The
// guarded send must surface error.StreamStalled promptly instead, so
// request()'s bounded reconnect → WS→SSE ladder can recover the turn.
test "sendFrameWatched (#401): a peer that stops draining fails fast instead of hanging" {
    // Windows loopback buffer sizing / RST timing is not deterministic enough
    // to guarantee the write blocks rather than failing outright (same reason
    // the #177 poison test is POSIX-only).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(HalfOpenServer.run, .{ io, &server, true, &done });
    defer fut.await(io);
    defer done.store(true, .release);
    defer server.deinit(io);

    const bound = server.socket.address;
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/x", .{bound.getPort()});
    const client = try ws.WsClient.connect(gpa, io, url, false, &.{});

    // head_stall_ms is shared with the SSE head path — restore it or every
    // later test in this binary inherits a 300ms budget.
    const saved = http.head_stall_ms;
    http.head_stall_ms = 300;
    defer http.head_stall_ms = saved;

    // Bigger than any plausible loopback send+receive buffer, so the write
    // really blocks in the kernel instead of slipping through.
    const big = try gpa.alloc(u8, 16 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');

    const t0 = nowMs(io);
    const sent = agent_ws.sendFrameWatched(io, client, big, false);
    const send_ms = nowMs(io) - t0;

    // …and the recovery must not re-hang: deinit's courtesy close frame is
    // another blocking write on the same wedged socket, so `dead` skips it.
    const t1 = nowMs(io);
    client.dead = true;
    client.deinit(gpa);
    const close_ms = nowMs(io) - t1;

    try std.testing.expectError(error.StreamStalled, sent);
    try std.testing.expect(send_ms < 10_000); // before the fix this never returned at all
    // …and it was the WATCHDOG that ended it, not the pool-exhausted shortcut
    // (which also returns StreamStalled, instantly, and would pass vacuously).
    try std.testing.expect(send_ms >= 200);
    try std.testing.expect(close_ms < 5_000);
}

// #401 (F3). Once the send is guarded, the retry it triggers redials — and the
// dial was unbounded too: DNS + TCP + TLS + a blocking read of the 101 status
// line. A host that accepts the connection but never upgrades would hang at the
// "connecting" note and swallow the recovery. Same watchdog, same error, so
// request()'s stall budget applies and the second failure latches SSE.
test "connectWatched (#401): a host that accepts but never upgrades times out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    var done: std.atomic.Value(bool) = .init(false);
    var fut = io.async(HalfOpenServer.run, .{ io, &server, false, &done });
    defer fut.await(io);
    defer done.store(true, .release);
    defer server.deinit(io);

    const bound = server.socket.address;
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/x", .{bound.getPort()});

    const saved = http.head_stall_ms;
    http.head_stall_ms = 300;
    defer http.head_stall_ms = saved;

    const t0 = nowMs(io);
    const dialed = agent_ws.connectWatched(gpa, io, url, &.{}, false);
    const dial_ms = nowMs(io) - t0;
    if (dialed) |c| {
        c.dead = true;
        c.deinit(gpa);
    } else |_| {}

    try std.testing.expectError(error.StreamStalled, dialed);
    try std.testing.expect(dial_ms < 10_000);
    try std.testing.expect(dial_ms >= 200); // the watchdog fired, not the pool-exhausted shortcut
}

// #134's classification, pinned for the two arms #401 adds. A wedged send is a
// harness stall (the turn reconnects, and mainloop records it as "response
// ended early"), never "[response interrupted by user]"; a real Esc during the
// send — which was inert before #401, since nothing polled stdin there — must
// stay a deliberate interrupt that request()'s retry loop refuses to retry.
test "the #401 send/dial guards classify a deadline as a stall and an Esc as an interrupt" {
    try std.testing.expect(http.watchdogError(.deadline, error.StreamStalled) == error.StreamStalled);
    try std.testing.expect(http.watchdogError(.deadline, error.StreamStalled) != error.Interrupted);
    try std.testing.expect(http.watchdogError(.esc, error.StreamStalled) == error.Interrupted);
    // The send budget is the head budget, not the pre-first-token stream budget:
    // it measures "the frame is not on the wire yet", not "the model is slow".
    try std.testing.expect(http.head_stall_ms < http.stream_stall_ms);
}
