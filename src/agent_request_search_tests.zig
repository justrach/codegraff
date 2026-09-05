//! Hosted-search wire regressions, split from the Responses serializer.
const std = @import("std");
const Value = std.json.Value;
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;

test "#746 emitted Responses body has hosted search only with a deferred tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { catalog: []const u8, deferred: bool }{
        .{ .catalog = "[]", .deferred = false },
        .{ .catalog = "[{\"type\":\"function\",\"name\":\"bash\"}]", .deferred = false },
        .{ .catalog = "[{\"type\":\"function\",\"name\":\"webfetch\",\"defer_loading\":false}]", .deferred = false },
        .{ .catalog = "[{\"type\":\"function\",\"name\":\"webfetch\"}]", .deferred = true },
    }) |case| {
        var agent = try testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
        const body = try agent.buildBody(case.catalog, false, true, true);
        defer std.testing.allocator.free(body);
        const parsed = try std.json.parseFromSliceLeaky(Value, a, body, .{});
        var searches: usize = 0;
        var deferred = false;
        for (parsed.object.get("tools").?.array.items) |tool| {
            if (tool.object.get("type")) |typ| {
                if (typ == .string and std.mem.eql(u8, typ.string, "tool_search")) searches += 1;
            }
            if (tool.object.get("defer_loading")) |flag| {
                if (flag == .bool and flag.bool) deferred = true;
            }
        }
        try std.testing.expectEqual(case.deferred, deferred);
        try std.testing.expectEqual(@as(usize, if (case.deferred) 1 else 0), searches);
    }
}
