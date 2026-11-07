//! The context meter trusts a provider's count of a full request (agent_context.zig).

const std = @import("std");
const util = @import("util.zig");
const Agent = @import("agent.zig").Agent;
const messages_mod = @import("messages.zig");
const agent_context = @import("agent_context.zig");

// Static, not `&util.repeatBytes(...)` inside anthropicAgent: that would point
// the returned Agent at the helper's dead stack frame.
const sys_filler = blk: {
    @setEvalBranchQuota(20_000);
    break :blk util.repeatBytes("s", 6_000);
};
const tools_filler = blk: {
    @setEvalBranchQuota(20_000);
    break :blk util.repeatBytes("t", 7_000);
};

/// What a real provider reports: more than bytes/4, since code and JSON
/// tokenize at fewer than four bytes a token.
fn providerCount(agent: *Agent) u64 {
    return agent_context.measuredRequestTokens(agent, @import("context_tokens.zig").serializedLen(std.json.Value{ .array = agent.messages })) + 1_000;
}

fn anthropicAgent(a: std.mem.Allocator) Agent {
    var agent: Agent = undefined;
    agent.io = std.testing.io;
    agent.arena = a;
    agent.messages = std.json.Array.init(a);
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.last_usage_includes_output = false;
    agent.provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = "claude", .context = 200_000 };
    agent.sub = false;
    agent.strict = false;
    // Every field systemPrompt() reads: left undefined, review_mode can pick
    // another prompt and the estimate stops being deterministic.
    agent.review_mode = false;
    agent.sys_override = null;
    agent.ultracode_mode = false;
    agent.reasoning = .medium;
    agent.sys_normal = &sys_filler;
    agent.sys_strict = "";
    agent.tools_anthropic = &tools_filler;
    return agent;
}

test "before any usage the meter keeps the conservative local estimate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = anthropicAgent(arena_state.allocator());
    try agent.messages.append(try messages_mod.textMessage(arena_state.allocator(), "user", "hi"));
    // 13 KB of system + tools is ~3.3k by bytes/4; the pre-usage baseline holds it at 8k.
    try std.testing.expect(agent.fullRequestEstimateTokens() >= 8_000);
    try std.testing.expectEqual(agent.fullRequestEstimateTokens(), agent.effectiveContextTokens());
}

test "a provider count below the local estimate is the meter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = anthropicAgent(a);
    try agent.messages.append(try messages_mod.textMessage(a, "user", "hi"));
    const local = agent.fullRequestEstimateTokens();
    const reported = providerCount(&agent);
    agent_context.replaceContextTokens(&agent, reported);
    try std.testing.expect(local > reported);
    try std.testing.expectEqual(reported, agent.effectiveContextTokens());
}

test "a report below plain bytes/4 is not credible and floors there" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = anthropicAgent(a);
    try agent.messages.append(try messages_mod.textMessage(a, "user", "hi"));
    const floor = providerCount(&agent) - 1_000;
    agent_context.replaceContextTokens(&agent, 12); // a server that under-reports
    try std.testing.expectEqual(floor, agent.effectiveContextTokens());
}

test "growth after the sample adds to the provider count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = anthropicAgent(a);
    try agent.messages.append(try messages_mod.textMessage(a, "user", "hi"));
    const reported = providerCount(&agent);
    agent_context.replaceContextTokens(&agent, reported);
    const anchor = agent.context_local_tokens;
    try agent.messages.append(try messages_mod.textMessage(a, "user", &util.repeatBytes("x", 4_000)));
    const grown = agent.fullRequestEstimateTokens() - anchor;
    try std.testing.expect(grown >= 900);
    try std.testing.expectEqual(reported + grown, agent.effectiveContextTokens());
}

test "pairing provider-covered output does not re-floor at the local estimate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = anthropicAgent(a);
    try agent.messages.append(try messages_mod.textMessage(a, "user", "hi"));
    const reported = providerCount(&agent) + 200; // input + the reply's output tokens
    agent_context.replaceContextTokens(&agent, reported);
    agent.last_usage_includes_output = true;
    try agent.messages.append(try messages_mod.textMessage(a, "assistant", &util.repeatBytes("y", 600)));
    agent.pairContextMeterWithCurrentLocal();
    try std.testing.expectEqual(reported, agent.effectiveContextTokens());
}

test "a cleared sample falls back to the local estimate even with a stale anchor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = anthropicAgent(a);
    try agent.messages.append(try messages_mod.textMessage(a, "user", "hi"));
    agent_context.replaceContextTokens(&agent, providerCount(&agent));
    agent.last_context_tokens = 0; // what compaction does
    try std.testing.expectEqual(agent.fullRequestEstimateTokens(), agent.effectiveContextTokens());
}
