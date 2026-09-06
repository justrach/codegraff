//! #752: tool-call argument strings must be JSON objects in replayable history.
//!
//! OpenAI chat and the Responses wire store `arguments` as a string. A truncated
//! stream used to persist that fragment, execute with an empty object (so bash
//! reported a missing `command`), then 400 every later request:
//! `function.arguments: arguments must be a valid JSON object string`.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const empty_object = "{}";
pub const invalid_exec_message = "tool call arguments were truncated or not a JSON object; the call was not executed";

pub const Parsed = struct {
    input: Value,
    /// False: do not execute; persist `{}` instead of the raw fragment.
    valid: bool,
};

/// Empty arguments still run as `{}` (a completed empty call). Anything that is
/// not a JSON object — truncated strings, arrays, scalars — is invalid.
pub fn parse(alloc: Allocator, s: []const u8) Parsed {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0) return .{ .input = .{ .object = .empty }, .valid = true };
    const value = std.json.parseFromSliceLeaky(Value, alloc, t, .{ .allocate = .alloc_always }) catch
        return .{ .input = .{ .object = .empty }, .valid = false };
    if (value != .object) return .{ .input = .{ .object = .empty }, .valid = false };
    return .{ .input = value, .valid = true };
}

/// `gpa` must free (session arena is bump-only). Used only to validate.
pub fn isObjectString(gpa: Allocator, s: []const u8) bool {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    if (t.len == 0 or t[0] != '{') return false;
    const parsed = std.json.parseFromSlice(Value, gpa, t, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

/// Rewrite OpenAI `tool_calls[].function.arguments` and Responses
/// `function_call.arguments` that are not JSON object strings. Ids / pairing stay.
pub fn repairHistory(gpa: Allocator, map_alloc: Allocator, messages: []Value) void {
    for (messages) |*m| repairMessage(gpa, map_alloc, m);
}

pub fn repairMessage(gpa: Allocator, map_alloc: Allocator, m: *Value) void {
    if (m.* != .object) return;
    const mtype = if (m.object.get("type")) |t| (if (t == .string) t.string else "") else "";
    if (std.mem.eql(u8, mtype, "function_call")) {
        repairArgumentsField(gpa, map_alloc, &m.object);
        return;
    }
    const tcs = m.object.get("tool_calls") orelse return;
    if (tcs != .array) return;
    for (tcs.array.items) |*tc| {
        if (tc.* != .object) continue;
        var function = tc.object.get("function") orelse continue;
        if (function != .object) continue;
        repairArgumentsField(gpa, map_alloc, &function.object);
    }
}

fn repairArgumentsField(gpa: Allocator, map_alloc: Allocator, obj: *std.json.ObjectMap) void {
    const args = obj.get("arguments") orelse {
        obj.put(map_alloc, "arguments", .{ .string = empty_object }) catch return;
        return;
    };
    if (args == .string and isObjectString(gpa, args.string)) return;
    obj.put(map_alloc, "arguments", .{ .string = empty_object }) catch return;
}

test "parse: empty is a completed empty object; truncated and non-objects are not" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        const p = parse(arena, "");
        try std.testing.expect(p.valid);
        try std.testing.expect(p.input == .object);
    }
    {
        const p = parse(arena, "  {}  ");
        try std.testing.expect(p.valid);
        try std.testing.expect(p.input == .object);
    }
    {
        const p = parse(arena, "{\"command\":\"echo hi\"}");
        try std.testing.expect(p.valid);
        try std.testing.expectEqualStrings("echo hi", p.input.object.get("command").?.string);
    }
    // Issue #752: unterminated command string, 750-byte class fragment.
    const truncated = "{\"command\":\"echo hi";
    {
        const p = parse(arena, truncated);
        try std.testing.expect(!p.valid);
        try std.testing.expect(p.input == .object);
        try std.testing.expectEqual(@as(usize, 0), p.input.object.count());
    }
    {
        const p = parse(arena, "[1,2]");
        try std.testing.expect(!p.valid);
    }
    {
        const p = parse(arena, "\"not-an-object\"");
        try std.testing.expect(!p.valid);
    }
}

test "repairHistory: openai tool_calls and responses function_call keep ids" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Value, arena,
        \\[
        \\  {"role":"assistant","content":null,"tool_calls":[
        \\    {"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi"}}
        \\  ]},
        \\  {"role":"tool","tool_call_id":"c1","content":"missing or non-string argument: command"},
        \\  {"type":"function_call","call_id":"r1","name":"bash","arguments":"{\"command\":\"partial"},
        \\  {"role":"assistant","tool_calls":[
        \\    {"id":"c2","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}
        \\  ]}
        \\]
    , .{});
    try std.testing.expect(parsed == .array);
    repairHistory(gpa, arena, parsed.array.items);

    const tc0 = parsed.array.items[0].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("c1", tc0.get("id").?.string);
    try std.testing.expectEqualStrings(empty_object, tc0.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("c1", parsed.array.items[1].object.get("tool_call_id").?.string);

    const fc = parsed.array.items[2].object;
    try std.testing.expectEqualStrings("r1", fc.get("call_id").?.string);
    try std.testing.expectEqualStrings(empty_object, fc.get("arguments").?.string);

    const good = parsed.array.items[3].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", good.get("function").?.object.get("arguments").?.string);

    // Repaired strings are JSON objects, so a later request body would accept them.
    try std.testing.expect(isObjectString(gpa, empty_object));
    try std.testing.expect(isObjectString(gpa, good.get("function").?.object.get("arguments").?.string));
    try std.testing.expect(!isObjectString(gpa, "{\"command\":\"echo hi"));
}
