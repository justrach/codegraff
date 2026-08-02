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

fn assertClean(name: []const u8, sch: Value) anyerror!void {
    if (combinatorAnywhere(sch)) |key| {
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

    // The guard has to be able to fail, or it proves nothing.
    const bad = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"object","properties":{},"anyOf":[{"required":["a"]},{"required":["b"]}]}
    , .{});
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
