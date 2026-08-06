//! Recovery-side tests for agent_overflow.zig — the half that drives a live
//! Agent (pin the meter, emergency-trim, retry once). The pure classification
//! tables are tested next to the tables themselves, in agent_overflow.zig.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const overflow = @import("agent_overflow.zig");
const recoverContextOverflow = overflow.recoverContextOverflow;
const recoverBehavioralOverflow = overflow.recoverBehavioralOverflow;

test { // main.zig's test root lists this file; carry agent_overflow.zig's own tests in with it
    _ = overflow;
}

/// A history emergencyTrim can actually reclaim: one clean user turn followed
/// by fat tool outputs (the #163 shape trimOldestToolOutputs recovers from).
fn trimmableAgent(a: std.mem.Allocator, kind: @import("provider.zig").Provider.Kind, window: u64) !Agent {
    var msgs = std.json.Array.init(a);
    var um: std.json.ObjectMap = .empty;
    try um.put(a, "role", .{ .string = "user" });
    try um.put(a, "content", .{ .string = "do a thing" });
    try msgs.append(.{ .object = um });
    const big = try a.alloc(u8, 5000);
    @memset(big, 'x');
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "type", .{ .string = "function_call_output" });
        try o.put(a, "call_id", .{ .string = "c" });
        try o.put(a, "output", .{ .string = big });
        try msgs.append(.{ .object = o });
    }
    var agent: Agent = undefined;
    agent.arena = a;
    agent.messages = msgs;
    agent.tracer = null;
    agent.provider = .{ .id = @tagName(kind), .kind = kind, .auth = .x_api_key, .url = "", .api_key = "", .model = "claude", .context = window };
    agent.last_context_tokens = 0;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_anthropic = "";
    agent.tools_openai = "";
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    agent.stream_quiet = true;
    agent.compaction_request = false;
    agent.last_request_context_overflow = false;
    agent.last_api_error = null;
    agent.out = null;
    agent.label = "test";
    return agent;
}

test "recoverContextOverflow (#414): a Bedrock throttle rides the retry ladder instead of compacting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try trimmableAgent(a, .anthropic, 100000);
    const before = agent.messages.items.len;

    // The whole point of the guard list: this string matches the generic
    // "too many tokens" overflow fallback, but it is a 429. Recovering here
    // would discard real history AND shadow the Retry-After backoff.
    var retried = false;
    try std.testing.expect(!recoverContextOverflow(&agent, "ThrottlingException: Too many tokens, please wait before trying again.", null, &retried));
    try std.testing.expect(!retried);
    try std.testing.expect(!agent.last_request_context_overflow); // meter untouched: no compaction is scheduled
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(before, agent.messages.items.len);
}

fn parse(a: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(Value, a, body, .{ .allocate = .alloc_always });
    return v.object;
}

test "recoverBehavioralOverflow (#414): the silent 200 compacts and retries; a normal reply does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try trimmableAgent(a, .openai, 128_000);

    // An ordinary answer is never touched, even at a high token count.
    const ok_body =
        \\{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":120000,"completion_tokens":8}}
    ;
    var retried = false;
    try std.testing.expect(!recoverBehavioralOverflow(&agent, try parse(a, ok_body), &retried));
    try std.testing.expect(!retried);
    try std.testing.expect(!agent.last_request_context_overflow);
    try std.testing.expect(agent.last_api_error == null);

    // z.ai's shape: HTTP 200, no answer, usage over the window.
    const silent =
        \\{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":131072,"completion_tokens":0}}
    ;
    const before = agent.fullRequestEstimateTokens();
    try std.testing.expect(recoverBehavioralOverflow(&agent, try parse(a, silent), &retried));
    try std.testing.expect(retried);
    try std.testing.expect(agent.last_request_context_overflow);
    try std.testing.expect(agent.fullRequestEstimateTokens() < before); // history was actually trimmed
    try std.testing.expect(agent.last_api_error == null); // recovered -> nothing to report

    // Same request, second occurrence: the retry guard stops a loop, but the
    // meter stays pinned at the window so the between-turns compaction still
    // engages, and the now-unrecoverable condition is named instead of
    // surfacing as an inexplicably short answer.
    try std.testing.expect(!recoverBehavioralOverflow(&agent, try parse(a, silent), &retried));
    try std.testing.expectEqual(agent.provider.context, agent.last_context_tokens);
    try std.testing.expect(agent.last_api_error != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.last_api_error.?, "silent_overflow") != null);

    // A compaction summary request owns its own empty-summary escalation (#379).
    agent.compaction_request = true;
    agent.last_api_error = null;
    var fresh = false;
    try std.testing.expect(!recoverBehavioralOverflow(&agent, try parse(a, silent), &fresh));
    try std.testing.expect(agent.last_api_error == null);
}

test "recoverBehavioralOverflow (#414): truncate-then-length is reported as truncation, not a short answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try trimmableAgent(a, .openai, 32_768);

    // A genuine max-tokens completion must never be reclassified: it generated.
    const normal_length =
        \\{"choices":[{"message":{"role":"assistant","content":"a long answer that ran out of room"},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":32700,"completion_tokens":68}}
    ;
    var retried = false;
    try std.testing.expect(!recoverBehavioralOverflow(&agent, try parse(a, normal_length), &retried));
    try std.testing.expect(!agent.last_request_context_overflow);

    // MiMo: the server truncated our input to fit, so it had no room to answer.
    const truncated =
        \\{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"length"}],
        \\ "usage":{"prompt_tokens":32768,"completion_tokens":0}}
    ;
    try std.testing.expect(recoverBehavioralOverflow(&agent, try parse(a, truncated), &retried));
    try std.testing.expect(agent.last_request_context_overflow);

    // Unrecoverable repeat: the distinct diagnosis reaches last_api_error, which
    // is what a subagent's parent and the --json error event read.
    try std.testing.expect(!recoverBehavioralOverflow(&agent, try parse(a, truncated), &retried));
    try std.testing.expect(std.mem.indexOf(u8, agent.last_api_error.?, "upstream_truncation") != null);
}
