//! Compose one frame: top bar, welcome or scrollback, slash menu / overlay,
//! prompt box, status. Viewport math matches grok's "prompt pinned, history
//! scrolls".

const std = @import("std");

const anchor = @import("anchor.zig");
const app = @import("app.zig");
const chrome = @import("chrome.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const hover = @import("hover.zig");
const inset = @import("inset.zig");
const layout_cache = @import("layout_cache.zig");
const scrollbar = @import("scrollbar.zig");
const scrollback = @import("scrollback.zig");
const scrollpaint = @import("scrollpaint.zig");
const selection = @import("selection.zig");
const theme_mod = @import("theme.zig");
const welcome = @import("welcome.zig");
const Model = app.Model;

pub fn render(self: *Model, gpa: std.mem.Allocator, width: usize, height: usize, now_ms: u64) ![]const u8 {
    // A horizontal resize rewraps everything under the viewport, so the row
    // count in `scroll` stops meaning what it meant. Take a LOGICAL anchor off
    // the frame we last painted — read at the OLD width, before it is
    // overwritten — and restore the viewport onto it below. Only the
    // transcript is anchored this way: an overlay body scrolls too, but its
    // rows are not history entries.
    const rewrap: ?anchor.Anchor = if (width != self.last_term_width and
        (self.overlay == .none or self.overlay == .image))
        anchor.capture(self, inset.forTerm(self.last_term_width, self.compact_mode).inner)
    else
        null;
    self.last_term_width = width;
    self.last_term_height = height;
    self.now_ms = now_ms;
    // Where the scrollable band was last time, so the painter can be told the
    // viewport SLID rather than left to conclude every row changed. Presentation
    // state, and only ever a hint: paint.zig verifies it against the bytes.
    const prev_band = self.band;
    self.band = .{};
    @import("turn.zig").drainEvents(self);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // grok-build's outer pads (inset.zig): wrap the chrome and transcript to
    // `inner`, then prefix `left` spaces so nothing kisses the terminal edge.
    const pads = inset.forTerm(width, self.compact_mode);
    const inner = pads.inner;
    const left = pads.left;
    const gap = pads.vpad;

    // Nothing composed here may be wider than the screen. A row that is
    // becomes a lie the painter has to clean up after: with autowrap off the
    // terminal chops it, and on any terminal that does not honour ?7l it wraps
    // and pushes every row below it down by one — which desyncs the row↔line
    // map the composer's click math, the sticky header and the selection band
    // all ride on. The chrome builders that take `width` clamp themselves; the
    // overlay bodies and the image card historically did not.
    const top = theme_mod.takeCols(try chrome.topBar(self, a, inner), inner);
    const image_card = if (self.overlay == .image)
        try theme_mod.wrapToWidth(a, try chrome.overlay(self, a, inner), inner)
    else
        "";
    // The image overlay is a card ABOVE the composer, so `mid` stays the
    // transcript; every other overlay replaces it with its own body.
    const overlay_body = self.overlay != .none and self.overlay != .image;
    // Anything in the transcript — including a live background op's pending
    // row — outranks the welcome pane: keeping it up hid a running `!cmd`/
    // @-list entirely and froze the paint loop (the welcome frame is static,
    // so the hash-diff suppressed every paint).
    const welcome_pane = self.screen == .welcome and self.history.items.len == 0 and self.pending == null;
    const mid = if (overlay_body)
        try theme_mod.wrapToWidth(a, try chrome.overlay(self, a, inner), inner)
    else if (welcome_pane)
        try welcome.render(self, a, inner)
    else
        "";
    // The transcript is never composed whole: the layout cache holds its
    // wrapped lines and the frame takes a SLICE of them (layout_cache.zig).
    const cache: ?*layout_cache.Cache = if (overlay_body or welcome_pane) null else layout_cache.ensure(self, inner);
    const slash = try chrome.slashMenu(self, a, inner);
    const prompt = try chrome.promptBox(self, a, inner);
    const status = try chrome.statusBar(self, a, inner);

    var bottom = std.array_list.Managed(u8).init(a);
    if (slash.len > 0) {
        try bottom.appendSlice(slash);
        if (slash[slash.len - 1] != '\n') try bottom.append('\n');
    }
    try bottom.appendSlice(prompt);
    if (prompt.len == 0 or prompt[prompt.len - 1] != '\n') try bottom.append('\n');
    try bottom.appendSlice(status);
    // grok-build outer_vpad: one blank row under the hints so the footer is
    // not glued to the last cell of the screen. Compact drops it.
    if (gap > 0) try bottom.append('\n');

    const top_lines = countLines(top);
    // countLines counts a trailing '\n' as an extra line but the append below
    // adds no newline of its own — the off-by-one shifted the whole frame up
    // one row and broke composer clicks (prompt_origin pointed past the box).
    const card_lines = if (image_card.len == 0) 0 else countLines(image_card) - @intFromBool(image_card[image_card.len - 1] == '\n');
    // The bottom block owns the LAST rows of the screen, so when the chrome
    // cannot all fit — a short terminal with the slash menu open — it is
    // trimmed from the top, where the expendable rows (the menu, the paste
    // hint) are. Untrimmed, the composed frame ran LONGER than the screen: the
    // painter clipped it at the last row, so the composer and the status bar
    // were simply never drawn, while prompt_origin went on claiming a row for
    // a composer that was not on screen.
    const room = if (height > top_lines + card_lines + gap + gap + 1) height - top_lines - card_lines - gap - gap - 1 else 1;
    const bottom_block = lastLines(bottom.items, room);
    const bottom_lines = countLines(bottom_block);
    // The completion menu rides at the TOP of the bottom block, and a short
    // terminal trims that block from the top — so what survives is what a
    // click can land on (click.zig). Counted here, where both the untrimmed
    // and the trimmed shapes are in hand.
    self.slash_rows = if (slash.len == 0)
        0
    else
        (countLines(slash) - @intFromBool(slash[slash.len - 1] == '\n')) -| (countLines(bottom.items) - bottom_lines);
    self.preview_rows = card_lines;
    self.mid_origin = top_lines + gap;
    self.prompt_origin = if (height > bottom_lines) height - bottom_lines else 0;
    // One blank row above the mid (top gutter) and one between the transcript
    // and the composer — grok-build's outer_vpad on both ends of the viewport.
    const used = bottom_lines + top_lines + card_lines + gap + gap;
    const view_h: usize = if (height > used) height - used else 1;

    var mid_lines = std.array_list.Managed([]const u8).init(a);
    if (cache == null) {
        var it = std.mem.splitScalar(u8, mid, '\n');
        while (it.next()) |ln| try mid_lines.append(ln);
        if (mid_lines.items.len > 0 and mid_lines.items[mid_lines.items.len - 1].len == 0) _ = mid_lines.pop();
    }

    var out = std.array_list.Managed(u8).init(a);
    try inset.appendPadded(&out, top, left);
    if (top.len > 0 and top[top.len - 1] != '\n') try out.append('\n');
    var lead_gap = gap;
    while (lead_gap > 0) : (lead_gap -= 1) try out.append('\n');

    const n = if (cache) |c| c.total else mid_lines.items.len;
    // Mid lines this frame, transcript or overlay body alike. A press below
    // the last of them is on the backdrop, not on the panel (click.zig).
    self.mid_total = n;
    self.sticky_rows = 0;
    if (n <= view_h) {
        self.scroll = 0;
        self.mid_skip = 0;
        // An overlay panel DOCKS to the composer, the way the slash menu does
        // and grok-build's minimal pickers do: the list rises out of the box
        // you are typing in. Top-anchored it floated at the ceiling with a
        // field of blank rows between the thing being chosen and the caret
        // choosing it. The transcript keeps its own habit, top-down.
        const above: usize = if (overlay_body) view_h - n else 0;
        var lead = above;
        while (lead > 0) : (lead -= 1) try out.append('\n');
        for (try midSlice(a, cache, mid_lines.items, 0, n)) |ln| {
            try out.appendNTimes(' ', left);
            try out.appendSlice(ln);
            try out.append('\n');
        }
        var pad: usize = view_h - n - above;
        while (pad > 0) : (pad -= 1) try out.append('\n');
        self.mid_origin += above;
    } else {
        const max_scroll = n - view_h;
        // An overlay body reads TOP-DOWN. The transcript is pinned to its tail
        // because the newest line is the one you want; a shortcut sheet is a
        // document, and opening one at its last row showed the tail of /help
        // and nothing else. Its own cursor, so closing the overlay leaves the
        // transcript's viewport where it was.
        var start: usize = undefined;
        if (overlay_body) {
            if (self.overlay_scroll > max_scroll) self.overlay_scroll = max_scroll;
            start = self.overlay_scroll;
        } else {
            if (self.follow) self.scroll = 0;
            // Put the anchored logical line back on the top row. Saturating:
            // when the rewrap pushed it past the last possible top line the
            // viewport parks at the bottom, which still shows it.
            if (rewrap) |anc| {
                if (cache) |c| self.scroll = max_scroll -| anchor.rowAt(self, c, anc);
            }
            if (self.scroll > max_scroll) self.scroll = max_scroll;
            start = max_scroll - self.scroll;
        }
        self.mid_skip = start;
        // grok sticky header (minimal single slot): once the last user prompt
        // scrolls past the viewport top, its first line stays pinned as row 0
        // with a blank separator row under it. The two chrome rows OCCLUDE the
        // two top content lines instead of shifting them, so the row↔line map
        // for everything below is unchanged and the bottom line stays put.
        var chrome_rows: usize = 0;
        // Only the transcript gets a pinned prompt. On an overlay screen `mid`
        // is the overlay's own body, and a long one (/help, /models) scrolls
        // too — ungated, this pinned a user prompt over its first two rows.
        if (!overlay_body and view_h >= 5) {
            if (if (cache) |c| layout_cache.stickyUserAbove(c, start) else null) |utext| {
                const th = self.theme();
                var head = std.array_list.Managed(u8).init(a);
                try head.appendSlice(th.accent);
                try head.appendSlice(glyphs.prompt_mark ++ " ");
                try head.appendSlice(th.text);
                var one = utext;
                if (std.mem.indexOfScalar(u8, utext, '\n')) |nl| one = utext[0..nl];
                try head.appendSlice(one);
                const cols = if (inner > 2) inner - 2 else 1;
                try out.appendNTimes(' ', left);
                try out.appendSlice(theme_mod.takeCols(head.items, cols));
                try out.appendSlice(theme_mod.reset);
                try out.append('\n');
                try out.append('\n');
                chrome_rows = 2;
                self.sticky_rows = 2;
            }
        }
        for (try midSlice(a, cache, mid_lines.items, start + chrome_rows, view_h - chrome_rows)) |ln| {
            try out.appendNTimes(' ', left);
            try out.appendSlice(ln);
            try out.append('\n');
        }
        // The band is the part of the frame a wheel event MOVES: content rows
        // only. The sticky header occludes the top of the viewport, so it is
        // chrome that happens to sit inside it, and the composer, status bar
        // and image card are below the end.
        self.band = .{
            .live = true,
            .top = self.mid_origin + chrome_rows,
            .len = view_h - chrome_rows,
            .off = start + chrome_rows,
            .total = n,
        };
    }
    var mid_gap = gap;
    while (mid_gap > 0) : (mid_gap -= 1) try out.append('\n');
    if (image_card.len > 0) {
        try inset.appendPadded(&out, image_card, left);
        if (image_card[image_card.len - 1] != '\n') try out.append('\n');
    }
    try inset.appendPadded(&out, bottom_block, left);
    // Hover, selection and the scroll gutter are all post-passes over the
    // finished frame: the row builders stay unaware of all three, and each
    // lands on screen rows exactly as the mouse reported them (#529). Hover
    // runs FIRST so a drag band painted over the same row wins — a selection
    // CLAIMS a region, a hover tint only announces one.
    const hovered = try hover.paint(self, a, out.items, width);
    const banded = try selection.paint(self, a, hovered, width);
    // The scroll gutter goes LAST, after the capture: the thumb is chrome the
    // selection must never copy, and it hides for the duration of a drag
    // anyway (scrollbar.zig owns both halves of that rule).
    const had_gutter = self.gutter_on;
    const painted = try scrollbar.paint(self, a, banded, width);
    // The hint describes the FINISHED frames, so it is taken after every
    // post-pass: the gutter reshapes every band row, and whether the painter
    // may scroll them depends on the two frames having the same shape.
    self.paint_hint = scrollHint(self, prev_band, had_gutter and self.gutter_on);
    return gpa.dupe(u8, painted);
}

/// `count` mid rows starting at `from`, taken from the layout cache when the
/// mid IS the transcript and from the composed overlay/welcome lines otherwise.
/// The cached path never materialises the rows outside the viewport, which is
/// the whole point: a wheel tick copies a screenful, not a transcript.
fn midSlice(a: std.mem.Allocator, cache: ?*layout_cache.Cache, lines: [][]const u8, from: usize, count: usize) ![]const []const u8 {
    if (cache) |c| return layout_cache.window(c, a, from, count);
    const end = @min(lines.len, from + count);
    return lines[@min(from, end)..end];
}

/// The delta the scrollable band moved by between the last frame and this one,
/// when that is the ONLY thing that happened to it — the painter's scroll fast
/// path. Null is always safe: it just means the ordinary row diff.
fn scrollHint(self: *const Model, prev: app.Band, gutter: bool) ?scrollpaint.Hint {
    const cur = self.band;
    if (!cur.live or !prev.live) return null;
    // Geometry moved, so screen row N is not the same slot it was: a resize, an
    // image card appearing, the sticky header engaging, an overlay opening.
    if (cur.top != prev.top or cur.len != prev.len) return null;
    if (cur.off == prev.off) return null;
    // The drag-selection band is anchored to SCREEN rows (#529), so its
    // inverse video does not travel with the content a hardware scroll moves.
    // The wheel drops the band for exactly this reason; keyboard scrolling
    // keeps it, and that case has to keep repainting.
    if (self.sel.active or self.sel.pressed) return null;
    const d = @as(isize, @intCast(cur.off)) - @as(isize, @intCast(prev.off));
    if (@abs(d) >= cur.len) return null;
    return .{ .top = cur.top, .len = cur.len, .delta = d, .gutter = gutter };
}

fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    return std.mem.count(u8, s, "\n") + 1;
}

/// The last `n` lines of `s`, whole. Trimming a block that has to sit on the
/// screen's last rows can only ever come off the top.
fn lastLines(s: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    var have = countLines(s);
    var i: usize = 0;
    while (have > n) : (have -= 1) {
        i = (std.mem.indexOfScalarPos(u8, s, i, '\n') orelse return s[i..]) + 1;
    }
    return s[i..];
}

test "lastLines keeps whole lines off the bottom" {
    try std.testing.expectEqualStrings("c", lastLines("a\nb\nc", 1));
    try std.testing.expectEqualStrings("b\nc", lastLines("a\nb\nc", 2));
    try std.testing.expectEqualStrings("a\nb\nc", lastLines("a\nb\nc", 9));
    try std.testing.expectEqualStrings("", lastLines("a\nb", 0));
}

test "a frame is exactly `height` rows of at most `width` columns" {
    // The painter addresses screen row N as the Nth line of this string, and
    // nothing else ever tells it where a row is. Every off-by-one in this
    // file — the trailing-newline overcount that once shifted the whole frame
    // up a row and broke composer clicks — shows up here first, and the
    // occluding chrome rows (sticky header) and the image card are exactly the
    // regions that write OUTSIDE the plain mid-lines flow.
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    // Model-owned: deinit frees it.
    m.session_name = try std.testing.allocator.dupe(u8, "a session name for the top bar");
    for ([_][2]usize{ .{ 40, 12 }, .{ 80, 24 }, .{ 100, 30 }, .{ 132, 60 }, .{ 200, 40 } }) |wh| {
        const w = wh[0];
        const h = wh[1];
        // Welcome, then a short transcript, then one long enough to scroll (so
        // the sticky header pins two chrome rows), then the same with the
        // image card above the composer, then an overlay body.
        for (0..7) |stage| {
            switch (stage) {
                1 => {
                    try m.push(.user, "how do I frobnicate the widget?");
                    try m.push(.assistant, "like this");
                },
                2 => for (0..60) |_| try m.push(.assistant, "filler prose that fills the scrollback with wrapped content"),
                3 => {
                    m.preview_path = "/tmp/shot.png";
                    m.preview_n = 1;
                    m.openOverlay(.image);
                },
                4 => {
                    m.closeOverlay();
                    m.openOverlay(.help);
                },
                5 => {
                    m.closeOverlay();
                    if (m.goal) |g| std.testing.allocator.free(g);
                    m.goal = try std.testing.allocator.dupe(u8, "a standing goal long enough to overrun a narrow top bar");
                },
                6 => {
                    m.focus = .prompt;
                    try m.input.setValue("/");
                },
                else => {},
            }
            const frame = try render(&m, std.testing.allocator, w, h, 0);
            defer std.testing.allocator.free(frame);
            try std.testing.expectEqual(h, countLines(frame));
            var it = std.mem.splitScalar(u8, frame, '\n');
            var rown: usize = 0;
            while (it.next()) |ln| : (rown += 1) {
                if (theme_mod.visibleLen(ln) > w) {
                    const dump = @import("dump.zig");
                    const vis = try dump.visible(std.testing.allocator, ln);
                    defer std.testing.allocator.free(vis);
                    std.debug.print("w={d} h={d} stage={d} row={d} cols={d}: {s}\n", .{ w, h, stage, rown, theme_mod.visibleLen(ln), vis });
                }
                try std.testing.expect(theme_mod.visibleLen(ln) <= w);
            }
        }
        m.closeOverlay();
    }
}

test "countLines" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("hi"));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
}

test {
    // The frame-level tests live next door so this file stays under the
    // ceiling. Without this reference they compile for nobody and never run.
    _ = @import("render_tests.zig");
}
