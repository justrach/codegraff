//! Logical scroll anchor across a width rewrap.
//!
//! `Model.scroll` is a distance from the BOTTOM of the transcript in visual
//! rows, so a width change — which rewraps every line under the viewport —
//! keeps the number and loses the content: the row that was on top becomes a
//! different row of a different entry, and the transcript jumps under the
//! user's eyes. grok-build fixes this by holding a LOGICAL position across the
//! rebuild instead of a row count, and so do we: before the rewrap, record
//! which history entry owned the top visible line and how far into that
//! entry's block the line sat; after it, put that same logical line back on
//! top. Presentation only — nothing here is engine state.

const std = @import("std");

const app = @import("app.zig");
const scrollback = @import("scrollback.zig");
const Model = app.Model;

/// Where the viewport was parked, in transcript terms rather than screen rows:
/// the history entry whose block the top visible line belonged to, plus that
/// line's ordinal WITHIN the block. Both survive a rewrap; a row index cannot.
pub const Anchor = struct { idx: usize, ordinal: usize };

/// The anchor for the top visible transcript line of the frame last painted at
/// `width`. Null when there is nothing to hold: an empty transcript, or a user
/// who is tailing — follow mode is already an anchor, and a better one (the
/// bottom), so a rewrap must not drag the viewport off it.
pub fn capture(self: *const Model, width: usize) ?Anchor {
    if (self.follow or width == 0 or self.history.items.len == 0) return null;
    const top = self.mid_skip;
    const idx = scrollback.indexAtVisual(self, top, width) orelse return null;
    const base = scrollback.visualOfIndex(self, idx, width) orelse return null;
    return .{ .idx = idx, .ordinal = top -| base };
}

/// The transcript row that shows the anchored logical line at `width`. A block
/// that rewrapped SHORTER clamps to its own last line, so the anchor stays
/// inside the entry it was taken from instead of sliding into the next one.
pub fn rowAt(self: *const Model, anc: Anchor, width: usize) usize {
    const base = scrollback.visualOfIndex(self, anc.idx, width) orelse return 0;
    const span = blockSpan(self, anc.idx, width, base);
    if (span == 0) return base;
    return base + @min(anc.ordinal, span - 1);
}

/// How many visual rows entry `idx`'s block occupies at `width`. Measured as
/// the gap to the next block rather than by re-rendering the entry, so a
/// collapsed or expanded tool RUN — which the row math treats as one unit —
/// is measured the same way the viewport lays it out.
fn blockSpan(self: *const Model, idx: usize, width: usize, base: usize) usize {
    const nxt = nextBlock(self, idx);
    if (nxt >= self.history.items.len) return scrollback.totalVisualLines(self, width) -| base;
    const nb = scrollback.visualOfIndex(self, nxt, width) orelse return 1;
    return nb -| base;
}

fn nextBlock(self: *const Model, idx: usize) usize {
    if (idx < self.history.items.len and self.history.items[idx].kind == .tool)
        return self.toolRun(idx).end;
    return idx + 1;
}

// ---------------------------------------------------------------------------

const render_mod = @import("render.zig");
const testing = std.testing;

/// Park the viewport so entry `idx`'s first row is the top visible line, using
/// only what a real frame leaves on the Model: after a render with scroll = 0
/// and follow off, `mid_skip` IS max_scroll. Fails loudly when the entry sits
/// too near the end to ever BE a top line — a silently mis-parked viewport
/// would make every assertion below vacuous.
fn park(m: *Model, width: usize, height: usize, idx: usize) !usize {
    m.follow = false;
    // Sync `last_term_width` FIRST so neither probe below is itself a rewrap —
    // parking is setup, not the behaviour under test.
    const sync = try render_mod.render(m, testing.allocator, width, height, 0);
    testing.allocator.free(sync);
    m.scroll = 0;
    const probe = try render_mod.render(m, testing.allocator, width, height, 0);
    testing.allocator.free(probe);
    const max_scroll = m.mid_skip;
    const want = scrollback.visualOfIndex(m, idx, width) orelse return error.NoSuchEntry;
    if (want > max_scroll) return error.EntryCannotBeTopLine;
    m.scroll = max_scroll - want;
    const frame = try render_mod.render(m, testing.allocator, width, height, 0);
    testing.allocator.free(frame);
    try testing.expectEqual(want, m.mid_skip);
    return want;
}

fn rewrap(m: *Model, width: usize, height: usize) ![]const u8 {
    return render_mod.render(m, testing.allocator, width, height, 0);
}

// `**` is avoided on purpose: this zig fmt mangles it. Ten words a line,
// seven lines — long enough that the entry spans several rows at 100 cols.
const wrapme = " wrapme wrapme wrapme wrapme wrapme wrapme wrapme wrapme wrapme wrapme";
const wrap_tail = wrapme ++ wrapme ++ wrapme ++ wrapme ++ wrapme ++ wrapme ++ wrapme;

fn fill(m: *Model, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try m.push(.assistant, "a long explanation line that fills the scrollback with content and wraps at every narrow width we test");
    }
}

test "a width rewrap keeps the anchored entry on the top row" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fill(&m, 30);
    try m.push(.user, "MARKERONE");
    try fill(&m, 30);

    const idx: usize = 30;
    _ = try park(&m, 100, 24, idx);
    try testing.expectEqual(idx, scrollback.indexAtVisual(&m, m.mid_skip, 100).?);

    // Every one of these widths rewraps the filler above the marker into a
    // different number of rows. Row-count scrolling drifts further on each
    // step; the logical anchor must not move at all. There is transcript to
    // spare above and below at every width here, so no edge clamp applies.
    for ([_]usize{ 72, 55, 41, 120, 64, 100 }) |w| {
        const frame = try rewrap(&m, w, 24);
        defer testing.allocator.free(frame);
        try testing.expectEqual(idx, scrollback.indexAtVisual(&m, m.mid_skip, w).?);
        try testing.expect(std.mem.indexOf(u8, frame, "MARKERONE") != null);
    }
}

test "an anchor inside a wrapped entry stays inside that entry" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fill(&m, 25);
    try m.push(.assistant, "WRAPME" ++ wrap_tail);
    try fill(&m, 25);

    const idx: usize = 25;
    const base = try park(&m, 100, 24, idx);
    // Park three rows INTO the long entry: the anchor now carries an ordinal.
    m.scroll -= 3;
    const at = try rewrap(&m, 100, 24);
    testing.allocator.free(at);
    try testing.expectEqual(base + 3, m.mid_skip);

    for ([_]usize{ 60, 44, 90, 40 }) |w| {
        const frame = try rewrap(&m, w, 24);
        defer testing.allocator.free(frame);
        // The row on top still belongs to the same logical entry — the ordinal
        // clamps into the rewrapped block rather than spilling past its end.
        try testing.expectEqual(idx, scrollback.indexAtVisual(&m, m.mid_skip, w).?);
        // Its head word is three rows above the viewport by construction; what
        // must be on screen is the block's own body.
        try testing.expect(std.mem.indexOf(u8, frame, "wrapme") != null);
    }
}

test "the top edge clamps: entry 0 stays pinned to row 0 when it widens" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try m.push(.user, "FIRSTENTRY");
    try fill(&m, 24);

    _ = try park(&m, 50, 24, 0);
    try testing.expectEqual(@as(usize, 0), m.mid_skip);
    // Widening shortens the transcript; the anchor is row 0, so the viewport
    // must stay at the top rather than being flung to the bottom.
    for ([_]usize{ 80, 110, 46 }) |w| {
        const frame = try rewrap(&m, w, 24);
        defer testing.allocator.free(frame);
        try testing.expectEqual(@as(usize, 0), m.mid_skip);
        try testing.expect(std.mem.indexOf(u8, frame, "FIRSTENTRY") != null);
    }
}

test "the bottom edge clamps: a widened rewrap still shows the anchor" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fill(&m, 20);
    try m.push(.user, "TAILMARK");
    try fill(&m, 8);

    const idx: usize = 20;
    _ = try park(&m, 42, 24, idx);
    // Widening collapses the whole transcript into far fewer rows, so the
    // anchored row can no longer BE the top line: max_scroll saturates and the
    // viewport parks at the bottom. The anchor must still be on screen — the
    // failure this guards against is scrolling past it entirely.
    const frame = try rewrap(&m, 120, 24);
    defer testing.allocator.free(frame);
    try testing.expectEqual(@as(usize, 0), m.scroll);
    try testing.expect(std.mem.indexOf(u8, frame, "TAILMARK") != null);
    try testing.expect(scrollback.indexAtVisual(&m, m.mid_skip, 120).? <= idx);
}

test "a vertical-only resize keeps bottom-follow and never anchors" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fill(&m, 30);
    try m.push(.assistant, "TAILROW");

    for ([_]usize{ 24, 12, 40, 18 }) |h| {
        const frame = try rewrap(&m, 80, h);
        defer testing.allocator.free(frame);
        try testing.expect(m.follow);
        try testing.expectEqual(@as(usize, 0), m.scroll);
        try testing.expect(std.mem.indexOf(u8, frame, "TAILROW") != null);
    }
    // Height-only changes leave a SCROLLED viewport's distance-from-bottom
    // alone: nothing rewrapped, so there is nothing to re-anchor.
    _ = try park(&m, 80, 24, 8);
    const kept = m.scroll;
    const frame = try rewrap(&m, 80, 20);
    defer testing.allocator.free(frame);
    try testing.expectEqual(kept, m.scroll);
}

test "capture declines when the user is tailing or the transcript is empty" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try testing.expect(capture(&m, 80) == null);
    try fill(&m, 4);
    m.follow = true;
    try testing.expect(capture(&m, 80) == null);
    m.follow = false;
    try testing.expect(capture(&m, 80) != null);
}

test "a collapsed tool run anchors as one block" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fill(&m, 25);
    try m.pushTool(.{ .name = "bash", .detail = "printf hello" });
    try m.pushTool(.{ .name = "bash", .detail = "hello", .done = true });
    try fill(&m, 25);

    const idx: usize = 25;
    _ = try park(&m, 100, 24, idx);
    try testing.expectEqual(idx, scrollback.indexAtVisual(&m, m.mid_skip, 100).?);
    for ([_]usize{ 62, 48, 96 }) |w| {
        const frame = try rewrap(&m, w, 24);
        defer testing.allocator.free(frame);
        // indexAtVisual maps anywhere in the run to its start — the anchored
        // block is the run, and the run is still what the top row shows.
        try testing.expectEqual(idx, scrollback.indexAtVisual(&m, m.mid_skip, w).?);
        try testing.expect(std.mem.indexOf(u8, frame, "Called") != null);
    }
}

test "without the anchor a width rewrap moves the top line" {
    // The bug this module exists for, pinned as a fact about the OLD policy:
    // holding `scroll` (a distance from the bottom) across a rewrap lands on a
    // different entry. If a future change makes plain row-count scrolling
    // width-stable on its own, this test says so out loud.
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fill(&m, 30);
    try m.push(.user, "MARKERONE");
    try fill(&m, 30);

    const idx: usize = 30;
    _ = try park(&m, 100, 24, idx);
    const kept = m.scroll;
    // Rewrap with the anchor bypassed: same width change, scroll restored to
    // exactly what the old code would have carried over.
    const frame = try rewrap(&m, 44, 24);
    testing.allocator.free(frame);
    m.scroll = kept;
    const naive = try rewrap(&m, 44, 24);
    defer testing.allocator.free(naive);
    try testing.expect(scrollback.indexAtVisual(&m, m.mid_skip, 44).? != idx);
}
