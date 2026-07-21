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

/// Count a JSON value's serialized bytes without allocating its output.
pub fn serializedLen(value: anytype) usize {
    var buf: [512]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&buf);
    var stringify: std.json.Stringify = .{ .writer = &discarding.writer };
    stringify.write(value) catch return discarding.fullCount();
    return discarding.fullCount();
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
