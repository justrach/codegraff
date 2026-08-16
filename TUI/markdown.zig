//! Compact ANSI markdown for the pager. No zigzag — SGR only.

const std = @import("std");
const diff = @import("diff.zig");
const theme_mod = @import("theme.zig");
const syntax = @import("syntax.zig");

/// Headers, fences, bullets, `code`, **bold**, and `/slash` tokens.
pub fn render(a: std.mem.Allocator, src: []const u8, accent: []const u8) ![]const u8 {
    return renderTinted(a, src, accent, theme_mod.zinc400, theme_mod.zinc200);
}

// ── Streaming contract ──────────────────────────────────────────────────────
// Every renderer here is a PURE function of the accumulated message text: the
// pager re-renders the whole entry each frame, so a document that arrived in
// deltas lands on exactly the bytes a one-shot render produces. The only thing
// a chunk boundary can hand us is a partial TAIL, and `sanitize` is what makes
// that tail harmless — see markdown_stream_tests.zig for the pinned invariant.

/// Is there anything in `src` a frame cannot carry? Model text goes to the
/// terminal verbatim, so a C0 control (CR rewinds the row, BEL rings, ESC
/// paints) or a byte sequence that is not valid UTF-8 (a delta split a glyph)
/// has to be filtered first. The scan is the fast path: clean prose renders
/// with no copy at all.
fn needsClean(src: []const u8) bool {
    for (src) |b| {
        if (b < 0x20) {
            if (b != '\n' and b != '\t') return true;
        } else if (b == 0x7f) return true;
    }
    return !std.unicode.utf8ValidateSlice(src);
}

/// Drop what `needsClean` found: whole escape sequences (never just the ESC,
/// or the parameter bytes would land as literal text), C0/DEL other than
/// newline and tab, and any byte that is not part of a complete UTF-8
/// codepoint. A glyph the delta cut in half is HELD BACK rather than painted
/// as U+FFFD — the next delta completes it and the frame settles.
pub fn sanitize(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b == 0x1b) {
            i = theme_mod.skipEsc(src, i); // a truncated sequence eats the rest
            continue;
        }
        if (b < 0x20 or b == 0x7f) {
            if (b == '\n' or b == '\t') try out.append(b);
            i += 1;
            continue;
        }
        if (b < 0x80) {
            try out.append(b);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (i + len > src.len) break; // the tail of a split glyph: wait for it
        _ = std.unicode.utf8Decode(src[i .. i + len]) catch {
            i += 1;
            continue;
        };
        try out.appendSlice(src[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

/// Theme-aware render: grok-style code fences — markers hidden behind a blank
/// separator row, a full-width background band (clear-to-EOL under the code
/// bg), and token colors from syntax.zig in the theme's polarity. Everything
/// else matches renderTinted.
pub fn renderThemed(a: std.mem.Allocator, src: []const u8, th: theme_mod.Theme, width: usize) ![]const u8 {
    const light = th.id == .day;
    const clean = if (needsClean(src)) try sanitize(a, src) else src;
    defer if (clean.ptr != src.ptr) a.free(clean);
    var lines = std.array_list.Managed([]const u8).init(a);
    defer lines.deinit();
    var split = std.mem.splitScalar(u8, clean, '\n');
    while (split.next()) |line| try lines.append(line);

    var out = std.array_list.Managed(u8).init(a);
    var in_fence = false;
    var lang: ?*const syntax.Lang = null;
    var lex: syntax.State = .{};
    // This fence is a patch: its lines are banded by diff.zig instead of
    // syntax-coloured on the code canvas.
    var diff_fence = false;
    var first = true;
    // The previous line ended inside the code band, so codeBg is still the
    // active canvas and the next line that is NOT band content has to reclaim
    // it. Restoring on the fence line's own tail instead ended the band at the
    // last code glyph: run.zig pads the rest of the row from wherever the line
    // left the background, so the band has to stay open until the row ends.
    var band = false;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (!first) try out.append('\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " ");
        const marker = std.mem.startsWith(u8, t, "```");
        if (band and !(in_fence and !marker)) {
            try out.appendSlice(th.bg); // leave the band before anything paints
            band = false;
        }
        if (marker) {
            in_fence = !in_fence;
            diff_fence = false;
            if (in_fence) {
                lang = syntax.resolve(t[3..]);
                lex = .{};
                diff_fence = diff.isDiffInfo(t[3..]) or diff.looksLikeLines(lines.items[i + 1 ..]);
            }
            // Hidden fence markers; the empty row is the grok separator.
            i += 1;
            continue;
        }
        if (in_fence and diff_fence) {
            // Banded, already wrapped, and closed at every row end — the band
            // must not reach the prose under the fence.
            try diff.appendLine(&out, line, th, width);
            band = false;
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
            try out.appendSlice(theme_mod.reset); // fg/weight only: the band survives to the row end
            band = true;
            i += 1;
            continue;
        }
        if (tableLen(lines.items[i..])) |n| {
            try emitTable(&out, a, lines.items[i .. i + n], th.accent, th.muted, th.text, width);
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
    const clean = if (needsClean(src)) try sanitize(a, src) else src;
    defer if (clean.ptr != src.ptr) a.free(clean);
    var lines = std.array_list.Managed([]const u8).init(a);
    defer lines.deinit();
    var split = std.mem.splitScalar(u8, clean, '\n');
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
            try emitTable(&out, a, lines.items[i .. i + n], accent, muted, text, 0);
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
    const clean = if (needsClean(src)) try sanitize(a, src) else src;
    defer if (clean.ptr != src.ptr) a.free(clean);
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(text);
    var img_n: u32 = 0;
    var i: usize = 0;
    while (i < clean.len) {
        if (std.mem.startsWith(u8, clean[i..], "@[")) {
            if (std.mem.indexOfScalarPos(u8, clean, i + 2, ']')) |close| {
                img_n += 1;
                var chip: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&chip, "[Image #{d}]", .{img_n}) catch "[Image]";
                try out.appendSlice(accent);
                try out.appendSlice(label);
                try out.appendSlice(text);
                i = close + 1;
                if (i < clean.len and clean[i] == ' ') i += 1;
                continue;
            }
        }
        if (clean[i] == '/' and (i == 0 or isBreak(clean[i - 1]))) {
            var j = i + 1;
            while (j < clean.len and (std.ascii.isAlphanumeric(clean[j]) or clean[j] == '-')) j += 1;
            if (j > i + 1) {
                try out.appendSlice(accent);
                try out.appendSlice(clean[i..j]);
                try out.appendSlice(text);
                i = j;
                continue;
            }
        }
        try out.append(clean[i]);
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
                try out.appendSlice("\x1b[22m"); // bold OFF — a 38;2 fg alone cannot clear SGR 1
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

/// Visible width of a cell AS RENDERED: run it through inlineSpans and count.
/// Guessing at markers went wrong on every unmatched ` or ** (the render kept
/// them, the measure dropped them, the pad math sheared the grid).
fn cellWidth(a: std.mem.Allocator, s: []const u8) usize {
    var scratch = std.array_list.Managed(u8).init(a);
    defer scratch.deinit();
    inlineSpans(&scratch, s, "", "") catch return s.len;
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

fn emitTable(
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

fn isBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '(' or c == '[';
}

test {
    // The tests live next door (this file is at the line ceiling). Without this
    // reference they compile for nobody and silently never run.
    _ = @import("markdown_tests.zig");
}
