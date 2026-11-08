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
            if (!std.mem.eql(u8, t.serverName(), sv)) continue;
        }
        const score = scoreTool(t, query);
        if (score == 0) continue;
        try hits.append(arena, .{ .score = score, .idx = i });
    }
    if (hits.items.len == 0) {
        return .{ .text = try std.fmt.allocPrint(arena, "no deferred MCP tool matched '{s}'. Use load_tool_schemas with no args to list what is deferred.", .{query}), .is_error = true };
    }
    @import("stable_sort.zig").sort(@TypeOf(hits.items[0]), hits.items, {}, struct {
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
    const catalog = reg.snapshotTools(agent.arena) catch return .{ .text = "mcp_search_tools failed", .is_error = true };
    const r = searchInto(agent.arena, catalog, input) catch
        return .{ .text = "mcp_search_tools failed", .is_error = true };
    return .{ .text = r.text, .is_error = r.is_error };
}

fn selectInput(arena: Allocator, input: Value) Value {
    const one = tools_mod.strField(input, "name") orelse return input;
    var obj: std.json.ObjectMap = .empty;
    var argv = std.json.Array.init(arena);
    if (input == .object) if (input.object.get("tools")) |list| if (list == .array) {
        for (list.array.items) |it| argv.append(it) catch return input;
    };
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

fn isListingRequest(input: Value) bool {
    if (input != .object) return true;
    if (tools_mod.strField(input, "server") != null) return false;
    if (tools_mod.strField(input, "query") != null) return false;
    if (input.object.get("tools")) |list| {
        if (list == .array and list.array.items.len > 0) return false;
    }
    return true;
}

fn unknownWithoutRegistry(arena: Allocator, rem: Value) tools_mod.ExecResult {
    const native_fold = @import("native_fold.zig");
    var aw: Io.Writer.Allocating = .init(arena);
    if (rem == .object) if (rem.object.get("tools")) |list| if (list == .array) {
        for (list.array.items) |item| {
            if (item == .string) aw.writer.print("no deferred tool named '{s}' (no MCP servers are connected). ", .{item.string}) catch {};
        }
    };
    if (native_fold.listDeferredNative(arena) catch null) |nl| {
        aw.writer.writeAll(nl) catch {};
    } else {
        aw.writer.writeAll("No MCP servers are connected, and all active native tools already carry full schemas.") catch {};
    }
    return .{ .text = aw.writer.buffered(), .is_error = true };
}

/// The load arm: the native half (folded, already-active, and gated), then the
/// MCP half of the same request. One call may name native tools and MCP tools
/// together, or run with `agent.registry == null` (#492).
pub fn loadBoth(agent: anytype, call: tools_mod.ToolCall) tools_mod.ExecResult {
    // #1425: search lists deferred MCP tools and loads nothing. The native
    // half's query arm LOADS matching natives, so it never sees a search.
    if (std.mem.eql(u8, call.name, search_name)) return dispatch(agent, call);
    if (agent.sub) return dispatch(agent, call);
    const native_fold = @import("native_fold.zig");
    const norm_input = if (std.mem.eql(u8, call.name, select_name)) selectInput(agent.arena, call.input) else call.input;

    if (isListingRequest(norm_input)) {
        const nl = native_fold.listDeferredNative(agent.arena) catch null;
        if (agent.registry == null) {
            return .{
                .text = nl orelse "No tool schemas are deferred (no MCP servers are connected, and all active native tools already carry full schemas).",
                .is_error = false,
            };
        }
        const mcp_res = dispatch(agent, call);
        if (nl) |native_text| {
            return .{
                .text = std.fmt.allocPrint(agent.arena, "{s}\n{s}", .{ native_text, mcp_res.text }) catch mcp_res.text,
                .is_error = mcp_res.is_error,
            };
        }
        return mcp_res;
    }

    if (tools_mod.strField(norm_input, "query")) |q| {
        const no_tools = norm_input.object.get("tools") == null and tools_mod.strField(norm_input, "server") == null;
        if (no_tools) {
            const native_q = native_fold.handleLoadNative(agent, norm_input) catch null;
            if (agent.registry == null) {
                if (native_q) |nq| return nq;
                if (native_fold.fallbackNativeQuery(agent, q) catch null) |fb| return fb;
                const rest_list = (native_fold.listDeferredNative(agent.arena) catch null) orelse "No native tool schemas are deferred, and no MCP servers are connected.";
                return .{
                    .text = std.fmt.allocPrint(agent.arena, "no deferred tool matched query '{s}'. {s}", .{ q, rest_list }) catch rest_list,
                    .is_error = true,
                };
            }
            const unavail = @import("mcp_call.zig").unavailableLoad(agent.registry.?, agent.arena, norm_input);
            if (unavail) |u_text| {
                if (native_q) |nq| {
                    return .{
                        .text = std.fmt.allocPrint(agent.arena, "{s}\n{s}", .{ nq.text, u_text }) catch nq.text,
                        .is_error = false,
                    };
                }
                return .{ .text = u_text, .is_error = true };
            }
            const mcp_q = dispatch(agent, call);
            if (native_q) |nq| {
                if (!mcp_q.is_error) {
                    return .{
                        .text = std.fmt.allocPrint(agent.arena, "{s}\n{s}", .{ nq.text, mcp_q.text }) catch nq.text,
                        .is_error = false,
                    };
                }
                return nq;
            }
            if (!mcp_q.is_error) return mcp_q;
            if (native_fold.fallbackNativeQuery(agent, q) catch null) |fb| {
                if (!fb.is_error) return fb;
                return .{
                    .text = std.fmt.allocPrint(agent.arena, "{s}\n{s}", .{ fb.text, mcp_q.text }) catch fb.text,
                    .is_error = true,
                };
            }
            return mcp_q;
        }
    }

    const native = native_fold.handleLoadNative(agent, norm_input) catch null;
    const rest = mcpRemainder(agent.arena, norm_input);
    if (native == null) {
        const rem = rest orelse return dispatch(agent, call);
        if (agent.registry == null and tools_mod.strField(rem, "server") == null) return unknownWithoutRegistry(agent.arena, rem);
        var mcp_call = call;
        mcp_call.input = rem;
        return dispatch(agent, mcp_call);
    }
    const nat = native.?;
    const rem = rest orelse return nat;
    if (agent.registry == null and tools_mod.strField(rem, "server") == null) {
        const unk = unknownWithoutRegistry(agent.arena, rem);
        return .{
            .text = std.fmt.allocPrint(agent.arena, "{s}\n{s}", .{ nat.text, unk.text }) catch nat.text,
            .is_error = nat.is_error and unk.is_error,
        };
    }
    var mcp_call = call;
    mcp_call.input = rem;
    const more = dispatch(agent, mcp_call);
    return .{
        .text = std.fmt.allocPrint(agent.arena, "{s}\n{s}", .{ nat.text, more.text }) catch nat.text,
        .is_error = nat.is_error and more.is_error,
    };
}

/// What the MCP half still has to do once the native half answered:
/// `server` and `query` as given, and `tools` without any known native names.
/// Null when nothing is left.
pub fn mcpRemainder(arena: Allocator, input: Value) ?Value {
    if (input != .object) return null;
    var obj: std.json.ObjectMap = .empty;
    if (input.object.get("server")) |v| obj.put(arena, "server", v) catch return null;
    if (input.object.get("query")) |v| obj.put(arena, "query", v) catch return null;
    if (input.object.get("tools")) |list| if (list == .array) {
        var keep = std.json.Array.init(arena);
        for (list.array.items) |item| {
            if (item == .string and @import("native_fold.zig").isKnownNative(arena, item.string)) continue;
            keep.append(item) catch return null;
        }
        if (keep.items.len > 0) obj.put(arena, "tools", .{ .array = keep }) catch return null;
    };
    if (obj.count() == 0) return null;
    return .{ .object = obj };
}

test "a load naming folded natives and an MCP server leaves the server for the MCP half" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mixed = try std.json.parseFromSliceLeaky(Value, a, "{\"tools\":[\"subagent\",\"mcp__linear__list_issues\"],\"server\":\"linear\"}", .{ .allocate = .alloc_always });
    const rest = mcpRemainder(a, mixed) orelse return error.TestExpectedRemainder;
    try std.testing.expectEqualStrings("linear", rest.object.get("server").?.string);
    const left = rest.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("mcp__linear__list_issues", left[0].string);
    const natives_only = try std.json.parseFromSliceLeaky(Value, a, "{\"tools\":[\"subagent\",\"workflow\"]}", .{ .allocate = .alloc_always });
    try std.testing.expect(mcpRemainder(a, natives_only) == null);
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

test "mcp_search_tools never loads or prints a matching native's schema (#1425)" {
    const native_fold = @import("native_fold.zig");
    const Kind = @import("provider.zig").Provider.Kind;
    const FakeAgent = struct {
        arena: Allocator,
        gpa: Allocator,
        io: Io,
        agent_cwd: ?[]const u8 = null,
        sub: bool = false,
        registry: ?*mcp.Registry = null,
        provider: struct { kind: Kind } = .{ .kind = .anthropic },
        rebuilds: usize = 0,
        pub fn invalidateRootTools(_: *@This()) void {}
        pub fn ensureRootTools(self: *@This(), _: Kind) !void {
            self.rebuilds += 1;
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = native_fold.enabled;
    defer native_fold.enabled = saved;
    native_fold.enabled = true;
    native_fold.unloadForTest("peer_message");
    defer native_fold.unloadForTest("peer_message");
    var agent: FakeAgent = .{ .arena = a, .gpa = std.testing.allocator, .io = std.testing.io };
    const input = try std.json.parseFromSliceLeaky(Value, a, "{\"query\":\"peer message\"}", .{ .allocate = .alloc_always });
    const r = loadBoth(&agent, .{ .id = "c1", .name = search_name, .input = input });
    try std.testing.expect(!native_fold.isLoaded("peer_message"));
    try std.testing.expectEqual(@as(usize, 0), agent.rebuilds);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "native tool schema") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "no MCP servers are connected") != null);
}

test {
    _ = @import("folded_native_load_tests.zig");
}
