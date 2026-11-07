//! Protocol result preservation shared by REPL, ACP and RLM host calls.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const content = @import("mcp_content.zig");
const CallResult = @import("mcp_call.zig").CallResult;
const testing = std.testing;

fn render(json: []const u8) !CallResult {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const result = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    var pending: ?@import("vision.zig").PendingImage = null;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const range = try content.renderResult(&out.writer, result.object, .{
        .arena = a,
        .slot = &pending,
        .label = "mcp__fixture__data",
        .supports_vision = false,
    }, a);
    const text = try out.toOwnedSlice();
    return .{ .text = text, .is_error = false, .structured_text = if (range) |r| text[r.start..r.end] else null };
}

test "MCP interoperability: human summaries do not suppress structured results or RLM binds" {
    const result = try render(
        \\{"content":[{"type":"text","text":"Done"}],"structuredContent":{"answer":42,"private_field":"kept"}}
    );
    try testing.expect(std.mem.indexOf(u8, result.text, "Done") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "\"answer\":42") != null);
    // The response arena has already died. RLM gets independent complete JSON,
    // not the summary, a slimmed object, or a slice dangling into that arena.
    const host = try result.takeHostText(testing.allocator);
    defer testing.allocator.free(host);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, host, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("answer").?.integer);
    try testing.expectEqualStrings("kept", parsed.value.object.get("private_field").?.string);
}

test "MCP interoperability: a serialized JSON text mirror is not duplicated" {
    const result = try render(
        \\{"content":[{"type":"text","text":"{ \"answer\": 42 }"}],"structuredContent":{"answer":42}}
    );
    defer testing.allocator.free(result.text);
    try testing.expectEqualStrings("{ \"answer\": 42 }", result.text);
    try testing.expectEqualStrings(result.text, result.structured_text.?);
}

test "MCP interoperability: structured-only results preserve every JSON value kind" {
    for ([_][]const u8{ "{\"answer\":42}", "[1,2,3]", "\"answer\"", "42", "true", "null" }) |json| {
        const source = try std.fmt.allocPrint(testing.allocator, "{{\"structuredContent\":{s}}}", .{json});
        defer testing.allocator.free(source);
        const result = try render(source);
        defer testing.allocator.free(result.text);
        try testing.expectEqualStrings(json, result.text);
        try testing.expectEqualStrings(json, result.structured_text.?);
    }
}

test "MCP interoperability: resource links and embedded text remain visible without fetching" {
    const result = try render(
        \\{"content":[{"type":"resource_link","uri":"fixture://report","name":"Report","description":"Full result"},{"type":"resource","resource":{"uri":"fixture://source","mimeType":"text/plain","text":"nested resource body"}}]}
    );
    defer testing.allocator.free(result.text);
    try testing.expect(std.mem.indexOf(u8, result.text, "Report: fixture://report") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "Full result") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "fixture://source") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "nested resource body") != null);
    try testing.expect(result.structured_text == null);
}

test "MCP interoperability: unsupported media and malformed resources are explicit" {
    const result = try render(
        \\{"content":[{"type":"resource","resource":{"uri":"fixture://binary","mimeType":"application/octet-stream","blob":"b3BhcXVl"}},{"type":"audio","mimeType":"audio/wav","data":"b3BhcXVl"},{"type":"resource"},{"type":"resource","resource":null}]}
    );
    defer testing.allocator.free(result.text);
    try testing.expect(std.mem.indexOf(u8, result.text, "binary resource (application/octet-stream); payload not rendered") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "MCP audio (audio/wav); payload not rendered") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "missing resource") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "malformed resource") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "b3BhcXVl") == null);
}

test "MCP interoperability: image placeholders cannot hide structured content and plain text stays unchanged" {
    const image = try render(
        \\{"content":[{"type":"image","mimeType":"image/png","data":"aGVsbG8="}],"structuredContent":{"image_count":1}}
    );
    defer testing.allocator.free(image.text);
    try testing.expect(std.mem.indexOf(u8, image.text, "image") != null);
    try testing.expectEqualStrings("{\"image_count\":1}", image.structured_text.?);
    const plain = try render(
        \\{"content":[{"type":"text","text":"original text"}]}
    );
    const host = try plain.takeHostText(testing.allocator);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("original text", host);
}
