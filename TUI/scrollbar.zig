//! The transcript's scroll position indicator — a one-column thumb on the right
//! edge of the viewport.
//!
//! Presentation state, end to end. The geometry comes from the band render.zig
//! already publishes on the Model (which rows scroll, which slice of the cached
//! layout they show, how many lines that layout holds); nothing here reads a
//! transcript entry, and nothing here re-parses a rendered row.
//!
//! Three rules, and every branch below serves one of them.
//!
//!   * **It appears only when it means something.** Scrolled off the tail, it
//!     is the only thing on screen that says how far. Parked at the tail it is
//!     noise, so it fades: visible for `fade_ms` after the last scroll event
//!     and then gone. A transcript that fits the viewport has no thumb at all.
//!   * **It never destroys content.** The overlay replaces the LAST column of
//!     the rows it covers, and it is applied to the composed frame — so when it
//!     hides, the row is simply composed without it and paint.zig's row diff
//!     rewrites exactly those rows. There is no separate "erase the scrollbar"
//!     path that could fall out of step, and a forced full repaint of the same
//!     frame lands on the same cells (paint.zig's own equality proof).
//!   * **The selection band outranks it.** The band owns inverse video across
//!     whole rows and captures the text under it; a thumb inside that rectangle
//!     would be painted over, and — worse — would be a glyph the capture never
//!     asked for. While a drag is live the thumb hides.
//!
//! The glyph is `glyphs.scroll_thumb`, registered narrow-class: one column in
//! every terminal, including one configured to draw ambiguous-width glyphs
//! double. A two-column thumb on the last column would push itself off the row.

const std = @import("std");

const app = @import("app.zig");
const glyphs = @import("glyphs.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// How long the thumb lingers after the last scroll event while parked at the
/// tail. Same 1.5s the copy toast uses — one dwell constant for the chrome.
pub const fade_ms: u64 = 1500;

pub const Thumb = struct {
    /// Rows into the track, 0-based.
    top: usize,
    /// Rows tall, never zero.
    len: usize,
};

/// Thumb geometry for a `track`-row gutter showing `view` of `total` visual
/// lines with `off` lines above the viewport. Null when there is nothing to
/// indicate: no track, or a transcript that already fits.
///
/// Proportional, with two clamps that matter. The length rounds to nearest but
/// never below one row, so a 20k-line transcript still shows a thumb rather
/// than nothing. The position maps `off` over `[0, total - view]` onto
/// `[0, track - len]`, so the extremes are exact: at the top the thumb sits on
/// row 0, at the tail its last row is the track's last row. An off-by-one in
/// either clamp is what makes a scrollbar look like it never quite arrives.
pub fn thumb(track: usize, view: usize, total: usize, off: usize) ?Thumb {
    if (track == 0 or view == 0 or total <= view) return null;
    const len = @min(track, @max(1, (track * view + total / 2) / total));
    const span = track - len;
    const max_off = total - view;
    const at = @min(off, max_off);
    const top = if (span == 0 or max_off == 0) 0 else (span * at + max_off / 2) / max_off;
    return .{ .top = @min(top, span), .len = len };
}

/// Whether the thumb shows at all. `scroll` is the model's distance from the
/// tail, so a non-zero one means the user is looking at history and the
/// indicator is load-bearing; at the tail it is only the fade window.
pub fn visible(self: *const Model) bool {
    if (self.sel.active or self.sel.pressed) return false;
    if (!self.band.live or self.band.len == 0) return false;
    if (self.band.total <= self.band.len) return false;
    if (self.scroll != 0) return true;
    if (self.scroll_seen_ms == 0) return false; // nothing has ever scrolled
    return self.now_ms -| self.scroll_seen_ms < fade_ms;
}

/// The thumb this frame wants, or null. Split out from `paint` so the geometry
/// is testable without composing a frame.
pub fn current(self: *const Model) ?Thumb {
    if (!visible(self)) return null;
    return thumb(self.band.len, self.band.len, self.band.total, self.band.off);
}

/// Post-pass over the COMPOSED frame, after selection.paint: the row builders
/// stay unaware of the gutter, and the selection capture never sees the glyph.
/// Returns `frame` untouched whenever the thumb is hidden, which is what makes
/// hiding self-healing rather than a second code path.
///
/// While it IS showing, EVERY band row gets the gutter shape — content cut to
/// `width - 1`, padded to it, then the cell — and rows off the thumb carry a
/// space there. That uniformity is not cosmetic: it is what lets the painter's
/// scroll fast path keep working. A hardware scroll slides the whole row, but
/// the gutter's position comes from the scroll OFFSET and does not travel with
/// the lines under it; with every band row the same shape, scrollpaint.zig can
/// compare the content halves (which do slide) and patch the one cell that
/// does not. Reshape only the thumb rows and every notch would look like a
/// band whose rows changed for their own reasons, and the fast path would be
/// refused on exactly the frames it exists for.
pub fn paint(self: *Model, a: std.mem.Allocator, frame: []const u8, width: usize) ![]const u8 {
    if (width < 2) return frame;
    const t = current(self) orelse {
        self.gutter_on = false;
        return frame;
    };
    self.gutter_on = true;
    const first = self.band.top + t.top;
    const last = first + t.len; // exclusive
    var out = std.array_list.Managed(u8).init(a);
    var row: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    const style = self.theme().muted;
    while (it.next()) |ln| : (row += 1) {
        if (row > 0) try out.append('\n');
        if (row < self.band.top or row >= self.band.top + self.band.len) {
            try out.appendSlice(ln);
            continue;
        }
        try gutterRow(&out, ln, width, style, row >= first and row < last);
    }
    return out.items;
}

/// One band row in the gutter shape: `content ++ pad ++ reset ++ style ++ cell`.
/// The reset is the SPLIT MARKER the painter looks for (scrollpaint.zig takes
/// everything from the last one as the cell), and it also stops the gutter's
/// colour leaking into the next row a diff paint touches.
fn gutterRow(out: *std.array_list.Managed(u8), ln: []const u8, width: usize, style: []const u8, thumb_here: bool) !void {
    const keep = width - 1;
    const body = theme_mod.takeCols(ln, keep);
    try out.appendSlice(body);
    var pad = keep - theme_mod.visibleLen(body);
    while (pad > 0) : (pad -= 1) try out.append(' ');
    try out.appendSlice(theme_mod.reset);
    try out.appendSlice(style);
    try out.appendSlice(if (thumb_here) glyphs.scroll_thumb else " ");
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "a transcript that fits the viewport has no thumb" {
    try testing.expect(thumb(10, 10, 10, 0) == null);
    try testing.expect(thumb(10, 10, 3, 0) == null);
    try testing.expect(thumb(0, 10, 100, 0) == null);
}

test "the thumb is proportional and its extremes are exact" {
    // Half the transcript on screen: half the track, at the top and then at
    // the bottom. The tail case is the one that goes wrong first — a thumb
    // that stops one row short reads as "there is still more below".
    const top = thumb(10, 10, 20, 0).?;
    try testing.expectEqual(@as(usize, 0), top.top);
    try testing.expectEqual(@as(usize, 5), top.len);
    const tail = thumb(10, 10, 20, 10).?;
    try testing.expectEqual(@as(usize, 5), tail.top);
    try testing.expectEqual(@as(usize, 5), tail.len);
    try testing.expectEqual(@as(usize, 10), tail.top + tail.len);
    // ...and the middle is the middle.
    const mid = thumb(10, 10, 20, 5).?;
    try testing.expectEqual(@as(usize, 3), mid.top);
}

test "a huge transcript still shows one row, and it still reaches the end" {
    // 20k lines in a 24-row viewport: the proportional length rounds to zero,
    // and a zero-row thumb is an invisible one.
    const t = thumb(24, 24, 20_000, 0).?;
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(@as(usize, 0), t.top);
    const end = thumb(24, 24, 20_000, 19_976).?;
    try testing.expectEqual(@as(usize, 1), end.len);
    try testing.expectEqual(@as(usize, 23), end.top);
}

test "the thumb never leaves the track, at any length or offset" {
    // The invariant a scrollbar is allowed exactly one of: every reachable
    // offset must produce a thumb wholly inside the gutter. Off by one here
    // and the glyph lands on the composer or on the row above the viewport.
    for ([_]usize{ 1, 2, 3, 7, 24, 60 }) |track| {
        for ([_]usize{ 1, 2, 5, 40, 999, 20_000 }) |extra| {
            const total = track + extra;
            var off: usize = 0;
            while (off <= extra) : (off += @max(1, extra / 17)) {
                const t = thumb(track, track, total, off).?;
                try testing.expect(t.len >= 1);
                try testing.expect(t.len <= track);
                try testing.expect(t.top + t.len <= track);
            }
            // The very last offset, exactly.
            const last = thumb(track, track, total, extra).?;
            try testing.expectEqual(track, last.top + last.len);
            const first = thumb(track, track, total, 0).?;
            try testing.expectEqual(@as(usize, 0), first.top);
        }
    }
}

test "an offset past the end is clamped, never wrapped" {
    const t = thumb(10, 10, 20, 999).?;
    try testing.expectEqual(@as(usize, 10), t.top + t.len);
}

fn scrolledModel(m: *Model) void {
    m.band = .{ .live = true, .top = 2, .len = 10, .off = 30, .total = 100 };
    m.scroll = 7;
    m.now_ms = 10_000;
    m.scroll_seen_ms = 10_000;
}

test "the hide rules: tail fade, no band, and a live selection" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    scrolledModel(&m);
    try testing.expect(visible(&m));
    // At the tail it lingers for the fade window and then goes.
    m.scroll = 0;
    m.now_ms = 10_000 + fade_ms - 1;
    try testing.expect(visible(&m));
    m.now_ms = 10_000 + fade_ms;
    try testing.expect(!visible(&m));
    // ...but scrolled off the tail it is unconditional, however stale.
    m.scroll = 3;
    m.now_ms = 10_000_000;
    try testing.expect(visible(&m));
    // A drag owns those rows.
    m.sel.pressed = true;
    try testing.expect(!visible(&m));
    m.sel.pressed = false;
    m.sel.active = true;
    try testing.expect(!visible(&m));
    m.sel.active = false;
    try testing.expect(visible(&m));
    // No band at all (welcome pane, an overlay body) means no gutter.
    m.band.live = false;
    try testing.expect(!visible(&m));
    // A transcript that fits shows nothing even mid-scroll.
    m.band.live = true;
    m.band.total = 4;
    try testing.expect(!visible(&m));
    // Nothing has ever scrolled: no thumb before the user asks for one.
    m.band.total = 100;
    m.scroll = 0;
    m.scroll_seen_ms = 0;
    try testing.expect(!visible(&m));
}

test "the overlay lands on the last column of exactly the thumb's rows" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    // Track rows 2..12 of the screen, half the transcript on view, parked at
    // the tail: the thumb is the bottom half of the track.
    m.band = .{ .live = true, .top = 2, .len = 10, .off = 10, .total = 20 };
    m.scroll = 1;
    const t = current(&m).?;
    try testing.expectEqual(@as(usize, 5), t.top);
    try testing.expectEqual(@as(usize, 5), t.len);
    var frame = std.array_list.Managed(u8).init(ar);
    for (0..16) |i| {
        if (i > 0) try frame.append('\n');
        try frame.appendSlice("row body");
    }
    const width: usize = 20;
    const out = try paint(&m, ar, frame.items, width);
    var row: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| : (row += 1) {
        const marked = std.mem.indexOf(u8, ln, glyphs.scroll_thumb) != null;
        const want = row >= 7 and row < 12; // band.top + [5,10)
        try testing.expectEqual(want, marked);
        if (!marked) continue;
        // Exactly `width` columns, with the glyph on the last one.
        try testing.expectEqual(width, theme_mod.visibleLen(ln));
        try testing.expect(std.mem.endsWith(u8, ln, glyphs.scroll_thumb));
    }
    try testing.expectEqual(@as(usize, 16), row);
}

test "hiding restores the frame byte for byte" {
    // The no-residue promise, at the source: with the thumb hidden the pass is
    // the identity, so the row the painter rewrites is the row the composer
    // built. Nothing has to remember to erase a gutter.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    const frame = "alpha\nbeta\ngamma\ndelta";
    m.band = .{ .live = true, .top = 0, .len = 2, .off = 1, .total = 4 };
    m.scroll = 1;
    const shown = try paint(&m, ar, frame, 12);
    try testing.expect(!std.mem.eql(u8, frame, shown));
    m.scroll = 0;
    m.scroll_seen_ms = 0;
    const hidden = try paint(&m, ar, frame, 12);
    try testing.expectEqualStrings(frame, hidden);
}

test "a row already at full width keeps its width when the thumb lands on it" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    m.band = .{ .live = true, .top = 0, .len = 1, .off = 1, .total = 8 };
    m.scroll = 1;
    // A full row, a short row, and a row ending in a double-width glyph that
    // would straddle the gutter column.
    for ([_][]const u8{ "0123456789", "ab", "12345678\u{1F409}" }) |body| {
        const out = try paint(&m, ar, body, 10);
        try testing.expectEqual(@as(usize, 10), theme_mod.visibleLen(out));
        try testing.expect(std.mem.endsWith(u8, out, glyphs.scroll_thumb));
    }
}
