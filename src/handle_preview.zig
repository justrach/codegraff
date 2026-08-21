//! Notable-line excerpt for a #440 handle preview.
//!
//! The first payload a spill returns is the HEAD of the result. A needle in
//! the middle (a single FAILED line in a 168 KiB log) is invisible there, so
//! the model pays a follow-up page. This file pulls a bounded set of
//! error-shaped lines into that first payload so the common "what broke?"
//! question does not need the pager. The full bytes still live only on disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Substrings that mark a line worth surfacing. Matched case-insensitively
/// as a literal, so `fail` hits `FAILED` and `error` hits `level=ERROR`.
pub const notable_needles = [_][]const u8{
    "error",
    "fail",
    "exception",
    "panic",
    "fatal",
    "traceback",
};

pub const max_notable_lines: usize = 8;
pub const max_notable_bytes: usize = 2048;

/// Inclusive-start, exclusive-end of the line that contains `at`.
pub fn lineBounds(text: []const u8, at: usize) struct { lo: usize, hi: usize } {
    const pos = @min(at, text.len);
    const lo = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |n| n + 1 else 0;
    const hi = if (std.mem.indexOfScalar(u8, text[pos..], '\n')) |n| pos + n else text.len;
    return .{ .lo = lo, .hi = hi };
}

pub fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn lineIsNotable(line: []const u8) bool {
    for (notable_needles) |n| {
        if (indexOfIgnoreCase(line, n) != null) return true;
    }
    return false;
}

/// Lines after `skip_before` that look like failures, capped. Empty when
/// nothing qualifies or `budget` cannot hold the header plus one line.
pub fn notableExcerpt(arena: Allocator, text: []const u8, skip_before: usize, budget: usize) ![]const u8 {
    if (budget < 40 or skip_before >= text.len) return "";
    var lines: std.ArrayList([]const u8) = .empty;
    var i = skip_before;
    if (i > 0 and text[i - 1] != '\n') {
        if (std.mem.indexOfScalar(u8, text[i..], '\n')) |n| i += n + 1 else return "";
    }
    while (i < text.len and lines.items.len < max_notable_lines) {
        const nl = std.mem.indexOfScalar(u8, text[i..], '\n');
        const end = if (nl) |n| i + n else text.len;
        const line = text[i..end];
        if (lineIsNotable(line)) try lines.append(arena, line);
        i = if (nl) |n| i + n + 1 else text.len;
    }
    if (lines.items.len == 0) return "";

    var body: std.Io.Writer.Allocating = .init(arena);
    try body.writer.print("[notable lines, {d} match", .{lines.items.len});
    if (lines.items.len != 1) try body.writer.writeByte('e');
    try body.writer.writeAll("]\n");
    for (lines.items) |line| {
        try body.writer.writeAll(line);
        try body.writer.writeByte('\n');
    }
    const out = body.writer.buffered();
    if (out.len > budget) return "";
    return out;
}

test "lineBounds includes the whole line, not an 80-byte pad" {
    const text = "aaa\nrequest_id=req-1 status=FAILED reason=boom\nzzz";
    const at = std.mem.indexOf(u8, text, "FAILED").?;
    const b = lineBounds(text, at);
    try std.testing.expectEqualStrings("request_id=req-1 status=FAILED reason=boom", text[b.lo..b.hi]);
}

test "notableExcerpt pulls a FAILED line that sits past the head" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const head = try a.alloc(u8, 600);
    @memset(head, 'x');
    head[head.len - 1] = '\n';
    const fail = "request_id=req-8c41de07 status=FAILED reason=undefined_symbol\n";
    const text = try std.fmt.allocPrint(a, "{s}{s}tail\n", .{ head, fail });
    const excerpt = try notableExcerpt(a, text, head.len, 512);
    try std.testing.expect(std.mem.indexOf(u8, excerpt, "req-8c41de07") != null);
    try std.testing.expect(std.mem.indexOf(u8, excerpt, "FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, excerpt, "1 match") != null);
}

test "notableExcerpt stays empty when nothing looks like a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const excerpt = try notableExcerpt(a, "cache=miss status=OK\nall good\n", 0, 512);
    try std.testing.expectEqualStrings("", excerpt);
}
