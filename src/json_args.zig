//! Tag-checked accessors for model-supplied JSON tool arguments.
//!
//! A model can emit any JSON shape as tool arguments — nothing constrains it
//! to what a tool's schema promises. Reading `v.object`/`v.string`/`v.array`
//! off a `std.json.Value` without first checking its active tag panics in a
//! Debug build but is UNDEFINED BEHAVIOR in ReleaseFast (the shipped build):
//! the union access is unchecked there, so a wrong-tag read silently
//! reinterprets whatever bytes happen to be in the payload as an object/
//! string/array header. Every accessor below returns null (or false, for
//! `flag`) on a tag mismatch instead, so a caller can turn a malformed
//! argument tree into an ordinary `is_error` tool result the model can see
//! and react to, rather than a memory-safety incident.

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub fn object(v: Value) ?ObjectMap {
    return if (v == .object) v.object else null;
}

pub fn text(v: Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}

pub fn list(v: Value) ?[]const Value {
    return if (v == .array) v.array.items else null;
}

pub fn str(o: ObjectMap, name: []const u8) ?[]const u8 {
    return text(o.get(name) orelse return null);
}

pub fn arrayOf(o: ObjectMap, name: []const u8) ?[]const Value {
    return list(o.get(name) orelse return null);
}

/// Takes the RAW argument tree: a flag on a non-object argument tree is
/// simply false.
pub fn flag(v: Value, name: []const u8) bool {
    const o = object(v) orelse return false;
    const f = o.get(name) orelse return false;
    return f == .bool and f.bool;
}

test "accessors return null on a tag mismatch instead of dereferencing (ReleaseFast UB)" {
    const string_v: Value = .{ .string = "x" };
    const int_v: Value = .{ .integer = 5 };
    const bool_v: Value = .{ .bool = true };
    const null_v: Value = .null;
    var arr = std.json.Array.init(std.testing.allocator);
    defer arr.deinit();
    try arr.append(.{ .integer = 1 });
    const arr_v: Value = .{ .array = arr };
    const obj_v: Value = .{ .object = ObjectMap.empty };

    for ([_]Value{ string_v, int_v, bool_v, null_v, arr_v }) |v| {
        try std.testing.expect(object(v) == null);
    }
    try std.testing.expect(object(obj_v) != null);

    for ([_]Value{ int_v, bool_v, null_v, arr_v, obj_v }) |v| {
        try std.testing.expect(text(v) == null);
    }
    try std.testing.expect(text(string_v) != null);

    for ([_]Value{ string_v, int_v, bool_v, null_v, obj_v }) |v| {
        try std.testing.expect(list(v) == null);
    }
    try std.testing.expect(list(arr_v) != null);
}

test "str/arrayOf survive every malformed tool-argument shape a model actually emits" {
    const gpa = std.testing.allocator;
    const shapes = [_][]const u8{
        "{\"result\":5}",
        "{\"question\":[]}",
        "{\"options\":[1,2]}",
        "{\"note\":null}",
        "{\"prompt\":{}}",
    };
    for (shapes) |shape| {
        const parsed = try std.json.parseFromSlice(Value, gpa, shape, .{});
        defer parsed.deinit();
        const o = object(parsed.value).?;
        var it = o.iterator();
        while (it.next()) |entry| {
            try std.testing.expect(str(o, entry.key_ptr.*) == null);
        }
    }

    const opts_parsed = try std.json.parseFromSlice(Value, gpa, "{\"options\":[1,2]}", .{});
    defer opts_parsed.deinit();
    const opts_obj = object(opts_parsed.value).?;
    const opts = arrayOf(opts_obj, "options").?;
    try std.testing.expectEqual(@as(usize, 2), opts.len);
    for (opts) |item| try std.testing.expect(text(item) == null);

    const top_level = [_][]const u8{ "[1,2]", "\"hi\"", "5", "null" };
    for (top_level) |shape| {
        const parsed = try std.json.parseFromSlice(Value, gpa, shape, .{});
        defer parsed.deinit();
        try std.testing.expect(object(parsed.value) == null);
    }
}

test "flag is true only for an explicit boolean true" {
    const gpa = std.testing.allocator;
    {
        const parsed = try std.json.parseFromSlice(Value, gpa, "{\"b\":true}", .{});
        defer parsed.deinit();
        try std.testing.expect(flag(parsed.value, "b"));
    }
    {
        const parsed = try std.json.parseFromSlice(Value, gpa, "{\"b\":false}", .{});
        defer parsed.deinit();
        try std.testing.expect(!flag(parsed.value, "b"));
    }
    {
        const parsed = try std.json.parseFromSlice(Value, gpa, "{\"b\":\"true\"}", .{});
        defer parsed.deinit();
        try std.testing.expect(!flag(parsed.value, "b"));
    }
    {
        const parsed = try std.json.parseFromSlice(Value, gpa, "{\"b\":1}", .{});
        defer parsed.deinit();
        try std.testing.expect(!flag(parsed.value, "b"));
    }
    {
        const parsed = try std.json.parseFromSlice(Value, gpa, "{}", .{});
        defer parsed.deinit();
        try std.testing.expect(!flag(parsed.value, "b"));
    }
    {
        const parsed = try std.json.parseFromSlice(Value, gpa, "[1]", .{});
        defer parsed.deinit();
        try std.testing.expect(!flag(parsed.value, "b"));
    }
}
