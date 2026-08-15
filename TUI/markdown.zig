//! Compact ANSI markdown for the pager. No zigzag — SGR only.

const std = @import("std");
const theme_mod = @import("theme.zig");
const syntax = @import("syntax.zig");

/// Headers, fences, bullets, `code`, **bold**, and `/slash` tokens.
pub fn render(a: std.mem.Allocator, src: []const u8, accent: []const u8) ![]const u8 {
    return renderTinted(a, src, accent, theme_mod.zinc400, theme_mod.zinc200);
}

/// Theme-aware render: grok-style code fences — markers hidden behind a blank
/// separator row, a full-width background band (clear-to-EOL under the code
/// bg), and token colors from syntax.zig in the theme's polarity. Everything
/// else matches renderTinted.
pub fn renderThemed(a: std.mem.Allocator, src: []const u8, th: theme_mod.Theme) ![]const u8 {
    const light = th.id == .day;
    var lines = std.array_list.Managed([]const u8).init(a);
    defer lines.deinit();
    var split = std.mem.splitScalar(u8, src, '\n');
    while (split.next()) |line| try lines.append(line);

    var out = std.array_list.Managed(u8).init(a);
    var in_fence = false;
    var lang: ?*const syntax.Lang = null;
    var lex: syntax.State = .{};
    var first = true;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (!first) try out.append('\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            if (in_fence) {
                lang = syntax.resolve(t[3..]);
                lex = .{};
            }
            // Hidden fence markers; the empty row is the grok separator.
            i += 1;
            continue;
        }
        if (in_fence) {
            try out.appendSlice(syntax.codeBg(light));
            try out.appendSlice("\x1b[K");
            if (lang) |l| {
                try syntax.highlightLine(&out, line, l, &lex, light);
            } else {
                try out.appendSlice(th.text);
                try out.appendSlice(line);
            }
            try out.appendSlice(theme_mod.reset);
            i += 1;
            continue;
        }
        if (tableLen(lines.items[i..])) |n| {
            try emitTable(&out, a, lines.items[i .. i + n], th.accent, th.muted, th.text);
            i += n;
            continue;
        }
        if (std.mem.startsWith(u8, t, "#")) {
            var h = t;
            while (h.len > 0 and h[0] == '#') h = h[1..];
            try out.appendSlice(theme_mod.bold);
            try out.appendSlice(th.accent);
            try out.appendSlice(std.mem.trimStart(u8, h, " "));
            try out.appendSlice(theme_mod.reset);
            i += 1;
            continue;
        }
        try out.appendSlice(th.text);
        var rest = line;
        if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ")) {
            try out.appendSlice(th.accent);
            try out.appendSlice("  • ");
            try out.appendSlice(th.text);
            rest = t[2..];
        }
        try inlineSpans(&out, rest, th.accent, th.text);
        i += 1;
    }
    return out.toOwnedSlice();
}

pub fn renderTinted(a: std.mem.Allocator, src: []const u8, accent: []const u8, muted: []const u8, text: []const u8) ![]const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    defer lines.deinit();
    var split = std.mem.splitScalar(u8, src, '\n');
    while (split.next()) |line| try lines.append(line);

    var out = std.array_list.Managed(u8).init(a);
    var in_fence = false;
    var first = true;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (!first) try out.append('\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            const lang = std.mem.trim(u8, t[3..], " \t");
            try out.appendSlice(muted);
            try out.appendSlice(if (in_fence and lang.len > 0) lang else "─────");
            try out.appendSlice(theme_mod.reset);
            i += 1;
            continue;
        }
        if (in_fence) {
            try out.appendSlice(muted);
            try out.appendSlice("▏ ");
            try out.appendSlice(line);
            try out.appendSlice(theme_mod.reset);
            i += 1;
            continue;
        }
        if (tableLen(lines.items[i..])) |n| {
            try emitTable(&out, a, lines.items[i .. i + n], accent, muted, text);
            i += n;
            continue;
        }
        if (std.mem.startsWith(u8, t, "#")) {
            var h = t;
            while (h.len > 0 and h[0] == '#') h = h[1..];
            try out.appendSlice(theme_mod.bold);
            try out.appendSlice(accent);
            try out.appendSlice(std.mem.trimStart(u8, h, " "));
            try out.appendSlice(theme_mod.reset);
            i += 1;
            continue;
        }
        try out.appendSlice(text);
        var rest = line;
        if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ")) {
            try out.appendSlice(accent);
            try out.appendSlice("  • ");
            try out.appendSlice(text);
            rest = t[2..];
        }
        try inlineSpans(&out, rest, accent, text);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// User-row display: `@[path]` → `[Image #n]`, `/cmd` in accent.
pub fn renderUser(a: std.mem.Allocator, src: []const u8, accent: []const u8, text: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(text);
    var img_n: u32 = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "@[")) {
            if (std.mem.indexOfScalarPos(u8, src, i + 2, ']')) |close| {
                img_n += 1;
                var chip: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&chip, "[Image #{d}]", .{img_n}) catch "[Image]";
                try out.appendSlice(accent);
                try out.appendSlice(label);
                try out.appendSlice(text);
                i = close + 1;
                if (i < src.len and src[i] == ' ') i += 1;
                continue;
            }
        }
        if (src[i] == '/' and (i == 0 or isBreak(src[i - 1]))) {
            var j = i + 1;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '-')) j += 1;
            if (j > i + 1) {
                try out.appendSlice(accent);
                try out.appendSlice(src[i..j]);
                try out.appendSlice(text);
                i = j;
                continue;
            }
        }
        try out.append(src[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn inlineSpans(out: *std.array_list.Managed(u8), line: []const u8, accent: []const u8, text: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(accent);
                try out.appendSlice(line[i + 1 .. end]);
                try out.appendSlice(text);
                i = end + 1;
                continue;
            }
        } else if (line[i] == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                try out.appendSlice(theme_mod.bold);
                try out.appendSlice(line[i + 2 .. end]);
                try out.appendSlice(text);
                i = end + 2;
                continue;
            }
        }
        try out.append(line[i]);
        i += 1;
    }
}

const max_table_cols: usize = 8;

fn isTableRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3 or t[0] != '|') return false;
    return std.mem.indexOfScalar(u8, t[1..], '|') != null;
}

fn isSepRow(line: []const u8) bool {
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

fn tableLen(lines: []const []const u8) ?usize {
    if (lines.len < 2 or !isTableRow(lines[0]) or !isSepRow(lines[1])) return null;
    var n: usize = 2;
    while (n < lines.len and isTableRow(lines[n]) and !isSepRow(lines[n])) n += 1;
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

fn cellWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '`') {
            i += 1;
            continue;
        }
        if (s[i] == '*' and i + 1 < s.len and s[i + 1] == '*') {
            i += 2;
            continue;
        }
        const w = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(w, s.len - i);
        n += 1;
    }
    return n;
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

fn emitTable(
    out: *std.array_list.Managed(u8),
    a: std.mem.Allocator,
    rows: []const []const u8,
    accent: []const u8,
    muted: []const u8,
    text: []const u8,
) !void {
    _ = a;
    var widths: [max_table_cols]usize = @splat(0);
    var ncol: usize = 0;
    for (rows, 0..) |row, ri| {
        if (ri == 1) continue;
        var cells: [max_table_cols][]const u8 = undefined;
        const n = splitCells(row, &cells);
        if (n > ncol) ncol = n;
        var c: usize = 0;
        while (c < n) : (c += 1) {
            const w = @min(cellWidth(cells[c]), @as(usize, 36));
            if (w > widths[c]) widths[c] = w;
        }
    }
    if (ncol == 0) return;
    const cols = widths[0..ncol];
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
            if (ri == 0) {
                try out.appendSlice(theme_mod.bold);
                try out.appendSlice(accent);
                try inlineSpans(out, cell, accent, accent);
                try out.appendSlice(theme_mod.reset);
            } else {
                try out.appendSlice(text);
                try inlineSpans(out, cell, accent, text);
            }
            const vis = cellWidth(cell);
            const want = cols[c];
            if (vis < want) {
                var p: usize = 0;
                while (p < want - vis) : (p += 1) try out.append(' ');
            }
            try out.append(' ');
        }
        try out.appendSlice(muted);
        try out.appendSlice("│");
        try out.appendSlice(theme_mod.reset);
        try out.append('\n');
    }
    try emitRule(out, muted, cols, "└", "┴", "┘");
}

fn isBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '(' or c == '[';
}

test "render paints headers, code, bold, and bullets" {
    const text = try render(std.testing.allocator, "# Title\n- item\n`code` and **bold**\n```zig\nconst x = 1;\n```", theme_mod.emerald);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "•") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "code") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "▏ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, theme_mod.emerald) != null);
}

test "renderUser chips @[path] and paints slash commands" {
    const text = try renderUser(std.testing.allocator, "@[/tmp/a.png] /goal look at this", theme_mod.emerald, theme_mod.zinc200);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Image #1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/tmp/a.png") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/goal") != null);
}

test "render paints a Grok-style box table and hides raw pipes" {
    const src = "| Path | What |\n| --- | --- |\n| src/ | the product |\n| `TUI/` | pager |\n";
    const text = try render(std.testing.allocator, src, theme_mod.emerald);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pager") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| --- |") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| Path |") == null);
}
