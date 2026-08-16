//! Bounded native text-file reads. Whole-file reads return a small actionable
//! preview when the file exceeds the tool cap; explicit line windows stream
//! through large files without first allocating their entire contents.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const binaryFileExt = @import("input_util.zig").binaryFileExt;

pub const max_bytes: usize = 256 * 1024;
pub const preview_bytes: usize = 1536;

pub const Truncated = struct {
    head: []u8,
    total_bytes: u64,
};

pub const Result = union(enum) {
    text: []u8,
    truncated: Truncated,
    binary: u64,
    range_too_large,
    start_past_end,
    no_match,
};

fn normalizedBounds(start_opt: ?i64, end_opt: ?i64) ?struct { start: usize, end: usize } {
    const start: usize = if (start_opt) |value| (if (value < 1) 1 else @intCast(value)) else 1;
    const end: usize = if (end_opt) |value| (if (value < 1) 1 else @intCast(value)) else std.math.maxInt(usize);
    if (end < start) return null;
    return .{ .start = start, .end = end };
}

fn readPrefix(io: Io, file: Io.File, size: u64, buffer: []u8) ![]const u8 {
    const want: usize = @intCast(@min(size, buffer.len));
    const got = try file.readPositionalAll(io, buffer[0..want], 0);
    if (got != want) return error.UnexpectedEndOfFile;
    return buffer[0..got];
}

fn readWindow(io: Io, gpa: Allocator, file: Io.File, size: u64, start_opt: ?i64, end_opt: ?i64) !Result {
    const bounds = normalizedBounds(start_opt, end_opt) orelse return .start_past_end;
    if (size == 0) return .start_past_end;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var line: usize = 1;
    var reached_start = bounds.start == 1;

    while (offset < size) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), size - offset));
        const got = try file.readPositionalAll(io, buffer[0..want], offset);
        if (got != want) return error.UnexpectedEndOfFile;
        offset += got;
        for (buffer[0..got]) |byte| {
            if (line >= bounds.start and line <= bounds.end) {
                if (output.items.len == max_bytes) return .range_too_large;
                try output.append(gpa, byte);
            }
            if (byte != '\n') continue;
            if (line == bounds.end) return .{ .text = try output.toOwnedSlice(gpa) };
            line +|= 1;
            if (line == bounds.start) reached_start = true;
        }
    }
    if (!reached_start) return .start_past_end;
    return .{ .text = try output.toOwnedSlice(gpa) };
}

fn appendLiteralMatch(gpa: Allocator, output: *std.ArrayList(u8), line_bytes: []const u8, line_number: usize, needle: []const u8) !bool {
    if (std.mem.indexOf(u8, line_bytes, needle) == null) return true;
    var prefix_buffer: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "{d}: ", .{line_number}) catch return false;
    const needed = prefix.len + line_bytes.len;
    if (needed > max_bytes or output.items.len > max_bytes - needed) return false;
    try output.appendSlice(gpa, prefix);
    try output.appendSlice(gpa, line_bytes);
    return true;
}

fn readMatches(io: Io, gpa: Allocator, file: Io.File, size: u64, needle: []const u8) !Result {
    if (needle.len == 0 or size == 0) return .no_match;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var current_line: std.ArrayList(u8) = .empty;
    defer current_line.deinit(gpa);
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var line_number: usize = 1;

    while (offset < size) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), size - offset));
        const got = try file.readPositionalAll(io, buffer[0..want], offset);
        if (got != want) return error.UnexpectedEndOfFile;
        offset += got;
        for (buffer[0..got]) |byte| {
            if (current_line.items.len == max_bytes) return .range_too_large;
            try current_line.append(gpa, byte);
            if (byte != '\n') continue;
            if (!try appendLiteralMatch(gpa, &output, current_line.items, line_number, needle)) return .range_too_large;
            current_line.clearRetainingCapacity();
            line_number +|= 1;
        }
    }
    if (current_line.items.len > 0 and !try appendLiteralMatch(gpa, &output, current_line.items, line_number, needle))
        return .range_too_large;
    if (output.items.len == 0) return .no_match;
    return .{ .text = try output.toOwnedSlice(gpa) };
}

/// Reads from `dir` with bounded buffers. The caller owns `text` and
/// `truncated.head` results.
pub fn read(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, start_line: ?i64, end_line: ?i64, contains: ?[]const u8) !Result {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.IsDir;
    if (binaryFileExt(path)) return .{ .binary = before.size };

    var prefix_buffer: [4096]u8 = undefined;
    const prefix = try readPrefix(io, file, before.size, &prefix_buffer);
    if (std.mem.indexOfScalar(u8, prefix, 0) != null) return .{ .binary = before.size };

    if (contains) |needle| return readMatches(io, gpa, file, before.size, needle);
    if (start_line != null or end_line != null)
        return readWindow(io, gpa, file, before.size, start_line, end_line);

    if (before.size > max_bytes) return .{ .truncated = .{
        .head = try gpa.dupe(u8, prefix[0..@min(prefix.len, preview_bytes)]),
        .total_bytes = before.size,
    } };

    const bytes = try gpa.alloc(u8, @intCast(before.size));
    errdefer gpa.free(bytes);
    const got = try file.readPositionalAll(io, bytes, 0);
    if (got != bytes.len) return error.UnexpectedEndOfFile;
    return .{ .text = bytes };
}

test "large whole reads preview while line windows stream byte-exactly" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const large = try gpa.alloc(u8, max_bytes + 64);
    defer gpa.free(large);
    @memset(large, 'x');
    large[large.len - 13] = '\n';
    @memcpy(large[large.len - 12 ..], "target\nlast\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large.txt", .data = large });

    const whole = try read(std.testing.io, gpa, tmp.dir, "large.txt", null, null, null);
    switch (whole) {
        .truncated => |value| {
            defer gpa.free(value.head);
            try std.testing.expectEqual(@as(u64, large.len), value.total_bytes);
            try std.testing.expectEqual(@as(usize, preview_bytes), value.head.len);
        },
        else => return error.TestExpectedTruncated,
    }

    const window = try read(std.testing.io, gpa, tmp.dir, "large.txt", 2, 3, null);
    switch (window) {
        .text => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("target\nlast\n", text);
        },
        else => return error.TestExpectedText,
    }
}

test "streamed windows preserve the original line-slice semantics" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.txt", .data = "a\nb\nc\nd\n" });

    const cases = [_]struct { start: ?i64, end: ?i64, expected: ?[]const u8 }{
        .{ .start = null, .end = null, .expected = "a\nb\nc\nd\n" },
        .{ .start = 1, .end = 1, .expected = "a\n" },
        .{ .start = 2, .end = 3, .expected = "b\nc\n" },
        .{ .start = 3, .end = 99, .expected = "c\nd\n" },
        .{ .start = 99, .end = 100, .expected = null },
    };
    for (cases) |case| {
        const outcome = try read(std.testing.io, gpa, tmp.dir, "small.txt", case.start, case.end, null);
        if (case.expected) |expected| switch (outcome) {
            .text => |text| {
                defer gpa.free(text);
                try std.testing.expectEqualStrings(expected, text);
            },
            else => return error.TestExpectedText,
        } else try std.testing.expect(outcome == .start_past_end);
    }

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unterminated.txt", .data = "x\ny" });
    const final_line = try read(std.testing.io, gpa, tmp.dir, "unterminated.txt", 2, 2, null);
    switch (final_line) {
        .text => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("y", text);
        },
        else => return error.TestExpectedText,
    }
}

test "oversized requested line fails bounded instead of StreamTooLong" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const large = try gpa.alloc(u8, max_bytes + 1);
    defer gpa.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one-line.txt", .data = large });
    try std.testing.expect((try read(std.testing.io, gpa, tmp.dir, "one-line.txt", 1, 1, null)) == .range_too_large);
}

test "literal matching streams only numbered target lines" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "catalog.txt", .data = "alpha\nSKU0420 price=685 stock=105\nomega SKU0420\nlast" });

    const matches = try read(std.testing.io, gpa, tmp.dir, "catalog.txt", null, null, "SKU0420");
    switch (matches) {
        .text => |text| {
            defer gpa.free(text);
            try std.testing.expectEqualStrings("2: SKU0420 price=685 stock=105\n3: omega SKU0420\n", text);
        },
        else => return error.TestExpectedText,
    }
    try std.testing.expect((try read(std.testing.io, gpa, tmp.dir, "catalog.txt", null, null, "missing")) == .no_match);
}
