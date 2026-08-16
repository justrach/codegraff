//! Capture-contract tests for the drag band (#529). They drive `selection.paint`
//! over a hand-written frame, so they hold what lands on the CLIPBOARD rather
//! than any one helper's shape. Split out of selection.zig for the 600-line
//! ceiling.
//!
//! The contract: the band is a rectangle over the frame, the capture is the
//! text under it. Blank rows contribute nothing, the blanks at either end of
//! the drag fall off, an interior run of them collapses to one empty line, and
//! every row loses its trailing blanks.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const selection = @import("selection.zig");
const Model = app.Model;

const paint = selection.paint;

var copied: [4096]u8 = undefined;
var copied_len: usize = 0;

fn fakeCopy(_: ?*anyopaque, text: []const u8) bool {
    copied_len = @min(text.len, copied.len);
    @memcpy(copied[0..copied_len], text[0..copied_len]);
    return true;
}

test "column bounds hold on the first and last row; middle rows are whole" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 10;
    m.mid_origin = 0;
    m.prompt_origin = 5;
    m.sel = .{ .active = true, .a_row = 0, .a_col = 3, .h_row = 2, .h_col = 4 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try paint(&m, arena.allocator(), "abcdefghij\nklmnopqrst\nuvwxyz\nTAIL", 10);
    // First row starts at column 3, last row ends after column 4.
    try std.testing.expect(std.mem.indexOf(u8, out, "abc\x1b[7mdefghij") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7muvwxy\x1b[27m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "TAIL") != null);
    try std.testing.expectEqualStrings("defghij\nklmnopqrst\nuvwxy", m.sel_text);
    try std.testing.expectEqual(@as(usize, 3), m.sel.text_rows);
    // A row shorter than the band is padded, and the pad is not text.
    m.sel = .{ .active = true, .a_row = 0, .a_col = 0, .h_row = 0, .h_col = 9 };
    const short = try paint(&m, arena.allocator(), "hi", 10);
    try std.testing.expect(std.mem.indexOf(u8, short, "\x1b[7mhi        \x1b[27m") != null);
    try std.testing.expectEqualStrings("hi", m.sel_text);
}

test "the band drops SGR inside it and restores the style after it" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 12;
    m.mid_origin = 0;
    m.prompt_origin = 4;
    m.sel = .{ .active = true, .a_row = 0, .a_col = 2, .h_row = 0, .h_col = 5 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try paint(&m, arena.allocator(), "ab\x1b[31mcdef\x1b[0mgh", 12);
    // No reset survives inside the band...
    const b0 = std.mem.indexOf(u8, out, "\x1b[7m").?;
    const b1 = std.mem.indexOf(u8, out, "\x1b[27m").?;
    try std.testing.expect(std.mem.indexOf(u8, out[b0..b1], "\x1b[") == 0);
    try std.testing.expect(std.mem.indexOf(u8, out[b0 + 4 .. b1], "\x1b[") == null);
    try std.testing.expectEqualStrings("cdef", m.sel_text);
}

test "a wide glyph never straddles a band edge" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 10;
    m.mid_origin = 0;
    m.prompt_origin = 4;
    // "a" + 世 (2 cols) + "b": a band ending mid-glyph must leave it out.
    m.sel = .{ .active = true, .a_row = 0, .a_col = 0, .h_row = 0, .h_col = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try paint(&m, arena.allocator(), "a\u{4e16}b", 10);
    try std.testing.expectEqualStrings("a", m.sel_text);
    // The excluded glyph leaves a pad column so the band still measures 2, and
    // the glyph itself paints outside it, whole.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7ma \x1b[27m") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\u{4e16}b"));
}

test "blank rows at the ends drop and an interior run collapses to one line" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 12;
    m.mid_origin = 0;
    m.prompt_origin = 9;
    // The drag covers all eight rows: two of leading padding, a text row, a
    // three-row gap, another text row, then the empty screen below.
    m.sel = .{ .active = true, .a_row = 0, .a_col = 0, .h_row = 7, .h_col = 11 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = "\n   \nalpha one\n\n    \n\nbeta two\n        ";
    const out = try paint(&m, arena.allocator(), frame, 12);
    // The band still PAINTS every covered row — only the capture is text-only.
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, out, "\x1b[7m"));
    try std.testing.expectEqualStrings("alpha one\n\nbeta two", m.sel_text);
    try std.testing.expectEqual(@as(usize, 2), m.sel.text_rows);
}

test "every captured row is trimmed, column-bounded first and last included" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 16;
    m.mid_origin = 0;
    m.prompt_origin = 4;
    // First row bounded at column 2, last row bounded after column 11 — both
    // end inside a run of spaces, and neither may carry them out.
    m.sel = .{ .active = true, .a_row = 0, .a_col = 2, .h_row = 2, .h_col = 11 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try paint(&m, arena.allocator(), "xxfirst     \nmid   \nlast        zzzz", 16);
    try std.testing.expectEqualStrings("first\nmid\nlast", m.sel_text);
    try std.testing.expectEqual(@as(usize, 3), m.sel.text_rows);
    // The painted band keeps its full width; only the capture is trimmed.
    try std.testing.expect(std.mem.indexOf(u8, out, "xx\x1b[7mfirst     ") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "zzzz"));
}

test "a band over nothing but padding copies nothing and shows no toast" {
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    copied_len = @min("SENTINEL".len, copied.len);
    @memcpy(copied[0..copied_len], "SENTINEL");
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 12;
    m.mid_origin = 0;
    m.prompt_origin = 5;
    m.sel = .{ .active = true, .a_row = 0, .a_col = 0, .h_row = 3, .h_col = 11, .copy_pending = true };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try paint(&m, arena.allocator(), "\n    \n\n        \nTAIL", 12);
    try std.testing.expectEqualStrings("SENTINEL", copied[0..copied_len]);
    try std.testing.expectEqual(@as(usize, 0), m.sel_text.len);
    try std.testing.expectEqual(@as(usize, 0), m.sel.text_rows);
    try std.testing.expectEqualStrings("", m.toast);
    try std.testing.expect(!m.sel.active);
}
