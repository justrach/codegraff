//! /resume picker: the line REPL's saved sessions (.graff/sessions), listed
//! and loaded through the engine seam so the TUI stays engine-agnostic.
//! Cache rows are "base\ttitle\tage" lines from engine.g_sessions_fn.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const models = @import("models.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub const max_rows = 256;
/// Rows the picker draws at once — overlays.rowSpan reads the same window.
pub const visible_rows = 14;

pub const Row = struct { base: []const u8, title: []const u8, age: []const u8 };

fn parseRow(line: []const u8) Row {
    var it = std.mem.splitScalar(u8, line, '\t');
    return .{
        .base = it.next() orelse "",
        .title = it.next() orelse "",
        .age = it.next() orelse "",
    };
}

pub fn filterRows(cache: []const u8, query: []const u8, out: []Row) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, cache, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const r = parseRow(line);
        if (!(models.modelMatch(r.base, query) or models.modelMatch(r.title, query))) continue;
        if (n >= out.len) break;
        out[n] = r;
        n += 1;
    }
    return n;
}

/// Load the saved-session list once, then open the picker.
pub fn open(self: *Model) void {
    if (self.sessions_cache == null) {
        if (engine.g_sessions_fn) |f| self.sessions_cache = f(engine.g_turn_ctx, self.alloc);
    }
    if (self.sessions_cache == null or self.sessions_cache.?.len == 0) {
        self.screen = .agent; // welcome hides system rows until a user turn
        self.push(.system, "no saved sessions — /save one in the line REPL first") catch {};
        return;
    }
    self.openOverlay(.resume_pick);
}

/// The panel's top-edge slots (overlaypane.zig places them).
pub fn head(self: *const Model, a: std.mem.Allocator) !panel.Head {
    var rows: [max_rows]Row = undefined;
    const cache = self.sessions_cache orelse "";
    const total = filterRows(cache, "", &rows);
    const n = filterRows(cache, self.overlay_filter, &rows);
    return .{
        .title = try std.fmt.allocPrint(a, "Resume › {s}\u{258B}", .{self.overlay_filter}),
        .note = try std.fmt.allocPrint(a, "{d}/{d}", .{ n, total }),
    };
}

pub const hint = "type to search · ↑↓ move · click or Enter resume · Esc";

/// The ROWS only — the frame carries the rest.
pub fn render(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var rows: [max_rows]Row = undefined;
    const n = filterRows(self.sessions_cache orelse "", self.overlay_filter, &rows);
    var out = std.array_list.Managed(u8).init(a);
    if (n == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "  no matches — type to filter"));
        try out.append('\n');
        return out.items;
    }
    const sel = self.overlay_sel % n;
    const vis = @min(visible_rows, n);
    const off = if (sel >= vis) sel - vis + 1 else 0;
    var i = off;
    while (i < n and i < off + vis) : (i += 1) {
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const line = if (rows[i].title.len > 0)
            try std.fmt.allocPrint(a, "{s}{s} — {s}  ({s})", .{ mark, rows[i].base, rows[i].title, rows[i].age })
        else
            try std.fmt.allocPrint(a, "{s}{s}  ({s})", .{ mark, rows[i].base, rows[i].age });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    if (n > vis) try out.appendSlice(try panel.windowRow(a, th, off, vis, n));
    return out.items;
}

/// Enter in the picker.
pub fn pick(self: *Model) void {
    var rows: [max_rows]Row = undefined;
    const n = filterRows(self.sessions_cache orelse "", self.overlay_filter, &rows);
    const sel = if (n == 0) 0 else self.overlay_sel % n;
    self.closeOverlay(); // keeps sessions_cache, so rows[sel].base stays valid
    if (n == 0) return;
    resumeByName(self, rows[sel].base);
}

pub fn resumeByName(self: *Model, base: []const u8) void {
    const f = engine.g_resume_fn orelse {
        self.push(.system, "resume needs a live session") catch {};
        return;
    };
    var out: engine.ResumeOut = .{};
    const ok = f(engine.g_turn_ctx, self.alloc, base, &out);
    defer {
        for (out.turns) |t| self.alloc.free(t.text);
        if (out.turns.len > 0) self.alloc.free(out.turns);
        if (out.model.len > 0) self.alloc.free(out.model);
    }
    if (!ok) {
        self.screen = .agent; // welcome hides err rows until a user turn
        self.pushFmt(.err, "couldn't resume '{s}' — see /sessions in the line REPL", .{base}) catch {};
        return;
    }
    self.clearHistory();
    // The engine owns the conversation (#551): drop it so the next turn's
    // adopt() seeds from the resumed transcript instead of the old session.
    engine.historyChanged(.reset);
    self.screen = .agent;
    for (out.turns) |t| {
        self.push(switch (t.role) {
            .user => .user,
            .assistant => .assistant,
        }, t.text) catch {};
    }
    if (out.model.len > 0) {
        if (engine.g_model_fn) |mf| {
            if (mf(engine.g_turn_ctx, self.alloc, "", out.model)) |got| self.adoptModel(got);
        }
    }
    self.pushFmt(.system, "resumed {s} · {d} turns", .{ base, out.turns.len }) catch {};
    self.scroll = 0;
    self.follow = true;
}

test "filterRows parses tab rows and fuzzy-matches base or title" {
    const cache = "fix-login\tFix login bug\t2h ago\nspike\t\tjust now";
    var rows: [8]Row = undefined;
    try std.testing.expectEqual(@as(usize, 2), filterRows(cache, "", &rows));
    try std.testing.expectEqual(@as(usize, 1), filterRows(cache, "login", &rows));
    try std.testing.expectEqualStrings("fix-login", rows[0].base);
    try std.testing.expectEqualStrings("2h ago", rows[0].age);
    try std.testing.expectEqual(@as(usize, 1), filterRows(cache, "spk", &rows));
}

test "resume picker loads turns into history and notes the session" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.sessions_cache = try std.testing.allocator.dupe(u8, "alpha\tFirst try\t1h ago");
    const Seen = struct {
        var reset: bool = false;
        fn hist(_: ?*anyopaque, op: engine.HistoryOp) void {
            if (op == .reset) reset = true;
        }
    };
    Seen.reset = false;
    engine.g_history_fn = Seen.hist;
    defer engine.g_history_fn = null;
    engine.g_resume_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, base: []const u8, out: *engine.ResumeOut) bool {
            std.testing.expectEqualStrings("alpha", base) catch return false;
            const turns = gpa.alloc(engine.Turn, 2) catch return false;
            turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "hi") catch return false };
            turns[1] = .{ .role = .assistant, .text = gpa.dupe(u8, "hello") catch return false };
            out.turns = turns;
            return true;
        }
    }.f;
    defer engine.g_resume_fn = null;
    m.openOverlay(.resume_pick);
    pick(&m);
    try std.testing.expect(Seen.reset);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqual(@as(usize, 3), m.history.items.len); // 2 turns + note
    try std.testing.expectEqual(app.EntryKind.user, m.history.items[0].kind);
    try std.testing.expectEqualStrings("hello", m.history.items[1].text);
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[2].text, "resumed alpha") != null);
    try std.testing.expectEqual(app.Screen.agent, m.screen);
}

test "resume with no saved sessions explains instead of opening an empty picker" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    engine.g_sessions_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8 {
            return gpa.dupe(u8, "") catch null;
        }
    }.f;
    defer engine.g_sessions_fn = null;
    open(&m);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[0].text, "no saved sessions") != null);
}
