//! Compact ANSI markdown for the pager. No zigzag — SGR only.

const std = @import("std");
const diff = @import("diff.zig");
const theme_mod = @import("theme.zig");
const mdtable = @import("mdtable.zig");
const syntax = @import("syntax.zig");
const image = @import("image.zig");

/// Headers, fences, lists, quotes, tasks, `code`, **bold**, `_italic_`, and `/slash` tokens.
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
        if (mdtable.tableLen(lines.items[i..])) |n| {
            try mdtable.emitTable(&out, a, lines.items[i .. i + n], th.accent, th.muted, th.text, width);
            i += n;
            continue;
        }
        try appendBlock(&out, line, th.accent, th.muted, th.text);
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
        if (mdtable.tableLen(lines.items[i..])) |n| {
            try mdtable.emitTable(&out, a, lines.items[i .. i + n], accent, muted, text, 0);
            i += n;
            continue;
        }
        try appendBlock(&out, line, accent, muted, text);
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
                const path = clean[i + 2 .. close];
                // Accent only when the file is still there (#577). A stale or
                // typed `@[path]` is ordinary text, not an attachment chip.
                if (image.pathBacked(path)) {
                    try out.appendSlice(accent);
                    try out.appendSlice(label);
                    try out.appendSlice(text);
                } else {
                    try out.appendSlice(label);
                }
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

/// Headers, lists, quotes, and tasks — the pager's prose blocks. Shared by
/// the themed and tinted renderers so they cannot drift.
fn appendBlock(out: *std.array_list.Managed(u8), line: []const u8, accent: []const u8, muted: []const u8, text: []const u8) !void {
    var lead: usize = 0;
    while (lead < line.len and line[lead] == ' ') lead += 1;
    const body = line[lead..];
    var h: usize = 0;
    while (h < body.len and body[h] == '#') h += 1;
    if (h >= 1 and h <= 6 and h < body.len and body[h] == ' ') {
        try out.appendSlice(theme_mod.bold);
        try out.appendSlice(accent);
        try inlineSpans(out, std.mem.trimStart(u8, body[h + 1 ..], " "), accent, text);
        try out.appendSlice(theme_mod.reset);
        return;
    }
    if (body.len >= 3 and isRule(body)) {
        try out.appendSlice(muted);
        try out.appendSlice("────────────");
        try out.appendSlice(theme_mod.reset);
        return;
    }
    if (taskItem(body)) |task| {
        try out.appendSlice(line[0..lead]);
        try out.appendSlice(accent);
        try out.appendSlice(if (task.checked) "☑ " else "☐ ");
        try out.appendSlice(text);
        try inlineSpans(out, task.text, accent, text);
        return;
    }
    if (std.mem.startsWith(u8, body, "> ")) {
        try out.appendSlice(line[0..lead]);
        try out.appendSlice(muted);
        try out.appendSlice("│ ");
        try out.appendSlice(text);
        try inlineSpans(out, body[2..], accent, text);
        return;
    }
    if (std.mem.startsWith(u8, body, "- ") or std.mem.startsWith(u8, body, "* ") or std.mem.startsWith(u8, body, "+ ")) {
        try out.appendSlice(line[0..lead]);
        try out.appendSlice(accent);
        try out.appendSlice(if (lead == 0) "  • " else "  ◦ ");
        try out.appendSlice(text);
        try inlineSpans(out, body[2..], accent, text);
        return;
    }
    var d: usize = 0;
    while (d < body.len and body[d] >= '0' and body[d] <= '9') d += 1;
    if (d >= 1 and d + 1 < body.len and (body[d] == '.' or body[d] == ')') and body[d + 1] == ' ') {
        try out.appendSlice(line[0..lead]);
        try out.appendSlice(accent);
        try out.appendSlice(body[0 .. d + 1]);
        try out.appendSlice(" ");
        try out.appendSlice(text);
        try inlineSpans(out, body[d + 2 ..], accent, text);
        return;
    }
    try out.appendSlice(text);
    try inlineSpans(out, line, accent, text);
}

/// `code`, **bold** and `_italic_`, painted in place. Public for table.zig,
/// which renders a cell the same way prose is rendered rather than measuring
/// markers by hand — see the note at the head of that file.
pub fn inlineSpans(out: *std.array_list.Managed(u8), line: []const u8, accent: []const u8, text: []const u8) !void {
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
        } else if (line[i] == '_' and (i == 0 or line[i - 1] == ' ')) {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '_')) |end| {
                if (end > i + 1) {
                    try out.appendSlice(theme_mod.dim);
                    try out.appendSlice(line[i + 1 .. end]);
                    try out.appendSlice("\x1b[22m"); // dim OFF; a 38;2 fg alone cannot clear SGR 2
                    try out.appendSlice(text);
                    i = end + 1;
                    continue;
                }
            }
        }
        try out.append(line[i]);
        i += 1;
    }
}

const TaskItem = struct { checked: bool, text: []const u8 };

fn taskItem(body: []const u8) ?TaskItem {
    if (body.len < 6 or (body[0] != '-' and body[0] != '*' and body[0] != '+') or body[1] != ' ' or body[2] != '[' or body[4] != ']' or body[5] != ' ') return null;
    if (body[3] != ' ' and body[3] != 'x' and body[3] != 'X') return null;
    return .{ .checked = body[3] != ' ', .text = body[6..] };
}

/// True if every char is one of '-', '*', or '_' (markdown thematic break).
fn isRule(body: []const u8) bool {
    const c0 = body[0];
    if (c0 != '-' and c0 != '*' and c0 != '_') return false;
    for (body) |c| if (c != c0) return false;
    return true;
}

fn isBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '(' or c == '[';
}

test {
    // The tests live next door (this file is at the line ceiling). Without this
    // reference they compile for nobody and silently never run.
    _ = @import("markdown_tests.zig");
}
