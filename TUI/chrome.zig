//! Top bar, prompt box, status, overlays. ANSI only.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub fn topBar(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    _ = width;
    if (self.goal) |g| {
        const clip = if (g.len > 48) g[0..48] else g;
        return theme_mod.paint(a, self.theme().muted, try std.fmt.allocPrint(a, " :: Goal  {s}", .{clip}));
    }
    if (self.session_name) |name| {
        if (self.userTurnCount() == 0) return "";
        return theme_mod.paint(a, self.theme().muted, try std.fmt.allocPrint(a, " {s}", .{name}));
    }
    return "";
}

pub fn promptBox(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const th = self.theme();
    const cols = if (width < 24) @as(usize, 80) else width;
    // Between the │ │. Top/footer use the same inner so corners line up.
    const inner = if (cols > 2) cols - 2 else cols;
    const focused = self.focus == .prompt and self.overlay == .none;
    const border = if (focused) th.focus else th.border;
    var out = std.array_list.Managed(u8).init(a);
    // No standing row above the composer. The one that used to sit here read
    // "Image in clipboard · ctrl+v to paste" whenever a paste hook was wired at
    // all — which is always — so it announced an image nobody had copied, on
    // every idle frame, at the cost of a row. The affordance belongs with the
    // other keys, in the footer hint (statusBar).
    try out.appendSlice(border);
    try out.appendSlice("╭");
    var n: usize = 0;
    while (n < inner) : (n += 1) try out.appendSlice("─");
    try out.appendSlice("╮");
    try out.appendSlice(theme_mod.reset);
    try out.append('\n');
    var body = std.array_list.Managed(u8).init(a);
    try body.appendSlice(glyphs.caret ++ " ");
    if (self.images.items.len > 0) {
        try body.appendSlice(try imageChips(self, a, th.accent, th.text));
        try body.appendSlice("  ");
    }
    try body.appendSlice(try self.input.view(a));
    const wrapped = try theme_mod.wrapPreferWords(a, body.items, inner);
    var lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, wrapped, '\n');
    while (it.next()) |ln| try lines.append(ln);
    const max_body: usize = 8;
    const start: usize = if (lines.items.len > max_body) lines.items.len - max_body else 0;
    for (lines.items[start..]) |ln| {
        try out.appendSlice(try rowInner(a, border, th.text, ln, inner));
        try out.append('\n');
    }
    const model = if (engine.g_model_name.len > 0) engine.g_model_name else "offline";
    // The context share comes from the engine's meter and appears only once a
    // turn has reported usage — a "0%" before the first response would be the
    // char-counter's old habit of showing a number it had not measured (#551).
    // The share is right-aligned in a THREE-column field. The footer label is
    // centred, so a meter ticking 9% → 10% used to widen the label by one and
    // slide every character of the footer half a cell sideways mid-turn — the
    // same class of jitter a two-column spinner frame causes (glyphs.zig).
    var pct_buf: [32]u8 = undefined;
    const pct: []const u8 = if (self.contextPercent()) |p| blk: {
        const cache = if (self.status) |st| st.cachePercent() else null;
        break :blk (std.fmt.bufPrint(&pct_buf, " · {d: >3}% · {d: >3}%c", .{ p, cache orelse 0 }) catch "");
    } else "";
    const label = try std.fmt.allocPrint(a, " {s} ({s}) · {s}{s} ", .{ model, @tagName(self.effort), self.modeSlug(), pct });
    try out.appendSlice(try footer(a, border, th.muted, label, inner));
    return out.items;
}

fn imageChips(self: *const Model, a: std.mem.Allocator, accent: []const u8, text: []const u8) ![]const u8 {
    var chips = std.array_list.Managed(u8).init(a);
    for (self.images.items, 0..) |path, i| {
        if (i > 0) try chips.append(' ');
        var buf: [24]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "[Image #{d}]", .{i + 1});
        if (@import("image.zig").pathBacked(path)) {
            try chips.appendSlice(accent);
            try chips.appendSlice(label);
            try chips.appendSlice(text);
        } else {
            try chips.appendSlice(label);
        }
    }
    return chips.items;
}

fn rowInner(a: std.mem.Allocator, border: []const u8, fg: []const u8, text: []const u8, inner: usize) ![]const u8 {
    const shown = theme_mod.takeCols(text, inner);
    var pad = std.array_list.Managed(u8).init(a);
    try pad.appendSlice(fg);
    try pad.appendSlice(shown);
    try pad.appendSlice(theme_mod.reset);
    const cols = theme_mod.visibleLen(shown);
    if (cols < inner) try pad.appendNTimes(' ', inner - cols);
    return std.fmt.allocPrint(a, "{s}│{s}{s}{s}│{s}", .{ border, theme_mod.reset, pad.items, border, theme_mod.reset });
}

fn footer(a: std.mem.Allocator, border: []const u8, muted: []const u8, label: []const u8, inner: usize) ![]const u8 {
    const shown = theme_mod.takeCols(label, inner);
    const vis = theme_mod.visibleLen(shown);
    const rest = if (inner > vis) inner - vis else 0;
    const left = rest / 2;
    const right = rest - left;
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(border);
    try out.appendSlice("╰");
    var i: usize = 0;
    while (i < left) : (i += 1) try out.appendSlice("─");
    try out.appendSlice(muted);
    try out.appendSlice(shown);
    try out.appendSlice(theme_mod.reset);
    try out.appendSlice(border);
    i = 0;
    while (i < right) : (i += 1) try out.appendSlice("─");
    try out.appendSlice("╯");
    try out.appendSlice(theme_mod.reset);
    return out.items;
}

pub fn statusBar(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const th = self.theme();
    if (self.now_ms < self.toast_until_ms and self.toast.len > 0) {
        return theme_mod.paint(a, th.accent, theme_mod.takeCols(try std.fmt.allocPrint(a, " {s}", .{self.toast}), fitWidth(width)));
    }
    if (self.pending != null or self.bg != null) {
        return hintLine(self, a, width, &.{
            .{ .text = "Enter:queue" },
            .{ .text = "Shift+Tab:mode" },
            .{ .text = "Esc:cancel" },
            .{ .text = "[stop]", .sgr = th.error_fg, .pin = true },
        });
    }
    return hintLine(self, a, width, &.{
        .{ .text = "Enter:send" },
        .{ .text = "Shift+Enter:newline" },
        .{ .text = "Shift+Tab:mode" },
        .{ .text = "Ctrl+V:image", .want = engine.g_paste_fn != null },
        .{ .text = "Ctrl+X:help" },
    });
}

fn fitWidth(width: usize) usize {
    return if (width == 0) 80 else width;
}

const Hint = struct {
    text: []const u8,
    /// Defaults to the muted token at paint time — a hint is never the accent.
    sgr: []const u8 = "",
    /// Reserved before anything else is measured, and painted last: the stop
    /// control is the one segment a narrow terminal may not drop.
    pin: bool = false,
    /// False leaves the segment out entirely (an affordance that is not wired).
    want: bool = true,
};

const hint_sep = "  ·  ";

/// The footer hint, assembled from the segments that FIT.
///
/// grok-build's footer is one line that never wraps and never runs off the
/// edge. graff's was a fixed string handed to takeCols, so an 44-column
/// terminal read "Enter:send  ·  Shift+Enter:newl" — a key name cut in half.
/// Segments are whole or absent, dropped from the right, and a pinned one keeps
/// its room reserved before the walk begins.
fn hintLine(self: *const Model, a: std.mem.Allocator, width: usize, segs: []const Hint) ![]const u8 {
    const th = self.theme();
    const room = fitWidth(width);
    var reserved: usize = 0;
    for (segs) |s| {
        if (s.pin and s.want) reserved += theme_mod.visibleLen(s.text) + theme_mod.visibleLen(hint_sep);
    }
    var out = std.array_list.Managed(u8).init(a);
    try out.append(' ');
    var used: usize = 1;
    var any = false;
    for (segs) |s| {
        if (s.pin or !s.want) continue;
        const cost = theme_mod.visibleLen(s.text) + (if (any) theme_mod.visibleLen(hint_sep) else 0);
        if (used + cost + reserved > room) break;
        if (any) try out.appendSlice(hint_sep);
        try out.appendSlice(try theme_mod.paint(a, if (s.sgr.len > 0) s.sgr else th.muted, s.text));
        used += cost;
        any = true;
    }
    for (segs) |s| {
        if (!s.pin or !s.want) continue;
        if (any) try out.appendSlice(hint_sep);
        try out.appendSlice(try theme_mod.paint(a, if (s.sgr.len > 0) s.sgr else th.muted, s.text));
        any = true;
    }
    // The separators are painted outside any span, so the row would otherwise
    // wear whatever pen the previous paint left on it.
    return theme_mod.paint(a, th.muted, out.items);
}

/// The completion menu's geometry, published so the renderer below and the
/// click map (click.zig) share ONE set of numbers instead of each deriving
/// its own. `line0` and `lines` describe the COMPOSED block, frame included:
/// the menu is a panel now, so its first row is a border and an item no
/// longer sits at the block's top line.
pub const SlashGeom = struct {
    /// First item shown - the window follows the highlight.
    first: usize,
    /// Item rows drawn.
    show: usize,
    /// Items in the filtered catalogue.
    n: usize,
    /// Block line the first item row sits on: 1 inside a frame, else 0.
    line0: usize,
    /// Lines the whole block composes to, edges and window row included.
    lines: usize,
};

pub fn slashWindow(self: *const Model) ?SlashGeom {
    const v = self.input.getValue();
    if (self.focus != .prompt or v.len == 0 or v[0] != '/') return null;
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(v, &idx);
    if (n == 0) return null;
    const show = @min(n, @as(usize, 8));
    const sel = @min(self.slash_sel, n - 1);
    // A panel too narrow to frame is returned as bare rows (panel.min_width),
    // and then the first item IS the first line.
    const framed = @import("inset.zig").wrapWidth(self) >= panel.min_width;
    const edges: usize = if (framed) 2 else 0;
    return .{
        .first = if (sel >= show) sel + 1 - show else 0,
        .show = show,
        .n = n,
        .line0 = if (framed) 1 else 0,
        .lines = show + @intFromBool(n > show) + edges,
    };
}

pub fn slashMenu(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const w = slashWindow(self) orelse return "";
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(self.input.getValue(), &idx);
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    // Clamped selection + a window that follows it, so the highlighted row is
    // always visible and always the row Enter fires (#522).
    const show = w.show;
    const sel = @min(self.slash_sel, n - 1);
    const first = w.first;
    var i: usize = first;
    while (i < first + show) : (i += 1) {
        const it = catalog.items[idx[i]];
        const mark = glyphs.frame(&glyphs.row_mark, @intFromBool(i != sel));
        // One menu entry is one ROW: a click maps a screen row straight back to
        // an item, so a long description is CUT, never wrapped — wrapping
        // would slide every entry below it off its own row.
        const line = theme_mod.takeCols(try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, it.name, it.desc }), width);
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    if (n > show) try out.appendSlice(try panel.windowRow(a, th, first, show, n));
    // The same box the palette wears (overlaypane.zig). The completion menu and
    // Ctrl+P show the SAME catalogue; before this one was a framed panel and
    // the other bare text hanging over the transcript, which read as two
    // unrelated features rather than one list reached two ways.
    return panel.wrap(a, th, width, .{
        .title = "Commands",
        .note = try std.fmt.allocPrint(a, "{d}/{d}", .{ n, catalog.items.len }),
        .footer = "↑↓ move · Enter run · Esc",
        .body = out.items,
    });
}

test "composer footer shows the live agent mode" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.indexOf(u8, try promptBox(&m, a, 80), "normal") != null);
    m.mode = .plan;
    try std.testing.expect(std.mem.indexOf(u8, try promptBox(&m, a, 80), "plan") != null);
    m.mode = .always_approve;
    try std.testing.expect(std.mem.indexOf(u8, try promptBox(&m, a, 80), "always-approve") != null);
    try std.testing.expect(std.mem.indexOf(u8, try statusBar(&m, a, 80), "Enter:send") != null);
    try std.testing.expect(std.mem.indexOf(u8, try statusBar(&m, a, 80), "Shift+Tab") != null);
}

test "status paints coral [stop] while a turn is pending" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const job = try std.testing.allocator.create(@import("engine.zig").Job);
    job.* = .{ .gpa = std.testing.allocator, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
    m.pending = job;
    defer {
        m.pending = null;
        std.testing.allocator.destroy(job);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try statusBar(&m, arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, text, "[stop]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, theme_mod.coral) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Esc:cancel") != null);
}

/// The overlay bodies live in overlaypane.zig — they are the panel's business,
/// not the composer's, and keeping both here put this file over its ceiling.
/// Re-exported so the frame composer still has one door to the chrome.
pub const overlay = @import("overlaypane.zig").overlay;

test "model overlay lists engine.g_model_entries with their providers" {
    engine.g_model_entries = &.{
        .{ .name = "grok-4", .provider = "xai", .has_key = true, .cost = .plan },
        .{ .name = "gpt-5.5", .provider = "openai", .has_key = true, .cost = .api },
    };
    engine.g_model_name = "grok-4";
    engine.g_model_provider = "xai";
    defer {
        engine.g_model_entries = &.{};
        engine.g_model_name = "";
        engine.g_model_provider = "";
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try overlay(&m, arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, text, "grok-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gpt-5.5") != null);
    // The name and the tally ride in the panel's TOP EDGE now, not in a body row.
    try std.testing.expect(std.mem.indexOf(u8, text, "Model \u{203A}") != null);
    // The blind spot this fixes: the provider was nowhere on the surface.
    try std.testing.expect(std.mem.indexOf(u8, text, "xai \u{B7} plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "openai \u{B7} api") != null);
}

test "the composer footer holds its columns as the context meter ticks" {
    // The footer label is CENTRED, so a share that widened from 9% to 10%
    // shifted every character of it one column mid-turn. Same class of defect
    // as a two-column animation frame, same rule: the field is fixed-width.
    engine.g_model_name = "grok-4";
    defer engine.g_model_name = "";
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var col: ?usize = null;
    for ([_]u64{ 5, 9, 10, 99, 100 }) |pct| {
        m.setStatus(.{
            .model = "grok-4",
            .provider_id = "xai",
            .has_context = true,
            .tokens = pct,
            .window = 100,
            .cache_read = pct / 2,
        });
        const box = try promptBox(&m, arena.allocator(), 80);
        var it = std.mem.splitScalar(u8, box, '\n');
        var footer_row: []const u8 = "";
        while (it.next()) |ln| {
            if (std.mem.indexOf(u8, ln, "╰") != null) footer_row = ln;
        }
        const at = std.mem.indexOf(u8, footer_row, "grok-4") orelse return error.NoFooterLabel;
        const start = theme_mod.visibleLen(footer_row[0..at]);
        if (col) |want| try std.testing.expectEqual(want, start) else col = start;
        try std.testing.expectEqual(@as(usize, 80), theme_mod.visibleLen(footer_row));
        try std.testing.expect(std.mem.indexOf(u8, footer_row, "%c") != null);
    }
}

test "composer footer prints last-turn cache hit next to context share" {
    engine.g_model_name = "grok-4";
    defer engine.g_model_name = "";
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    m.setStatus(.{
        .model = "grok-4",
        .provider_id = "xai",
        .has_context = true,
        .tokens = 12_345,
        .window = 200_000,
        .cache_read = 2048,
    });
    const box = try promptBox(&m, arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, box, "  6%") != null);
    try std.testing.expect(std.mem.indexOf(u8, box, " 16%c") != null);
}

test "prompt box wraps a long draft onto several rows" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const long = "can we make it fit in things better if that makes sense and showcase how that looks";
    try m.input.setValue(long);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const box = try promptBox(&m, arena.allocator(), 40);
    try std.testing.expect(std.mem.count(u8, box, "│") >= 6);
    try std.testing.expect(std.mem.indexOf(u8, box, "can we make") != null);
}

test "the composer's right border holds its column for ambiguous and wide glyphs" {
    // rowInner pads from visibleLen, so a mis-measured glyph moves the wall.
    // ✓/⚙ draw one cell (they used to claim two, pulling the border in); emoji
    // and CJK draw two and must not push it out.
    const drafts = [_][]const u8{
        "✓ done ⚙ running ✗ failed ❯ next",
        "🚀 ship it 🚀🚀 and keep typing until this wraps onto another row 🚀",
        "你好世界你好世界你好世界你好世界你好世界你好世界你好世界你好世界",
        "mixed ✓ 🚀 漢字 tail",
    };
    for (drafts) |draft| {
        for ([_]usize{ 40, 41, 57, 80 }) |w| {
            var m: Model = undefined;
            m.setup(std.testing.allocator);
            defer m.deinit();
            try m.input.setValue(draft);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const box = try promptBox(&m, arena.allocator(), w);
            var it = std.mem.splitScalar(u8, box, '\n');
            while (it.next()) |ln| {
                if (ln.len == 0) continue;
                try std.testing.expectEqual(w, theme_mod.visibleLen(ln));
            }
        }
    }
}
