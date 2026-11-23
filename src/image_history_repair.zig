//! Remove corrupt inline PNG blocks from restored conversation history.
const std = @import("std");
const vision = @import("vision.zig");
const png_integrity = @import("png_integrity.zig");

const placeholder = "[A corrupt PNG attachment was omitted from saved history. Re-export and attach it again if needed.]";
const png_data_prefix = "data:image/png;base64,";

/// Repair corrupt inline PNGs once when a saved session is loaded. Remote URLs,
/// other formats, and unknown provider block shapes are deliberately untouched.
pub fn repair(gpa: std.mem.Allocator, arena: std.mem.Allocator, history: *std.json.Array) !void {
    for (history.items) |*item| {
        if (item.* != .object) continue;
        const content = item.object.getPtr("content") orelse continue;
        if (content.* != .array) continue;
        for (content.array.items) |*block| {
            if (block.* != .object) continue;
            const data = inlinePngData(block.object) orelse continue;
            if (try isValidPngBase64(gpa, data)) continue;
            const kind = stringField(block.object, "type");
            var text_block: std.json.ObjectMap = .empty;
            try text_block.put(arena, "type", .{ .string = if (std.mem.eql(u8, kind, "input_image")) "input_text" else "text" });
            try text_block.put(arena, "text", .{ .string = placeholder });
            block.* = .{ .object = text_block };
        }
    }
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = obj.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

fn inlinePngData(block: std.json.ObjectMap) ?[]const u8 {
    const kind = stringField(block, "type");
    if (std.mem.eql(u8, kind, "input_image")) {
        const url = block.get("image_url") orelse return null;
        if (url != .string or !std.mem.startsWith(u8, url.string, png_data_prefix)) return null;
        return url.string[png_data_prefix.len..];
    }
    if (std.mem.eql(u8, kind, "image_url")) {
        const nested = block.get("image_url") orelse return null;
        if (nested != .object or !std.mem.startsWith(u8, stringField(nested.object, "url"), png_data_prefix)) return null;
        return stringField(nested.object, "url")[png_data_prefix.len..];
    }
    if (std.mem.eql(u8, kind, "image")) {
        if (block.get("source")) |source| if (source == .object and std.mem.eql(u8, stringField(source.object, "type"), "base64") and
            std.mem.eql(u8, stringField(source.object, "media_type"), "image/png")) return stringField(source.object, "data");
        if (std.mem.eql(u8, stringField(block, "mime_type"), "image/png")) return stringField(block, "data");
    }
    return null;
}

fn isValidPngBase64(gpa: std.mem.Allocator, data: []const u8) !bool {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(data) catch return false;
    const decoded = try gpa.alloc(u8, size);
    defer gpa.free(decoded);
    decoder.decode(decoded, data) catch return false;
    return png_integrity.valid(decoded);
}

const good_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00\x00\x3a\x7e\x9b\x55\x00\x00\x00\x0aIDATx\x9c\x63\x60\x00\x00\x00\x02\x00\x01\x48\xaf\xa4\x71\x00\x00\x00\x00IEND\xae\x42\x60\x82";

fn encoded(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const result = try a.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(result, bytes);
    return result;
}

test "#1926 restored inline PNGs are repaired for all provider wire shapes" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var corrupt: [good_png.len - 4]u8 = undefined;
    @memcpy(corrupt[0..29], good_png[0..29]);
    @memcpy(corrupt[29..], good_png[33..]);
    const bad_b64 = try encoded(arena, &corrupt);
    const good_b64 = try encoded(arena, good_png);
    const kinds = [_]@import("provider.zig").Provider.Kind{ .responses, .openai, .anthropic, .interactions };
    for (kinds) |kind| {
        const images = [_]vision.PendingImage{
            .{ .media_type = "image/png", .b64 = bad_b64, .label = "broken" },
            .{ .media_type = "image/png", .b64 = good_b64, .label = "good" },
            .{ .media_type = "image/png", .b64 = "", .url = "https://images.test/remote.png", .label = "remote" },
        };
        const msg = try vision.imageMessages(arena, kind, "caption", &images);
        var history = std.json.Array.init(arena);
        try history.append(msg);
        try repair(a, arena, &history);
        const content = history.items[0].object.get("content").?.array.items;
        try std.testing.expect(std.mem.eql(u8, stringField(content[1].object, "type"), if (kind == .responses) "input_text" else "text"));
        try std.testing.expect(std.mem.eql(u8, stringField(content[1].object, "text"), placeholder));
        try std.testing.expect(std.mem.eql(u8, stringField(content[2].object, "type"), if (kind == .responses) "input_image" else if (kind == .openai) "image_url" else "image"));
        try std.testing.expect(std.mem.eql(u8, stringField(content[3].object, "type"), if (kind == .responses) "input_image" else if (kind == .openai) "image_url" else if (kind == .interactions) "text" else "image"));
        try std.testing.expectEqualStrings(good_b64, inlinePngData(content[2].object).?);
        switch (kind) {
            .responses => try std.testing.expectEqualStrings("https://images.test/remote.png", content[3].object.get("image_url").?.string),
            .openai => try std.testing.expectEqualStrings("https://images.test/remote.png", content[3].object.get("image_url").?.object.get("url").?.string),
            .anthropic => try std.testing.expectEqualStrings("https://images.test/remote.png", content[3].object.get("source").?.object.get("url").?.string),
            .interactions => try std.testing.expectEqualStrings("[image: https://images.test/remote.png]", content[3].object.get("text").?.string),
        }
        const before = content[1].object.get("text").?.string;
        try repair(a, arena, &history);
        const after = history.items[0].object.get("content").?.array.items[1].object.get("text").?.string;
        try std.testing.expectEqualStrings(before, after);
    }
}
