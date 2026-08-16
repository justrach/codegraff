//! Scroll-aware painting: the fast path out of the diff painter.
//!
//! The diff painter compares screen row i to the PREVIOUS frame's row i. That
//! is exactly right for a token arriving or a spinner ticking, and exactly
//! wrong for a wheel event: sliding the transcript by one line makes every row
//! of the viewport differ from the row above it, so a one-line scroll repaints
//! the entire screen. At 3 lines per wheel notch and a notch every few
//! milliseconds that is the whole frame, over and over, down the pty.
//!
//! A terminal can do the sliding itself. Set a scroll region over the band
//! that actually moved (DECSTBM), emit SU/SD, drop the region, and only the
//! rows the scroll EXPOSED need bytes — plus whatever chrome legitimately
//! changed, which the ordinary row diff still handles.
//!
//! The danger is emitting a hardware scroll when the screen did not, in fact,
//! merely scroll. So this module never trusts the hint on its own: render.zig
//! reports the delta it believes the band moved by, and `plan` VERIFIES it
//! against the bytes of both frames — every row that would survive the shift
//! must already hold what the new frame wants there. Anything else in the band
//! (a fold toggling, a tool row finishing, a rewrap, a live token, an image
//! card resizing the viewport) breaks that equality and the caller falls back
//! to the full diff. Cases the verification cannot see — a self-heal repaint,
//! a resize, kitty images on screen, a live selection band anchored to SCREEN
//! rows rather than to content — are refused before we get here.

const std = @import("std");
const Io = std.Io;

const paint = @import("paint.zig");

/// What render.zig believes the last two frames did to the scrollable band.
/// `delta` counts CONTENT lines: positive means the viewport moved further
/// down the transcript, so the band's content slides UP the screen (SU).
pub const Hint = struct {
    /// First screen row of the band, 0-based. Sticky header rows are chrome
    /// and sit ABOVE this; the composer and status bar sit below the end.
    top: usize,
    len: usize,
    delta: isize,
};

/// Terminals taller than this fall back to the diff path rather than grow the
/// stack. Nothing in the TUI is fast enough to care at that size anyway.
const max_rows = 256;

const Plan = struct {
    /// Band rows the scroll exposes, as absolute screen rows.
    first_exposed: usize,
    count: usize,
    up: bool,
};

/// Frame lines indexed once. The diff painter's nthLine rescans from byte 0
/// for every row, which is O(rows x frame) per paint; the verification below
/// touches every row, so it does the split once instead.
const Lines = struct {
    buf: [max_rows][]const u8 = undefined,
    n: usize = 0,

    fn index(s: []const u8, rows: usize) Lines {
        var l: Lines = .{};
        var it = std.mem.splitScalar(u8, s, '\n');
        while (it.next()) |ln| {
            if (l.n >= rows or l.n >= max_rows) break;
            l.buf[l.n] = ln;
            l.n += 1;
        }
        return l;
    }

    fn at(self: *const Lines, i: usize) []const u8 {
        return if (i < self.n) self.buf[i] else "";
    }
};

/// Everything about a hint that can be judged from the hint alone, so the two
/// line indexes below are never built for a frame that cannot use them.
fn viable(rows: usize, h: Hint) bool {
    if (h.delta == 0 or h.len < 2 or rows > max_rows) return false;
    if (h.top + h.len > rows) return false;
    // A scroll that clears the whole band exposes every row of it: the region
    // dance would be pure overhead on top of the same repaint.
    return @abs(h.delta) < h.len;
}

/// Decide, writing nothing. Returns the exposed-row plan when a hardware
/// scroll is provably equivalent to repainting the band, and null otherwise —
/// a null here is never a correctness risk, only a missed optimisation.
fn plan(rows: usize, h: Hint, cur: *const Lines, old: *const Lines) ?Plan {
    if (!viable(rows, h)) return null;
    const mag: usize = @abs(h.delta);
    const up = h.delta > 0;
    const kept = h.len - mag;
    var j: usize = 0;
    while (j < kept) : (j += 1) {
        const dst = if (up) j else j + mag;
        const src = if (up) j + mag else j;
        if (!std.mem.eql(u8, cur.at(h.top + dst), old.at(h.top + src))) return null;
    }
    return .{
        .first_exposed = h.top + (if (up) kept else 0),
        .count = mag,
        .up = up,
    };
}

/// Paint `frame` over `prev` as a scroll plus its exposed rows. Returns false
/// WITHOUT writing a byte when the hint does not hold up, so the caller can
/// fall through to the ordinary diff.
pub fn tryPaint(
    w: *Io.Writer,
    frame: []const u8,
    rows: usize,
    cols: usize,
    prev: []const u8,
    bg: []const u8,
    h: Hint,
) !bool {
    if (!viable(rows, h)) return false;
    const cur = Lines.index(frame, rows);
    const old = Lines.index(prev, rows);
    const p = plan(rows, h, &cur, &old) orelse return false;

    // The rows the scroll opens up are filled with the ACTIVE background, not
    // the theme's, so establish it before the region moves. (Under ?2026 the
    // whole thing swaps atomically, but a terminal without it would flash.)
    try w.writeAll(paint.row_prologue);
    try w.writeAll(bg);
    // DECSTBM is 1-based and inclusive. It also homes the cursor, which costs
    // nothing here: every row painted below addresses itself with CUP.
    try w.print("\x1b[{d};{d}r", .{ h.top + 1, h.top + h.len });
    if (p.up) try w.print("\x1b[{d}S", .{p.count}) else try w.print("\x1b[{d}T", .{p.count});
    // Drop the region immediately. Left set, an LF anywhere later — a panic
    // message, the restore sequence — would scroll inside it instead of the
    // screen, and the margins survive the alt-screen exit.
    try w.writeAll("\x1b[r");

    var e: usize = 0;
    while (e < p.count) : (e += 1) {
        const r = p.first_exposed + e;
        try w.print("\x1b[{d};1H", .{r + 1});
        try paint.paintRow(w, cur.at(r), cols, bg);
    }
    // The band moved; nothing else did. Chrome that changed for its own
    // reasons — the sticky header now pinning a different prompt, a scroll
    // indicator, the composer — is still an ordinary row diff.
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        if (r >= h.top and r < h.top + h.len) continue;
        if (std.mem.eql(u8, cur.at(r), old.at(r))) continue;
        try w.print("\x1b[{d};1H", .{r + 1});
        try paint.paintRow(w, cur.at(r), cols, bg);
    }
    try w.flush();
    return true;
}

// ------------------------------------------------------------------ tests

const test_bg = "\x1b[48;2;20;20;20m";

fn emit(a: std.mem.Allocator, frame: []const u8, rows: usize, cols: usize, prev: []const u8, h: Hint) !?[]u8 {
    var aw = Io.Writer.Allocating.init(a);
    errdefer aw.deinit();
    if (!try tryPaint(&aw.writer, frame, rows, cols, prev, test_bg, h)) {
        aw.deinit();
        return null;
    }
    return try aw.toOwnedSlice();
}

/// A frame with two chrome rows on top, a scrollable band, and two chrome rows
/// at the bottom. `off` is the content offset of the band's first row.
fn frameAt(a: std.mem.Allocator, off: usize, rows: usize, band_top: usize, band_len: usize, chrome: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        if (r > 0) try out.append('\n');
        const line = if (r >= band_top and r < band_top + band_len)
            try std.fmt.allocPrint(a, "content line {d} of the transcript", .{off + r - band_top})
        else
            try std.fmt.allocPrint(a, "{s} chrome row {d}", .{ chrome, r });
        try out.appendSlice(line);
    }
    return out.items;
}

test "a one-line scroll costs one SU and the rows it exposed, not the screen" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const rows: usize = 24;
    const cols: usize = 80;
    const top: usize = 3; // top bar + sticky header + separator
    const len: usize = 18;
    const before = try frameAt(ar, 100, rows, top, len, "same");
    const after = try frameAt(ar, 101, rows, top, len, "same");
    const scrolled = (try emit(ar, after, rows, cols, before, .{ .top = top, .len = len, .delta = 1 })).?;
    // Exactly one scroll, in the right direction, over the right region.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, scrolled, "\x1b[1S"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, scrolled, "\x1b[1T"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, scrolled, "\x1b[4;21r"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, scrolled, "\x1b[r"));
    // ...and exactly one row of cells: the one the scroll exposed at the bottom.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, scrolled, "\x1b[21;1H"));
    // ...and that is the ONLY row addressed at all: the other 23 kept their cells.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, scrolled, ";1H"));
    // The budget. A full repaint of the same frame is the thing this replaces.
    var aw = Io.Writer.Allocating.init(ar);
    try paint.paint(&aw.writer, after, rows, cols, before, test_bg, true, null);
    const full = aw.written();
    try std.testing.expect(full.len > 1000); // sanity: a real 80x24 repaint
    if (scrolled.len * 4 >= full.len) {
        std.debug.print("scroll paint {d} bytes vs full repaint {d}\n", .{ scrolled.len, full.len });
        return error.ScrollPaintTooExpensive;
    }
}

test "scrolling the other way is a single SD over the same region" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const before = try frameAt(ar, 100, 24, 3, 18, "same");
    const after = try frameAt(ar, 97, 24, 3, 18, "same");
    const out = (try emit(ar, after, 24, 80, before, .{ .top = 3, .len = 18, .delta = -3 })).?;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[3T"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "S"));
    // Three rows exposed, and they are the TOP three of the band.
    for ([_][]const u8{ "\x1b[4;1H", "\x1b[5;1H", "\x1b[6;1H" }) |cup| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, cup));
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7;1H") == null);
}

test "chrome that changed on the same frame is still repainted" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    // The sticky header now pins a different prompt and the status bar moved:
    // both live OUTSIDE the band, so the scroll cannot carry them.
    const before = try frameAt(ar, 100, 24, 3, 18, "old");
    const after = try frameAt(ar, 101, 24, 3, 18, "new");
    const out = (try emit(ar, after, 24, 80, before, .{ .top = 3, .len = 18, .delta = 1 })).?;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[1S"));
    for ([_][]const u8{ "\x1b[1;1H", "\x1b[2;1H", "\x1b[3;1H", "\x1b[22;1H", "\x1b[23;1H", "\x1b[24;1H" }) |cup| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, cup));
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "new chrome row 0") != null);
}

test "a hint the frames do not bear out is refused without writing a byte" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const before = try frameAt(ar, 100, 24, 3, 18, "same");
    const after = try frameAt(ar, 101, 24, 3, 18, "same");
    // Wrong magnitude, wrong direction, a band the frame never moved, a delta
    // that clears the band, a band running off the screen: all refused.
    for ([_]Hint{
        .{ .top = 3, .len = 18, .delta = 2 },
        .{ .top = 3, .len = 18, .delta = -1 },
        .{ .top = 3, .len = 18, .delta = 18 },
        .{ .top = 3, .len = 18, .delta = 0 },
        .{ .top = 3, .len = 30, .delta = 1 },
        .{ .top = 2, .len = 18, .delta = 1 },
    }) |h| {
        try std.testing.expect((try emit(ar, after, 24, 80, before, h)) == null);
    }
    // A fold toggling inside the band on the same frame as the scroll: the
    // rows that "survive" no longer match, so the scroll is off the table.
    var folded = std.array_list.Managed(u8).init(ar);
    var it = std.mem.splitScalar(u8, after, '\n');
    var r: usize = 0;
    while (it.next()) |ln| : (r += 1) {
        if (r > 0) try folded.append('\n');
        try folded.appendSlice(if (r == 9) "the tool run just expanded" else ln);
    }
    try std.testing.expect((try emit(ar, folded.items, 24, 80, before, .{ .top = 3, .len = 18, .delta = 1 })) == null);
}

test "a selection band dropped by the same wheel notch blocks the scroll" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    // The wheel CLEARS the drag band and scrolls in one event (keys.zig): the
    // band is anchored to screen rows, so it cannot ride the scroll. render.zig
    // refuses the hint while a band is live, but the frame AFTER it clears is
    // an ordinary frame with an ordinary hint — and the screen it is painted
    // over still has inverse video on rows the scroll would carry. Bytes catch
    // it: an SGR-only difference is a difference.
    const clean_prev = try frameAt(ar, 100, 24, 3, 18, "same");
    var banded = std.array_list.Managed(u8).init(ar);
    var it = std.mem.splitScalar(u8, clean_prev, '\n');
    var r: usize = 0;
    while (it.next()) |ln| : (r += 1) {
        if (r > 0) try banded.append('\n');
        if (r >= 6 and r <= 8) try banded.appendSlice("\x1b[7m");
        try banded.appendSlice(ln);
        if (r >= 6 and r <= 8) try banded.appendSlice("\x1b[27m");
    }
    const after = try frameAt(ar, 101, 24, 3, 18, "same");
    const h: Hint = .{ .top = 3, .len = 18, .delta = 1 };
    // Over the CLEAN screen the scroll is fine; over the banded one it is not.
    try std.testing.expect((try emit(ar, after, 24, 80, clean_prev, h)) != null);
    try std.testing.expect((try emit(ar, after, 24, 80, banded.items, h)) == null);
}

/// A terminal that also knows DECSTBM / SU / SD — the two sequences the diff
/// painter's own screen model never had to understand.
const Screen = struct {
    rows: usize,
    cols: usize,
    cells: []u8,
    row: usize = 0,
    col: usize = 0,
    top: usize = 0,
    bot: usize,

    fn init(a: std.mem.Allocator, rows: usize, cols: usize) !Screen {
        const cells = try a.alloc(u8, rows * cols);
        @memset(cells, ' ');
        return .{ .rows = rows, .cols = cols, .cells = cells, .bot = rows - 1 };
    }

    fn at(self: *Screen, r: usize, c: usize) *u8 {
        return &self.cells[r * self.cols + c];
    }

    fn rowSlice(self: *Screen, r: usize) []u8 {
        return self.cells[r * self.cols ..][0..self.cols];
    }

    fn scroll(self: *Screen, n: usize, up: bool) void {
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (up) {
                var r = self.top;
                while (r < self.bot) : (r += 1) @memcpy(self.rowSlice(r), self.rowSlice(r + 1));
                @memset(self.rowSlice(self.bot), ' ');
            } else {
                var r = self.bot;
                while (r > self.top) : (r -= 1) @memcpy(self.rowSlice(r), self.rowSlice(r - 1));
                @memset(self.rowSlice(self.top), ' ');
            }
        }
    }

    fn feed(self: *Screen, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1b) {
                const e = @import("theme.zig").skipEsc(s, i);
                self.control(s[i..e]);
                i = e;
                continue;
            }
            if (s[i] == '\r') {
                self.col = 0;
            } else if (s[i] == '\n') {
                self.row += 1;
            } else if (self.row < self.rows and self.col < self.cols) {
                self.at(self.row, self.col).* = s[i];
                self.col += 1;
            }
            i += 1;
        }
    }

    fn control(self: *Screen, seq: []const u8) void {
        if (seq.len < 3 or seq[1] != '[') return;
        const final = seq[seq.len - 1];
        const body = seq[2 .. seq.len - 1];
        var it = std.mem.splitScalar(u8, body, ';');
        const p0 = std.fmt.parseInt(usize, it.first(), 10) catch 0;
        switch (final) {
            'H' => {
                self.row = if (p0 > 0) p0 - 1 else 0;
                self.col = 0;
            },
            'J' => if (std.mem.eql(u8, body, "2")) {
                @memset(self.cells, ' ');
                self.row = 0;
                self.col = 0;
            },
            'K' => if (self.row < self.rows) {
                var c = self.col;
                while (c < self.cols) : (c += 1) self.at(self.row, c).* = ' ';
            },
            'r' => {
                const p1 = std.fmt.parseInt(usize, it.next() orelse "", 10) catch 0;
                self.top = if (p0 > 0) p0 - 1 else 0;
                self.bot = if (p1 > 0 and p1 <= self.rows) p1 - 1 else self.rows - 1;
                self.row = self.top;
                self.col = 0;
            },
            'S' => self.scroll(@max(p0, 1), true),
            'T' => self.scroll(@max(p0, 1), false),
            else => {},
        }
    }
};

test "a scroll storm leaves the screen exactly where a full repaint would" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const rows: usize = 24;
    const cols: usize = 80;
    const top: usize = 3;
    const len: usize = 18;
    var screen = try Screen.init(ar, rows, cols);
    var off: usize = 200;
    var cur = try frameAt(ar, off, rows, top, len, "same");
    // Lay the first frame down in full, then scroll it around.
    {
        var aw = Io.Writer.Allocating.init(ar);
        try paint.paint(&aw.writer, cur, rows, cols, "", test_bg, false, null);
        screen.feed(aw.written());
    }
    var took: usize = 0;
    for ([_]isize{ 3, 3, 3, -1, -3, 7, -7, 1, 1, 1, 1, -17, 17, 2, -2 }) |d| {
        const next_off: usize = @intCast(@as(isize, @intCast(off)) + d);
        const next = try frameAt(ar, next_off, rows, top, len, "same");
        const out = try emit(ar, next, rows, cols, cur, .{ .top = top, .len = len, .delta = d });
        if (out) |bytes| {
            screen.feed(bytes);
            took += 1;
        } else {
            // The fallback the caller would take.
            var aw = Io.Writer.Allocating.init(ar);
            try paint.paint(&aw.writer, next, rows, cols, cur, test_bg, false, null);
            screen.feed(aw.written());
        }
        off = next_off;
        cur = next;
    }
    // Most of the storm really did take the scroll path...
    try std.testing.expect(took >= 10);
    // ...and a forced full repaint of the final frame changes nothing at all.
    var truth = try Screen.init(ar, rows, cols);
    {
        var aw = Io.Writer.Allocating.init(ar);
        try paint.paint(&aw.writer, cur, rows, cols, "", test_bg, false, null);
        truth.feed(aw.written());
    }
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        if (std.mem.eql(u8, screen.rowSlice(r), truth.rowSlice(r))) continue;
        std.debug.print("row {d}:\n  screen {s}\n  truth  {s}\n", .{ r, screen.rowSlice(r), truth.rowSlice(r) });
        return error.ScrollStormLeftResidue;
    }
    // And the scroll region is back to the whole screen, so nothing later
    // scrolls inside a stale margin.
    try std.testing.expectEqual(@as(usize, 0), screen.top);
    try std.testing.expectEqual(rows - 1, screen.bot);
}
