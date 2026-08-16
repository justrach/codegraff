//! Unified diffs in the pager: detection, per-line banding, and a wrap that
//! preserves the band.
//!
//! grok-build bands a hunk by LINE — insertions on a green-tinted canvas,
//! deletions on a red one, the hunk header on a dim rail — and carries that
//! canvas across every continuation row a narrow terminal forces. Two rules
//! make that safe here:
//!
//!   * a wrapped row re-opens the band itself and marks the fold with a
//!     continuation gutter, so a reader never reads a fold as a new diff line;
//!   * every row CLOSES with the theme canvas plus a foreground reset. The
//!     wrappers in theme.zig re-emit whatever SGR is still active at a line
//!     break, so leaving a band open at EOL is exactly how a red deletion ends
//!     up painting the unrelated line underneath it.
//!
//! Presentation only. The bytes come from the typed tool events and message
//! bodies the Model already holds; nothing here asks the engine for anything.

const std = @import("std");

const markdown = @import("markdown.zig");
const syntax = @import("syntax.zig");
const theme_mod = @import("theme.zig");

/// What one diff line is. `meta` is the file/index header block, `ctx` an
/// unchanged line.
pub const Kind = enum { add, del, hunk, meta, ctx };

/// The fold marker a continuation row opens with (one column, like ↳).
pub const gutter = "\u{21AA} ";

/// Insertion band — tinted toward the theme's `ok` green, one value per
/// polarity so a light theme gets a wash rather than a hole.
pub fn addBg(light: bool) []const u8 {
    return if (light) "\x1b[48;2;214;240;218m" else "\x1b[48;2;28;48;32m";
}

/// Deletion band, tinted toward `error_fg`.
pub fn delBg(light: bool) []const u8 {
    return if (light) "\x1b[48;2;250;220;224m" else "\x1b[48;2;56;28;34m";
}

/// Hunk header: a dim neutral rail, never either edit color.
pub fn hunkBg(light: bool) []const u8 {
    return if (light) "\x1b[48;2;232;232;236m" else "\x1b[48;2;34;34;40m";
}

/// Classify one line. The `+++`/`---` file headers are tested BEFORE the bare
/// `+`/`-` markers — otherwise every patch opens with a green and a red row
/// that are not edits at all.
pub fn classify(line: []const u8) Kind {
    const s = std.mem.trimEnd(u8, line, "\r");
    if (std.mem.startsWith(u8, s, "@@")) return .hunk;
    if (std.mem.startsWith(u8, s, "+++") or std.mem.startsWith(u8, s, "---")) return .meta;
    for ([_][]const u8{ "diff --git", "index ", "new file", "deleted file", "rename ", "similarity index", "Binary files" }) |p| {
        if (std.mem.startsWith(u8, s, p)) return .meta;
    }
    if (s.len == 0) return .ctx;
    return switch (s[0]) {
        '+' => .add,
        '-' => .del,
        else => .ctx,
    };
}

/// Evidence accumulator behind both detectors.
const Scan = struct {
    hunk: bool = false,
    minus_hdr: bool = false,
    plus_hdr: bool = false,
    edits: usize = 0,

    fn feed(s: *Scan, line: []const u8) void {
        switch (classify(line)) {
            .hunk => s.hunk = true,
            .add, .del => s.edits += 1,
            .meta => {
                if (std.mem.startsWith(u8, line, "---")) s.minus_hdr = true;
                if (std.mem.startsWith(u8, line, "+++")) s.plus_hdr = true;
                if (std.mem.startsWith(u8, line, "diff --git")) {
                    s.minus_hdr = true;
                    s.plus_hdr = true;
                }
            },
            .ctx => {},
        }
    }

    fn verdict(s: Scan) bool {
        return s.edits > 0 and (s.hunk or (s.minus_hdr and s.plus_hdr));
    }
};

/// Does this body read as a unified diff? A hunk header (or a `---`/`+++`
/// file pair) AND at least one edit line. Both halves matter: markdown bullet
/// lists are full of lines that open with `-`, and a lone `@@` is not a patch.
pub fn looksLikeUnified(src: []const u8) bool {
    var s: Scan = .{};
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |ln| s.feed(ln);
    return s.verdict();
}

/// The same verdict over an already-split fence body, stopping at the closing
/// fence so the prose after it never votes.
pub fn looksLikeLines(lines: []const []const u8) bool {
    var s: Scan = .{};
    for (lines) |ln| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, ln, " "), "```")) break;
        s.feed(ln);
    }
    return s.verdict();
}

/// A fence info string that DECLARES a diff, whatever its body looks like.
pub fn isDiffInfo(info: []const u8) bool {
    const t = std.mem.trim(u8, info, " \t\r");
    return std.mem.eql(u8, t, "diff") or std.mem.eql(u8, t, "patch") or std.mem.eql(u8, t, "udiff");
}

fn bandBg(k: Kind, light: bool) ?[]const u8 {
    return switch (k) {
        .add => addBg(light),
        .del => delBg(light),
        .hunk => hunkBg(light),
        .meta, .ctx => null,
    };
}

fn fgOf(k: Kind, th: theme_mod.Theme) []const u8 {
    return switch (k) {
        .add => th.ok,
        .del => th.error_fg,
        .hunk, .meta => th.muted,
        .ctx => th.text,
    };
}

/// One diff line, banded and wrapped to `width` (0 = do not wrap).
pub fn lineThemed(a: std.mem.Allocator, line: []const u8, th: theme_mod.Theme, width: usize) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    try appendLine(&out, line, th, width);
    return out.toOwnedSlice();
}

/// A whole diff body, one banded block. Already wrapped: the wrappers in
/// theme.zig find every row inside `width` and leave it alone.
pub fn renderThemed(a: std.mem.Allocator, src: []const u8, th: theme_mod.Theme, width: usize) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |ln| {
        if (!first) try out.append('\n');
        first = false;
        try appendLine(&out, ln, th, width);
    }
    return out.toOwnedSlice();
}

/// Append one banded line straight into a caller's buffer — the allocation-free
/// form markdown.zig uses while it walks a fence.
pub fn appendLine(out: *std.array_list.Managed(u8), line: []const u8, th: theme_mod.Theme, width: usize) !void {
    const light = th.id == .day;
    const k = classify(line);
    const band = bandBg(k, light);
    const bg = band orelse th.bg;
    const fg = fgOf(k, th);
    const cols = if (width == 0) std.math.maxInt(usize) else width;
    var rest = std.mem.trimEnd(u8, line, "\r");
    var row: usize = 0;
    while (true) {
        const lead: []const u8 = if (row == 0) "" else gutter;
        const lead_cols = theme_mod.visibleLen(lead);
        const chunk = take(rest, cols -| lead_cols);
        if (row > 0) try out.append('\n');
        try out.appendSlice(bg);
        if (k == .hunk) try out.appendSlice(theme_mod.dim);
        try out.appendSlice(fg);
        try out.appendSlice(lead);
        try out.appendSlice(chunk);
        // A band is a FIELD: pad it out so the row is one solid stripe rather
        // than a coloured ribbon that stops at the last glyph.
        if (band != null and width > 0) {
            var pad = width -| (lead_cols + theme_mod.visibleLen(chunk));
            while (pad > 0) : (pad -= 1) try out.append(' ');
        }
        try out.appendSlice(th.bg); // canvas back before the row ends
        try out.appendSlice(theme_mod.reset); // fg/weight/italic/underline off
        rest = rest[chunk.len..];
        row += 1;
        if (rest.len == 0) break;
    }
}

/// The next `cols` columns of `s`, never empty while bytes remain — a glyph
/// wider than the whole row still has to advance or the wrap spins forever.
fn take(s: []const u8, cols: usize) []const u8 {
    if (s.len == 0) return s;
    if (cols > 0) {
        const got = theme_mod.takeCols(s, cols);
        if (got.len > 0) return got;
    }
    return s[0..@min(s.len, std.unicode.utf8ByteSequenceLength(s[0]) catch 1)];
}

const patch =
    "diff --git a/TUI/run.zig b/TUI/run.zig\n" ++
    "--- a/TUI/run.zig\n" ++
    "+++ b/TUI/run.zig\n" ++
    "@@ -1,4 +1,4 @@\n" ++
    " const std = @import(\"std\");\n" ++
    "-const old = 1;\n" ++
    "+const new = 2;\n";

test "classify separates file headers from the edits under them" {
    try std.testing.expectEqual(Kind.meta, classify("--- a/TUI/run.zig"));
    try std.testing.expectEqual(Kind.meta, classify("+++ b/TUI/run.zig"));
    try std.testing.expectEqual(Kind.meta, classify("diff --git a/x b/x"));
    try std.testing.expectEqual(Kind.hunk, classify("@@ -1,4 +1,4 @@"));
    try std.testing.expectEqual(Kind.add, classify("+const new = 2;"));
    try std.testing.expectEqual(Kind.del, classify("-const old = 1;"));
    try std.testing.expectEqual(Kind.ctx, classify(" const std = @import(\"std\");"));
    try std.testing.expectEqual(Kind.ctx, classify(""));
}

test "the detector wants a hunk header AND an edit, so prose never bands" {
    try std.testing.expect(looksLikeUnified(patch));
    try std.testing.expect(looksLikeUnified("@@ -1 +1 @@\n-a\n+b"));
    // A markdown bullet list is nothing but lines that start with `-`.
    try std.testing.expect(!looksLikeUnified("- one\n- two\n- three"));
    // A lone hunk-shaped line with no edits under it is prose about diffs.
    try std.testing.expect(!looksLikeUnified("the @@ marker names a hunk"));
    try std.testing.expect(!looksLikeUnified(""));
    try std.testing.expect(!looksLikeUnified("+1 more\n"));
    // A `---`/`+++` pair stands in for the hunk header (git shows both).
    try std.testing.expect(looksLikeUnified("--- a/x\n+++ b/x\n+added\n"));
}

test "looksLikeLines stops at the closing fence" {
    const body = [_][]const u8{ "@@ -1 +1 @@", "-a", "+b", "```", "- a bullet", "- another" };
    try std.testing.expect(looksLikeLines(&body));
    const prose = [_][]const u8{ "```", "@@ -1 +1 @@", "-a", "+b" };
    try std.testing.expect(!looksLikeLines(&prose));
    try std.testing.expect(isDiffInfo("diff"));
    try std.testing.expect(isDiffInfo(" patch \t"));
    try std.testing.expect(!isDiffInfo("zig"));
}

/// Every row of a banded block must close its band, or theme.zig's wrap
/// re-opens it on whatever comes next.
fn expectClosed(row: []const u8, th: theme_mod.Theme) !void {
    try std.testing.expect(std.mem.endsWith(u8, row, theme_mod.reset));
    try std.testing.expect(std.mem.endsWith(u8, row[0 .. row.len - theme_mod.reset.len], th.bg));
}

test "golden: bands, boundaries and reset bytes at 40/80/120" {
    const th = theme_mod.of(.night);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 40, 80, 120 }) |w| {
        const out = try renderThemed(a, patch, th, w);
        var it = std.mem.splitScalar(u8, out, '\n');
        var adds: usize = 0;
        var dels: usize = 0;
        var hunks: usize = 0;
        while (it.next()) |ln| {
            try std.testing.expect(theme_mod.visibleLen(ln) <= w);
            try expectClosed(ln, th);
            const is_add = std.mem.startsWith(u8, ln, addBg(false));
            const is_del = std.mem.startsWith(u8, ln, delBg(false));
            const is_hunk = std.mem.startsWith(u8, ln, hunkBg(false));
            // A banded row is a full-width field; exactly one band per row.
            if (is_add or is_del or is_hunk) {
                try std.testing.expectEqual(w, theme_mod.visibleLen(ln));
                try std.testing.expectEqual(@as(usize, 1), @as(usize, @intFromBool(is_add)) + @intFromBool(is_del) + @intFromBool(is_hunk));
            }
            // The `---`/`+++` file headers are meta: they never band as edits.
            if (is_add) try std.testing.expect(std.mem.indexOf(u8, ln, "+++") == null);
            if (is_del) try std.testing.expect(std.mem.indexOf(u8, ln, "---") == null);
            adds += @intFromBool(is_add);
            dels += @intFromBool(is_del);
            hunks += @intFromBool(is_hunk);
        }
        try std.testing.expectEqual(@as(usize, 1), adds);
        try std.testing.expectEqual(@as(usize, 1), dels);
        try std.testing.expectEqual(@as(usize, 1), hunks);
    }
}

test "wrap-bleed regression: a long deletion never paints the line under it" {
    const th = theme_mod.of(.night);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "@@ -1,2 +1,2 @@\n" ++
        "-const message = try std.fmt.allocPrint(gpa, \"a very long deleted line that has to wrap\", .{});\n" ++
        " const equal = 1;\n";
    const out = try renderThemed(a, src, th, 40);
    var it = std.mem.splitScalar(u8, out, '\n');
    var del_rows: usize = 0;
    var saw_equal = false;
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "const equal = 1;") != null) {
            saw_equal = true;
            // The equal line inherits nothing: no red band anywhere on it.
            try std.testing.expect(std.mem.indexOf(u8, ln, delBg(false)) == null);
            try std.testing.expect(std.mem.startsWith(u8, ln, th.bg));
            continue;
        }
        if (std.mem.startsWith(u8, ln, delBg(false))) {
            del_rows += 1;
            try expectClosed(ln, th);
            // The band survives the fold, and the fold is marked.
            if (del_rows > 1) try std.testing.expect(std.mem.indexOf(u8, ln, gutter) != null);
        }
    }
    try std.testing.expect(saw_equal);
    try std.testing.expect(del_rows > 1); // it really did wrap
}

test "both polarities band, and a day theme never uses the night wash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day = try renderThemed(a, patch, theme_mod.of(.day), 60);
    try std.testing.expect(std.mem.indexOf(u8, day, addBg(true)) != null);
    try std.testing.expect(std.mem.indexOf(u8, day, delBg(true)) != null);
    try std.testing.expect(std.mem.indexOf(u8, day, addBg(false)) == null);
    try std.testing.expect(std.mem.indexOf(u8, day, delBg(false)) == null);
    const night = try renderThemed(a, patch, theme_mod.of(.night), 60);
    try std.testing.expect(std.mem.indexOf(u8, night, addBg(false)) != null);
    try std.testing.expect(std.mem.indexOf(u8, night, addBg(true)) == null);
}

test "a glyph wider than the row still advances, and width 0 does not wrap" {
    const th = theme_mod.of(.night);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wide = try lineThemed(a, "+\u{1F680}\u{1F680}", th, 1);
    try std.testing.expect(std.mem.count(u8, wide, "\n") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, wide, "\u{1F680}") != null);
    const unwrapped = try lineThemed(a, "+xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", th, 0);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, unwrapped, "\n"));
    try expectClosed(unwrapped, th);
}

// The markdown side of the same contract: a fence that IS a patch is banded
// by this module instead of taking the code canvas. Lives here for the
// 600-line ceiling on markdown.zig.

test "a diff fence bands its edits instead of taking the code canvas" {
    const th = theme_mod.of(.night);
    const src = "before\n```diff\n@@ -1,2 +1,2 @@\n const keep = 0;\n-const old = 1;\n+const new = 2;\n```\nafter";
    const out = try markdown.renderThemed(std.testing.allocator, src, th, 40);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, addBg(false)) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, delBg(false)) != null);
    // A patch is not code: it never picks up the fence's own background.
    try std.testing.expect(std.mem.indexOf(u8, out, syntax.codeBg(false)) == null);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| {
        try std.testing.expect(theme_mod.visibleLen(ln) <= 40);
        if (std.mem.indexOf(u8, ln, "after") == null) continue;
        // The prose under the fence inherits neither band.
        try std.testing.expect(std.mem.indexOf(u8, ln, addBg(false)) == null);
        try std.testing.expect(std.mem.indexOf(u8, ln, delBg(false)) == null);
    }
}

test "an undeclared fence that IS a patch bands; a bullet list never does" {
    const th = theme_mod.of(.night);
    const banded = try markdown.renderThemed(std.testing.allocator, "```\n--- a/x\n+++ b/x\n-gone\n+here\n```", th, 40);
    defer std.testing.allocator.free(banded);
    try std.testing.expect(std.mem.indexOf(u8, banded, addBg(false)) != null);
    // Lines that merely START with `-` are a list, not a diff (#diff).
    const list = try markdown.renderThemed(std.testing.allocator, "- one\n- two\n- three", th, 40);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, delBg(false)) == null);
    // …and a zig fence still gets syntax colors on the code canvas.
    const code = try markdown.renderThemed(std.testing.allocator, "```zig\nconst x = 1;\n```", th, 40);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, syntax.codeBg(false)) != null);
    try std.testing.expect(std.mem.indexOf(u8, code, addBg(false)) == null);
}
