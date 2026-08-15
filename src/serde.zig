//! Session persistence + request-body serialization (std-only leaf): remember
//! the last provider+model, load/save the input-history file, and the two
//! wire-format message serializers — the Anthropic prompt-caching writer (marks
//! the final user turn with a cache_control breakpoint) and the OpenAI
//! assistant-tool-call content normalizer. Split out of main.zig (600-line
//! goal). main aliases all 6 entry points back.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

const history_file = ".simple-harness-history";
const model_file = ".simple-harness-model"; // remembers the last-selected provider+model

pub const SavedModel = struct { pid: []const u8, model: []const u8 };

/// Persist the active provider+model so the next launch starts on it.
pub fn saveModel(io: Io, home: []const u8, pid: []const u8, model: []const u8) void {
    if (home.len == 0) return;
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ home, model_file }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    var wbuf: [256]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.print("{s}\n{s}\n", .{ pid, model }) catch return;
    fw.interface.flush() catch return;
}

/// Load the remembered provider+model (pid on line 1, model on line 2).
pub fn loadModel(io: Io, arena: Allocator, home: []const u8) ?SavedModel {
    if (home.len == 0) return null;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, model_file }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    var it = std.mem.splitScalar(u8, data, '\n');
    const pid = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    const model = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (pid.len == 0 or model.len == 0) return null;
    return .{ .pid = pid, .model = model };
}
const history_cap = 1000; // keep the most recent N input lines

/// Load persisted ↑/↓ input history from ~/.simple-harness-history into the
/// in-memory list (gpa-owned entries; freed with the list at exit). Capped to
/// the last `history_cap` lines.
pub fn loadHistory(io: Io, gpa: Allocator, home: []const u8, history: *std.ArrayList([]const u8)) void {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, history_file }) catch return;
    defer gpa.free(path);
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const l = std.mem.trim(u8, ln, " \t\r");
        if (l.len == 0 or !util.rememberInput(l)) continue;
        const dup = gpa.dupe(u8, l) catch continue;
        history.append(gpa, dup) catch gpa.free(dup);
    }
    if (history.items.len > history_cap) {
        const drop = history.items.len - history_cap;
        for (history.items[0..drop]) |h| gpa.free(h);
        std.mem.copyForwards([]const u8, history.items[0..], history.items[drop..]);
        history.shrinkRetainingCapacity(history_cap);
    }
}

/// Write the (last `history_cap`) input lines back to ~/.simple-harness-history.
pub fn saveHistory(io: Io, arena: Allocator, home: []const u8, history: []const []const u8) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, history_file }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    var wbuf: [8 * 1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    const start = if (history.len > history_cap) history.len - history_cap else 0;
    for (history[start..]) |h| {
        if (!util.rememberInput(h)) continue;
        fw.interface.writeAll(h) catch return;
        fw.interface.writeByte('\n') catch return;
    }
    fw.interface.flush() catch return;
}

fn anthropicCacheableBlock(value: Value) bool {
    if (value != .object) return false;
    const kind = value.object.get("type") orelse return false;
    if (kind != .string) return false;
    for ([_][]const u8{ "text", "image", "document", "search_result", "tool_use", "tool_result", "server_tool_use", "web_search_tool_result" }) |candidate| {
        if (std.mem.eql(u8, kind.string, candidate)) return true;
    }
    return false;
}

fn writeObjectWithCache(s: *std.json.Stringify, obj: std.json.ObjectMap) !void {
    try s.beginObject();
    var it = obj.iterator();
    while (it.next()) |kv| {
        try s.objectField(kv.key_ptr.*);
        try s.write(kv.value_ptr.*);
    }
    if (obj.get("cache_control") == null) {
        try s.objectField("cache_control");
        try s.print("{s}", .{"{\"type\":\"ephemeral\"}"});
    }
    try s.endObject();
}

/// Serialize Anthropic messages. `normalize_blocks` matches the official Kimi
/// adapter by turning every plain string into a `{type:text,text}` content
/// array. `cache` marks the final cacheable block (including tool_result), not
/// just the plain-string happy path.
pub fn writeAnthropicMessages(s: *std.json.Stringify, messages: std.json.Array, cache: bool, normalize_blocks: bool) !void {
    const items = messages.items;
    try s.beginArray();
    for (items, 0..) |m, i| {
        if (m != .object or m.object.get("content") == null) {
            try s.write(m);
            continue;
        }
        const content = m.object.get("content").?;
        const cache_this = cache and i + 1 == items.len;
        const string_content = content == .string;
        const array_cache = cache_this and content == .array and content.array.items.len > 0 and anthropicCacheableBlock(content.array.items[content.array.items.len - 1]);
        if (!normalize_blocks and !cache_this) {
            try s.write(m);
            continue;
        }
        if (!string_content and !array_cache) {
            try s.write(m);
            continue;
        }
        try s.beginObject();
        var it = m.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "content")) continue;
            try s.objectField(kv.key_ptr.*);
            try s.write(kv.value_ptr.*);
        }
        try s.objectField("content");
        if (string_content) {
            try s.beginArray();
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(content.string);
            if (cache_this) {
                try s.objectField("cache_control");
                try s.print("{s}", .{"{\"type\":\"ephemeral\"}"});
            }
            try s.endObject();
            try s.endArray();
        } else {
            try s.beginArray();
            for (content.array.items, 0..) |block, block_i| {
                if (block_i + 1 == content.array.items.len and anthropicCacheableBlock(block))
                    try writeObjectWithCache(s, block.object)
                else
                    try s.write(block);
            }
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
}

fn hasSchemaComposition(obj: std.json.ObjectMap) bool {
    for ([_][]const u8{ "$ref", "allOf", "anyOf", "oneOf", "not", "if" }) |key| if (obj.get(key) != null) return true;
    return false;
}

/// Issue #261: an MCP server may advertise an inputSchema with no root "type"
/// (mcp.zig also defaults a missing one to `{}`), and it reached the wire
/// verbatim — both Moonshot ("parameters.type is required and must be
/// 'object'") and Anthropic reject the whole request for it, so no tool call
/// ever got a chance to run. A tool's argument schema is an object by
/// construction on both wires, so say so. A schema that already declares a
/// type, or that defers to a root composition keyword, is left untouched.
///
/// Reports whether it changed anything, so a writer that would otherwise pass
/// the catalog through verbatim can keep the original bytes.
fn defaultRootObjectType(arena: Allocator, value: *Value) Allocator.Error!bool {
    if (value.* != .object) return false;
    if (value.object.get("type") != null or hasSchemaComposition(value.object)) return false;
    try value.object.put(arena, "type", .{ .string = "object" });
    return true;
}

/// Kimi's official Anthropic adapter places a cache breakpoint on the final
/// tool definition. The source catalog is already JSON, so rewrite only the
/// last object and fall back to the original bytes if a custom catalog is bad.
/// The parse is unconditional because every catalog also needs the #261 root
/// type repair, not just the cached ones.
pub fn writeAnthropicTools(s: *std.json.Stringify, arena: Allocator, raw: []const u8, cache: bool) !void {
    const value = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return s.print("{s}", .{raw});
    if (value != .array or value.array.items.len == 0) return s.print("{s}", .{raw});
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        if (tool.object.getPtr("input_schema")) |schema| _ = try defaultRootObjectType(arena, schema);
    }
    try s.beginArray();
    for (value.array.items, 0..) |tool, i| {
        if (cache and i + 1 == value.array.items.len and tool == .object)
            try writeObjectWithCache(s, tool.object)
        else
            try s.write(tool);
    }
    try s.endArray();
}

fn jsonValueType(value: Value) ?[]const u8 {
    return switch (value) {
        .string => "string",
        .integer => "integer",
        .float => "number",
        .bool => "boolean",
        .object => "object",
        .array => "array",
        .null => "null",
        else => null,
    };
}

fn inferredKimiType(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("enum")) |values| if (values == .array and values.array.items.len > 0) {
        const first = jsonValueType(values.array.items[0]) orelse return null;
        for (values.array.items[1..]) |value| {
            const current = jsonValueType(value) orelse return null;
            if (!std.mem.eql(u8, first, current) and
                !(std.mem.eql(u8, first, "integer") and std.mem.eql(u8, current, "number")) and
                !(std.mem.eql(u8, first, "number") and std.mem.eql(u8, current, "integer"))) return null;
        }
        return first;
    };
    if (obj.get("const")) |value| return jsonValueType(value);
    for ([_][]const u8{ "properties", "required", "additionalProperties", "patternProperties" }) |key| if (obj.get(key) != null) return "object";
    for ([_][]const u8{ "items", "prefixItems", "minItems", "maxItems" }) |key| if (obj.get(key) != null) return "array";
    for ([_][]const u8{ "pattern", "format", "minLength", "maxLength" }) |key| if (obj.get(key) != null) return "string";
    for ([_][]const u8{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf" }) |key| if (obj.get(key) != null) return "number";
    return "string";
}

fn normalizeKimiSchemaMap(arena: Allocator, value: *Value) Allocator.Error!void {
    if (value.* != .object) return;
    var it = value.object.iterator();
    while (it.next()) |entry| try normalizeKimiSchema(arena, entry.value_ptr, false);
}

fn normalizeKimiSchemaArray(arena: Allocator, value: *Value) Allocator.Error!void {
    if (value.* != .array) return;
    for (value.array.items) |*item| try normalizeKimiSchema(arena, item, false);
}

fn normalizeKimiSchema(arena: Allocator, value: *Value, root: bool) Allocator.Error!void {
    if (value.* != .object) return;
    const obj = &value.object;

    // Moonshot requires a union's type on each anyOf branch, never on the
    // parent. MCP generators commonly emit the opposite shape.
    if (root) {
        // Native Kimi simultaneously requires parameters.type="object" and
        // rejects a root anyOf beside that type. Preserve the union as oneOf,
        // which its current schema walker accepts in this root position.
        if (obj.get("anyOf")) |branches| {
            if (obj.get("oneOf") == null) try obj.put(arena, "oneOf", branches);
            _ = obj.orderedRemove("anyOf");
        }
    } else if (obj.get("anyOf") != null) {
        if (obj.fetchOrderedRemove("type")) |removed| {
            const branches = obj.get("anyOf").?;
            if (branches == .array) {
                for (branches.array.items) |*branch| if (branch.* == .object and branch.object.get("type") == null) {
                    try branch.object.put(arena, "type", removed.value);
                };
            }
        }
    }
    // The root never guesses (#261 wants "object" there, and inferredKimiType's
    // fallback is "string"); every child keeps the kimi-code inference.
    if (root) {
        _ = try defaultRootObjectType(arena, value);
    } else if (obj.get("type") == null and !hasSchemaComposition(obj.*)) {
        if (inferredKimiType(obj.*)) |kind| try obj.put(arena, "type", .{ .string = kind });
    }

    // These are the child-schema slots walked by Moonshot's adapter. Map
    // containers such as `properties` are not schemas themselves.
    for ([_][]const u8{ "$defs", "definitions", "dependencies", "dependentSchemas", "patternProperties", "properties" }) |key| {
        if (obj.getPtr(key)) |child| try normalizeKimiSchemaMap(arena, child);
    }
    for ([_][]const u8{ "additionalItems", "additionalProperties", "contains", "contentSchema", "else", "if", "not", "propertyNames", "then", "unevaluatedItems", "unevaluatedProperties" }) |key| {
        if (obj.getPtr(key)) |child| try normalizeKimiSchema(arena, child, false);
    }
    for ([_][]const u8{ "allOf", "anyOf", "oneOf", "prefixItems" }) |key| {
        if (obj.getPtr(key)) |child| try normalizeKimiSchemaArray(arena, child);
    }
    if (obj.getPtr("items")) |items| {
        if (items.* == .array)
            try normalizeKimiSchemaArray(arena, items)
        else
            try normalizeKimiSchema(arena, items, false);
    }
}

/// Kimi's native tool validator is stricter than JSON Schema. Apply the same
/// property-type completion as kimi-code plus its required anyOf rewrite.
pub fn writeKimiTools(s: *std.json.Stringify, arena: Allocator, raw: []const u8) !void {
    const value = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return s.print("{s}", .{raw});
    if (value != .array) return s.write(value);
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        var tool_it = tool.object.iterator();
        while (tool_it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "function") or entry.value_ptr.* != .object) continue;
            var function_it = entry.value_ptr.object.iterator();
            while (function_it.next()) |field| {
                if (std.mem.eql(u8, field.key_ptr.*, "parameters")) try normalizeKimiSchema(arena, field.value_ptr, true);
            }
        }
    }
    try s.write(value);
}

/// Issue #261 follow-up: writeKimiTools and writeAnthropicTools repair a
/// typeless MCP root schema, but every other OpenAI-compatible endpoint got the
/// catalog bytes verbatim — and any endpoint validating as strictly as Moonshot
/// rejects the whole request ("parameters.type is required and must be
/// 'object'") before a single tool can run. Repair the root for both OpenAI
/// tool shapes: chat completions nests the schema at `function.parameters`,
/// the Responses API keeps it flat at `parameters`.
///
/// Only the root type is added — no child inference (that is Kimi-only), and a
/// catalog that needs no repair, or that we cannot parse, goes out as its
/// original bytes so the usual request keeps a byte-identical cached prefix.
pub fn writeOpenAITools(s: *std.json.Stringify, arena: Allocator, raw: []const u8) !void {
    const value = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return s.print("{s}", .{raw});
    if (value != .array) return s.print("{s}", .{raw});
    var repaired = false;
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        const params = if (tool.object.getPtr("function")) |f|
            (if (f.* == .object) f.object.getPtr("parameters") else null)
        else
            tool.object.getPtr("parameters");
        if (params) |p| {
            if (try defaultRootObjectType(arena, p)) repaired = true;
        }
    }
    if (!repaired) return s.print("{s}", .{raw});
    try s.write(value);
}

/// Serialize one chat-completions history message. Everything is echoed
/// verbatim except an assistant tool-call turn whose `content` is null, which
/// several providers reject — that one is rebuilt with `content: ""`.
///
/// Retained reasoning (the ARC-AGI-3 setting): the rebuild copies EVERY other
/// field through, so a streamed `reasoning_content` / `reasoning` that
/// assembleOpenAI folded into the assistant message goes back out on the next
/// request. That is deliberate, not incidental. DeepSeek's thinking mode makes
/// the replay mandatory ("the reasoning_content in the thinking mode must be
/// passed back to the API" — a 400 once the turn contained a tool call), and
/// Moonshot/Kimi ask for the assistant message to be passed back as-is so the
/// model can reuse its own chain. Do not add a strip here. If a provider ever
/// rejects the field, gate the removal on that provider id rather than dropping
/// it for everyone. (Kimi k2.6 additionally needs `thinking.keep` on the
/// request before the server will USE the replayed reasoning; see the audit
/// note in the ARC parity work.)
pub fn writeOpenAIMessageNormalized(s: *std.json.Stringify, m: Value) !void {
    if (m != .object) return s.write(m);
    const role = if (m.object.get("role")) |v| (if (v == .string) v.string else "") else "";
    const is_assistant_tool_call = std.mem.eql(u8, role, "assistant") and m.object.get("tool_calls") != null;
    const null_content = if (m.object.get("content")) |v| v == .null else false;
    if (!is_assistant_tool_call or !null_content) return s.write(m);

    try s.beginObject();
    var it = m.object.iterator();
    var wrote_content = false;
    while (it.next()) |kv| {
        try s.objectField(kv.key_ptr.*);
        if (std.mem.eql(u8, kv.key_ptr.*, "content")) {
            try s.write("");
            wrote_content = true;
        } else {
            try s.write(kv.value_ptr.*);
        }
    }
    if (!wrote_content) {
        try s.objectField("content");
        try s.write("");
    }
    try s.endObject();
}

fn renderKimiTools(arena: Allocator, raw: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeKimiTools(&s, arena, raw);
    return aw.writer.buffered();
}

fn renderOpenAITools(arena: Allocator, raw: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeOpenAITools(&s, arena, raw);
    return aw.writer.buffered();
}

fn renderAnthropicTools(arena: Allocator, raw: []const u8, cache: bool) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeAnthropicTools(&s, arena, raw, cache);
    return aw.writer.buffered();
}

test "kimi tools give a typeless MCP root schema type object (#261)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // mcp.zig substitutes `{}` for a server that advertises no inputSchema.
    const empty = try renderKimiTools(arena, "[{\"type\":\"function\",\"function\":{\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{}}}]");
    try std.testing.expect(std.mem.indexOf(u8, empty, "\"parameters\":{\"type\":\"object\"}") != null);

    // Properties but no root type: the root says object, children still infer.
    const props = try renderKimiTools(arena, "[{\"type\":\"function\",\"function\":{\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{\"properties\":{\"path\":{}}}}}]");
    try std.testing.expect(std.mem.indexOf(u8, props, "\"parameters\":{\"properties\":{\"path\":{\"type\":\"string\"}},\"type\":\"object\"}") != null);

    // A declared type and a root composition keyword are both left alone.
    const typed = try renderKimiTools(arena, "[{\"type\":\"function\",\"function\":{\"name\":\"t\",\"description\":\"\",\"parameters\":{\"type\":\"string\"}}}]");
    try std.testing.expect(std.mem.indexOf(u8, typed, "\"parameters\":{\"type\":\"string\"}") != null);
    const composed = try renderKimiTools(arena, "[{\"type\":\"function\",\"function\":{\"name\":\"t\",\"description\":\"\",\"parameters\":{\"allOf\":[{\"type\":\"object\"}]}}}]");
    try std.testing.expect(std.mem.indexOf(u8, composed, "\"parameters\":{\"allOf\":[{\"type\":\"object\"}]}") != null);
}

test "anthropic tools give a typeless MCP input_schema type object (#261)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "[{\"name\":\"mcp__s__t\",\"description\":\"\",\"input_schema\":{}}]";
    try std.testing.expectEqualStrings(
        "[{\"name\":\"mcp__s__t\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]",
        try renderAnthropicTools(arena, raw, false),
    );
    // The repair survives the cache-breakpoint rewrite on the last tool.
    const cached = try renderAnthropicTools(arena, raw, true);
    try std.testing.expect(std.mem.indexOf(u8, cached, "\"input_schema\":{\"type\":\"object\"},\"cache_control\":{\"type\":\"ephemeral\"}") != null);

    const composed = "[{\"name\":\"t\",\"description\":\"\",\"input_schema\":{\"oneOf\":[{\"type\":\"object\"}]}}]";
    try std.testing.expectEqualStrings(composed, try renderAnthropicTools(arena, composed, false));
    const typed = "[{\"name\":\"t\",\"description\":\"\",\"input_schema\":{\"type\":\"object\",\"properties\":{}}}]";
    try std.testing.expectEqualStrings(typed, try renderAnthropicTools(arena, typed, false));
}

test "openai and responses tools give a typeless MCP root schema type object (#261)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Chat completions: mcp.zig substitutes `{}` for a server that advertises
    // no inputSchema, and renderRootTools nests it under function.parameters.
    const chat = try renderOpenAITools(arena, "[{\"type\":\"function\",\"function\":{\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{}}}]");
    try std.testing.expectEqualStrings(
        "[{\"type\":\"function\",\"function\":{\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{\"type\":\"object\"}}}]",
        chat,
    );

    // Responses: the same tool, flat, with `strict` after the schema.
    const responses = try renderOpenAITools(arena, "[{\"type\":\"function\",\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{},\"strict\":false}]");
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"parameters\":{\"type\":\"object\"},\"strict\":false") != null);

    // Only the root is repaired: a typeless child keeps no type here (that
    // inference is Kimi's stricter validator, not JSON Schema).
    const props = try renderOpenAITools(arena, "[{\"type\":\"function\",\"function\":{\"name\":\"t\",\"description\":\"\",\"parameters\":{\"properties\":{\"path\":{}}}}}]");
    try std.testing.expect(std.mem.indexOf(u8, props, "\"parameters\":{\"properties\":{\"path\":{}},\"type\":\"object\"}") != null);

    // A declared type, a root composition keyword, and an unparsable catalog
    // all reach the wire as their original bytes — whitespace included, since
    // a catalog that needs no repair is never re-serialized.
    const typed = "[{\"type\":\"function\",\"name\":\"t\",\"description\":\"\",\"parameters\":{\"type\": \"object\", \"properties\": {}},\"strict\":false}]";
    try std.testing.expectEqualStrings(typed, try renderOpenAITools(arena, typed));
    const composed = "[{\"type\":\"function\",\"function\":{\"name\":\"t\",\"description\":\"\",\"parameters\":{\"anyOf\":[{\"type\":\"object\"}]}}}]";
    try std.testing.expectEqualStrings(composed, try renderOpenAITools(arena, composed));
    try std.testing.expectEqualStrings("not json", try renderOpenAITools(arena, "not json"));
}

test "#108: a composer line that names @[path] is persisted in input history" {
    try std.testing.expect(util.rememberInput("@[/tmp/shot.png] look at this"));
    try std.testing.expect(util.rememberInput("go on"));
}
