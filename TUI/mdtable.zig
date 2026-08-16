//! The pipe-table half of the pager's markdown: detection, column fitting and
//! the box-drawing grid. Split out of markdown.zig to keep both files inside
//! the 600-line ceiling; the cell CONTENT still goes through markdown's own
//! inline renderer, so a table cell and a paragraph style identically.

const std = @import("std");
const markdown = @import("markdown.zig");
const theme_mod = @import("theme.zig");

const inlineSpans = markdown.inlineSpans;

pub const max_table_cols: usize = 8;

pub fn isTableRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3 or t[0] != '|') return false;
    return std.mem.indexOfScalar(u8, t[1..], '|') != null;
}

pub fn isSepRow(line: []const u8) bool {
    if (!isTableRow(line)) return false;
    var buf: [max_table_cols][]const u8 = undefined;
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

pub fn tableLen(lines: []const []const u8) ?usize {
    if (lines.len < 2 or !isTableRow(lines[0]) or !isSepRow(lines[1])) return null;
    var n: usize = 2;
    while (n < lines.len and isTableRow(lines[n]) and !isSepRow(lines[n])) n += 1;
    return n;
}

pub fn splitCells(line: []const u8, out: [][]const u8) usize {
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
pub fn cellWidth(a: std.mem.Allocator, s: []const u8) usize {
    var scratch = std.array_list.Managed(u8).init(a);
    defer scratch.deinit();
    inlineSpans(&scratch, s, "", "") catch return s.len;
    return theme_mod.visibleLen(scratch.items);
}

pub fn emitRule(out: *std.array_list.Managed(u8), muted: []const u8, widths: []const usize, left: []const u8, mid: []const u8, right: []const u8) !void {
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

pub fn emitTable(
    out: *std.array_list.Managed(u8),
    a: std.mem.Allocator,
    rows: []const []const u8,
    accent: []const u8,
    muted: []const u8,
    text: []const u8,
    width: usize,
) !void {
    var widths: [max_table_cols]usize = @splat(0);
    var ncol: usize = 0;
    for (rows, 0..) |row, ri| {
        if (ri == 1) continue;
        var cells: [max_table_cols][]const u8 = undefined;
        const n = splitCells(row, &cells);
        if (n > ncol) ncol = n;
        var c: usize = 0;
        while (c < n) : (c += 1) {
            const w = @min(cellWidth(a, cells[c]), @as(usize, 36));
            if (w > widths[c]) widths[c] = w;
        }
    }
    if (ncol == 0) return;
    const cols = widths[0..ncol];
    // Fit the grid into the terminal: every row costs ncol*3+1 border/pad
    // columns on top of the content. Shave the widest column until it fits
    // (floor 5), then clamp each CELL to its column so an over-long cell can
    // never blow the grid — before this, content was emitted unclamped and
    // the line-wrapper sheared tables apart at narrow widths.
    const chrome_cost = ncol * 3 + 1;
    const budget = if (width == 0) 76 else if (width > chrome_cost) width - chrome_cost else ncol * 5;
    var total: usize = 0;
    for (cols) |w| total += w;
    while (total > budget) {
        var widest: usize = 0;
        for (cols, 0..) |w, ci| {
            if (w > cols[widest]) widest = ci;
        }
        if (cols[widest] <= 5) break;
        cols[widest] -= 1;
        total -= 1;
    }
    try emitRule(out, muted, cols, "┌", "┬", "┐");
    try out.append('\n');
    for (rows, 0..) |row, ri| {
        if (ri == 1) {
            try emitRule(out, muted, cols, "├", "┼", "┤");
            try out.append('\n');
            continue;
        }
        var cells: [max_table_cols][]const u8 = undefined;
        const n = splitCells(row, &cells);
        var c: usize = 0;
        while (c < ncol) : (c += 1) {
            try out.appendSlice(muted);
            try out.appendSlice("│");
            try out.appendSlice(theme_mod.reset);
            try out.append(' ');
            const cell = if (c < n) cells[c] else "";
            const want = cols[c];
            var scratch = std.array_list.Managed(u8).init(a);
            defer scratch.deinit();
            if (ri == 0) {
                try scratch.appendSlice(theme_mod.bold);
                try scratch.appendSlice(accent);
                try inlineSpans(&scratch, cell, accent, accent);
            } else {
                try scratch.appendSlice(text);
                try inlineSpans(&scratch, cell, accent, text);
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
    try emitRule(out, muted, cols, "└", "┴", "┘");
}
