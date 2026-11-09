//! ADR 0227: a child's catalog carries the MCP tools its root loaded.
//!
//! A worker is served a fixed, comptime-baked catalog. A root that loaded an
//! MCP server's tools and delegated work on them got children that could not
//! call them: each child reported the tools missing, and the root re-spawned
//! children to speak the server's JSON-RPC by hand. Loading is the root's
//! decision to use a server, so its children inherit what it loaded, with full
//! schemas and no meta tool. Unloaded tools stay out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const schema = @import("schema.zig");
const Provider = @import("provider.zig").Provider;
const Agent = @import("agent.zig").Agent;

/// subagent_run calls this once as it builds a child: whatever catalog the
/// child would be served gains the MCP tools the root loaded. A resumed worker
/// is rebuilt through the same path, so it also picks up later loads.
pub fn inherit(agent: *Agent) void {
    const registry = agent.registry orelse return;
    agent.worker_tools = "";
    const base = agent.toolsJson();
    const tools = registry.snapshotTools(agent.arena) catch return;
    const built = withLoaded(agent.arena, agent.provider.kind, base, tools, agent.read_only);
    if (built.ptr != base.ptr) agent.worker_tools = built;
    agent.tools_epoch = @import("native_fold.zig").catalogEpoch();
}

/// `base` (a JSON array of tool entries) plus an entry for each loaded MCP
/// tool in `tools`; for a read-only child, only the tools their server
/// declares read-only, the ones its gate lets it call (ADR 0228). `base`
/// itself when nothing qualifies.
pub fn withLoaded(arena: Allocator, kind: Provider.Kind, base: []const u8, tools: []const mcp.Tool, read_only: bool) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    var n: usize = 0;
    s.beginArray() catch return base;
    for (tools) |t| {
        if (mcp_schema_gate.omitMcp(t.qualified_name) or !mcp_schema_gate.isLoaded(t.qualified_name)) continue;
        if (read_only and !t.read_only) continue;
        if (kind == .responses) {
            schema.writeEagerResponsesEntry(&s, t.qualified_name, t.description, .{ .value = t.input_schema }) catch return base;
        } else schema.writeToolEntry(&s, kind, t.qualified_name, t.description, .{ .value = t.input_schema }) catch return base;
        n += 1;
    }
    s.endArray() catch return base;
    if (n == 0) return base;
    const extra = aw.writer.buffered();
    const head = std.mem.trimEnd(u8, base, " \t\r\n");
    if (head.len < 2 or head[head.len - 1] != ']') return base;
    if (std.mem.trim(u8, head[1 .. head.len - 1], " \t\r\n").len == 0) return extra;
    return std.fmt.allocPrint(arena, "{s},{s}]", .{ head[0 .. head.len - 1], extra[1 .. extra.len - 1] }) catch base;
}

test "a child's catalog gains the MCP tools the root loaded, and only those" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    mcp_schema_gate.reset();
    defer mcp_schema_gate.reset();
    const saved_policy = mcp_schema_gate.g_policy;
    defer mcp_schema_gate.g_policy = saved_policy;
    mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
    const all = try @import("mcp_schema_gate_tests.zig").fixture(a, "wiki", 2, 200);
    const base = "[{\"type\":\"function\",\"name\":\"shell\"}]";
    try std.testing.expectEqualStrings(base, withLoaded(a, .responses, base, all, false)); // nothing loaded yet
    mcp_schema_gate.autoLoad(a, all, all[1].qualified_name); // what a root's direct call does
    const out = withLoaded(a, .responses, base, all, false);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out, all[1].qualified_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, all[0].qualified_name) == null);
    // ADR 0231: eager, so hosted tool search (codex_tool_search.splice) leaves it callable.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"defer_loading\":false") != null);
    const spliced = try @import("codex_tool_search.zig").splice(a, out);
    try std.testing.expect(std.mem.indexOf(u8, spliced, "\"defer_loading\":true") == null);
    const alone = withLoaded(a, .responses, "[]", all, false);
    try std.testing.expectEqual(@as(usize, 1), (try std.json.parseFromSliceLeaky(std.json.Value, a, alone, .{})).array.items.len);
}

test "a spawned child's catalog carries the tools its root loaded" {
    // A child starts with the static catalogs in its provider slots, so a build
    // that waited for an empty slot never ran: the live child saw no loaded tool.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    mcp_schema_gate.reset();
    defer mcp_schema_gate.reset();
    const saved_policy = mcp_schema_gate.g_policy;
    defer mcp_schema_gate.g_policy = saved_policy;
    mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
    var registry = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const all = try @import("mcp_schema_gate_tests.zig").fixture(a, "wiki", 2, 200);
    registry.tools = all;
    var child: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6.1-sol", .context = 272_000 },
        .messages = undefined,
        .sub = true,
        .label = "child",
        .out = null,
        .registry = &registry,
    };
    const static = child.toolsJson();
    inherit(&child); // nothing loaded: the static catalog, untouched
    try std.testing.expectEqualStrings(static, child.toolsJson());
    mcp_schema_gate.autoLoad(a, all, all[1].qualified_name);
    inherit(&child);
    const got = child.toolsJson();
    try std.testing.expect(std.mem.indexOf(u8, got, all[1].qualified_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, got, all[0].qualified_name) == null);
    try std.testing.expect(std.mem.startsWith(u8, got, static[0 .. static.len - 1]));
}

test "a read-only child inherits only the loaded tools declared read-only (ADR 0228)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    mcp_schema_gate.reset();
    defer mcp_schema_gate.reset();
    const saved_policy = mcp_schema_gate.g_policy;
    defer mcp_schema_gate.g_policy = saved_policy;
    mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
    const all = try @import("mcp_schema_gate_tests.zig").fixture(a, "wiki", 2, 200);
    all[0].read_only = true;
    mcp_schema_gate.autoLoad(a, all, all[0].qualified_name);
    mcp_schema_gate.autoLoad(a, all, all[1].qualified_name);
    const base = "[{\"type\":\"function\",\"name\":\"shell\"}]";
    const reader = withLoaded(a, .responses, base, all, true);
    try std.testing.expect(std.mem.indexOf(u8, reader, all[0].qualified_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, reader, all[1].qualified_name) == null);
    try std.testing.expect(std.mem.indexOf(u8, withLoaded(a, .responses, base, all, false), all[1].qualified_name) != null);
}
