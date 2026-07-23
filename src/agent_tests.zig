//! Larger Agent fixtures kept separate from the state/method definition.

const std = @import("std");
const mcp = @import("mcp.zig");

pub fn lazyRootTools(comptime Agent: type) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    var connected = [_]mcp.Tool{.{
        .server_index = 0,
        .original_name = "search",
        .qualified_name = "mcp__bench__search",
        .description = "search the benchmark index",
        .input_schema = .{ .object = .empty },
    }};
    registry.tools = &connected;

    var agent: Agent = undefined;
    agent.arena = arena;
    agent.sub = false;
    agent.registry = &registry;
    agent.tools_anthropic = "";
    agent.tools_openai = "";
    agent.tools_responses = "";

    try agent.ensureRootTools(.responses);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_responses, "mcp__bench__search") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.tools_openai.len);
    try std.testing.expectEqual(@as(usize, 0), agent.tools_anthropic.len);

    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_anthropic, "mcp__bench__search") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.tools_responses.len);
}
