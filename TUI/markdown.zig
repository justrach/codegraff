//! Compact ANSI markdown for the pager. No zigzag — SGR only.

const std = @import("std");
const diff = @import("diff.zig");
const theme_mod = @import("theme.zig");
const mdtable = @import("mdtable.zig");
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
        if (mdtable.tableLen(lines.items[i..])) |n| {
            try mdtable.emitTable(&out, a, lines.items[i .. i + n], th.accent, th.muted, th.text, width);
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
        if (mdtable.tableLen(lines.items[i..])) |n| {
            try mdtable.emitTable(&out, a, lines.items[i .. i + n], accent, muted, text, 0);
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

/// `code`, **bold** and bare URLs, painted in place. Public for table.zig,
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
        }
        try out.append(line[i]);
        i += 1;
    }
}

fn isBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '(' or c == '[';
}

test {
    // The tests live next door (this file is at the line ceiling). Without this
    // reference they compile for nobody and silently never run.
    _ = @import("markdown_tests.zig");
}
