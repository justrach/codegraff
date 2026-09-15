//! Differential coverage for the byte-stream citation filter (#874).
const std = @import("std");
const markup = @import("cite_markup.zig");
const a = std.testing.allocator;
const start = "\u{E200}";
const end = "\u{E201}";
const sep = "\u{E202}";

fn feed(stream: *markup.Stream, output: *std.Io.Writer.Allocating, chunk: []const u8) !void {
    for (chunk) |byte| {
        var buf: [3]u8 = undefined;
        try output.writer.writeAll(stream.byte(byte, &buf));
    }
}

// Chunk boundaries intentionally include UTF-8 continuation bytes. Empty chunks
// must neither flush a pending marker prefix nor reset annotation suppression.
fn checkChunks(raw: []const u8, expected: []const u8, width: usize, seed: ?u64) !void {
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var stream: markup.Stream = .{};
    var random = std.Random.DefaultPrng.init(seed orelse 0);
    var offset: usize = 0;
    try feed(&stream, &output, "");
    while (offset < raw.len) {
        const n = @min(raw.len - offset, if (seed != null) random.random().intRangeAtMost(usize, 1, width) else width);
        try feed(&stream, &output, raw[offset .. offset + n]);
        try feed(&stream, &output, "");
        offset += n;
    }
    try feed(&stream, &output, "");
    try std.testing.expectEqualStrings(expected, output.written());
}

fn check(raw: []const u8, known: ?[]const u8, every_split: bool) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(raw));
    const expected = try markup.dupe(a, raw);
    defer a.free(expected);
    if (known) |text| try std.testing.expectEqualStrings(text, expected);
    try checkChunks(raw, expected, 1, null);
    try checkChunks(raw, expected, @max(raw.len, 1), null);
    for ([_]usize{ 2, 3, 7, 31 }) |width| try checkChunks(raw, expected, width, null);
    for ([_]u64{ 0, 1, 874, 0xdeadbeef }) |seed| try checkChunks(raw, expected, 47, seed);
    if (every_split) {
        for (0..raw.len + 1) |split| {
            var output: std.Io.Writer.Allocating = .init(a);
            defer output.deinit();
            var stream: markup.Stream = .{};
            try feed(&stream, &output, raw[0..split]);
            try feed(&stream, &output, "");
            try feed(&stream, &output, raw[split..]);
            try std.testing.expectEqualStrings(expected, output.written());
        }
    }
}

test "stream preserves ordinary UTF-8 and unrelated private-use glyphs" {
    try check("", "", true);
    try check("plain\x00text\n\t\r", "plain\x00text\n\t\r", true);
    const text = "é e\u{301} 日本語 😀 \u{E000}\u{E1FF}\u{E203}\u{E23F}\u{E240}\u{F8FF}\u{F0000}\u{10FFFD}";
    try check(text, text, true);
    // Exhaust the BMP private-use range, including every non-marker sharing
    // either one or two marker-prefix bytes, both visible and hidden.
    var raw: std.Io.Writer.Allocating = .init(a);
    defer raw.deinit();
    for (0xE000..0xF900) |cp| {
        if (cp >= 0xE200 and cp <= 0xE202) continue;
        var encoded: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(@intCast(cp), &encoded);
        try raw.writer.writeAll(encoded[0..n]);
    }
    try check(raw.written(), raw.written(), false);
    try raw.writer.writeAll(start);
    // A second copy inside an unclosed annotation must not escape.
    const visible_len = raw.written().len - start.len;
    const visible = try a.dupe(u8, raw.written()[0..visible_len]);
    defer a.free(visible);
    try raw.writer.writeAll(visible);
    try check(raw.written(), visible, false);
}

test "stream adjacent nested unclosed and standalone annotations match batch semantics" {
    const Case = struct { raw: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .raw = start ++ end, .want = "" },
        .{ .raw = start, .want = "" },
        .{ .raw = end ++ sep ++ end, .want = "" },
        .{ .raw = "a" ++ sep ++ "b" ++ end ++ "c", .want = "abc" },
        .{ .raw = "a" ++ start ++ "cite" ++ sep ++ "turn0search0" ++ end ++ "b", .want = "ab" },
        .{ .raw = "a" ++ start ++ "one" ++ end ++ start ++ "two" ++ end ++ "b", .want = "ab" },
        // Batch stripping ends at the first end mark, not at balanced depth.
        .{ .raw = "a" ++ start ++ "outer" ++ start ++ "inner" ++ end ++ "visible" ++ end ++ "b", .want = "avisibleb" },
        .{ .raw = "a" ++ start ++ "unclosed 😀\u{E203}", .want = "a" },
        .{ .raw = "a" ++ start ++ start ++ sep, .want = "a" },
        .{ .raw = "\u{E203}" ++ start ++ "\u{E203}\u{E240}日本語" ++ end ++ "\u{E240}", .want = "\u{E203}\u{E240}" },
        .{ .raw = start ++ "x" ++ sep ++ sep ++ "y" ++ end ++ "😀" ++ start ++ "tail", .want = "😀" },
    };
    for (cases) |case| try check(case.raw, case.want, true);
}

test "stream exhausts short delimiter and unicode combinations" {
    const atoms = [_][]const u8{ "x", start, end, sep, "\u{E203}", "\u{E240}", "😀" };
    var raw: std.Io.Writer.Allocating = .init(a);
    defer raw.deinit();
    for (atoms) |first| for (atoms) |second| for (atoms) |third| {
        raw.clearRetainingCapacity();
        try raw.writer.writeAll(first);
        try raw.writer.writeAll(second);
        try raw.writer.writeAll(third);
        try check(raw.written(), null, true);
    };
}

test "stream suppresses long payload without truncating resumed prose" {
    var raw: std.Io.Writer.Allocating = .init(a);
    defer raw.deinit();
    try raw.writer.writeAll("before 😀" ++ start);
    for (0..8192) |_| try raw.writer.writeAll("payload\u{E203}\u{E240}日本語" ++ sep);
    try check(raw.written(), "before 😀", false);
    try raw.writer.writeAll(end ++ "after é" ++ start ++ "next" ++ end ++ "!");
    try check(raw.written(), "before 😀after é!", false);
}
