const std = @import("std");
const provider = @import("provider.zig");
const schema = @import("schema.zig");
const fixtures = @import("agent_request_body_responses.zig");

test "MiMo Chat uses the documented binary thinking switch on direct and gateway routes" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    for ([_][]const u8{ "xiaomi", "codegraff" }) |id| {
        var agent = try fixtures.testAgentFor(state.allocator(), id, .openai, "mimo-v2.6-flash");
        try std.testing.expect(schema.providerTakesEffort(agent.provider.kind, id, agent.provider.model));
        agent.reasoning = .none;
        const off = try agent.buildBody(null, false, true, true);
        defer std.testing.allocator.free(off);
        try std.testing.expect(std.mem.indexOf(u8, off, "\"thinking\":{\"type\":\"disabled\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, off, "reasoning_effort") == null);
        agent.reasoning = .low; // a saved positive level still means On
        const on = try agent.buildBody(null, false, true, true);
        defer std.testing.allocator.free(on);
        try std.testing.expect(std.mem.indexOf(u8, on, "\"thinking\":{\"type\":\"enabled\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, on, "reasoning_effort") == null);
    }
}

test "MiMo Responses sends none or high, including internal summaries" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var agent = try fixtures.testAgentFor(state.allocator(), "xiaomi", .responses, "mimo-v2.6-pro");
    agent.reasoning = .none;
    agent.compaction_request = true;
    const off = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "\"reasoning\":{\"effort\":\"none\"}") != null);
    agent.compaction_request = false;
    agent.reasoning = .medium;
    const on = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(on);
    try std.testing.expect(std.mem.indexOf(u8, on, "\"reasoning\":{\"effort\":\"high\"}") != null);
}

test "Off is refused before serialization for unrelated providers" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var agent = try fixtures.testAgentFor(state.allocator(), "openai", .responses, "gpt-6-astra");
    agent.reasoning = .none;
    try std.testing.expectError(error.ReasoningOffUnsupported, agent.buildBody(null, false, true, true));
    try std.testing.expect(!schema.providerTakesEffort(provider.Provider.Kind.openai, "xiaomi", "unrelated"));
}
