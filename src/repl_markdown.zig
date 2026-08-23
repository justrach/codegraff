//! Markdown and pipe-table rendering for the interactive REPL.
//!
//! Kept separate from repl.zig so the REPL facade and Model stay compact.
//! The public entry point remains repl.renderMarkdown.

const std = @import("std");
const zz = @import("zigzag");

const util = @import("repl_util.zig");
const softCut = @import("util.zig").softCut;
const accent = util.accent;

/// Render a markdown string to ANSI for display — approximates the harness's
/// streamed renderer: fenced code blocks (left bar), inline `code`, **bold**,
/// # headers, - bullets, and | pipe tables (box-drawing, wrapped to fit
/// `width_hint` columns; 0 = assume 100). Temporaries live in a local arena;
/// the result is owned by `gpa`.
pub fn renderMarkdown(gpa: std.mem.Allocator, src: []const u8, width_hint: usize) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out = std.array_list.Managed(u8).init(a);

    var line_list = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try line_list.append(l);
    const lines = line_list.items;

    var in_fence = false;
    var first = true;
    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        if (!first) try out.append('\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            const lang = std.mem.trim(u8, t[3..], " \t");
            const label = if (in_fence and lang.len > 0) lang else "─────";
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, label));
            continue;
        }
        if (in_fence) {
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, "▏ "));
            try out.appendSlice(line);
            continue;
        }
        if (isTableRow(t) and idx + 1 < lines.len and isTableSep(std.mem.trim(u8, lines[idx + 1], " \t"))) {
            var end = idx;
            while (end < lines.len and isTableRow(std.mem.trimStart(u8, lines[end], " "))) end += 1;
            try renderTable(&out, a, lines[idx..end], width_hint);
            idx = end - 1;
            continue;
        }
        // Pipe-less GFM table ("a | b" / "--- | ---"): same box form. Only
        // whole-buffer rendering can see the separator row, so this lives
        // here rather than in the streaming classifier.
        if (hasPipeCells(t) and idx + 1 < lines.len and isPipelessSep(std.mem.trim(u8, lines[idx + 1], " \t"))) {
            var end = idx;
            while (end < lines.len and hasPipeCells(std.mem.trimStart(u8, lines[end], " "))) end += 1;
            try renderTable(&out, a, lines[idx..end], width_hint);
            idx = end - 1;
            continue;
        }
        if (std.mem.startsWith(u8, t, "#")) {
            var h = t;
            while (h.len > 0 and h[0] == '#') h = h[1..];
            try out.appendSlice(try (zz.Style{}).fg(accent).bold(true).render(a, std.mem.trimStart(u8, h, " ")));
            continue;
        }
        var rest = line;
        if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ")) {
            try out.appendSlice(try (zz.Style{}).fg(accent).render(a, "  • "));
            rest = t[2..];
        }
        try util.renderInline(&out, a, rest);
    }
    return gpa.dupe(u8, out.items);
}

fn isTableRow(t: []const u8) bool {
    return t.len >= 2 and t[0] == '|';
}

/// Cells joined by ` | ` somewhere in the line — a GFM row written without
/// leading/trailing pipes. Never true for a leading-pipe row (checked first).
fn hasPipeCells(t: []const u8) bool {
    var i: usize = 1;
    while (i + 1 < t.len) : (i += 1) {
        if (t[i] == '|' and t[i - 1] == ' ' and t[i + 1] == ' ') return true;
    }
    return false;
}

/// `--- | ---` alignment row in the pipe-less shape: dashes required, only
/// separator characters otherwise, and at least one pipe.
fn isPipelessSep(t: []const u8) bool {
    var dash = false;
    var pipe = false;
    for (t) |c| switch (c) {
        ':', ' ', '\t' => {},
        '-' => dash = true,
        '|' => pipe = true,
        else => return false,
    };
    return dash and pipe;
}

/// `|---|:--:|` style alignment row: pipes/colons/spaces only, dashes required.
fn isTableSep(t: []const u8) bool {
    if (t.len == 0 or t[0] != '|') return false;
    var dash = false;
    for (t) |c| switch (c) {
        '|', ':', ' ', '\t' => {},
        '-' => dash = true,
        else => return false,
    };
    return dash;
}

/// Inline markdown with `code`/**bold** markers stripped — exactly what
/// renderInline makes visible, unstyled. Cell layout is computed from this.
fn plainInline(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(line[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                try out.appendSlice(line[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        try out.append(c);
        i += 1;
    }
    return out.items;
}

/// Display columns for one codepoint (wcwidth-style, #142): 0 for combining /
/// zero-width marks, 2 for East-Asian wide + emoji, 1 otherwise. Approximate —
/// covers the ranges that misalign TUI table borders (CJK, Hangul, kana,
/// fullwidth forms, common emoji planes). Emoji-presentation via a VS16 (U+FE0F)
/// on a text-default base is not width-promoted. ASCII/Latin-1 skip the table.
fn codepointWidth(cp: u21) usize {
    if (cp < 0x300) return 1; // ASCII + Latin-1 (control bytes stay 1, as before)
    if ((cp >= 0x300 and cp <= 0x36F) or // combining diacritical marks
        (cp >= 0x200B and cp <= 0x200F) or // ZWSP..RLM
        (cp >= 0xFE00 and cp <= 0xFE0F) or // variation selectors
        cp == 0xFEFF) return 0; // BOM / ZWNBSP
    if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK radicals .. symbols
        (cp >= 0x3041 and cp <= 0x33FF) or // kana .. CJK compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK unified
        (cp >= 0xA000 and cp <= 0xA4CF) or // Yi
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compat ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK compat forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // fullwidth forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // fullwidth signs
        (cp >= 0x1F000 and cp <= 0x1F02F) or // mahjong tiles
        (cp >= 0x1F0A0 and cp <= 0x1F0FF) or // playing cards
        (cp >= 0x1F100 and cp <= 0x1F1FF) or // enclosed alphanumeric / regional
        (cp >= 0x1F300 and cp <= 0x1FAFF) or // emoji & pictographs
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2; // CJK ext B+
    return 1;
}

fn dispWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            n += 1;
            continue;
        };
        const end = @min(i + len, s.len);
        n += if (std.unicode.utf8Decode(s[i..end])) |cp| codepointWidth(cp) else |_| 1;
        i = end;
    }
    return n;
}

test "dispWidth: East-Asian wide, combining, emoji (#142)" {
    try std.testing.expectEqual(@as(usize, 5), dispWidth("hello"));
    try std.testing.expectEqual(@as(usize, 4), dispWidth("\u{4F60}\u{597D}")); // CJK x2 -> 4 cols
    try std.testing.expectEqual(@as(usize, 2), dispWidth("\u{3042}")); // hiragana wide
    try std.testing.expectEqual(@as(usize, 1), dispWidth("\u{00E9}")); // precomposed e-acute -> 1
    try std.testing.expectEqual(@as(usize, 1), dispWidth("e\u{0301}")); // e + combining acute -> 1
    try std.testing.expectEqual(@as(usize, 2), dispWidth("\u{1F600}")); // emoji -> 2
    try std.testing.expectEqual(@as(usize, 0), dispWidth("\u{200B}")); // ZWSP -> 0
    try std.testing.expectEqual(@as(usize, 2), dispWidth("\u{FF21}")); // fullwidth A -> 2
}

/// Word-wrap `s` to `w` display columns; words longer than `w` hard-split at
/// codepoint boundaries. Never emits leading/trailing spaces on a line.
fn wrapCell(a: std.mem.Allocator, s: []const u8, w: usize) ![]const []const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    var cur = std.array_list.Managed(u8).init(a);
    var cur_w: usize = 0;
    var words = std.mem.tokenizeScalar(u8, s, ' ');
    while (words.next()) |word| {
        var rem = word;
        while (dispWidth(rem) > w) {
            if (cur_w > 0) {
                try lines.append(try a.dupe(u8, cur.items));
                cur.clearRetainingCapacity();
                cur_w = 0;
            }
            var bytes: usize = 0;
            var cw: usize = 0;
            while (bytes < rem.len) {
                const clen = @min(std.unicode.utf8ByteSequenceLength(rem[bytes]) catch 1, rem.len - bytes);
                const cpw = if (std.unicode.utf8Decode(rem[bytes .. bytes + clen])) |cp| codepointWidth(cp) else |_| 1;
                if (cw + cpw > w and bytes > 0) break; // stop before overflowing the column (>=1 char guaranteed)
                bytes += clen;
                cw += cpw;
            }
            const cut = softCut(rem, 0, bytes); // break after / _ - . : rather than mid-token
            try lines.append(try a.dupe(u8, rem[0..cut]));
            rem = rem[cut..];
        }
        const ww = dispWidth(rem);
        if (ww == 0) continue;
        if (cur_w > 0 and cur_w + 1 + ww > w) {
            try lines.append(try a.dupe(u8, cur.items));
            cur.clearRetainingCapacity();
            cur_w = 0;
        }
        if (cur_w > 0) {
            try cur.append(' ');
            cur_w += 1;
        }
        try cur.appendSlice(rem);
        cur_w += ww;
    }
    if (cur_w > 0 or lines.items.len == 0) try lines.append(try a.dupe(u8, cur.items));
    return lines.items;
}

fn tableRule(out: *std.array_list.Managed(u8), a: std.mem.Allocator, widths: []const usize, l: []const u8, m: []const u8, r: []const u8) !void {
    var buf = std.array_list.Managed(u8).init(a);
    try buf.appendSlice(l);
    for (widths, 0..) |w, i| {
        for (0..w + 2) |_| try buf.appendSlice("─");
        try buf.appendSlice(if (i + 1 == widths.len) r else m);
    }
    try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, buf.items));
}

/// Narrow-table fallback: one record per data row — bold `Header: value`
/// lines with wrapped continuations indented, a brightBlack rule between
/// records. Used when the box form cannot fit `budget` columns.
fn renderRecords(out: *std.array_list.Managed(u8), a: std.mem.Allocator, rows: []const []const []const u8, budget: usize) !void {
    const header = rows[0];
    var rule_buf = std.array_list.Managed(u8).init(a);
    const rule_w = @max(@as(usize, 16), @min(budget, 40));
    for (0..rule_w) |_| try rule_buf.appendSlice("─");
    var first_line = true;
    for (rows[1..], 0..) |cells, ri| {
        if (ri > 0) {
            try out.append('\n');
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, rule_buf.items));
        }
        for (header, 0..) |label, i| {
            const value = if (i < cells.len) cells[i] else "";
            const lw = dispWidth(label);
            const segs = try wrapCell(a, value, @max(@as(usize, 16), budget -| (lw + 2)));
            if (!first_line) try out.append('\n');
            first_line = false;
            try out.appendSlice(try (zz.Style{}).bold(true).render(a, label));
            try out.appendSlice(": ");
            if (segs.len > 0) try out.appendSlice(segs[0]);
            if (segs.len > 1) for (segs[1..]) |seg| {
                try out.append('\n');
                try out.appendSlice("  ");
                try out.appendSlice(seg);
            };
        }
    }
}

/// Per-column alignment parsed from a table's `:---:` separator row (#143).
const TableAlign = enum { left, center, right };

/// Render `| a | b |` source rows (row 1 = alignment separator) as a
/// box-drawing table: bold header, ├─┼─┤ rules between rows, cells
/// word-wrapped so the whole table fits `width_hint` columns.
fn renderTable(out: *std.array_list.Managed(u8), a: std.mem.Allocator, raw_rows: []const []const u8, width_hint: usize) !void {
    var rows = std.array_list.Managed([]const []const u8).init(a);
    for (raw_rows, 0..) |raw, ri| {
        if (ri == 1) continue; // alignment separator row
        var body = std.mem.trim(u8, raw, " \t");
        if (body.len > 0 and body[0] == '|') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
        var cells = std.array_list.Managed([]const u8).init(a);
        var cell = std.array_list.Managed(u8).init(a);
        var bi: usize = 0;
        while (bi < body.len) : (bi += 1) {
            if (body[bi] == '\\' and bi + 1 < body.len and body[bi + 1] == '|') {
                try cell.append('|'); // escaped \| is a literal pipe, not a column delimiter
                bi += 1;
            } else if (body[bi] == '|') {
                try cells.append(try plainInline(a, std.mem.trim(u8, cell.items, " \t")));
                cell = std.array_list.Managed(u8).init(a);
            } else {
                try cell.append(body[bi]);
            }
        }
        try cells.append(try plainInline(a, std.mem.trim(u8, cell.items, " \t")));
        try rows.append(cells.items);
    }
    if (rows.items.len == 0 or rows.items[0].len == 0) return;
    const ncols = rows.items[0].len;

    // Column alignment from the separator row (raw_rows[1]): ":--" left, "--:"
    // right, ":-:" center, "---" defaults left. Applied to header + data like
    // the GUI's ChatTable (#143). Skipped rows never reach here.
    const aligns = try a.alloc(TableAlign, ncols);
    @memset(aligns, .left);
    if (raw_rows.len > 1) {
        var sbody = std.mem.trim(u8, raw_rows[1], " \t");
        if (sbody.len > 0 and sbody[0] == '|') sbody = sbody[1..];
        if (sbody.len > 0 and sbody[sbody.len - 1] == '|') sbody = sbody[0 .. sbody.len - 1];
        var ci: usize = 0;
        var it = std.mem.splitScalar(u8, sbody, '|');
        while (it.next()) |raw_spec| {
            if (ci >= ncols) break;
            const spec = std.mem.trim(u8, raw_spec, " \t");
            const lc = spec.len > 0 and spec[0] == ':';
            const rc = spec.len > 0 and spec[spec.len - 1] == ':';
            aligns[ci] = if (lc and rc) .center else if (rc) .right else .left;
            ci += 1;
        }
    }

    const widths = try a.alloc(usize, ncols);
    @memset(widths, 1);
    for (rows.items) |cells| {
        for (cells, 0..) |c, i| {
            if (i < ncols) widths[i] = @max(widths[i], dispWidth(c));
        }
    }
    const budget = (if (width_hint == 0) @as(usize, 100) else @max(width_hint, 40)) -| 8;
    const overhead = ncols * 3 + 1;
    while (true) {
        var total: usize = overhead;
        for (widths) |w| total += w;
        if (total <= budget) break;
        var wi: usize = 0;
        var wmax: usize = 0;
        for (widths, 0..) |w, i| {
            if (w > wmax) {
                wmax = w;
                wi = i;
            }
        }
        if (wmax <= 8) break; // column floor reached — record fallback below
        widths[wi] = wmax - 1;
    }

    var total: usize = overhead;
    for (widths) |w| total += w;
    if (total > budget and rows.items.len >= 2) {
        // Even at the column floor the box form overflows the pane — fall back
        // to one record per row, mirroring the harness's narrow rendering.
        try renderRecords(out, a, rows.items, budget);
        return;
    }

    try tableRule(out, a, widths, "┌", "┬", "┐");
    for (rows.items, 0..) |cells, ri| {
        const wrapped = try a.alloc([]const []const u8, ncols);
        var height: usize = 1;
        for (0..ncols) |i| {
            wrapped[i] = try wrapCell(a, if (i < cells.len) cells[i] else "", widths[i]);
            height = @max(height, wrapped[i].len);
        }
        for (0..height) |li| {
            try out.append('\n');
            for (0..ncols) |i| {
                try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, "│"));
                try out.append(' ');
                const seg = if (li < wrapped[i].len) wrapped[i][li] else "";
                const pad = widths[i] -| dispWidth(seg);
                const lead: usize = switch (aligns[i]) {
                    .left => 0,
                    .right => pad,
                    .center => pad / 2,
                };
                for (0..lead) |_| try out.append(' ');
                if (seg.len > 0) {
                    if (ri == 0) {
                        try out.appendSlice(try (zz.Style{}).bold(true).render(a, seg));
                    } else {
                        try out.appendSlice(seg);
                    }
                }
                for (0..pad - lead) |_| try out.append(' ');
                try out.append(' ');
            }
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, "│"));
        }
        try out.append('\n');
        if (ri + 1 == rows.items.len) {
            try tableRule(out, a, widths, "└", "┴", "┘");
        } else {
            try tableRule(out, a, widths, "├", "┼", "┤");
        }
    }
}

test "renderMarkdown: pipe table renders as box-drawing" {
    const gpa = std.testing.allocator;
    const md = "before\n| Impact | Site |\n|---|---|\n| high | `repl.zig:700` |\n| medium | **main.zig** |\nafter";
    const out = try renderMarkdown(gpa, md, 80);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "repl.zig:700") != null); // backticks stripped in cells
    try std.testing.expect(std.mem.indexOf(u8, out, "|---") == null); // separator row consumed
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "renderMarkdown: table cells wrap to the width budget" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md = "| K | V |\n|---|---|\n| x | this is a very long cell that must wrap across multiple lines to stay inside a narrow table |";
    const out = try renderMarkdown(gpa, md, 48);
    defer gpa.free(out);
    const plain = util.stripControl(a, out);
    var it = std.mem.splitScalar(u8, plain, '\n');
    var cell_rows: usize = 0;
    while (it.next()) |line| {
        try std.testing.expect(dispWidth(line) <= 48);
        if (std.mem.indexOf(u8, line, "│") != null) cell_rows += 1;
    }
    try std.testing.expect(cell_rows >= 3); // long cell spans several visual lines
}

test "renderMarkdown: lone pipe line is not a table" {
    const gpa = std.testing.allocator;
    const out = try renderMarkdown(gpa, "| just text with pipes |\nno separator", 80);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| just text with pipes |") != null);
}

test "renderMarkdown: too-wide table falls back to record layout" {
    const gpa = std.testing.allocator;
    const md = "| Impact | Site | Finding | Fix safe? |\n|---|---|---|---|\n| high | repl.zig:700 | full scrollback re-styled and re-allocated every single frame | needs care |\n| medium | main.zig:14048 | never-reset session arena grows RSS forever | no |";
    const out = try renderMarkdown(gpa, md, 44);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") == null); // box form abandoned
    try std.testing.expect(std.mem.indexOf(u8, out, "Impact") != null); // labels repeated per record
    try std.testing.expect(std.mem.indexOf(u8, out, "────") != null); // rule between records
    try std.testing.expect(std.mem.indexOf(u8, out, "repl.zig:700") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "main.zig:14048") != null);
}

test "renderMarkdown: escaped pipe stays inside a table cell" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md = "| head |\n|---|\n| a \\| b |";
    const out = try renderMarkdown(gpa, md, 100);
    defer gpa.free(out);
    const plain = util.stripControl(a, out); // arena-owned; freed with arena_state
    // the escaped \\| renders as a literal pipe inside the single cell.
    try std.testing.expect(std.mem.indexOf(u8, plain, "a | b") != null);
}

test "renderMarkdown: table honors column alignment" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // right-aligned: short "5" in the 5-wide "Count" column gets 4 leading spaces.
    const rout = try renderMarkdown(gpa, "| Count |\n| ---: |\n| 5 |", 100);
    defer gpa.free(rout);
    try std.testing.expect(std.mem.indexOf(u8, util.stripControl(a, rout), "    5") != null);
    // centered: "x" in the 8-wide "Wide col" column gets leading pad (not flush-left).
    const cout = try renderMarkdown(gpa, "| Wide col |\n| :---: |\n| x |", 100);
    defer gpa.free(cout);
    try std.testing.expect(std.mem.indexOf(u8, util.stripControl(a, cout), "   x") != null);
    // left default: "5" stays flush-left (no leading pad before it).
    const lout = try renderMarkdown(gpa, "| Count |\n| --- |\n| 5 |", 100);
    defer gpa.free(lout);
    try std.testing.expect(std.mem.indexOf(u8, util.stripControl(a, lout), "    5") == null);
}

test "renderMarkdown: pipe-less GFM table renders as box-drawing" {
    const gpa = std.testing.allocator;
    const md = "Item | Desc\n--- | ---\n1 | Inspect files";
    const out = try renderMarkdown(gpa, md, 80);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null); // box form
    try std.testing.expect(std.mem.indexOf(u8, out, "Inspect files") != null);
    // A lone pipe-less line with NO separator row stays prose.
    const prose = try renderMarkdown(gpa, "left | right\njust text", 80);
    defer gpa.free(prose);
    try std.testing.expect(std.mem.indexOf(u8, prose, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, prose, "left | right") != null);
}
