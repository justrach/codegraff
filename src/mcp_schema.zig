//! MCP tool JSON Schema normalization: making a server-supplied
//! `inputSchema` acceptable to every provider graff can talk to.
//!
//! Split out of mcp_protocol.zig (600-line ceiling) when the Anthropic
//! top-level-combinator fix landed; that file keeps protocol negotiation and
//! re-exports these so existing call sites are unchanged.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Recursively rewrite the JSON Schema keyword `oneOf` to `anyOf` (graff's
/// rewrite_one_of_to_any_of). OpenAI's tool-schema validator — including the
/// chatgpt.com /codex/responses endpoint — rejects `oneOf` outright with
/// "'oneOf' is not permitted"; `anyOf` is accepted by both OpenAI and
/// Anthropic and is equivalent for the discriminated unions MCP servers emit
/// in practice. When both keywords are present (rare, ambiguous to merge),
/// the existing `anyOf` wins and `oneOf` is dropped. Runs once per tool at
/// discovery, so the rendered tools JSON stays KV-cache-stable.
pub fn rewriteOneOf(a: Allocator, v: *Value) Allocator.Error!void {
    switch (v.*) {
        .object => |*obj| {
            if (obj.get("oneOf")) |branches| {
                if (obj.get("anyOf") == null) try obj.put(a, "anyOf", branches);
                _ = obj.swapRemove("oneOf");
            }
            var it = obj.iterator();
            while (it.next()) |e| try rewriteOneOf(a, e.value_ptr);
        },
        .array => |*arr| for (arr.items) |*item| try rewriteOneOf(a, item),
        else => {},
    }
}

/// The JSON Schema combinators no provider agrees on at the top level of a
/// tool schema.
pub const combinators = [_][]const u8{ "allOf", "anyOf", "oneOf" };

/// The first combinator present at the TOP level of `schema`, or null. Nested
/// combinators (inside a property) are legal everywhere and are not reported.
pub fn topLevelCombinator(schema: Value) ?[]const u8 {
    if (schema != .object) return null;
    for (combinators) |key| {
        if (schema.object.get(key) != null) return key;
    }
    return null;
}

/// Lower a top-level `allOf`/`anyOf`/`oneOf` into a plain object schema.
///
/// The Anthropic Messages API rejects any tool whose input_schema carries one
/// of these at the top level — "input_schema does not support oneOf, allOf, or
/// anyOf at the top level" — and it rejects the whole REQUEST, so a single
/// MCP server advertising one takes down every turn, not just calls to that
/// tool. `rewriteOneOf` above does not help: it rewrites `oneOf` to `anyOf`,
/// which Anthropic rejects just as hard. Real example that caused this
/// (codedbpro's `replace`): `{type, properties, required,
/// anyOf:[{required:["path"]},{required:["paths"]}]}` — "path or paths".
///
/// Lowering rather than deleting, so nothing the model can pass is lost:
///   * `allOf` branches all hold, so their `properties` AND `required` merge in;
///   * `anyOf`/`oneOf` branches are alternatives, so only their `properties`
///     merge — hoisting their `required` would demand every alternative at
///     once. The requirement instead becomes a sentence in the schema's
///     description, so the model still knows one of them is needed and the
///     server keeps enforcing it.
/// Existing top-level keys always win; nested combinators are left alone.
pub fn flattenTopLevel(a: Allocator, v: *Value) Allocator.Error!void {
    if (v.* != .object) return;
    if (topLevelCombinator(v.*) == null) return; // the overwhelmingly common case
    var alternatives: std.ArrayList([]const u8) = .empty;
    for (combinators) |key| {
        const branches = v.object.get(key) orelse continue;
        _ = v.object.swapRemove(key);
        if (branches != .array) continue;
        const all = std.mem.eql(u8, key, "allOf");
        for (branches.array.items) |branch| {
            if (branch != .object) continue;
            try mergeProperties(a, &v.object, branch.object);
            if (all) try mergeRequired(a, &v.object, branch.object) else try noteRequired(a, &alternatives, branch.object);
        }
    }
    // A flattened schema must still be a valid object schema to Anthropic.
    if (v.object.get("type") == null) try v.object.put(a, "type", .{ .string = "object" });
    if (alternatives.items.len > 1) {
        const joined = try std.mem.join(a, " or ", alternatives.items);
        const existing = if (v.object.get("description")) |d| (if (d == .string) d.string else "") else "";
        const note = try std.fmt.allocPrint(a, "{s}{s}Requires one of: {s}.", .{ existing, if (existing.len > 0) " " else "", joined });
        try v.object.put(a, "description", .{ .string = note });
    }
}

fn mergeProperties(a: Allocator, top: *std.json.ObjectMap, branch: std.json.ObjectMap) Allocator.Error!void {
    const from = branch.get("properties") orelse return;
    if (from != .object) return;
    const existing = top.get("properties");
    if (existing == null or existing.? != .object) {
        try top.put(a, "properties", from);
        return;
    }
    var target = existing.?.object;
    var it = from.object.iterator();
    while (it.next()) |e| {
        if (target.get(e.key_ptr.*) != null) continue; // the top level wins
        try target.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    try top.put(a, "properties", .{ .object = target });
}

fn mergeRequired(a: Allocator, top: *std.json.ObjectMap, branch: std.json.ObjectMap) Allocator.Error!void {
    const from = branch.get("required") orelse return;
    if (from != .array) return;
    var list: std.json.Array = if (top.get("required")) |r|
        (if (r == .array) r.array else std.json.Array.init(a))
    else
        std.json.Array.init(a);
    for (from.array.items) |name| {
        if (name != .string) continue;
        var seen = false;
        for (list.items) |have| {
            if (have == .string and std.mem.eql(u8, have.string, name.string)) seen = true;
        }
        if (!seen) try list.append(name);
    }
    try top.put(a, "required", .{ .array = list });
}

/// Record one alternative branch's required names ("path", or "a + b") so the
/// dropped constraint survives as prose.
fn noteRequired(a: Allocator, out: *std.ArrayList([]const u8), branch: std.json.ObjectMap) Allocator.Error!void {
    const from = branch.get("required") orelse return;
    if (from != .array or from.array.items.len == 0) return;
    var names: std.ArrayList([]const u8) = .empty;
    for (from.array.items) |name| {
        if (name == .string) try names.append(a, name.string);
    }
    if (names.items.len == 0) return;
    try out.append(a, try std.mem.join(a, " + ", names.items));
}

test "rewriteOneOf: converts oneOf to anyOf, recursively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"oneOf":[{"type":"string"}],"properties":{"x":{"oneOf":[{"type":"number"},{"type":"null"}]}}}
    , .{});
    try rewriteOneOf(a, &v);
    try std.testing.expect(v.object.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 1), v.object.get("anyOf").?.array.items.len);
    const x = v.object.get("properties").?.object.get("x").?;
    try std.testing.expect(x.object.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 2), x.object.get("anyOf").?.array.items.len);
}

test "rewriteOneOf: existing anyOf wins when both are present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"anyOf":[{"type":"string"}],"oneOf":[{"type":"number"},{"type":"boolean"}]}
    , .{});
    try rewriteOneOf(a, &v);
    try std.testing.expect(v.object.get("oneOf") == null);
    // the pre-existing single-branch anyOf survives, the oneOf is dropped
    try std.testing.expectEqual(@as(usize, 1), v.object.get("anyOf").?.array.items.len);
}

test "rewriteOneOf: arrays and scalars pass through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"items":[{"oneOf":[1,2]},"plain",42]}
    , .{});
    try rewriteOneOf(a, &v);
    const first = v.object.get("items").?.array.items[0];
    try std.testing.expect(first.object.get("oneOf") == null);
    try std.testing.expect(first.object.get("anyOf") != null);
}
