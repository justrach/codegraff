//! Conservative JSON context estimates that treat inline image bytes as media,
//! not ordinary text. Providers tokenize images from decoded dimensions/content;
//! the Base64 transport size is not part of the language-model context.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

/// One image can still consume meaningful vision context. This bound is high
/// enough for detailed screenshots while keeping one fresh attachment inside
/// compaction's 8k recent-turn preservation budget.
pub const image_tokens: u64 = 4_096;

const MediaStats = struct {
    payload_bytes: usize = 0,
    images: u64 = 0,

    fn add(self: *MediaStats, other: MediaStats) void {
        self.payload_bytes +|= other.payload_bytes;
        self.images +|= other.images;
    }
};

fn stringValue(value: ?Value) ?[]const u8 {
    const found = value orelse return null;
    return if (found == .string) found.string else null;
}

fn dataImagePayloadLen(uri: []const u8) ?usize {
    if (!std.mem.startsWith(u8, uri, "data:image/")) return null;
    const marker = ";base64,";
    const marker_start = std.mem.indexOf(u8, uri, marker) orelse return null;
    return uri.len - (marker_start + marker.len);
}

fn imageBlockPayloadLen(obj: std.json.ObjectMap) ?usize {
    const kind = stringValue(obj.get("type")) orelse return null;
    if (std.mem.eql(u8, kind, "image_url")) {
        const image_url = obj.get("image_url") orelse return null;
        const uri = switch (image_url) {
            .string => |s| s,
            .object => |nested| stringValue(nested.get("url")) orelse return null,
            else => return null,
        };
        return dataImagePayloadLen(uri);
    }
    if (std.mem.eql(u8, kind, "input_image")) {
        return dataImagePayloadLen(stringValue(obj.get("image_url")) orelse return null);
    }
    if (std.mem.eql(u8, kind, "image")) {
        const source = obj.get("source") orelse return null;
        if (source != .object) return null;
        if (!std.mem.eql(u8, stringValue(source.object.get("type")) orelse return null, "base64")) return null;
        return (stringValue(source.object.get("data")) orelse return null).len;
    }
    return null;
}

fn mediaStats(value: Value) MediaStats {
    var stats: MediaStats = .{};
    switch (value) {
        .array => |items| for (items.items) |item| stats.add(mediaStats(item)),
        .object => |obj| {
            if (imageBlockPayloadLen(obj)) |payload_bytes| {
                stats.payload_bytes +|= payload_bytes;
                stats.images +|= 1;
            }
            var it = obj.iterator();
            while (it.next()) |entry| stats.add(mediaStats(entry.value_ptr.*));
        },
        else => {},
    }
    return stats;
}

/// Count default JSON bytes without formatting the common history tree. This
/// walks live values on every call: no stale cache after in-place compaction,
/// tool-result repair, or a history replacement. Keep the serializer as the
/// authority for number formatting, invalid UTF-8, and other Zig types.
pub fn serializedLen(value: anytype) usize {
    if (@TypeOf(value) == Value) return valueLen(value);
    if (@TypeOf(value) == []const u8 or @TypeOf(value) == []u8) return stringLen(value);
    return stringifyLen(value);
}

fn stringifyLen(value: anytype) usize {
    var buf: [512]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&buf);
    var stringify: std.json.Stringify = .{ .writer = &discarding.writer };
    stringify.write(value) catch return discarding.fullCount();
    return discarding.fullCount();
}

fn valueLen(value: Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |b| if (b) 4 else 5,
        .string => |s| stringLen(s),
        .number_string => |s| s.len,
        .integer, .float => stringifyLen(value),
        .array => |items| blk: {
            var count: usize = 2 +| (items.items.len -| 1);
            for (items.items) |item| count +|= valueLen(item);
            break :blk count;
        },
        .object => |obj| blk: {
            var count: usize = 2 +| (obj.count() -| 1);
            var it = obj.iterator();
            while (it.next()) |entry| {
                // objectField encodes key bytes directly; unlike string values,
                // invalid UTF-8 keys are not converted into numeric arrays.
                count +|= encodedStringLen(entry.key_ptr.*) +| 1;
                count +|= valueLen(entry.value_ptr.*);
            }
            break :blk count;
        },
    };
}

fn stringLen(text: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(text)) return stringifyLen(text);
    return encodedStringLen(text);
}

/// Default Stringify leaves Unicode and '/' alone, escapes quotes/backslashes,
/// and uses either a two-byte short escape or six-byte \u00XX for controls.
fn encodedStringLen(text: []const u8) usize {
    var count: usize = text.len +| 2;
    var i: usize = 0;
    const width = 16;
    const Bytes = @Vector(width, u8);
    while (i < text.len) {
        if (text.len - i >= width) {
            const bytes: Bytes = text[i..][0..width].*;
            const controls = bytes < @as(Bytes, @splat(0x20));
            const quotes = bytes == @as(Bytes, @splat('"'));
            const slashes = bytes == @as(Bytes, @splat('\\'));
            if (@reduce(.Or, controls) or @reduce(.Or, quotes) or @reduce(.Or, slashes)) {
                for (text[i..][0..width]) |byte| count +|= escapeExtra(byte);
            }
            i += width;
            continue;
        }
        count +|= escapeExtra(text[i]);
        i += 1;
    }
    return count;
}

fn escapeExtra(byte: u8) usize {
    return switch (byte) {
        '"', '\\', 0x08, 0x0c, '\n', '\r', '\t' => 1,
        0...7, 0x0b, 0x0e...0x1f => 5,
        else => 0,
    };
}

/// Estimate a JSON container when its serialized byte count is already known.
/// Inline image payloads are removed from the text estimate and replaced by a
/// bounded per-image vision estimate; every other byte retains the prior /4
/// policy so tool output and reasoning overflow protection stays conservative.
pub fn estimatedTokensFromLen(value: Value, total_bytes: usize) u64 {
    const media = mediaStats(value);
    const text_bytes = total_bytes -| media.payload_bytes;
    return @as(u64, @intCast(text_bytes / 4)) +| media.images *| image_tokens;
}

pub fn estimatedTokens(value: Value) u64 {
    return estimatedTokensFromLen(value, serializedLen(value));
}

test "inline image payload size does not masquerade as text context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const payload = try arena.alloc(u8, 1_600_000);
    @memset(payload, 'A');
    const uri = try std.fmt.allocPrint(arena, "data:image/png;base64,{s}", .{payload});
    var image_url: std.json.ObjectMap = .empty;
    try image_url.put(arena, "url", .{ .string = uri });
    var block: std.json.ObjectMap = .empty;
    try block.put(arena, "type", .{ .string = "image_url" });
    try block.put(arena, "image_url", .{ .object = image_url });

    const value: Value = .{ .object = block };
    try std.testing.expect(serializedLen(value) / 4 > 390_000);
    try std.testing.expect(estimatedTokens(value) >= image_tokens);
    try std.testing.expect(estimatedTokens(value) < 5_000);
}

test "ordinary large strings remain fully counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try arena.alloc(u8, 40_000);
    @memset(text, 'A');
    try std.testing.expect(estimatedTokens(.{ .string = text }) >= 10_000);
}

fn expectSerializedLen(value: anytype) !void {
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(encoded.len, serializedLen(value));
}

test "JSON length matches serializer for every single byte and Unicode" {
    for (0..256) |byte| {
        const text = [_]u8{@intCast(byte)};
        try expectSerializedLen(Value{ .string = &text });
    }
    for ([_][]const u8{ "", "hello", "a\"b\\c\n\t", "日本語 😀 café", "\xe2\x80\xa8", "\xc0\x80", "\xed\xa0\x80" }) |text| {
        try expectSerializedLen(Value{ .string = text });
        try expectSerializedLen(text);
    }
}

test "JSON length matches serializer at vector boundaries and mixed controls" {
    var text: [257]u8 = @splat('x');
    for (0..64) |position| {
        for ([_]u8{ 0, '\n', '\r', '\t', '"', '\\', 0x1f, 0x7f }) |byte| {
            text[position] = byte;
            for ([_]usize{ position + 1, 64, 257 }) |len| {
                try expectSerializedLen(Value{ .string = text[0..len] });
            }
        }
        text[position] = 'x';
    }
    for (&text, 0..) |*byte, i| byte.* = @intCast(i % 128);
    try expectSerializedLen(Value{ .string = &text });
}

test "JSON length matches nested containers keys and numeric formatting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(Value, arena, "{\"escaped\\nkey\": [null,true,false,0,-9223372036854775808,1.25,1e100,{},[],\"line\\ntext\"],\"é\":42}", .{});
    try expectSerializedLen(value);
    try expectSerializedLen(Value{ .number_string = "123456789012345678901234567890" });
    for ([_]f64{ 0, -0.0, 1.0e-100, std.math.inf(f64), std.math.nan(f64) }) |n| {
        try expectSerializedLen(Value{ .float = n });
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "\xff\n", .{ .string = "\xff" });
    try expectSerializedLen(Value{ .object = obj });
}

test "JSON length observes edits replacement and truncation without cached state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.json.Array = .init(arena);
    try items.append(.{ .string = "long original message" });
    const original = serializedLen(Value{ .array = items });
    items.items[0] = .{ .string = "short" };
    try std.testing.expect(serializedLen(Value{ .array = items }) < original);
    try expectSerializedLen(Value{ .array = items });
    try items.append(.{ .string = "another message\n" });
    try expectSerializedLen(Value{ .array = items });
    items.shrinkRetainingCapacity(0);
    try std.testing.expectEqual(@as(usize, 2), serializedLen(Value{ .array = items }));
}

test "JSON length retains generic Zig serialization contracts" {
    try expectSerializedLen(.{ .name = "generic\nstruct", .count = @as(u32, 42) });
    try expectSerializedLen([_]u8{ 0xff, 0x00 });
    try expectSerializedLen(@as(?u32, null));
}
