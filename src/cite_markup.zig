//! Provider citation control annotations (U+E200…U+E202).
//!
//! Hosted web search requires markers such as
//! `\u{E200}cite\u{E202}turn0view0\u{E201}`. Those private-use glyphs are not
//! a renderable citation on the line REPL or TUI, so they must be stripped
//! before copy-ready text, including `attempt_completion` results (#805, #811).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// UTF-8 U+E200 (annotation start), U+E201 (end), U+E202 (separator).
const pua_lead = [_]u8{ 0xEE, 0x88 };
const mark_start: u8 = 0x80;
const mark_end: u8 = 0x81;
const mark_sep: u8 = 0x82;

pub fn isMark(text: []const u8, i: usize) ?u8 {
    if (i + 2 >= text.len) return null;
    if (text[i] != pua_lead[0] or text[i + 1] != pua_lead[1]) return null;
    const b = text[i + 2];
    if (b < mark_start or b > mark_sep) return null;
    return b;
}

pub fn contains(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (isMark(text, i) != null) return true;
    }
    return false;
}

/// Index after a citation span starting at `i`, or `i` when `i` is not a mark.
pub fn skip(text: []const u8, i: usize) usize {
    const mark = isMark(text, i) orelse return i;
    if (mark != mark_start) return i + 3;
    var j = i + 3;
    while (j < text.len) {
        if (isMark(text, j) == mark_end) return j + 3;
        j += 1;
    }
    return text.len;
}

pub fn strippedLen(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const j = skip(text, i);
        if (j != i) {
            i = j;
            continue;
        }
        n += 1;
        i += 1;
    }
    return n;
}

/// Always a new slice owned by `alloc`.
pub fn dupe(alloc: Allocator, text: []const u8) ![]u8 {
    if (!contains(text)) return alloc.dupe(u8, text);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const j = skip(text, i);
        if (j != i) {
            i = j;
            continue;
        }
        try aw.writer.writeByte(text[i]);
        i += 1;
    }
    return aw.toOwnedSlice();
}

test "citation annotations strip to surrounding prose (#805, #811)" {
    const a = std.testing.allocator;
    const raw = "See the docs\u{E200}cite\u{E202}turn0view0\u{E201} for details.";
    try std.testing.expect(contains(raw));
    const got = try dupe(a, raw);
    defer a.free(got);
    try std.testing.expectEqualStrings("See the docs for details.", got);
    try std.testing.expectEqual(@as(usize, got.len), strippedLen(raw));
}

test "unpaired separator and end marks are dropped" {
    const a = std.testing.allocator;
    const raw = "a\u{E202}b\u{E201}c";
    const got = try dupe(a, raw);
    defer a.free(got);
    try std.testing.expectEqualStrings("abc", got);
}

test "clean text is unchanged" {
    const a = std.testing.allocator;
    const raw = "no citations here";
    try std.testing.expect(!contains(raw));
    const got = try dupe(a, raw);
    defer a.free(got);
    try std.testing.expectEqualStrings(raw, got);
}

test "open annotation at EOF is dropped" {
    const a = std.testing.allocator;
    const raw = "tail\u{E200}cite\u{E202}turn0search0";
    const got = try dupe(a, raw);
    defer a.free(got);
    try std.testing.expectEqualStrings("tail", got);
}
