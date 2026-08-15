//! Top bar, prompt box, status, overlays. ANSI only.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
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
    if (self.input.getValue().len == 0 and self.images.items.len == 0 and engine.g_paste_fn != null) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, " Image in clipboard · ctrl+v to paste"));
        try out.append('\n');
    }
    try out.appendSlice(border);
    try out.appendSlice("╭");
    var n: usize = 0;
    while (n < inner) : (n += 1) try out.appendSlice("─");
    try out.appendSlice("╮");
    try out.appendSlice(theme_mod.reset);
    try out.append('\n');
    var body = std.array_list.Managed(u8).init(a);
    try body.appendSlice("› ");
    if (self.images.items.len > 0) {
        try body.appendSlice(try imageChips(self, a));
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
    const label = try std.fmt.allocPrint(a, " {s} ({s}) · {s} ", .{ model, @tagName(self.effort), self.modeSlug() });
    try out.appendSlice(try footer(a, border, th.muted, label, inner));
    return out.items;
}

fn imageChips(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    var chips = std.array_list.Managed(u8).init(a);
    for (self.images.items, 0..) |_, i| {
        if (i > 0) try chips.append(' ');
        var buf: [24]u8 = undefined;
        try chips.appendSlice(try std.fmt.bufPrint(&buf, "[Image #{d}]", .{i + 1}));
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
        return theme_mod.paint(a, th.accent, self.toast);
    }
    if (self.pending != null) {
        const raw = try std.fmt.allocPrint(a, "{s} Enter:queue  ·  Shift+Tab:mode  ·  Esc:cancel  ·  {s}[stop]{s}", .{
            th.muted, th.error_fg, theme_mod.reset,
        });
        return theme_mod.takeCols(raw, if (width == 0) 80 else width);
    }
    return theme_mod.paint(a, th.muted, theme_mod.takeCols(" Enter:send  ·  Shift+Enter:newline  ·  Shift+Tab:mode", if (width == 0) 80 else width));
}

pub fn overlay(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    return switch (self.overlay) {
        .none => "",
        .palette => try listOverlay(self, a, width),
        .theme => try themeOverlay(self, a),
        .help => try helpOverlay(self, a),
        .rewind => try std.fmt.allocPrint(a, "{s}{s}Rewind last turn?{s}\n{s}Enter rewind  ·  Esc cancel{s}\n", .{ theme_mod.bold, self.theme().accent, theme_mod.reset, self.theme().muted, theme_mod.reset }),
        .debug => try debugOverlay(self, a),
        .model => try @import("models.zig").render(self, a),
        .effort => try @import("effort.zig").render(self, a),
        .settings => try settingsOverlay(self, a),
        .image => try @import("image.zig").render(self, a, width),
        .file => try @import("files.zig").render(self, a),
        .jump => try jumpOverlay(self, a),
        .slash => "",
    };
}

pub fn slashMenu(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const v = self.input.getValue();
    if (self.focus != .prompt or v.len == 0 or v[0] != '/') return "";
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(v, &idx);
    if (n == 0) return "";
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    const show = @min(n, @as(usize, 8));
    const sel = if (n == 0) 0 else self.slash_sel % n;
    var i: usize = 0;
    while (i < show) : (i += 1) {
        const it = catalog.items[idx[i]];
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const line = try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, it.name, it.desc });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    _ = width;
    return out.items;
}

fn listOverlay(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const th = self.theme();
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(self.input.getValue(), &idx);
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(try theme_mod.paint(a, th.accent, "Commands"));
    try out.append('\n');
    const show = @min(n, @as(usize, 12));
    if (show == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "no matches\n"));
        return out.items;
    }
    const sel = self.overlay_sel % show;
    var i: usize = 0;
    while (i < show) : (i += 1) {
        const it = catalog.items[idx[i]];
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const line = try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, it.name, it.desc });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    _ = width;
    return out.items;
}

fn themeOverlay(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(try theme_mod.paint(a, th.accent, "Theme"));
    try out.append('\n');
    const sel = self.overlay_sel % theme_mod.all.len;
    for (theme_mod.all, 0..) |id, i| {
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const cur: []const u8 = if (id == self.theme_id) "  (current)" else "";
        const line = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ mark, id.label(), cur });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    return out.items;
}

fn jumpOverlay(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(try theme_mod.paint(a, th.accent, "Jump to turn"));
    try out.appendSlice("\n\n");
    const total = self.userTurnCount();
    if (total == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "no turns yet\n"));
        return out.items;
    }
    const sel = self.overlay_sel % total;
    var no: usize = 0;
    for (self.history.items) |e| {
        if (e.kind != .user) continue;
        const nl = std.mem.indexOfScalar(u8, e.text, '\n') orelse e.text.len;
        const clip = e.text[0..@min(nl, 60)];
        const mark: []const u8 = if (no == sel) "› " else "  ";
        const line = try std.fmt.allocPrint(a, "{s}#{d}  {s}", .{ mark, no + 1, clip });
        try out.appendSlice(if (no == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
        no += 1;
    }
    try out.append('\n');
    try out.appendSlice(try theme_mod.paint(a, th.muted, "↑↓ move · Enter jump · Esc"));
    try out.append('\n');
    return out.items;
}

fn helpOverlay(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    return theme_mod.paint(a, self.theme().text,
        \\Shortcuts
        \\
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
        \\  Shift+drag     copy (native selection)
        \\  Ctrl+Z          undo composer
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
    );
}

test "help overlay names the advertised pager commands" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.help);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try overlay(&m, arena.allocator(), 80);
    for ([_][]const u8{
        "/quit",     "/help", "/new", "/home", "/model", "/settings", "/usage", "/debug", "/plan", "/always-approve",
        "Shift+Tab", "PgUp",  "PgDn",
        "←",
        "→",
        "Tab",       "Enter", "Esc",
    }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, text, name) != null);
    }
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

test "model overlay lists engine.g_models" {
    engine.g_models = "grok-4, gpt-5.5";
    engine.g_model_name = "grok-4";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
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
    try std.testing.expect(std.mem.indexOf(u8, text, "Model ›") != null);
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
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.debug);
    const text = try overlay(&m, std.testing.allocator, 80);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "offline") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "overlay       debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt-origin") != null);
}

pub const splitModels = @import("models.zig").splitModels;

fn settingsOverlay(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(try theme_mod.paint(a, th.accent, "Settings"));
    try out.appendSlice("\n\n");
    const rows = [_][2][]const u8{
        .{ "Model", if (engine.g_model_name.len > 0) engine.g_model_name else "—" },
        .{ "Effort", @tagName(self.effort) },
        .{ "Mode", self.modeLabel() },
        .{ "Theme", self.theme_id.label() },
    };
    const sel = self.overlay_sel % rows.len;
    for (rows, 0..) |r, i| {
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const line = try std.fmt.allocPrint(a, "{s}{s:<10}  {s}", .{ mark, r[0], r[1] });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    try out.append('\n');
    try out.appendSlice(try theme_mod.paint(a, th.muted, "Enter change · type /model to search · Esc"));
    try out.append('\n');
    return out.items;
}

fn debugOverlay(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var buf: [2048]u8 = undefined;
    const body: []const u8 = if (engine.g_hud_fn) |f| buf[0..f(.debug, &buf)] else "observability  (offline — no session sink)\n";
    var lbuf: [256]u8 = undefined;
    const lay = @import("dump.zig").layoutBuf(&lbuf, self);
    return std.fmt.allocPrint(a, "{s}{s}Observability{s}\n{s}{s}{s}\n{s}Esc close{s}\n", .{
        theme_mod.bold, th.text, theme_mod.reset, th.text, body, lay, th.muted, theme_mod.reset,
    });
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
