//! Compose one frame: top bar, welcome or scrollback, slash menu / overlay,
//! prompt box, status. Viewport math matches grok's "prompt pinned, history
//! scrolls".

const std = @import("std");

const anchor = @import("anchor.zig");
const app = @import("app.zig");
const chrome = @import("chrome.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const scrollback = @import("scrollback.zig");
const layout_cache = @import("layout_cache.zig");
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
        anchor.capture(self, self.last_term_width)
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

    // Nothing composed here may be wider than the screen. A row that is
    // becomes a lie the painter has to clean up after: with autowrap off the
    // terminal chops it, and on any terminal that does not honour ?7l it wraps
    // and pushes every row below it down by one — which desyncs the row↔line
    // map the composer's click math, the sticky header and the selection band
    // all ride on. The chrome builders that take `width` clamp themselves; the
    // overlay bodies and the image card historically did not.
    const top = theme_mod.takeCols(try chrome.topBar(self, a, width), width);
    const image_card = if (self.overlay == .image)
        try theme_mod.wrapToWidth(a, try chrome.overlay(self, a, width), width)
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
        try theme_mod.wrapToWidth(a, try chrome.overlay(self, a, width), width)
    else if (welcome_pane)
        try welcome.render(self, a, width)
    else
        "";
    // The transcript is never composed whole: the layout cache holds its
    // wrapped lines and the frame takes a SLICE of them (layout_cache.zig).
    const cache: ?*layout_cache.Cache = if (overlay_body or welcome_pane) null else layout_cache.ensure(self, width);
    const slash = try chrome.slashMenu(self, a, width);
    const prompt = try chrome.promptBox(self, a, width);
    const status = try chrome.statusBar(self, a, width);

    var bottom = std.array_list.Managed(u8).init(a);
    if (slash.len > 0) {
        try bottom.appendSlice(slash);
        if (slash[slash.len - 1] != '\n') try bottom.append('\n');
    }
    try bottom.appendSlice(prompt);
    if (prompt.len == 0 or prompt[prompt.len - 1] != '\n') try bottom.append('\n');
    try bottom.appendSlice(status);

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
    const room = if (height > top_lines + card_lines + 1) height - top_lines - card_lines - 1 else 1;
    const bottom_block = lastLines(bottom.items, room);
    const bottom_lines = countLines(bottom_block);
    self.preview_rows = card_lines;
    self.mid_origin = top_lines;
    self.prompt_origin = if (height > bottom_lines) height - bottom_lines else 0;
    const used = bottom_lines + top_lines + card_lines;
    const view_h: usize = if (height > used) height - used else 1;

    var mid_lines = std.array_list.Managed([]const u8).init(a);
    if (cache == null) {
        var it = std.mem.splitScalar(u8, mid, '\n');
        while (it.next()) |ln| try mid_lines.append(ln);
        if (mid_lines.items.len > 0 and mid_lines.items[mid_lines.items.len - 1].len == 0) _ = mid_lines.pop();
    }

    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(top);
    if (top.len > 0 and top[top.len - 1] != '\n') try out.append('\n');

    const n = if (cache) |c| c.total else mid_lines.items.len;
    self.sticky_rows = 0;
    if (n <= view_h) {
        self.scroll = 0;
        self.mid_skip = 0;
        for (try midSlice(a, cache, mid_lines.items, 0, n)) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
        }
        var pad: usize = view_h - n;
        while (pad > 0) : (pad -= 1) try out.append('\n');
    } else {
        const max_scroll = n - view_h;
        if (self.follow) self.scroll = 0;
        // Put the anchored logical line back on the top row. Saturating: when
        // the rewrap pushed it past the last possible top line the viewport
        // parks at the bottom, which still shows it.
        if (rewrap) |anc| {
            if (cache) |c| self.scroll = max_scroll -| anchor.rowAt(self, c, anc);
        }
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const start = max_scroll - self.scroll;
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
                const cols = if (width > 2) width - 2 else 1;
                try out.appendSlice(theme_mod.takeCols(head.items, cols));
                try out.appendSlice(theme_mod.reset);
                try out.append('\n');
                try out.append('\n');
                chrome_rows = 2;
                self.sticky_rows = 2;
            }
        }
        for (try midSlice(a, cache, mid_lines.items, start + chrome_rows, view_h - chrome_rows)) |ln| {
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
        };
    }
    if (image_card.len > 0) {
        try out.appendSlice(image_card);
        if (image_card[image_card.len - 1] != '\n') try out.append('\n');
    }
    try out.appendSlice(bottom_block);
    self.paint_hint = scrollHint(self, prev_band);
    // Selection is a post-pass over the finished frame: the row builders stay
    // unaware of it, and the band lands on screen rows exactly as the mouse
    // reported them (#529).
    return gpa.dupe(u8, try selection.paint(self, a, out.items, width));
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
fn scrollHint(self: *const Model, prev: app.Band) ?scrollpaint.Hint {
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
    return .{ .top = cur.top, .len = cur.len, .delta = d };
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

test "welcome frame has chrome, prompt, and no offline stub" {
    engine.g_model_name = "grok-4";
    engine.g_cwd = "/tmp/proj";
    defer {
        engine.g_model_name = "";
        engine.g_cwd = ".";
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "grok-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "›") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "offline") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Fullscreen") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "click") == null);
}

test "click on a painted fold header expands the tools" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.assistant, "Hey. I am in /Users/blackfloofie/codegraff on wip/shared-checkout-2026-08-14 and holding a long worktree path so this wraps");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    var row: usize = 0;
    var hit: ?usize = null;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |ln| : (row += 1) {
        if (std.mem.indexOf(u8, ln, "Ran bash") != null) {
            hit = row;
            break;
        }
    }
    try std.testing.expect(hit != null);
    try std.testing.expect(m.history.items[1].folded);
    _ = @import("keys.zig").handle(&m, .{ .mouse = .{ .btn = 0, .x = 4, .y = @intCast(hit.? + 1), .down = true } });
    try std.testing.expect(!m.history.items[1].folded);
}

test "image overlay keeps the conversation and paints the Grok card" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.push(.assistant, "got it");
    m.preview_path = "/tmp/shot.png";
    m.preview_n = 1;
    m.openOverlay(.image);
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Image #1") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "got it") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "y copy path") != null);
}

test "visible dump of a fixture frame shows chips, the fold header, composer, no CSI" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    const dump_mod = @import("dump.zig");
    const vis = try dump_mod.visible(std.testing.allocator, frame);
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "[Image #1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "Ran bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "›") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "\x1b") == null);
    const lay = try dump_mod.layout(std.testing.allocator, &m);
    defer std.testing.allocator.free(lay);
    try std.testing.expect(std.mem.indexOf(u8, lay, "overlay       none") != null);
    try std.testing.expect(std.mem.indexOf(u8, lay, "prompt-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, lay, "mid-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, lay, "images") != null);

    m.openOverlay(.debug);
    const dbg = try chrome.overlay(&m, std.testing.allocator, 80);
    defer std.testing.allocator.free(dbg);
    const lay_dbg = try dump_mod.layout(std.testing.allocator, &m);
    defer std.testing.allocator.free(lay_dbg);
    try std.testing.expect(std.mem.indexOf(u8, lay_dbg, "overlay       debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, dbg, "Observability") != null);
    if (std.c.getenv("GRAFF_TUI_DUMP")) |dir_z| {
        const dir = std.mem.span(dir_z);
        const io = std.Io.Threaded.global_single_threaded.io();
        var fb: [512]u8 = undefined;
        var lb: [512]u8 = undefined;
        const fp = std.fmt.bufPrint(&fb, "{s}/tui-frame.txt", .{dir}) catch return error.PathTooLong;
        const lp = std.fmt.bufPrint(&lb, "{s}/tui-layout.txt", .{dir}) catch return error.PathTooLong;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fp, .data = vis }) catch {};
        const both = try std.fmt.allocPrint(std.testing.allocator, "--- overlay none ---\n{s}\n--- overlay debug ---\n{s}\n--- debug overlay body ---\n{s}", .{ lay, lay_dbg, dbg });
        defer std.testing.allocator.free(both);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = both }) catch {};
    }
}

test "debug overlay keeps the observability HUD and adds layout" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.pushTool(.{ .name = "bash" });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    m.openOverlay(.debug);
    const text = try chrome.overlay(&m, std.testing.allocator, 80);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Observability") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "overlay       debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mid-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "images") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pending") != null);
}

test "a wheel notch reports a scroll hint; anything else about the frame refuses one" {
    const keys = @import("keys.zig");
    const a = std.testing.allocator;
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try m.push(.user, "how do I frobnicate the widget?");
    var i: usize = 0;
    while (i < 60) : (i += 1)
        try m.pushFmt(.assistant, "explanation line {d}, long enough to fill the transcript", .{i});

    // A first frame has nothing to compare against, and an idle one has not moved.
    for (0..2) |_| {
        a.free(try render(&m, a, 80, 24, 0));
        try std.testing.expect(m.paint_hint == null);
    }

    // One wheel notch. The band slides by exactly the three content lines
    // keys.zig moved the viewport, and keeps its geometry — which is the whole
    // claim paint.zig acts on. `top` clears the sticky header: those rows are
    // chrome occluding the viewport, and a hardware scroll must not move them.
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 64, .x = 1, .y = 5, .down = true } });
    a.free(try render(&m, a, 80, 24, 0));
    const h = m.paint_hint orelse return error.NoScrollHint;
    try std.testing.expectEqual(@as(isize, -3), h.delta);
    try std.testing.expectEqual(m.mid_origin + m.sticky_rows, h.top);
    try std.testing.expectEqual(@as(usize, 2), m.sticky_rows);
    try std.testing.expect(h.len >= 2 and h.top + h.len <= 24);

    // A resize on the same frame as a scroll: every row below rewraps, so the
    // band is not the same band and nothing about it may be claimed to slide.
    keys.scrollBy(&m, 3);
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);

    // A live drag-selection band is anchored to SCREEN rows, so its inverse
    // video does not travel with the content a hardware scroll would move.
    a.free(try render(&m, a, 79, 24, 0));
    m.sel.active = true;
    keys.scrollBy(&m, 3);
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);
    m.sel.active = false;

    // Scrolling all the way to the top clamps: the viewport stops moving, and
    // a band that did not move is not a scroll.
    m.scroll = 1_000_000;
    a.free(try render(&m, a, 79, 24, 0));
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);

    // An overlay replaces the whole viewport — no band at all, so no hint even
    // though the frame changed completely.
    m.openOverlay(.help);
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);
}

test "the sticky header never pins a prompt over an overlay" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "SECRETPROMPT about widgets");
    var i: usize = 0;
    while (i < 40) : (i += 1) try m.push(.assistant, "filler assistant prose to make the transcript long");
    // It engages on the transcript...
    const transcript = try render(&m, std.testing.allocator, 80, 24, 0);
    std.testing.allocator.free(transcript);
    try std.testing.expectEqual(@as(usize, 2), m.sticky_rows);
    // ...and stands down once `mid` is an overlay body long enough to scroll:
    // ungated, the pin ate the overlay's own first two rows.
    m.openOverlay(.help);
    const overlay_frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(overlay_frame);
    try std.testing.expectEqual(@as(usize, 0), m.sticky_rows);
    try std.testing.expect(std.mem.indexOf(u8, overlay_frame, "SECRETPROMPT") == null);
    // The image overlay is a card, not a body: the transcript keeps its pin.
    m.closeOverlay();
    m.preview_path = "/tmp/shot.png";
    m.preview_n = 1;
    m.openOverlay(.image);
    const card_frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(card_frame);
    try std.testing.expectEqual(@as(usize, 2), m.sticky_rows);
}

test "sticky header pins the last scrolled-past user prompt with a blank separator" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "how do I frobnicate the widget?");
    var i: usize = 0;
    while (i < 40) : (i += 1) try m.push(.assistant, "a long explanation line that fills the scrollback with content");
    // follow-mode bottom: prompt is far above, so it pins.
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    var it = std.mem.splitScalar(u8, frame, '\n');
    var row: usize = 0;
    var pin_row: ?usize = null;
    while (it.next()) |ln| : (row += 1) {
        if (std.mem.indexOf(u8, ln, "\u{276F} ") != null and std.mem.indexOf(u8, ln, "frobnicate") != null) {
            pin_row = row;
            break;
        }
    }
    try std.testing.expect(pin_row != null);
    // scrolled fully back to the top, the prompt is inline: no pin.
    m.follow = false;
    m.scroll = 100000;
    const top_frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(top_frame);
    try std.testing.expect(std.mem.indexOf(u8, top_frame, "\u{276F} ") == null);
}
