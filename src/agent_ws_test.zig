//! Regression tests for Codex WebSocket delta-session re-anchoring.

const std = @import("std");
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
    const arm_end = std.mem.indexOf(u8, src, "codex api error: {s}").?;
    const arm = src[arm_start..arm_end];

    const call = std.mem.indexOf(u8, arm, "retryAfterAuthRefresh(self, msg, &auth_refreshed)") orelse
        return error.ResponsesPathHasNoAuthRecovery;
    const after = arm[call..];
    const reanchor = std.mem.indexOf(u8, after, "closeCodexWs()") orelse return error.RetryDoesNotReanchor;
    const resend = std.mem.indexOf(u8, after, "continue :rebuild") orelse return error.RetryDoesNotRebuild;
    try std.testing.expect(reanchor < resend);

    // Both wire formats go through the one helper — no second, drifting copy.
    try std.testing.expect(std.mem.indexOf(u8, src[arm_end..], "retryAfterAuthRefresh(self, msg, &auth_refreshed)") != null);

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
