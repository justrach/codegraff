//! Wire-compatibility guard for every tool schema graff serves.
//!
//! The Anthropic Messages API rejects a tool whose `input_schema` carries
//! `oneOf`, `allOf` or `anyOf` at the TOP level — and it rejects the entire
//! REQUEST, not just that tool, so one bad schema takes down every turn before
//! the model is ever reached:
//!
//!   api error: tools.27.custom.input_schema: input_schema does not support
//!   oneOf, allOf, or anyOf at the top level
//!
//! That was a live failure on a real Anthropic run. It survived the earlier
//! checks because those exercised the codex/Responses wire and `--schema`,
//! neither of which validates this. The offender was an MCP tool
//! (codedbpro's `replace`, expressing "path or paths"), which is why the guard
//! covers BOTH sources: the built-in catalogs are asserted clean at every
//! nesting level, and MCP-sourced schemas — where nested combinators are legal
//! and common — are asserted clean at the top level after normalization.
//!
//! Pulled in from tool_gates.zig's test block; an unreferenced module's tests
//! silently compile to nothing.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const schema = @import("schema.zig");
const mcp = @import("mcp.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const imagegen = @import("imagegen.zig");
const no_local_tools = @import("no_local_tools.zig");
const Provider = @import("provider.zig").Provider;
const gate = @import("mcp_schema_gate.zig"); // #416
const smolify_manifest = @import("smolify_manifest.zig"); // a REAL 13-tool MCP manifest to measure #416 against

const testing = std.testing;

/// Any combinator at any depth, for schemas we author ourselves.
fn combinatorAnywhere(v: Value) ?[]const u8 {
    switch (v) {
        .object => |obj| {
            if (mcp_protocol.topLevelCombinator(v)) |k| return k;
            var it = obj.iterator();
            while (it.next()) |e| {
                if (combinatorAnywhere(e.value_ptr.*)) |k| return k;
            }
        },
        .array => |arr| for (arr.items) |item| {
            if (combinatorAnywhere(item)) |k| return k;
        },
        else => {},
    }
    return null;
}

/// Every rendered catalog, parsed, with each tool's schema handed to `check`.
fn forEachServedSchema(arena: Allocator, catalog: []const u8, check: *const fn (name: []const u8, sch: Value) anyerror!void) !void {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, catalog, .{ .allocate = .alloc_always });
    for (parsed.array.items) |tool| {
        const obj = tool.object;
        // anthropic: {name, input_schema}; openai: {function:{name,parameters}};
        // responses: {name, parameters}.
        const fn_obj = if (obj.get("function")) |f| f.object else obj;
        const name = fn_obj.get("name").?.string;
        const sch = fn_obj.get("input_schema") orelse fn_obj.get("parameters").?;
        try check(name, sch);
    }
}

/// #444: the diagnostic below is for a REAL offender, where stderr is exactly
/// what you want. The negative control at the bottom of the next test deals in
/// a deliberately bad schema, and its print landed on every green run — where
/// zig's build runner error-prints any Run step whose stderr is non-empty, so a
/// passing suite rendered a step-failure tree and `failed command: …/test`.
/// Reading that as a failure cost real time. Muted for the control only; the
/// assertion it makes is unchanged.
var report_offenders: bool = true;

fn assertClean(name: []const u8, sch: Value) anyerror!void {
    if (combinatorAnywhere(sch)) |key| {
        if (report_offenders)
            std.debug.print("\ntool '{s}' has a JSON Schema '{s}' — Anthropic rejects the whole request over a top-level one\n", .{ name, key });
        return error.ToolSchemaHasCombinator;
    }
}

test "no built-in tool schema carries oneOf/allOf/anyOf — the wire rejection that killed a live Anthropic run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved_gate = no_local_tools.enabled;
    const saved_imagegen = imagegen.available;
    defer {
        no_local_tools.enabled = saved_gate;
        imagegen.available = saved_imagegen;
    }

    // Every root catalog variant, in every wire format, with the gated tool
    // both present and absent — the served set is what has to be valid.
    for ([_]bool{ false, true }) |gated| {
        no_local_tools.enabled = gated;
        for ([_]bool{ false, true }) |optional| {
            imagegen.available = optional;
            const specs = try schema.effectiveRootSpecs(arena);
            for ([_]Provider.Kind{ .anthropic, .openai, .responses }) |kind| {
                const catalog = try schema.renderRootTools(arena, kind, specs, &.{});
                try forEachServedSchema(arena, catalog, assertClean);
                // ...and the subagent catalogs, which are comptime constants
                // rather than assembled here.
                try forEachServedSchema(arena, schema.subToolsJson(kind, gated), assertClean);
            }
        }
    }

    // The guard has to be able to fail, or it proves nothing. Silently (#444):
    // this is the ONE call to assertClean that is meant to fail, so its
    // diagnostic is noise on a green run — and a green run's stderr is what
    // zig's build runner error-prints.
    const bad = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"object","properties":{},"anyOf":[{"required":["a"]},{"required":["b"]}]}
    , .{});
    report_offenders = false;
    defer report_offenders = true;
    try testing.expectError(error.ToolSchemaHasCombinator, assertClean("fake", bad));
}

test "an MCP tool's top-level combinator is lowered at discovery, so one server cannot break every turn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exact shape that failed live: codedbpro's `replace`.
    var replace = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array"}},"required":["pattern"],"anyOf":[{"required":["path"]},{"required":["paths"]}]}
    , .{});
    try mcp_protocol.rewriteOneOf(arena, &replace);
    try mcp_protocol.flattenTopLevel(arena, &replace);

    try testing.expect(mcp_protocol.topLevelCombinator(replace) == null);
    // Nothing callable was lost, and the dropped constraint survives as prose.
    try testing.expectEqualStrings("object", replace.object.get("type").?.string);
    for ([_][]const u8{ "pattern", "path", "paths" }) |p|
        try testing.expect(replace.object.get("properties").?.object.get(p) != null);
    try testing.expectEqual(@as(usize, 1), replace.object.get("required").?.array.items.len); // alternatives NOT force-merged
    try testing.expect(std.mem.indexOf(u8, replace.object.get("description").?.string, "Requires one of: path or paths.") != null);

    // A server that sends oneOf gets the same treatment (rewriteOneOf makes it
    // anyOf first, which Anthropic rejects just as hard).
    var one_of = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"object","oneOf":[{"required":["a"]},{"required":["b","c"]}]}
    , .{});
    try mcp_protocol.rewriteOneOf(arena, &one_of);
    try mcp_protocol.flattenTopLevel(arena, &one_of);
    try testing.expect(mcp_protocol.topLevelCombinator(one_of) == null);
    try testing.expect(std.mem.indexOf(u8, one_of.object.get("description").?.string, "Requires one of: a or b + c.") != null);

    // allOf DOES conjoin: every branch holds, so properties and required merge.
    var all_of = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"allOf":[{"properties":{"x":{"type":"string"}},"required":["x"]},{"properties":{"y":{"type":"number"}},"required":["y"]}]}
    , .{});
    try mcp_protocol.flattenTopLevel(arena, &all_of);
    try testing.expect(mcp_protocol.topLevelCombinator(all_of) == null);
    try testing.expectEqualStrings("object", all_of.object.get("type").?.string); // added, since the source had none
    try testing.expectEqual(@as(usize, 2), all_of.object.get("required").?.array.items.len);
    try testing.expect(all_of.object.get("properties").?.object.get("y") != null);

    // A NESTED combinator is legal on every provider and must survive.
    var nested = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"object","properties":{"v":{"anyOf":[{"type":"string"},{"type":"number"}]}}}
    , .{});
    try mcp_protocol.flattenTopLevel(arena, &nested);
    try testing.expect(mcp_protocol.topLevelCombinator(nested) == null);
    try testing.expect(nested.object.get("properties").?.object.get("v").?.object.get("anyOf") != null);

    // A schema with no combinator is returned byte-identical.
    var plain = try std.json.parseFromSliceLeaky(Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
    try mcp_protocol.flattenTopLevel(arena, &plain);
    try testing.expectEqual(@as(usize, 2), plain.object.count());
}

test "the discovery path itself flattens, so nothing reaches a provider unlowered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Render an MCP tool through the same writer the root catalog uses, with
    // a schema that has already been through discovery's normalization.
    var sch = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"object","properties":{"a":{"type":"string"}},"oneOf":[{"required":["a"]},{"required":["b"]}]}
    , .{});
    try mcp_protocol.rewriteOneOf(arena, &sch);
    try mcp_protocol.flattenTopLevel(arena, &sch);
    const tools = [_]mcp.Tool{.{
        .server_index = 0,
        .original_name = "replace",
        .qualified_name = "mcp__srv__replace",
        .description = "d",
        .input_schema = sch,
    }};
    for ([_]Provider.Kind{ .anthropic, .openai, .responses }) |kind| {
        const catalog = try schema.renderRootTools(arena, kind, &.{}, &tools);
        try forEachServedSchema(arena, catalog, struct {
            fn check(name: []const u8, s: Value) anyerror!void {
                if (mcp_protocol.topLevelCombinator(s)) |key| {
                    std.debug.print("\nMCP tool '{s}' still has top-level '{s}'\n", .{ name, key });
                    return error.ToolSchemaHasCombinator;
                }
            }
        }.check);
    }
}

/// #416's catalog half, measured against a REAL MCP manifest rather than a
/// made-up one: the bundled Smolify server (13 tools, ~9.5 KB of description +
/// schema — the same order as the companion server that provoked the issue at
/// +2,568 input tokens per call).
fn realServerTools(arena: Allocator) ![]const mcp.Tool {
    var list: std.ArrayList(mcp.Tool) = .empty;
    _ = try smolify_manifest.appendTools(mcp.Tool, arena, &list, 0, true);
    return list.items;
}

test "#416: deferring a real MCP server's schemas cuts the served catalog in half" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    gate.reset();
    gate.g_policy = .{};
    defer {
        gate.reset();
        gate.g_policy = .{};
    }
    const tools = try realServerTools(arena);
    try testing.expectEqual(@as(usize, 13), tools.len);

    // Pre-#416 behavior, still reachable with the escape-hatch pin.
    gate.g_policy = .{ .eager = &.{"*"} };
    const eager = try schema.renderRootTools(arena, .anthropic, &.{}, tools);

    // The default: this server is 2.3x over the 4 KiB budget, so it defers.
    gate.g_policy = .{};
    try testing.expect(gate.serverCost(tools, "smolify") > gate.default_budget);
    const deferred = try schema.renderRootTools(arena, .anthropic, &.{}, tools);

    // The measurement this issue exists for: the MCP half of the catalog on
    // its own (no built-in specs), so the number is the saving and nothing
    // else. Measured on this manifest: 10,505 -> 3,696 bytes, a 64.8% cut, or
    // roughly 1,700 input tokens at 4 bytes/token — per request, for the whole
    // session, from ONE server. Asserted at a conservative 50% so a schema
    // that grows a little does not turn the guard red.
    try testing.expect(deferred.len * 2 < eager.len);

    // Every tool is still REGISTERED — deferral hides schemas, not tools.
    for (tools) |t| try testing.expect(std.mem.indexOf(u8, deferred, t.qualified_name) != null);
    // ...with a one-line description, and no schema body. These property names
    // appear in the real schemas and in no description, so finding one would
    // mean a schema leaked through.
    for ([_][]const u8{ "pathHints", "maxTokens", "lineCount" }) |only_in_schema| {
        try testing.expect(std.mem.indexOf(u8, eager, only_in_schema) != null);
        try testing.expect(std.mem.indexOf(u8, deferred, only_in_schema) == null);
    }
    // ...and the tool that undoes it rides along — but only while it is needed,
    // so a session whose servers are all eager is never charged for it.
    const with_specs = try schema.renderRootTools(arena, .anthropic, &schema.root_specs, tools);
    try testing.expect(std.mem.indexOf(u8, with_specs, gate.tool_name) != null);
    gate.g_policy = .{ .eager = &.{"*"} };
    const eager_specs = try schema.renderRootTools(arena, .anthropic, &schema.root_specs, tools);
    try testing.expect(std.mem.indexOf(u8, eager_specs, gate.tool_name) == null);
    gate.g_policy = .{};

    // Loading one tool restores that tool's schema to the catalog and nothing
    // else's: enabling is per tool, not per server.
    const req = try std.json.parseFromSliceLeaky(Value, arena, "{\"tools\":[\"mcp__smolify__read_public_source\"]}", .{ .allocate = .alloc_always });
    const loaded = try gate.loadInto(arena, tools, req);
    try testing.expect(!loaded.is_error);
    try testing.expectEqual(@as(usize, 1), loaded.loaded);
    const after = try schema.renderRootTools(arena, .anthropic, &.{}, tools);
    try testing.expect(std.mem.indexOf(u8, after, "lineCount") != null); // read_public_source's own schema is back
    try testing.expect(std.mem.indexOf(u8, after, "pathHints") == null); // build_docs_context's is not
    try testing.expect(after.len > deferred.len and after.len < eager.len);
}

test "pinEagerRuntime: a post-configure license probe promotes the server for the first catalog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    gate.reset();
    gate.g_policy = .{};
    defer {
        gate.reset();
        gate.g_policy = .{};
    }
    const tools = try realServerTools(arena);
    try testing.expect(!gate.pinnedEager("smolify"));
    gate.pinEagerRuntime(arena, "smolify");
    try testing.expect(gate.pinnedEager("smolify"));
    gate.pinEagerRuntime(arena, "smolify"); // a second probe must not grow the list
    try testing.expectEqual(@as(usize, 1), gate.g_policy.eager.len);
    // The pin is what isDeferred consults, so the pinned server's tools serve eagerly...
    for (tools) |t| try testing.expect(!gate.isDeferred(tools, t));
    // ...and nothing deferred means load_tool_schemas drops out of the catalog too.
    try testing.expect(!gate.anyDeferred(tools));
}

test "#416: every provider wire format defers identically, and stays valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    gate.reset();
    gate.g_policy = .{};
    defer {
        gate.reset();
        gate.g_policy = .{};
    }
    const tools = try realServerTools(arena);
    for ([_]Provider.Kind{ .anthropic, .openai, .responses }) |kind| {
        const catalog = try schema.renderRootTools(arena, kind, &.{}, tools);
        // A placeholder must be as wire-legal as a real schema: parseable,
        // combinator-free, and a JSON Schema object like every other entry.
        try forEachServedSchema(arena, catalog, struct {
            fn check(name: []const u8, sch: Value) anyerror!void {
                _ = name;
                try testing.expectEqualStrings("object", sch.object.get("type").?.string);
                try testing.expect(mcp_protocol.topLevelCombinator(sch) == null);
            }
        }.check);
    }
}

// The two below live here rather than in schema.zig, which is at the
// 600-line ceiling.

test "isMetaName: every orchestrator-handled meta tool, and nothing else" {
    for (schema.meta_names) |name| try std.testing.expect(schema.isMetaName(name));
    try std.testing.expect(schema.isMetaName("note_constraint")); // #381: inline — it mutates the root's own system prompt
    try std.testing.expect(!schema.isMetaName("bash"));
    try std.testing.expect(!schema.isMetaName("subagent"));
    try std.testing.expect(!schema.isMetaName("codedb"));
    // Every meta name must be a real root spec: a meta tool nothing advertises
    // is dead dispatch, and a meta name with no spec is unreachable.
    for (schema.meta_names) |name| {
        var found = false;
        for (schema.root_specs) |t| if (std.mem.eql(u8, t.name, name)) {
            found = true;
        };
        try std.testing.expect(found);
    }
}

test "note_constraint (#381): root-only, append-only, and a valid one-property schema" {
    var found = false;
    for (schema.root_specs) |t| if (std.mem.eql(u8, t.name, "note_constraint")) {
        found = true;
        var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, t.schema, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("text", parsed.value.object.get("required").?.array.items[0].string);
        try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("properties").?.object.count());
        // The append-only contract is ADVERTISED, not merely implemented: a
        // model that believed it could retire an item would keep trying.
        try std.testing.expect(std.mem.indexOf(u8, t.desc, "Append-only") != null);
        try std.testing.expect(std.mem.indexOf(u8, t.desc, "survives compaction") != null);
    };
    try std.testing.expect(found);
    // A subagent must never be handed it: a child never saw the rejection, so
    // anything it recorded would be second-hand at best.
    try std.testing.expect(std.mem.indexOf(u8, schema.tools_openai_sub, "note_constraint") == null);
    try std.testing.expect(std.mem.indexOf(u8, schema.tools_anthropic_sub, "note_constraint") == null);
}
