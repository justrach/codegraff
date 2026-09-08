
test "inputOverCompactThreshold: server meter trips the gate on empty history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.messages = std.json.Array.init(a);
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 10_000 };
    try std.testing.expect(!inputOverCompactThreshold(&agent));
    agent.last_context_tokens = agent.provider.compactAt();
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    try std.testing.expect(inputOverCompactThreshold(&agent));
}
