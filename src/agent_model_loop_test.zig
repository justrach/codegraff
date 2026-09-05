//! Local delivery/finalization regressions: no external endpoint or identity.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const loop = @import("agent_model_loop.zig");
const Value = std.json.Value;

fn testAgent(arena: std.mem.Allocator, client: *std.http.Client) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = client,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "", .context = 0 },
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = "",
        .out = null,
    };
}

test "model loop buffered response preserves useful prefix and finalizes without cancel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = testAgent(arena, &client);
    var prose: std.ArrayList(u8) = .empty;
    try prose.appendSlice(arena, "The useful answer is preserved.\n");
    for (0..100) |_| try prose.appendSlice(arena, "I will wait for your reply.\n");
    const raw = try std.json.Stringify.valueAlloc(arena, .{ .choices = .{.{ .message = .{ .content = prose.items } }} }, .{});
    const parsed = try std.json.parseFromSlice(Value, arena, raw, .{});
    @import("cancel_source.zig").clear();
    try std.testing.expectError(error.ModelLoop, loop.checkResponse(&agent, parsed.value.object));
    const final = try loop.finish(&agent);
    try std.testing.expect(std.mem.startsWith(u8, final, "The useful answer is preserved."));
    try std.testing.expect(std.mem.endsWith(u8, final, loop.marker));
    try std.testing.expect(final.len < 650);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
    try std.testing.expectEqual(@import("cancel_source.zig").Source.none, @import("cancel_source.zig").take(null));
}

test "model loop all text wires stop at same bound without painting or a terminal event" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const fixtures = [_]struct { kind: @import("provider.zig").Provider.Kind, raw: []const u8 }{
        .{ .kind = .openai, .raw = "{\"choices\":[{\"delta\":{\"content\":\"I will wait for your reply.\\n\"}}]}" },
        .{ .kind = .anthropic, .raw = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"I will wait for your reply.\\n\"}}" },
        .{ .kind = .responses, .raw = "{\"type\":\"response.output_text.delta\",\"delta\":\"I will wait for your reply.\\n\"}" },
    };
    for (fixtures) |fixture| {
        var agent = testAgent(arena, &client);
        agent.provider.kind = fixture.kind;
        var guard: loop.Stream = .{};
        var stopped = false;
        for (0..100) |_| {
            guard.event(&agent, fixture.raw, false) catch |err| {
                try std.testing.expectEqual(error.ModelLoop, err);
                stopped = true;
                break;
            };
        }
        try std.testing.expect(stopped);
        try std.testing.expect(agent.partial_text.items.len < 600);
        try std.testing.expect(!agent.streamed_text);
    }
}

test "model loop exemptions preserve tool output structured answers and compaction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = testAgent(arena, &client);
    const raw = "{\"choices\":[{\"delta\":{\"content\":\"I will wait for your reply.\\n\"}}]}";
    agent.compaction_request = true;
    var guard: loop.Stream = .{};
    for (0..100) |_| try guard.event(&agent, raw, false);
    try std.testing.expect(!guard.detector.stopped);
    agent.compaction_request = false;
    agent.output_schema = "{}";
    guard = .{};
    for (0..100) |_| try guard.event(&agent, raw, false);
    try std.testing.expect(!guard.detector.stopped);
    agent.output_schema = null;
    const tools = try std.json.parseFromSlice(Value, arena, "{\"choices\":[{\"message\":{\"tool_calls\":[{\"function\":{\"arguments\":\"repeated text\"}}]}}]}", .{});
    try loop.checkResponse(&agent, tools.value.object);
}
