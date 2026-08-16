//! The frame painter: the only code in the TUI that writes cells to a screen.
//!
//! One invariant, and every line below exists to hold it: **when paint()
//! returns, each of the `rows` screen rows shows the matching line of `frame`
//! and nothing else** — no cell of an older frame, no colour borrowed from a
//! row that happened to be painted earlier.
//!
//! Two mechanisms carry it.
//!
//!   * Every repainted row re-establishes its own style before its first cell
//!     (SGR reset, then the theme background). A diff paint rewrites an
//!     ARBITRARY SUBSET of rows, so a row that inherited fg/inverse from the
//!     row above it under a full paint would inherit whatever the last
//!     repainted row left behind under a diff paint: the same frame bytes,
//!     two different pictures.
//!   * Every repainted row is covered out to the last column. A row the frame
//!     proves SHORTER than the screen is written, padded with the theme
//!     background and erased to end of line. A row that MEASURES full is
//!     erased FIRST and written after — a trailing erase would sit on the last
//!     cell and eat it (that is what ate the composer's right border), and
//!     simply skipping the erase trusted visibleLen to agree with the terminal
//!     about every ambiguous-width glyph on the row. When it does not agree,
//!     the cells past the last glyph the terminal actually drew keep the
//!     PREVIOUS frame. Erase-first is right whether the measurement is or not.

const std = @import("std");
const Io = std.Io;

const theme_mod = @import("theme.zig");

/// Rewrite only rows that changed, so a drag-select on older transcript
/// survives a live token / thinking tick.
///
/// `prev` empty  -> clear the screen and lay down every row (first paint, and
///                  after anything that blanks the alt screen: SIGCONT, a
///                  resize, a theme flip).
/// `force` true  -> rewrite every row WITHOUT the clear: the self-heal repaint.
///                  The bytes are the frame we already believe is on screen, so
///                  under synchronized output (?2026) it is visually a no-op —
///                  but it is also the only thing that can repair a screen some
///                  other writer, or a terminal-side reflow, has disturbed.
pub fn paint(
    w: *Io.Writer,
    frame: []const u8,
    rows: usize,
    cols: usize,
    prev: []const u8,
    bg: []const u8,
    force: bool,
) !void {
    if (prev.len == 0) {
        try w.writeAll(bg);
        try w.writeAll("\x1b[2J\x1b[H");
        var row: usize = 0;
        var it = std.mem.splitScalar(u8, frame, '\n');
        while (row < rows) : (row += 1) {
            try paintRow(w, if (it.next()) |ln| ln else "", cols, bg);
            if (row + 1 < rows) try w.writeAll("\r\n");
        }
        // No trailing ED here. The release tip added one ("erase below, so a
        // scrolled alt screen self-heals"), but the `\x1b[2J` above already
        // clears the WHOLE display, scrolled rows included — while ED is
        // cursor-INCLUSIVE, and with autowrap off the cursor sits ON the last
        // column after a bottom row that measures full. It would erase the
        // glyph the erase-first branch just drew. Pinned below.
        try w.flush();
        return;
    }
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        if (!force and !rowChanged(prev, frame, row)) continue;
        try w.print("\x1b[{d};1H", .{row + 1});
        try paintRow(w, nthLine(frame, row), cols, bg);
    }
    try w.flush();
}

/// One row, cursor already at its first column. See the file header: the
/// prologue makes the row's style self-contained, and the two shapes below are
/// the entire residue story.
fn paintRow(w: *Io.Writer, ln: []const u8, cols: usize, bg: []const u8) !void {
    try w.writeAll(row_prologue);
    try w.writeAll(bg);
    const vis = theme_mod.visibleLen(ln);
    if (vis < cols) {
        try w.writeAll(ln);
        try pad(w, cols - vis);
        try w.writeAll(bg);
        try w.writeAll("\x1b[K");
        return;
    }
    // Provably-full or over-wide: erase the whole row up front, then draw.
    try w.writeAll("\x1b[K");
    // Autowrap is off (?7l), so an over-wide row piles onto the last cell
    // rather than wrapping — but a terminal that ignores ?7l would push every
    // row below down by one and desync the row↔line map for the whole screen.
    // Cut it to fit and the question never arises.
    try w.writeAll(if (vis > cols) theme_mod.takeCols(ln, cols) else ln);
}

/// SGR reset (all attributes, including inverse from a selection band). The
/// theme background is re-applied immediately after, so this never leaves the
/// canvas on the terminal's default.
pub const row_prologue = "\x1b[m";

fn pad(w: *Io.Writer, cells: usize) !void {
    var n = cells;
    while (n > 0) : (n -= 1) try w.writeByte(' ');
}

pub fn nthLine(s: []const u8, row: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    var i: usize = 0;
    while (it.next()) |ln| : (i += 1) {
        if (i == row) return ln;
    }
    return "";
}

pub fn rowChanged(prev: []const u8, frame: []const u8, row: usize) bool {
    return !std.mem.eql(u8, nthLine(prev, row), nthLine(frame, row));
}

// ------------------------------------------------------------------ tests

const test_bg = "\x1b[48;2;20;20;20m";

fn paintToBuf(a: std.mem.Allocator, frame: []const u8, rows: usize, cols: usize, prev: []const u8) ![]u8 {
    return paintForced(a, frame, rows, cols, prev, false);
}

fn paintForced(a: std.mem.Allocator, frame: []const u8, rows: usize, cols: usize, prev: []const u8, force: bool) ![]u8 {
    var aw = Io.Writer.Allocating.init(a);
    errdefer aw.deinit();
    try paint(&aw.writer, frame, rows, cols, prev, test_bg, force);
    return aw.toOwnedSlice();
}

/// A terminal, reduced to the only thing the painter can get wrong: which
/// codepoint ends up in which cell. Autowrap is off, exactly as the TUI sets
/// it. `untouched` marks a cell no paint has ever written, so a test can tell
/// "stale content" apart from "never drawn".
const Screen = struct {
    const untouched: u21 = 0;
    const wide_tail: u21 = 0x10FFFE; // right half of a double-width glyph

    rows: usize,
    cols: usize,
    cells: []u21,
    row: usize = 0,
    col: usize = 0,
    /// Does this terminal honour a VS16 emoji-presentation selector by widening
    /// the glyph to two cells? Real ones disagree — and that disagreement is
    /// the whole hazard: when the terminal draws a row NARROWER than
    /// visibleLen measured it, every cell past the last glyph it drew keeps
    /// whatever the previous frame put there unless the painter erased first.
    vs16_wide: bool = true,

    fn init(a: std.mem.Allocator, rows: usize, cols: usize) !Screen {
        const cells = try a.alloc(u21, rows * cols);
        @memset(cells, untouched);
        return .{ .rows = rows, .cols = cols, .cells = cells };
    }

    fn at(self: *Screen, r: usize, c: usize) *u21 {
        return &self.cells[r * self.cols + c];
    }

    fn put(self: *Screen, cp: u21, wide: bool) void {
        if (self.row >= self.rows) return;
        const c = @min(self.col, self.cols - 1);
        self.at(self.row, c).* = cp;
        if (wide and c + 1 < self.cols) self.at(self.row, c + 1).* = wide_tail;
        self.col = @min(c + (if (wide) @as(usize, 2) else 1), self.cols);
    }

    fn eraseToEol(self: *Screen) void {
        if (self.row >= self.rows) return;
        var c = @min(self.col, self.cols - 1);
        while (c < self.cols) : (c += 1) self.at(self.row, c).* = ' ';
    }

    fn clearAll(self: *Screen) void {
        @memset(self.cells, ' ');
        self.row = 0;
        self.col = 0;
    }

    /// Feed terminal output. Understands exactly what the painter emits: CUP,
    /// EL, ED, CR/LF and text; every other escape is style and is skipped.
    fn feed(self: *Screen, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1b) {
                const e = theme_mod.skipEsc(s, i);
                self.control(s[i..e]);
                i = e;
                continue;
            }
            if (s[i] == '\r') {
                self.col = 0;
                i += 1;
                continue;
            }
            if (s[i] == '\n') {
                self.row += 1;
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const step = @min(@as(usize, len), s.len - i);
            const cp = std.unicode.utf8Decode(s[i .. i + step]) catch ' ';
            const own = theme_mod.visibleLen(s[i .. i + step]);
            const vs16 = i + step + 3 <= s.len and std.mem.eql(u8, s[i + step .. i + step + 3], "\u{FE0F}");
            if (own != 0) self.put(cp, own == 2 or (vs16 and self.vs16_wide));
            i += step;
        }
    }

    fn control(self: *Screen, seq: []const u8) void {
        if (seq.len < 3 or seq[1] != '[') return;
        const final = seq[seq.len - 1];
        const body = seq[2 .. seq.len - 1];
        switch (final) {
            'H' => {
                var r: usize = 1;
                var it = std.mem.splitScalar(u8, body, ';');
                if (it.next()) |p| r = std.fmt.parseInt(usize, p, 10) catch 1;
                self.row = if (r > 0) r - 1 else 0;
                self.col = 0;
            },
            'J' => if (std.mem.eql(u8, body, "2")) self.clearAll(),
            'K' => self.eraseToEol(),
            else => {},
        }
    }

    /// What `frame` SHOULD look like on this screen: every line padded to the
    /// full width, every row past the frame's last line blank.
    fn expect(a: std.mem.Allocator, frame: []const u8, rows: usize, cols: usize, vs16_wide: bool) !Screen {
        var s = try Screen.init(a, rows, cols);
        s.vs16_wide = vs16_wide;
        s.clearAll();
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            s.row = row;
            s.col = 0;
            s.feed(theme_mod.takeCols(nthLine(frame, row), cols));
        }
        return s;
    }

    fn expectMatches(self: *Screen, other: *Screen) !void {
        var r: usize = 0;
        while (r < self.rows) : (r += 1) {
            var c: usize = 0;
            while (c < self.cols) : (c += 1) {
                const got = self.at(r, c).*;
                const want = other.at(r, c).*;
                if (got == want) continue;
                std.debug.print(
                    "row {d} col {d}: screen has U+{X} but the frame says U+{X}\n",
                    .{ r, c, got, want },
                );
                return error.ResidueOnScreen;
            }
        }
    }
};

/// Rows a terminal is genuinely liable to disagree with us about: ambiguous
/// width symbols, a VS16 promotion, CJK, an emoji landing on the last cell,
/// box drawing that fills the row exactly.
const torture = [_][]const u8{
    "\u{2713} bash finished ok",
    "\u{2713}\u{FE0F} bash finished ok",
    "\u{65E5}\u{672C}\u{8A9E} mixed \u{1F680}",
    "\u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}",
    "plain ascii row",
    "",
    "e\u{0301}dge combining",
    "trailing wide \u{1F409}",
};

/// Frame A: the torture rows cut to exactly `cols`. Frame B: the same rows
/// half as wide, so every row shrinks under the diff paint — including the
/// ones that measured exactly full, which is where the painter used to skip
/// both the pad and the erase.
fn tortureFrames(ar: std.mem.Allocator, cols: usize) ![2][]const u8 {
    var a_buf = std.array_list.Managed(u8).init(ar);
    var b_buf = std.array_list.Managed(u8).init(ar);
    for (torture, 0..) |row, i| {
        if (i > 0) {
            try a_buf.append('\n');
            try b_buf.append('\n');
        }
        try a_buf.appendSlice(theme_mod.takeCols(row, cols));
        try b_buf.appendSlice(theme_mod.takeCols(row, cols / 2));
    }
    return .{ a_buf.items, b_buf.items };
}

test "diff paint leaves no residue when a torture frame shrinks under it" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const cols: usize = 10;
    const rows = torture.len;
    const frames = try tortureFrames(ar, cols);
    var screen = try Screen.init(ar, rows, cols);
    screen.feed(try paintToBuf(ar, frames[0], rows, cols, ""));
    var want_a = try Screen.expect(ar, frames[0], rows, cols, true);
    try screen.expectMatches(&want_a);
    // ...and now the diff paint, with A as the baseline.
    screen.feed(try paintToBuf(ar, frames[1], rows, cols, frames[0]));
    var want_b = try Screen.expect(ar, frames[1], rows, cols, true);
    try screen.expectMatches(&want_b);
}

test "a terminal that disagrees with visibleLen still shows only the frame" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const cols: usize = 10;
    // visibleLen says 10 — exactly full — but a terminal that ignores the
    // VS16 selector draws the check mark in ONE cell and the row ends a column
    // short. The frame before it filled all ten. Skipping the erase on a row
    // that "measures full" left column 9 showing the previous frame's X;
    // erasing the row before writing it cannot, whoever is right about the
    // glyph.
    const claims_full = "\u{2713}\u{FE0F}bash ok!";
    const filled = "XXXXXXXXXX";
    try std.testing.expectEqual(cols, theme_mod.visibleLen(claims_full));
    try std.testing.expectEqual(cols, theme_mod.visibleLen(filled));
    var screen = try Screen.init(ar, 1, cols);
    screen.vs16_wide = false;
    screen.feed(try paintToBuf(ar, filled, 1, cols, ""));
    screen.feed(try paintToBuf(ar, claims_full, 1, cols, filled));
    var want = try Screen.expect(ar, claims_full, 1, cols, false);
    try screen.expectMatches(&want);
}

test "a row that measures full is erased before it is written, never after" {
    const a = std.testing.allocator;
    // 10 columns of box drawing: EL after the last cell would erase the right
    // corner, EL before it cannot, and skipping EL entirely would strand the
    // previous frame's cells if the terminal draws the row narrower than we
    // measured it.
    const full = "\u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}";
    try std.testing.expectEqual(@as(usize, 10), theme_mod.visibleLen(full));
    const out = try paintToBuf(a, full, 1, 10, "XXXXXXXXXX");
    defer a.free(out);
    const erase = std.mem.indexOf(u8, out, "\x1b[K").?;
    const corner = std.mem.indexOf(u8, out, "\u{256D}").?;
    try std.testing.expect(erase < corner);
    try std.testing.expect(std.mem.indexOfPos(u8, out, corner, "\x1b[K") == null);
    // The border itself survives intact.
    try std.testing.expect(std.mem.indexOf(u8, out, full) != null);
}

test "a shorter row is padded to the width and then erased" {
    const a = std.testing.allocator;
    const out = try paintToBuf(a, "short", 1, 12, "RESIDUERESID");
    defer a.free(out);
    const text = std.mem.indexOf(u8, out, "short").?;
    const filler = std.mem.indexOfPos(u8, out, text, "       ").?; // 12 - 5
    const erase = std.mem.indexOfPos(u8, out, filler, "\x1b[K").?;
    try std.testing.expect(erase > filler);
}

test "an over-wide row is cut to the width instead of overflowing it" {
    const a = std.testing.allocator;
    // A builder bug (or a width the frame was composed at before a resize)
    // must not hand the terminal more cells than the row has: with autowrap
    // off it piles onto the last cell, and with autowrap ON it would shift
    // every row below by one and desync the whole diff model.
    const out = try paintToBuf(a, "abcdefghijklmnop", 1, 8, "old row!");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "abcdefgh") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "abcdefghi") == null);
}

test "every repainted row re-establishes its own style" {
    const a = std.testing.allocator;
    // Row 0 opens a colour and never closes it; row 1 is plain. Under a diff
    // paint that touches only row 1 it must NOT inherit row 0's colour — and
    // the only way to promise that is to reset at the head of every row.
    const frame = "\x1b[31mred and unterminated\nplain";
    const out = try paintToBuf(a, frame, 2, 40, "\x1b[31mred and unterminated\nSTALE");
    defer a.free(out);
    const cup = std.mem.indexOf(u8, out, "\x1b[2;1H").?;
    try std.testing.expectEqualStrings(row_prologue, out[cup + 6 ..][0..row_prologue.len]);
    // Row 0 did not change, so it was not touched at all.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") == null);
    // The full path resets per row too.
    const full = try paintToBuf(a, frame, 2, 40, "");
    defer a.free(full);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, full, row_prologue));
}

test "clearing a selection band repaints every row the band covered" {
    const a = std.testing.allocator;
    // The band is an SGR-only change on rows 1 and 2 — byte-wise different,
    // which is exactly why the diff painter has to rewrite them when the band
    // goes away. (If it ever compared visible text instead of bytes, the
    // inverse video would stay on screen after the copy.)
    const banded = "head\n\x1b[7malpha\x1b[27m\n\x1b[7mbeta\x1b[27m\ntail";
    const clean = "head\nalpha\nbeta\ntail";
    try std.testing.expect(!rowChanged(banded, clean, 0));
    try std.testing.expect(rowChanged(banded, clean, 1));
    try std.testing.expect(rowChanged(banded, clean, 2));
    try std.testing.expect(!rowChanged(banded, clean, 3));
    const out = try paintToBuf(a, clean, 4, 20, banded);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") == null);
}

test "the self-heal rewrites every row and never flashes the screen" {
    const a = std.testing.allocator;
    const frame = "one\ntwo\nthree";
    // Identical baseline: without `force` this is a no-op paint...
    const idle = try paintToBuf(a, frame, 3, 20, frame);
    defer a.free(idle);
    try std.testing.expectEqual(@as(usize, 0), idle.len);
    // ...and with it, every row is rewritten, with no clear-screen in sight.
    const healed = try paintForced(a, frame, 3, 20, frame, true);
    defer a.free(healed);
    for ([_][]const u8{ "\x1b[1;1H", "\x1b[2;1H", "\x1b[3;1H", "one", "two", "three" }) |want| {
        try std.testing.expect(std.mem.indexOf(u8, healed, want) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, healed, "\x1b[2J") == null);
    // The heal is idempotent on a screen that already shows the frame.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var screen = try Screen.init(ar, 3, 20);
    screen.feed(try paintToBuf(ar, frame, 3, 20, ""));
    var want = try Screen.expect(ar, frame, 3, 20, true);
    try screen.expectMatches(&want);
    screen.feed(try paintForced(ar, frame, 3, 20, frame, true));
    try screen.expectMatches(&want);
}

test "a full repaint never ends with a cursor-inclusive erase" {
    const a = std.testing.allocator;
    // The bottom row measures EXACTLY the width, so the erase-first branch
    // draws it and leaves the cursor ON the last column (autowrap is off).
    // Any ED/EL emitted after that erases the glyph just drawn — which is the
    // same class of loss the erase-first design exists to prevent, one row
    // lower. The clear at the head of a full paint already covers the whole
    // display, so nothing after the last row is needed OR safe.
    const bar = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}";
    const frame = "top row\nmiddle\n" ++ bar;
    try std.testing.expectEqual(@as(usize, 10), theme_mod.visibleLen(bar));
    const out = try paintToBuf(a, frame, 3, 10, "");
    defer a.free(out);
    const last = std.mem.lastIndexOf(u8, out, "\u{2500}").? + 3;
    try std.testing.expectEqualStrings("", out[last..]);
}

test "rows past the end of the frame are blanked, not left stale" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var screen = try Screen.init(ar, 4, 12);
    screen.feed(try paintToBuf(ar, "aaaa\nbbbb\ncccc\ndddd", 4, 12, ""));
    // The next frame is two rows shorter — the transcript scrolled away.
    screen.feed(try paintToBuf(ar, "aaaa\nbbbb", 4, 12, "aaaa\nbbbb\ncccc\ndddd"));
    var want = try Screen.expect(ar, "aaaa\nbbbb", 4, 12, true);
    try screen.expectMatches(&want);
}

test "the real band's rows are exactly the rows the painter rewrites (#529)" {
    // The band is a post-pass over the composed frame, so when it CLEARS the
    // only thing that puts those rows back is the byte comparison in
    // rowChanged. An SGR-only difference is still a difference — this pins
    // that, end to end, through the real model rather than a hand-written
    // frame, because a painter that ever compared visible TEXT instead would
    // leave inverse video on screen after the copy.
    const app = @import("app.zig");
    const keys = @import("keys.zig");
    const render_mod = @import("render.zig");
    const a = std.testing.allocator;
    var m: app.Model = undefined;
    m.setup(a);
    defer m.deinit();
    try m.push(.assistant, "BANDME alpha line");
    try m.push(.assistant, "BANDME beta line");
    a.free(try render_mod.render(&m, a, 80, 24, 0)); // lays down mid_origin
    const top = m.mid_origin + m.sticky_rows;
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 0, .x = 1, .y = @intCast(top + 1), .down = true } });
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 32, .x = 40, .y = @intCast(top + 2), .down = true } });
    const banded = try render_mod.render(&m, a, 80, 24, 0);
    defer a.free(banded);
    try std.testing.expect(std.mem.indexOf(u8, banded, "\x1b[7m") != null);
    _ = keys.handle(&m, .{ .char = 'x' }); // any ordinary key drops the band
    const clean = try render_mod.render(&m, a, 80, 24, 0);
    defer a.free(clean);
    try std.testing.expect(rowChanged(banded, clean, top));
    try std.testing.expect(rowChanged(banded, clean, top + 1));
    const out = try paintToBuf(a, clean, 24, 80, banded);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") == null);
    var buf: [16]u8 = undefined;
    for ([_]usize{ top + 1, top + 2 }) |one_based| {
        const cup = try std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{one_based});
        try std.testing.expect(std.mem.indexOf(u8, out, cup) != null);
    }
}

test "rowChanged only flags the line that actually moved" {
    const prev = "top\nmiddle\nbottom";
    const next = "top\nmiddle\nBOTTOM";
    try std.testing.expect(!rowChanged(prev, next, 0));
    try std.testing.expect(!rowChanged(prev, next, 1));
    try std.testing.expect(rowChanged(prev, next, 2));
    try std.testing.expect(!rowChanged(prev, prev, 2));
}

test "paint erases a row whose glyphs are ambiguous width" {
    const a = std.testing.allocator;
    // "  ✓ bash finished ok" draws 20 cells. When visibleLen claimed 21 it
    // measured full at cols=21, so the old painter skipped the pad AND the
    // erase and the 21st cell kept the previous frame.
    const frame = "  \u{2713} bash finished ok";
    try std.testing.expectEqual(@as(usize, 20), theme_mod.visibleLen(frame));
    const out = try paintToBuf(a, frame, 1, 21, "RESIDUE RESIDUE RESIDU");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[K") != null);
}
