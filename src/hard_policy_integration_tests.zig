const std = @import("std");
const policy = @import("hard_policy.zig");
const gate = @import("hard_policy_gate.zig");
const catalog = @import("hard_policy_catalog.zig");
const tools = @import("tools.zig");

test "hard policy explicit allow cannot override read-only children or protected settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = policy.parse(a,
        \\{"policies":[{"action":"tool.use","resource":"*","effect":"allow"},{"action":"mcp.use","resource":"*","effect":"allow"}]}
    );
    const call: tools.ToolCall = .{ .id = "fixture", .name = "write_file", .input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"ordinary.txt\",\"content\":\"fixture\"}", .{}) };
    try std.testing.expect(gate.callDenial(doc, a, call.name, null) == null);
    var agent: @import("agent.zig").Agent = undefined;
    agent.arena = a;
    agent.io = std.testing.io;
    agent.sub = true;
    agent.read_only = true;
    agent.registry = null;
    const blocked = (try @import("agent_tool_gate.zig").gateTool(&agent, call)).?;
    try std.testing.expect(blocked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocked.text, "read-only") != null);
    var own_settings = call;
    own_settings.input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\".harness/settings.json\",\"content\":\"{}\"}", .{});
    for ([_]bool{ false, true }) |sub| {
        agent.sub = sub;
        const denied = (try @import("agent_tool_gate.zig").gateTool(&agent, own_settings)).?;
        try std.testing.expect(denied.is_error);
        try std.testing.expect(std.mem.indexOf(u8, denied.text, "policy file") != null);
    }
    // Independently unconditional companion-write restrictions survive allows.
    const companion: tools.ToolCall = .{ .id = "fixture", .name = "mcp__codedbpro__edit", .input = .null };
    try std.testing.expect(gate.callDenial(doc, a, companion.name, null) == null);
    const ctx: tools.ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = undefined, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const denied = @import("tool_surface.zig").gate(ctx, companion).?;
    defer std.testing.allocator.free(denied.text);
    try std.testing.expect(denied.is_error);
}

test "hard policy MCP raw identity is not bypassed by an escaped wire name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = policy.parse(a,
        \\{"policies":[{"action":"mcp.use","resource":"docs server","effect":"deny"},{"action":"tool.use","resource":"mcp__*","effect":"allow"}]}
    );
    const wire = try @import("mcp_names.zig").qualify(a, "docs server", "read");
    var listed = [_]@import("mcp.zig").Tool{.{ .server_name = "docs server", .server_index = 0, .original_name = "read", .qualified_name = wire, .description = "", .input_schema = .null }};
    var reg: @import("mcp.zig").Registry = undefined;
    reg.tools = &listed;
    try std.testing.expect(gate.callDenial(doc, a, wire, &reg) != null);
    const raw = try std.fmt.allocPrint(a, "[{{\"type\":\"function\",\"name\":\"{s}\"}}]", .{wire});
    try std.testing.expectEqualStrings("[]", try catalog.filterDocument(doc, a, raw, "fixture", &reg));
}

test "hard policy final catalog removes native meta MCP and actual hosted search routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = policy.parse(a,
        \\{"policies":[{"action":"tool.use","resource":"shell","effect":"deny"},{"action":"tool.use","resource":"ask_user","effect":"deny"},{"action":"mcp.use","resource":"fixture","effect":"deny"},{"action":"websearch.use","resource":"*","effect":"deny"}]}
    );
    const json = "[{\"type\":\"function\",\"name\":\"bash\"},{\"type\":\"function\",\"function\":{\"name\":\"ask_user\"}},{\"name\":\"mcp__fixture__read\"},{\"name\":\"read_file\"}]";
    const out = try catalog.filterDocument(doc, a, json, "fixture", null);
    try std.testing.expectEqualStrings("[{\"name\":\"read_file\"}]", out);
    const xai = try @import("xai_hosted.zig").splice(a, "[]", true);
    try std.testing.expect(std.mem.indexOf(u8, xai, "web_search") != null);
    try std.testing.expectEqualStrings("[]", try catalog.filterDocument(doc, a, xai, "xai", null));
    const codex = try @import("codex_tool_search.zig").spliceWebSearch(a, "[]");
    try std.testing.expect(std.mem.indexOf(u8, codex, "web_search") != null);
    try std.testing.expectEqualStrings("[]", try catalog.filterDocument(doc, a, codex, "codex", null));
    // Route-specific restriction does not disable another provider's search.
    const specific = policy.parse(a, "{\"policies\":[{\"action\":\"websearch.use\",\"resource\":\"xai\",\"effect\":\"deny\"}]}");
    try std.testing.expectEqualStrings(codex, try catalog.filterDocument(specific, a, codex, "codex", null));
}
