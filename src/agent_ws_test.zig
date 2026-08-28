//! Regression tests for Codex WebSocket delta-session re-anchoring.

const std = @import("std");
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const textMessage = @import("messages.zig").textMessage;
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");
const codex_chain = @import("codex_chain.zig");
const agent_compact = @import("agent_compact.zig");
const engine_sink = @import("engine_sink.zig");
const engine_events = @import("engine_events.zig");

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
test "wssUrl: https->wss, http->ws" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("wss://chatgpt.com/backend-api/codex/responses", try agent_ws.wssUrl(a.allocator(), "https://chatgpt.com/backend-api/codex/responses"));
    try std.testing.expectEqualStrings("ws://localhost:1234/x", try agent_ws.wssUrl(a.allocator(), "http://localhost:1234/x"));
}

test "codexWsIdleExpired: fires only strictly past the idle limit (codex-ws)" {
    const limit = agent_ws.codex_ws_idle_ms;
    try std.testing.expectEqual(@as(i64, 4 * std.time.ms_per_min), limit); // default: stay under the observed server kill
    try std.testing.expect(!agent_ws.codexWsIdleExpired(1_000_000, 1_000_000)); // just used
    try std.testing.expect(!agent_ws.codexWsIdleExpired(1_000_000 + limit, 1_000_000)); // exactly at the limit — keep
    try std.testing.expect(agent_ws.codexWsIdleExpired(1_000_000 + limit + 1, 1_000_000)); // past it — re-anchor
    try std.testing.expect(agent_ws.codexWsIdleExpired(1_000_000 + 510 * std.time.ms_per_s, 1_000_000)); // the real 8.5-min trace gap
}

// (#402) The codex `.responses` error arm must recover from a rejected auth
// token the way the anthropic/openai arm does. Before the fix the #148 refresh
// lived only inside the generic apiErrorMessage branch, which a ChatGPT-backend
// 401 never reaches (the whole responses arm returns above it), so "Provided
// authentication token is expired" was terminal for the rest of the session.
//
// And because the retry re-sends the full history mid-turn, it must re-anchor
// first (PR #195): `continue :rebuild` over a live previous_response_id desyncs
// the chained WS meter, and the held socket still carries the stale bearer.
//
// The pure unit tests over retryAfterAuthRefresh all pass even if this call site
// is deleted, so pin the site itself — same shape as the source pins in
// route_policy_tests.zig / route_phase_tests.zig.
//
// A source pin proves placement, never behaviour: it would still pass against a
// stubbed-out helper. The behavioural half is scripts/test-codex-auth-recovery.py,
// which drives a real graff against the codex mock over a PTY and asserts the
// RETRIED request's Authorization header carries the newly adopted bearer.
test "the codex .responses arm refreshes auth and re-anchors before resending (#402)" {
    const src = @embedFile("agent_request.zig");
    const arm_start = std.mem.indexOf(u8, src, "unparseable codex response").?;
    const arm_end = std.mem.indexOf(u8, src, "{s} api error: {s}").?;
    const arm = src[arm_start..arm_end];

    const call = std.mem.indexOf(u8, arm, "retryAfterAuthRefresh(self, msg, &auth_refreshed)") orelse
        return error.ResponsesPathHasNoAuthRecovery;
    const after = arm[call..];
    const reanchor = std.mem.indexOf(u8, after, "closeCodexWs()") orelse return error.RetryDoesNotReanchor;
    const resend = std.mem.indexOf(u8, after, "continue :rebuild") orelse return error.RetryDoesNotRebuild;
    try std.testing.expect(reanchor < resend);

    // Both wire formats go through the one helper — no second, drifting copy.
    try std.testing.expect(std.mem.indexOf(u8, src[arm_end..], "retryAfterAuthRefresh(self, msg, &auth_refreshed)") != null);

    // A response.failed overload used to skip the shared transient retry path
    // and surface immediately (most visibly from detached recap calls).
    try std.testing.expect(std.mem.indexOf(u8, arm, "retryTransientServerError(self, \"\", failure.code, msg, &server_retries)") != null);

    // The guard bool is declared OUTSIDE `rebuild:`. Reset it inside the loop and a
    // permanently dead credential refresh-and-resends a full history forever, which
    // is strictly worse than the bug being fixed.
    try std.testing.expect(std.mem.indexOf(u8, src, "var auth_refreshed = false;").? <
        std.mem.indexOf(u8, src, "rebuild: while (true)").?);
}

test "WS fallback latches only after a retry" {
    try std.testing.expect(!agent_ws.wsShouldFallback(0));
    try std.testing.expect(!agent_ws.wsShouldFallback(1));
    try std.testing.expect(agent_ws.wsShouldFallback(2));
    try std.testing.expect(agent_ws.wsShouldFallback(255));
}

fn sinkRecord(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const rec: *std.ArrayList(engine_sink.Stamped) = @ptrCast(@alignCast(ctx));
    rec.append(std.testing.allocator, ev) catch @panic("OOM");
}

// (#422 slice 1b) postLive draws nothing itself anymore: each forced stall/
// drop seam emits exactly ONE transport_aborted event through the sink
// (ending-turn ⚠ only; mid-turn is silent — ADR 0021, pinned in
// engine_sink.zig) and returns the matching transport error. An injected
// recording sink observes the contract directly — no TTY, no globals read.
test "postLive force seams emit one transport_aborted through the sink (#422)" {
    const saved_sa = main_mod.g_force_stall_always;
    const saved_da = main_mod.g_force_drop_always;
    const saved_so = main_mod.g_force_stall_once;
    const saved_do = main_mod.g_force_drop_once;
    defer {
        main_mod.g_force_stall_always = saved_sa;
        main_mod.g_force_drop_always = saved_da;
        main_mod.g_force_stall_once = saved_so;
        main_mod.g_force_drop_once = saved_do;
    }
    main_mod.g_force_stall_always = false;
    main_mod.g_force_drop_always = false;
    main_mod.g_force_stall_once = false;
    main_mod.g_force_drop_once = false;

    var rec: std.ArrayList(engine_sink.Stamped) = .empty;
    defer rec.deinit(std.testing.allocator);
    const vt: engine_sink.VTable = .{ .emit = sinkRecord, .durable = false };
    var a: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
        .sink = .{ .ctx = &rec, .vt = &vt },
    };

    const Case = struct {
        flag: *bool,
        consumed: bool, // the once-seams reset themselves on use
        err: anyerror,
        reason: engine_events.StreamAbort,
        turn_ending: bool,
    };
    const cases = [_]Case{
        .{ .flag = &main_mod.g_force_stall_always, .consumed = false, .err = error.StreamStalled, .reason = .stalled, .turn_ending = false },
        .{ .flag = &main_mod.g_force_drop_always, .consumed = false, .err = error.StreamDropped, .reason = .dropped, .turn_ending = false },
        .{ .flag = &main_mod.g_force_stall_once, .consumed = true, .err = error.StreamStalled, .reason = .stalled, .turn_ending = true },
        .{ .flag = &main_mod.g_force_drop_once, .consumed = true, .err = error.StreamDropped, .reason = .dropped, .turn_ending = true },
    };
    for (cases, 1..) |c, want_events| {
        c.flag.* = true;
        try std.testing.expectError(c.err, agent_ws.postLive(&a, "{}"));
        if (c.consumed) try std.testing.expect(!c.flag.*) else c.flag.* = false;
        try std.testing.expectEqual(want_events, rec.items.len); // exactly one event per cut
        switch (rec.items[want_events - 1].event) {
            .transport_aborted => |t| {
                try std.testing.expectEqual(c.reason, t.reason);
                try std.testing.expectEqual(c.turn_ending, t.turn_ending);
            },
            else => return error.TestUnexpectedEvent,
        }
    }
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

// (#401) The exact SSE-parity boundary. `frames_seen != 0` was NOT this: it
// went true on response.created, milliseconds after the send, so the tightened
// 30s budget covered the whole silent reasoning phase — which SSE gives the full
// 120s. Everything in `quiet` below leaves the pre-first-token budget standing.
test "#401: only a visible output-text delta is the tokens-flowing signal (SSE parity)" {
    const gpa = std.testing.allocator;
    const quiet = [_][]const u8{
        "{\"type\":\"response.created\",\"response\":{}}", // protocol events: the
        "{\"type\":\"response.in_progress\",\"response\":{}}", // model has not
        "{\"type\":\"response.output_item.added\",\"output_index\":0}", // thought yet
        "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"hmm\"}", // never feeds partial_text
        // …nor does one that merely QUOTES the event name: the cheap substring
        // pre-filter must not be what decides.
        "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"response.output_text.delta\"}",
        "{\"type\":\"response.output_item.done\",\"item\":{\"content\":[{\"text\":\"hi\"}]}}", // carries text, but SSE ignores it too
        "{\"type\":\"response.output_text.delta\",\"delta\":\"\"}", // SSE's `text.len == 0` gate
        "{\"type\":\"response.completed\"}",
        "not json",
        "",
    };
    for (quiet) |f| try std.testing.expect(!agent_ws.frameHasOutputText(gpa, f));
    // …and the one thing that IS the signal, whatever the key order.
    try std.testing.expect(agent_ws.frameHasOutputText(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"));
    try std.testing.expect(agent_ws.frameHasOutputText(gpa, "{\"seq\":3,\"delta\":\"h\",\"type\":\"response.output_text.delta\"}"));
}

// (#401 round 4) …and the SECOND producer, which the round-3 signal missed.
//
// partial_text does NOT grow in only one place on SSE: streamSseLine calls
// argLiveDelta on every line, and emitArgText appends the streamed ARGUMENTS of
// a whitelisted meta call (agent_argstream.ArgTool). attempt_completion is
// graff's ordinary final-answer tool, so a codex turn whose whole visible output
// is that prose emits `response.function_call_arguments.delta` and never one
// output_text delta — SSE tightened from the first prose byte while WS held the
// full 120s. The whitelist is `argToolFor`, shared with ArgLive so the two
// cannot drift: an ordinary tool's argument stream prints nothing and must not
// tighten anything.
test "#401: whitelisted tool-argument prose is a tokens-flowing signal too (SSE parity)" {
    const gpa = std.testing.allocator;
    const open_meta = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"name\":\"attempt_completion\"}}";
    const open_edit = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"name\":\"edit_file\"}}";
    const arg_delta = "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"result\\\":\\\"hi\"}";
    const done_0 = "{\"type\":\"response.output_item.done\",\"output_index\":0}";

    // attempt_completion: the open event is not prose, the first argument byte is.
    var meta: agent_ws.TokenSignal = .{};
    try std.testing.expect(!meta.flowing(gpa, open_meta));
    try std.testing.expect(meta.flowing(gpa, arg_delta));

    // ask_user's `question` is the other whitelisted field.
    var ask: agent_ws.TokenSignal = .{};
    try std.testing.expect(!ask.flowing(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":7,\"item\":{\"type\":\"function_call\",\"name\":\"ask_user\"}}"));
    try std.testing.expect(ask.flowing(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":7,\"delta\":\"{\\\"question\\\":\\\"?\"}"));

    // rlm's `code` is speculated, not printed — same as an ordinary tool:
    // tightening here would drift from SSE (emitArgText does not grow partial_text).
    var rlm_sig: agent_ws.TokenSignal = .{};
    try std.testing.expect(!rlm_sig.flowing(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"name\":\"rlm\"}}"));
    try std.testing.expect(!rlm_sig.flowing(gpa, arg_delta));

    // An ORDINARY tool's arguments stream invisibly on SSE, so the identical
    // delta must leave the pre-first-token budget standing.
    var edit: agent_ws.TokenSignal = .{};
    try std.testing.expect(!edit.flowing(gpa, open_edit));
    try std.testing.expect(!edit.flowing(gpa, arg_delta));

    // …as must an arg delta for an item nobody opened, a different item, an
    // empty delta, a non-function_call item, and one whose call already closed.
    var stray: agent_ws.TokenSignal = .{};
    try std.testing.expect(!stray.flowing(gpa, arg_delta));
    try std.testing.expect(!stray.flowing(gpa, open_meta));
    try std.testing.expect(!stray.flowing(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"x\"}"));
    try std.testing.expect(!stray.flowing(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"\"}"));
    try std.testing.expect(!stray.flowing(gpa, done_0));
    try std.testing.expect(!stray.flowing(gpa, arg_delta)); // closed by done_0
    var msg: agent_ws.TokenSignal = .{};
    try std.testing.expect(!msg.flowing(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"name\":\"attempt_completion\"}}"));
    try std.testing.expect(!msg.flowing(gpa, arg_delta));

    // …and the other producer still reaches the same entry point unchanged.
    var text: agent_ws.TokenSignal = .{};
    try std.testing.expect(!text.flowing(gpa, "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"hmm\"}"));
    try std.testing.expect(text.flowing(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"));
}

// A flat head-sized send deadline is a false-positive generator on exactly the
// frame most likely to sit under it: every recovery re-anchors with the FULL
// conversation, so the retried frame is hundreds of KB where the delta was a few.
// Two such false positives latch SSE for the session, so the budget grows with
// the payload — while still never outlasting the read watchdog.
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

// #401's transport tests (mock-WS end-to-end) live in agent_ws_stall_test.zig
// (budgets, guards, teardown) and agent_ws_reuse_test.zig (reuse vs fresh
// connect), on the shared agent_ws_mock.zig harness: they need a loopback
// WebSocket server and a real Agent, which is more harness than this file's
// pure-decision tests carry. main.zig's test root is AT the 600-line cap, so
// those modules are hooked transitively through this one, which is already on
// the root chain (reference_zig_test_wiring: a module with no path to the root
// compiles but never runs a single test).
comptime {
    _ = @import("agent_ws_stall_test.zig");
    _ = @import("agent_ws_reuse_test.zig");
    _ = @import("agent_ws_fallback_test.zig"); // (#427) the WS→SSE ladder's routing decisions
}
