//! Comptime provider-tool renderers: one ToolSpec list in, one provider-shaped
//! JSON tools array out. Split out of schema.zig (600-line ceiling) when the
//! optional-tool catalogs (#352 imagegen) doubled the number of comptime
//! catalogs schema.zig has to hold. String building with no imports beyond
//! std, so schema.zig can call these while building its own constants;
//! writeToolsJson is the runtime twin for catalogs rendered on demand.
//!
//! `specs` is `anytype` rather than `[]const schema.ToolSpec` only to avoid an
//! import cycle back into schema.zig; every caller passes a list of
//! structs with `.name`, `.desc` and `.schema`, and `.desc` must stay free of
//! characters needing JSON escapes (the descriptions are spliced in verbatim).

const std = @import("std");

/// One tool entry in a provider's shape: `head` name `desc` description
/// `schema` JSON-schema `tail`. The comptime catalogs and the runtime renderer
/// both build from these pieces, so the two agree byte for byte.
pub const Shape = struct { head: []const u8, desc: []const u8, schema: []const u8, tail: []const u8 };

pub const anthropic: Shape = .{ .head = "{\"name\":\"", .desc = "\",\"description\":\"", .schema = "\",\"input_schema\":", .tail = "}" };
pub const openai: Shape = .{ .head = "{\"type\":\"function\",\"function\":{\"name\":\"", .desc = "\",\"description\":\"", .schema = "\",\"parameters\":", .tail = "}}" };
pub const responses: Shape = .{ .head = "{\"type\":\"function\",\"name\":\"", .desc = "\",\"description\":\"", .schema = "\",\"parameters\":", .tail = ",\"strict\":false}" };
/// Google Interactions: the Responses shape minus `strict`. The endpoint
/// validates strictly and rejects the whole request on an unknown field
/// ("Unknown parameter 'strict' at 'tools[0]'"), so the two cannot share a
/// catalog even though every other byte matches.
pub const interactions: Shape = .{ .head = responses.head, .desc = responses.desc, .schema = responses.schema, .tail = "}" };

fn toolsJson(comptime shape: Shape, comptime specs: anytype) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ shape.head ++ t.name ++ shape.desc ++ t.desc ++ shape.schema ++ t.schema ++ shape.tail;
        }
        return out ++ "]";
    }
}

pub fn anthropicToolsJson(comptime specs: anytype) []const u8 {
    return toolsJson(anthropic, specs);
}

pub fn openaiToolsJson(comptime specs: anytype) []const u8 {
    return toolsJson(openai, specs);
}

pub fn responsesToolsJson(comptime specs: anytype) []const u8 {
    return toolsJson(responses, specs);
}

pub fn interactionsToolsJson(comptime specs: anytype) []const u8 {
    return toolsJson(interactions, specs);
}

/// The runtime twin of the comptime renderers, for catalogs not worth a
/// compile-time copy in the binary.
pub fn writeToolsJson(w: *std.Io.Writer, shape: Shape, specs: anytype) !void {
    try w.writeByte('[');
    for (specs, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        for ([_][]const u8{ shape.head, t.name, shape.desc, t.desc, shape.schema, t.schema, shape.tail }) |part| try w.writeAll(part);
    }
    try w.writeByte(']');
}

test "renderers emit one entry per spec in each provider shape" {
    const Spec = struct { name: []const u8, desc: []const u8, schema: []const u8 };
    const specs = [_]Spec{
        .{ .name = "a", .desc = "first", .schema = "{}" },
        .{ .name = "b", .desc = "second", .schema = "{}" },
    };
    // Comptime-only by construction: the catalogs are compile-time constants,
    // so the call has to be forced into a comptime context here too.
    const anthropic_json = comptime anthropicToolsJson(&specs);
    const openai_json = comptime openaiToolsJson(&specs);
    const responses_json = comptime responsesToolsJson(&specs);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"a\",\"description\":\"first\",\"input_schema\":{}},{\"name\":\"b\",\"description\":\"second\",\"input_schema\":{}}]",
        anthropic_json,
    );
    try std.testing.expect(std.mem.indexOf(u8, openai_json, "\"type\":\"function\",\"function\":{\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, responses_json, ",\"strict\":false}]"));
    // Every rendered catalog must still parse as JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, openai_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    // The runtime renderer writes the same bytes.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeToolsJson(&aw.writer, responses, &specs);
    try std.testing.expectEqualStrings(responses_json, aw.written());
}
