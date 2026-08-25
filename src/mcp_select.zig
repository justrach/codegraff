//! fx-style MCP progressive load: search, then select.
//!
//! `load_tool_schemas` already folds schemas and can `query` (which LOADS
//! matches). These two tools split that into a cache-friendlier dance:
//! `mcp_search_tools` lists names + short descriptions and does not enable
//! anything; `mcp_select_tool` loads the chosen names. Same session state
//! as the existing fold — consent is untouched.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const tools_mod = @import("tools.zig");

pub const search_name = "mcp_search_tools";
pub const search_desc = "Search deferred MCP tools by keyword. Returns names and one-line descriptions only — it does not load schemas. Call mcp_select_tool with a name you want to enable.";
pub const search_schema =
    \\{"type": "object", "properties": {"query": {"type": "string", "description": "Keywords to match against deferred MCP tool names and descriptions"}, "server": {"type": "string", "description": "Optional: restrict the search to one MCP server"}}, "required": ["query"]}
;

pub const select_name = "mcp_select_tool";
pub const select_desc = "Load the full JSON schema for one deferred MCP tool (or a short list) and enable it for the rest of this session. Search first with mcp_search_tools if you do not know the exact name.";
pub const select_schema =
    \\{"type": "object", "properties": {"name": {"type": "string", "description": "Exact qualified MCP tool name, e.g. mcp__deepwiki__ask_question"}, "tools": {"type": "array", "items": {"type": "string"}, "description": "Several exact names to load in one call"}, "server": {"type": "string", "description": "Load every deferred tool on this MCP server"}}}
;

pub fn isName(name: []const u8) bool {
    return std.mem.eql(u8, name, search_name) or std.mem.eql(u8, name, select_name);
}

fn scoreTool(t: mcp.Tool, query: []const u8) usize {
    var score: usize = 0;
    var tok = std.mem.tokenizeAny(u8, query, " \t,;:/_-");
    while (tok.next()) |w| {
        if (w.len < 2) continue;
        if (mcp_schema_gate.containsIgnoreCase(t.qualified_name, w) or
            mcp_schema_gate.containsIgnoreCase(t.description, w)) score += 1;
    }
    return score;
}

/// Names + short descriptions only. Does not call enable().
pub fn searchInto(arena: Allocator, all: []const mcp.Tool, input: Value) !mcp_schema_gate.Loaded {
    const query = tools_mod.strField(input, "query") orelse
        return .{ .text = "mcp_search_tools needs query", .is_error = true };
    const server = tools_mod.strField(input, "server");
    var hits: std.ArrayList(struct { score: usize, idx: usize }) = .empty;
    for (all, 0..) |t, i| {
        if (!mcp_schema_gate.isDeferred(all, t)) continue;
        if (server) |sv| {
            if (!std.mem.eql(u8, mcp_schema_gate.serverOf(t.qualified_name), sv)) continue;
        }
        const score = scoreTool(t, query);
        if (score == 0) continue;
        try hits.append(arena, .{ .score = score, .idx = i });
    }
    if (hits.items.len == 0) {
        return .{ .text = try std.fmt.allocPrint(arena, "no deferred MCP tool matched '{s}'. Use load_tool_schemas with no args to list what is deferred.", .{query}), .is_error = true };
    }
    std.mem.sort(@TypeOf(hits.items[0]), hits.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(hits.items[0]), b: @TypeOf(hits.items[0])) bool {
            return a.score > b.score;
        }
    }.lessThan);
    const cap = @min(hits.items.len, 8);
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{d} deferred match(es). Call mcp_select_tool name=<qualified> to load a schema.\n", .{cap});
    for (hits.items[0..cap]) |h| {
        const t = all[h.idx];
        try aw.writer.print("  {s}: {s}\n", .{ t.qualified_name, mcp_schema_gate.shortDesc(t.description) });
    }
    return .{ .text = aw.writer.buffered() };
}

pub fn handleSearch(agent: anytype, input: Value) tools_mod.ExecResult {
    if (agent.sub) return .{ .text = "mcp_search_tools is root-only; a subagent has no MCP registry of its own", .is_error = true };
    const reg = agent.registry orelse return .{ .text = "no MCP servers are connected, so there are no tools to search", .is_error = true };
    const r = searchInto(agent.arena, reg.tools, input) catch
        return .{ .text = "mcp_search_tools failed", .is_error = true };
    return .{ .text = r.text, .is_error = r.is_error };
}

fn selectInput(arena: Allocator, input: Value) Value {
    const one = tools_mod.strField(input, "name") orelse return input;
    var obj: std.json.ObjectMap = .empty;
    var argv = std.json.Array.init(arena);
    argv.append(.{ .string = one }) catch return input;
    obj.put(arena, "tools", .{ .array = argv }) catch return input;
    if (tools_mod.strField(input, "server")) |sv| obj.put(arena, "server", .{ .string = sv }) catch {};
    return .{ .object = obj };
}

pub fn handleSelect(agent: anytype, input: Value) tools_mod.ExecResult {
    return mcp_schema_gate.handleLoad(agent, selectInput(agent.arena, input));
}

fn withShapes(agent: anytype, r: tools_mod.ExecResult) tools_mod.ExecResult {
    if (r.is_error) return r;
    const cwd = agent.agent_cwd;
    const text = @import("mcp_shapes.zig").annotate(agent.gpa, agent.arena, agent.io, cwd, r.text) catch r.text;
    return .{ .text = text, .is_error = r.is_error };
}

pub fn dispatch(agent: anytype, call: tools_mod.ToolCall) tools_mod.ExecResult {
    if (std.mem.eql(u8, call.name, search_name)) return withShapes(agent, handleSearch(agent, call.input));
    if (std.mem.eql(u8, call.name, select_name)) return withShapes(agent, handleSelect(agent, call.input));
    return withShapes(agent, mcp_schema_gate.handleLoad(agent, call.input));
}

test "search lists matches and does not enable them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    mcp_schema_gate.reset();
    defer mcp_schema_gate.reset();
    mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
    const all = try @import("mcp_schema_gate_tests.zig").fixture(a, "wiki", 2, 2000);
    const req = try std.json.parseFromSliceLeaky(Value, a, "{\"query\":\"first line\"}", .{ .allocate = .alloc_always });
    const r = try searchInto(a, all, req);
    try std.testing.expect(!r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "mcp__wiki__t0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "mcp_select_tool") != null);
    try std.testing.expect(!mcp_schema_gate.isLoaded("mcp__wiki__t0"));
}

test "isName covers only the progressive pair" {
    try std.testing.expect(isName(search_name));
    try std.testing.expect(isName(select_name));
    try std.testing.expect(!isName("load_tool_schemas"));
    try std.testing.expect(!isName("bash"));
}
