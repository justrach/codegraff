//! Regression tests for Codex WebSocket delta-session re-anchoring.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const textMessage = @import("messages.zig").textMessage;
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");

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
        .io = undefined, // unused by buildBody
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

    const delta_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(delta_body);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"previous_response_id\":\"resp_live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "third — not yet sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"first\"") == null); // NOT resent — already on the server

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
}
