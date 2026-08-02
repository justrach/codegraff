//! Comptime provider-tool renderers: one ToolSpec list in, one provider-shaped
//! JSON tools array out. Split out of schema.zig (600-line ceiling) when the
//! optional-tool catalogs (#352 imagegen) doubled the number of comptime
//! catalogs schema.zig has to hold. Pure comptime string building — no imports
//! beyond std, so schema.zig can call these while building its own constants.
//!
//! `specs` is `anytype` rather than `[]const schema.ToolSpec` only to avoid an
//! import cycle back into schema.zig; every caller passes a comptime list of
//! structs with `.name`, `.desc` and `.schema`, and `.desc` must stay free of
//! characters needing JSON escapes (the descriptions are spliced in verbatim).

const std = @import("std");

pub fn anthropicToolsJson(comptime specs: anytype) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"name\":\"" ++ t.name ++ "\",\"description\":\"" ++ t.desc ++
                "\",\"input_schema\":" ++ t.schema ++ "}";
        }
        return out ++ "]";
    }
}

pub fn openaiToolsJson(comptime specs: anytype) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"type\":\"function\",\"function\":{\"name\":\"" ++ t.name ++
                "\",\"description\":\"" ++ t.desc ++ "\",\"parameters\":" ++ t.schema ++ "}}";
        }
        return out ++ "]";
    }
}

pub fn responsesToolsJson(comptime specs: anytype) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"type\":\"function\",\"name\":\"" ++ t.name ++
                "\",\"description\":\"" ++ t.desc ++ "\",\"parameters\":" ++ t.schema ++
                ",\"strict\":false}";
        }
        return out ++ "]";
    }
}

test "renderers emit one entry per spec in each provider shape" {
    const Spec = struct { name: []const u8, desc: []const u8, schema: []const u8 };
    const specs = [_]Spec{
        .{ .name = "a", .desc = "first", .schema = "{}" },
        .{ .name = "b", .desc = "second", .schema = "{}" },
    };
    // Comptime-only by construction: the catalogs are compile-time constants,
    // so the call has to be forced into a comptime context here too.
    const anthropic = comptime anthropicToolsJson(&specs);
    const openai = comptime openaiToolsJson(&specs);
    const responses = comptime responsesToolsJson(&specs);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"a\",\"description\":\"first\",\"input_schema\":{}},{\"name\":\"b\",\"description\":\"second\",\"input_schema\":{}}]",
        anthropic,
    );
    try std.testing.expect(std.mem.indexOf(u8, openai, "\"type\":\"function\",\"function\":{\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, responses, ",\"strict\":false}]"));
    // Every rendered catalog must still parse as JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, openai, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}
