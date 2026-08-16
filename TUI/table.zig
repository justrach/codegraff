//! GitHub-flavoured markdown tables, drawn as a Grok-style box grid.
//!
//! Split out of markdown.zig, which the merge of the diff-banding and
//! stream-markdown work pushed past the 600-line ceiling. The seam is a real
//! one: everything here is about a GRID — which lines form a table, how wide
//! each column may be, and how a row is padded — and none of it touches the
//! inline/fence/heading machinery that surrounds it.
//!
//! `inlineSpans` is borrowed back from markdown.zig so a cell renders exactly
//! the way prose does. That is a module cycle on purpose: the alternative is
//! measuring markers by hand, which is how the grid used to shear — the render
//! dropped an unmatched ` or ** and the measure kept it.
//!
//! The one hard rule: a table row is ONE visual line. The pager's row↔line map
//! (clicks, the sticky header, the selection band) is built on that, so an
//! over-long cell is clamped and ellipsised rather than allowed to wrap.

const std = @import("std");

const markdown = @import("markdown.zig");
const theme_mod = @import("theme.zig");

pub const max_cols: usize = 8;

/// Widest a single column may grow before the fitting pass starts shaving.
const cell_ceiling: usize = 36;
/// Narrowest a column can be shaved to. Below this a cell is all ellipsis.
const cell_floor: usize = 5;

fn isRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3 or t[0] != '|') return false;
    return std.mem.indexOfScalar(u8, t[1..], '|') != null;
}

fn isSepRow(line: []const u8) bool {
    if (!isRow(line)) return false;
    var buf: [max_cols][]const u8 = undefined;
    const n = splitCells(line, &buf);
    if (n == 0) return false;
    for (buf[0..n]) |c| {
        if (c.len == 0) return false;
        for (c) |ch| {
            if (ch != '-' and ch != ':' and ch != ' ') return false;
        }
    }
    return true;
}

/// How many of `lines` form a table starting at line 0, or null for none. A
/// header and its `---` separator are both required, which is what keeps a
/// stray pipe-heavy prose line from being drawn as a grid.
pub fn len(lines: []const []const u8) ?usize {
    if (lines.len < 2 or !isRow(lines[0]) or !isSepRow(lines[1])) return null;
    var n: usize = 2;
    while (n < lines.len and isRow(lines[n]) and !isSepRow(lines[n])) n += 1;
    return n;
}

fn splitCells(line: []const u8, out: [][]const u8) usize {
    var t = std.mem.trim(u8, line, " \t");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, '|');
    while (it.next()) |raw| {
        if (n >= out.len) break;
        out[n] = std.mem.trim(u8, raw, " \t");
        n += 1;
    }
    return n;
}

/// Visible width of a cell AS RENDERED: run it through inlineSpans and count.
/// Guessing at markers went wrong on every unmatched ` or ** (the render kept
/// them, the measure dropped them, the pad math sheared the grid).
fn cellWidth(a: std.mem.Allocator, s: []const u8) usize {
    var scratch = std.array_list.Managed(u8).init(a);
    defer scratch.deinit();
    markdown.inlineSpans(&scratch, s, "", "") catch return s.len;
    return theme_mod.visibleLen(scratch.items);
}

fn emitRule(out: *std.array_list.Managed(u8), muted: []const u8, widths: []const usize, left: []const u8, mid: []const u8, right: []const u8) !void {
    try out.appendSlice(muted);
    try out.appendSlice(left);
    for (widths, 0..) |w, i| {
        if (i > 0) try out.appendSlice(mid);
        var n: usize = 0;
        while (n < w + 2) : (n += 1) try out.appendSlice("─");
    }
    try out.appendSlice(right);
    try out.appendSlice(theme_mod.reset);
}

/// Column widths that fit `width` terminal columns. Every row costs
/// `ncol*3 + 1` border/pad columns on top of its content; the widest column is
/// shaved until the rest fits. `width == 0` means "no terminal to fit", which
/// is the tinted (overlay/plain) path.
fn fit(cols: []usize, width: usize) void {
    const chrome_cost = cols.len * 3 + 1;
    const budget = if (width == 0) 76 else if (width > chrome_cost) width - chrome_cost else cols.len * cell_floor;
    var total: usize = 0;
    for (cols) |w| total += w;
    while (total > budget) {
        var widest: usize = 0;
        for (cols, 0..) |w, ci| {
            if (w > cols[widest]) widest = ci;
        }
        if (cols[widest] <= cell_floor) break;
        cols[widest] -= 1;
        total -= 1;
    }
}

pub fn emit(
    out: *std.array_list.Managed(u8),
    a: std.mem.Allocator,
    rows: []const []const u8,
    accent: []const u8,
    muted: []const u8,
    text: []const u8,
    width: usize,
) !void {
    var widths: [max_cols]usize = @splat(0);
    var ncol: usize = 0;
    for (rows, 0..) |row, ri| {
        if (ri == 1) continue; // the separator carries no content
        var cells: [max_cols][]const u8 = undefined;
        const n = splitCells(row, &cells);
        if (n > ncol) ncol = n;
        var c: usize = 0;
        while (c < n) : (c += 1) {
            const w = @min(cellWidth(a, cells[c]), cell_ceiling);
            if (w > widths[c]) widths[c] = w;
        }
    }
    if (ncol == 0) return;
    const cols = widths[0..ncol];
    fit(cols, width);
    try emitRule(out, muted, cols, "┌", "┬", "┐");
    try out.append('\n');
    for (rows, 0..) |row, ri| {
        if (ri == 1) {
            try emitRule(out, muted, cols, "├", "┼", "┤");
            try out.append('\n');
            continue;
        }
        try emitCells(out, a, row, cols, ri == 0, accent, muted, text);
    }
    try emitRule(out, muted, cols, "└", "┴", "┘");
}

/// One table row: `│ cell │ cell │`, every cell clamped to its column so an
/// over-long one can never blow the grid onto a second visual line.
fn emitCells(
    out: *std.array_list.Managed(u8),
    a: std.mem.Allocator,
    row: []const u8,
    cols: []const usize,
    header: bool,
    accent: []const u8,
    muted: []const u8,
    text: []const u8,
) !void {
    var cells: [max_cols][]const u8 = undefined;
    const n = splitCells(row, &cells);
    var c: usize = 0;
    while (c < cols.len) : (c += 1) {
        try out.appendSlice(muted);
        try out.appendSlice("│");
        try out.appendSlice(theme_mod.reset);
        try out.append(' ');
        const cell = if (c < n) cells[c] else "";
        const want = cols[c];
        var scratch = std.array_list.Managed(u8).init(a);
        defer scratch.deinit();
        if (header) {
            try scratch.appendSlice(theme_mod.bold);
            try scratch.appendSlice(accent);
            try markdown.inlineSpans(&scratch, cell, accent, accent);
        } else {
            try scratch.appendSlice(text);
            try markdown.inlineSpans(&scratch, cell, accent, text);
        }
        const vis = cellWidth(a, cell);
        if (vis > want) {
            try out.appendSlice(theme_mod.takeCols(scratch.items, if (want > 1) want - 1 else want));
            if (want > 1) try out.appendSlice("\u{2026}");
        } else {
            try out.appendSlice(scratch.items);
            var p: usize = 0;
            while (p < want - vis) : (p += 1) try out.append(' ');
        }
        try out.appendSlice(theme_mod.reset);
        try out.append(' ');
    }
    try out.appendSlice(muted);
    try out.appendSlice("│");
    try out.appendSlice(theme_mod.reset);
    try out.append('\n');
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "a table needs a header AND a separator" {
    try testing.expectEqual(@as(?usize, null), len(&.{"| a | b |"}));
    try testing.expectEqual(@as(?usize, null), len(&.{ "| a | b |", "| c | d |" }));
    try testing.expectEqual(@as(?usize, 3), len(&.{ "| a | b |", "|---|---|", "| c | d |" }));
    // Prose that merely contains pipes is not a grid.
    try testing.expectEqual(@as(?usize, null), len(&.{ "use a | b in the shell", "|---|---|" }));
}

test "the run stops at the first line that is not a row" {
    const lines = [_][]const u8{ "| a |", "|---|", "| c |", "plain prose", "| e |" };
    try testing.expectEqual(@as(?usize, 3), len(&lines));
}

test "cells split on pipes and lose their padding" {
    var buf: [max_cols][]const u8 = undefined;
    const n = splitCells("|  one  |  two  |", &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("one", buf[0]);
    try testing.expectEqualStrings("two", buf[1]);
    // More columns than the ceiling: the extras are dropped, never overrun.
    const wide = "|a|b|c|d|e|f|g|h|i|j|k|";
    try testing.expectEqual(max_cols, splitCells(wide, &buf));
}

test "fitting shaves the widest column and never past the floor" {
    var cols = [_]usize{ 40, 8, 8 };
    fit(&cols, 40);
    var total: usize = 0;
    for (cols) |w| total += w;
    try testing.expect(total + cols.len * 3 + 1 <= 40);
    try testing.expect(cols[1] == 8 and cols[2] == 8); // only the widest shrank
    // A width no grid can fit still stops at the floor rather than at zero.
    var tight = [_]usize{ 30, 30, 30 };
    fit(&tight, 12);
    for (tight) |w| try testing.expect(w >= cell_floor);
}
