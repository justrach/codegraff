//! Overlay bodies, and the panel each one is framed in.
//!
//! Split out of chrome.zig: the composer and the overlays had grown into one
//! file over its ceiling, and they answer to different rules. chrome.zig owns
//! the rows that are ALWAYS on screen; this file owns the ones that replace the
//! transcript while they are open.
//!
//! Every overlay is the same shape — a name, a tally, some rows, the keys —
//! and panel.zig turns that shape into grok-build's bordered box. Nothing here
//! paints an edge itself, so a panel cannot drift surface by surface.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// Scroll hint for the bodies that are PROSE rather than a list. It rides in
/// the TOP edge: those are the bodies long enough to overflow the viewport, and
/// an overflowing panel has its bottom edge off the bottom of the screen.
const scroll_note = "↑↓ scroll · Esc";

pub fn overlay(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    // The image card is a preview pinned above the composer, not a panel that
    // replaces the transcript; it keeps its own shape (image.zig).
    if (self.overlay == .none or self.overlay == .slash) return "";
    if (self.overlay == .image) return @import("image.zig").render(self, a, width);
    return panel.wrap(a, self.theme(), width, try spec(self, a));
}

fn spec(self: *const Model, a: std.mem.Allocator) !panel.Spec {
    const th = self.theme();
    return switch (self.overlay) {
        .palette => blk: {
            var idx: [catalog.items.len]usize = undefined;
            break :blk .{
                .title = "Commands",
                .note = try tally(a, catalog.filter(self.input.getValue(), &idx), catalog.items.len),
                .footer = "↑↓ move · click or Enter runs · Esc",
                .body = try listBody(self, a),
            };
        },
        // No tally: a list that cannot be filtered has nothing to count down.
        .theme => .{
            .title = "Theme",
            .footer = "↑↓ move · click or Enter applies · Esc",
            .body = try themeBody(self, a),
        },
        .help => .{
            .title = "Shortcuts",
            .note = scroll_note,
            .footer = "Esc close",
            .body = try theme_mod.paint(a, th.text, help_body),
        },
        .rewind => .{
            .title = "Rewind",
            .footer = "Enter rewind · Esc cancel",
            .body = try theme_mod.paint(a, th.text, "  Undo the last turn?"),
        },
        .debug => .{
            .title = "Observability",
            .note = scroll_note,
            .footer = "Esc close",
            .body = try debugBody(self, a),
        },
        .model => blk: {
            const models = @import("models.zig");
            const head = try models.head(self, a);
            break :blk .{ .title = head.title, .note = head.note, .footer = models.hint, .body = try models.render(self, a) };
        },
        .effort => blk: {
            const effort = @import("effort.zig");
            const head = try effort.head(self, a);
            break :blk .{ .title = head.title, .note = head.note, .footer = effort.hint, .body = try effort.render(self, a) };
        },
        .file => blk: {
            const files = @import("files.zig");
            const head = try files.head(self, a);
            break :blk .{ .title = head.title, .note = head.note, .footer = files.hint, .body = try files.render(self, a) };
        },
        .settings => .{
            .title = "Settings",
            .footer = "↑↓ move · click or Enter changes · Esc",
            .body = try settingsBody(self, a),
        },
        .jump => .{
            .title = "Jump to turn",
            .note = if (self.userTurnCount() == 0) "" else try std.fmt.allocPrint(a, "{d} turns", .{self.userTurnCount()}),
            .footer = "↑↓ move · click or Enter jumps · Esc",
            .body = try jumpBody(self, a),
        },
        else => .{ .body = "" },
    };
}

fn tally(a: std.mem.Allocator, n: usize, total: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}/{d}", .{ n, total });
}

fn listBody(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(self.input.getValue(), &idx);
    var out = std.array_list.Managed(u8).init(a);
    const show = @min(n, @as(usize, 12));
    if (show == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "  no matches"));
        try out.append('\n');
        return out.items;
    }
    const sel = self.overlay_sel % show;
    var i: usize = 0;
    while (i < show) : (i += 1) {
        const it = catalog.items[idx[i]];
        const mark = glyphs.frame(&glyphs.row_mark, @intFromBool(i != sel));
        // One menu entry is one ROW: a long description is CUT by the panel
        // wall, never wrapped — wrapping would slide every entry below it off
        // its own row.
        const line = try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, it.name, it.desc });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    if (n > show) try out.appendSlice(try panel.windowRow(a, th, 0, show, n));
    return out.items;
}

fn themeBody(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    const sel = self.overlay_sel % theme_mod.all.len;
    for (theme_mod.all, 0..) |id, i| {
        const mark = glyphs.frame(&glyphs.row_mark, @intFromBool(i != sel));
        const cur: []const u8 = if (id == self.theme_id) "  (current)" else "";
        const line = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ mark, id.label(), cur });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    return out.items;
}

fn jumpBody(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    const total = self.userTurnCount();
    if (total == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "  no turns yet"));
        try out.append('\n');
        return out.items;
    }
    const sel = self.overlay_sel % total;
    var no: usize = 0;
    for (self.history.items) |e| {
        if (e.kind != .user) continue;
        const nl = std.mem.indexOfScalar(u8, e.text, '\n') orelse e.text.len;
        const clip = e.text[0..@min(nl, 60)];
        const mark = glyphs.frame(&glyphs.row_mark, @intFromBool(no != sel));
        const line = try std.fmt.allocPrint(a, "{s}#{d}  {s}", .{ mark, no + 1, clip });
        try out.appendSlice(if (no == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
        no += 1;
    }
    return out.items;
}

fn settingsBody(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    const rows = [_][2][]const u8{
        .{ "Model", if (engine.g_model_name.len > 0) engine.g_model_name else "—" },
        .{ "Effort", @tagName(self.effort) },
        .{ "Mode", self.modeLabel() },
        .{ "Theme", self.theme_id.label() },
    };
    const sel = self.overlay_sel % rows.len;
    for (rows, 0..) |r, i| {
        const mark = glyphs.frame(&glyphs.row_mark, @intFromBool(i != sel));
        const line = try std.fmt.allocPrint(a, "{s}{s:<10}  {s}", .{ mark, r[0], r[1] });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    return out.items;
}

fn debugBody(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var buf: [2048]u8 = undefined;
    const hud: []const u8 = if (engine.g_hud_fn) |f| buf[0..f(.debug, &buf)] else "observability  (offline — no session sink)\n";
    var lbuf: [256]u8 = undefined;
    const lay = @import("dump.zig").layoutBuf(&lbuf, self);
    const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ hud, lay });
    // The HUD is written for a bare pager and starts every section flush left.
    // Inside a panel that puts the section headings hard against the wall while
    // their own rows sit two columns in, so the block is inset to the two the
    // picker rows already use and the whole overlay set shares one left margin.
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(th.text);
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0 and it.rest().len == 0) break;
        try out.appendSlice("  ");
        try out.appendSlice(ln);
        try out.append('\n');
    }
    return out.items;
}

/// The shortcut sheet. No leading heading of its own: the panel's top edge
/// already says "Shortcuts", and a body that repeated it spent a row saying
/// what the frame had said one line earlier.
const help_body =
    \\  Tab            prompt / scrollback
    \\  Enter          send
    \\  Esc            cancel · 2× clear · 2× rewind
    \\  Ctrl+C         cancel, then quit
    \\  Ctrl+X / F1    this overlay
    \\  Ctrl+P         command palette
    \\  Shift+Tab      Normal → Plan → Always-approve
    \\  click / ← →    collapse / expand tools
    \\  hover [Image]  preview  ·  y copy  ·  Enter open
    \\  Shift+← →      prev / next user turn
    \\  Ctrl+J / K     scroll one line
    \\  Ctrl+N N       new session
    \\  Ctrl+Q         quit
    \\  drag           select transcript · copy on release
    \\  Shift+drag     the terminal's own selection (any region)
    \\  Ctrl+Z         undo composer
    \\  Cmd+Delete     kill to start of line
    \\  Option+Delete  kill previous word
    \\  wheel          scroll transcript
    \\  PgUp / PgDn    page transcript
    \\  cmd+v          paste text
    \\  Ctrl+V         attach clipboard image
    \\  Ctrl+R         prompt history
    \\  /              slash menu
    \\  @              fuzzy file mention
    \\  !cmd           run a shell command
    \\
    \\Commands
    \\  /quit /exit /q    leave the pager
    \\  /help             this overlay
    \\  /new /clear       fresh session
    \\  /home             welcome screen
    \\  /model            switch model (type to search)
    \\  /effort           reasoning depth (type to filter)
    \\  /settings         model · effort · mode · theme
    \\  /usage /cost      live token/cost line
    \\  /debug            observability HUD
    \\  /plan             toggle plan mode
    \\  /always-approve   skip permission prompts
    \\  /import-claude    copy Claude and Cursor MCP + skills
    \\  /jump             jump to a previous turn
    \\  /copy             copy the last reply
    \\  /btw              queue an aside mid-turn
    \\  /vim-mode         vim keys in the scrollback
;

const testing = std.testing;

test "help overlay names the advertised pager commands" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    m.openOverlay(.help);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try overlay(&m, arena.allocator(), 80);
    for ([_][]const u8{
        "/quit",     "/help", "/new", "/home", "/model", "/settings", "/usage", "/debug", "/plan", "/always-approve",
        "Shift+Tab", "PgUp",  "PgDn",
        "←",
        "→",
        "Tab",       "Enter", "Esc",
    }) |name| {
        try testing.expect(std.mem.indexOf(u8, text, name) != null);
    }
    // The name is in the FRAME, and the body no longer repeats it.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Shortcuts"));
}

test "model overlay lists the catalog with its provider column" {
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
    m.setup(testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try overlay(&m, arena.allocator(), 80);
    try testing.expect(std.mem.indexOf(u8, text, "grok-4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "gpt-5.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Model ›") != null);
    // The provider rides on the row, inside the frame.
    try testing.expect(std.mem.indexOf(u8, text, "xai · plan") != null);
    try testing.expect(std.mem.indexOf(u8, text, "openai · api") != null);
}

test "debug overlay is not the offline fallback when a hud is wired" {
    engine.g_hud_fn = struct {
        fn f(kind: engine.HudKind, buf: []u8) usize {
            _ = kind;
            const s = "observability  graff.schema v1\n  usage      1 api call(s)";
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return n;
        }
    }.f;
    defer engine.g_hud_fn = null;
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    m.openOverlay(.debug);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try overlay(&m, arena.allocator(), 80);
    try testing.expect(std.mem.indexOf(u8, text, "offline") == null);
    try testing.expect(std.mem.indexOf(u8, text, "usage") != null);
    try testing.expect(std.mem.indexOf(u8, text, "overlay       debug") != null);
    try testing.expect(std.mem.indexOf(u8, text, "prompt-origin") != null);
}

test "every overlay is a bordered panel with its name in the frame" {
    // The audit this pass exists for: before it, an open picker was bare text
    // floating on the pager with no edge anywhere, and each surface spelled its
    // own title row. One panel builder means one look, and the check is that
    // NONE of them opts out.
    engine.g_model_entries = &.{
        .{ .name = "grok-4", .provider = "xai", .has_key = true, .cost = .plan },
        .{ .name = "gpt-5.5", .provider = "openai", .has_key = true, .cost = .api },
    };
    defer engine.g_model_entries = &.{};
    const cases = [_]struct { o: app.Overlay, name: []const u8 }{
        .{ .o = .palette, .name = "Commands" },
        .{ .o = .theme, .name = "Theme" },
        .{ .o = .help, .name = "Shortcuts" },
        .{ .o = .rewind, .name = "Rewind" },
        .{ .o = .debug, .name = "Observability" },
        .{ .o = .model, .name = "Model" },
        .{ .o = .effort, .name = "Effort" },
        .{ .o = .file, .name = "File" },
        .{ .o = .settings, .name = "Settings" },
        .{ .o = .jump, .name = "Jump to turn" },
    };
    for (cases) |c| {
        for ([_]usize{ 40, 60, 80, 120 }) |w| {
            var m: Model = undefined;
            m.setup(testing.allocator);
            defer m.deinit();
            try m.push(.user, "a turn so the jump list has a row");
            m.openOverlay(c.o);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const text = try overlay(&m, arena.allocator(), w);
            var it = std.mem.splitScalar(u8, text, '\n');
            const top = it.next() orelse return error.EmptyPanel;
            if (std.mem.indexOf(u8, top, "╭") == null) {
                std.debug.print("{s} @ {d} has no top edge: {s}\n", .{ @tagName(c.o), w, top });
                return error.NoPanelEdge;
            }
            try testing.expect(std.mem.indexOf(u8, top, c.name) != null);
            // ...and the last row is the closing edge, with the keys on it.
            var last: []const u8 = top;
            while (it.next()) |ln| {
                if (ln.len > 0) last = ln;
            }
            try testing.expect(std.mem.indexOf(u8, last, "╰") != null);
            try testing.expect(std.mem.indexOf(u8, last, "Esc") != null);
            // Every row is exactly the frame width — the painter's contract.
            var rows = std.mem.splitScalar(u8, text, '\n');
            while (rows.next()) |ln| {
                if (ln.len == 0 and rows.rest().len == 0) break;
                try testing.expectEqual(w, theme_mod.visibleLen(ln));
            }
        }
    }
}

test "a windowed list says how much of itself is off-screen" {
    // 75 models in a 14-row window used to show 14 rows and no hint at all
    // that the other 61 existed.
    var arena0 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena0.deinit();
    var buf = std.array_list.Managed(engine.ModelEntry).init(arena0.allocator());
    for (0..75) |i| {
        try buf.append(.{
            .name = try std.fmt.allocPrint(arena0.allocator(), "model-{d}", .{i}),
            .provider = "openai",
            .has_key = true,
            .cost = .api,
        });
    }
    engine.g_model_entries = buf.items;
    defer engine.g_model_entries = &.{};
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try overlay(&m, arena.allocator(), 80);
    try testing.expect(std.mem.indexOf(u8, text, "61 below") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0/75") == null);
    try testing.expect(std.mem.indexOf(u8, text, "75/75") != null);
    // Walked to the end of the list, the marker turns around instead of
    // vanishing — the row is reserved either way, so nothing below it jumps.
    m.overlay_sel = 74;
    const tail = try overlay(&m, arena.allocator(), 80);
    try testing.expect(std.mem.indexOf(u8, tail, "61 above") != null);
}
