//! Fullscreen `/resume` — session list overlay, plus `/resume SOURCE [--branch DEST]`.

const std = @import("std");
const app = @import("app.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const models = @import("models.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub const max_sessions = 512;
pub const visible_rows = 10;
pub const hint = "type to search · ↑↓ move · click or Enter resumes · Esc";

pub const Row = struct { base: []const u8, label: []const u8, desc: []const u8 };

fn parseRow(raw: []const u8) Row {
    const t1 = std.mem.indexOfScalar(u8, raw, '\t') orelse return .{ .base = raw, .label = raw, .desc = "" };
    const base = raw[0..t1];
    const rest = raw[t1 + 1 ..];
    const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse return .{ .base = base, .label = rest, .desc = "" };
    const label = rest[0..t2];
    return .{ .base = base, .label = if (label.len > 0) label else base, .desc = rest[t2 + 1 ..] };
}

pub fn filterList(list: []const u8, query: []const u8, out: []Row) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const row = parseRow(line);
        if (!models.modelMatch(row.base, query) and !models.modelMatch(row.label, query) and !models.modelMatch(row.desc, query)) continue;
        if (n >= out.len) break;
        out[n] = row;
        n += 1;
    }
    return n;
}

pub fn pick(self: *const Model) ?[]const u8 {
    var rows: [max_sessions]Row = undefined;
    const n = filterList(self.sessions_cache orelse "", self.overlay_filter, &rows);
    if (n == 0) return null;
    return rows[self.overlay_sel % n].base;
}

/// Bare `/resume`: load the saved-session list and open the picker.
pub fn open(self: *Model) void {
    if (self.sessions_cache) |old| {
        self.alloc.free(old);
        self.sessions_cache = null;
    }
    if (engine.g_sessions_fn) |f| self.sessions_cache = f(engine.g_turn_ctx, self.alloc);
    self.openOverlay(.sessions);
}

pub fn head(self: *const Model, a: std.mem.Allocator) !panel.Head {
    var rows: [max_sessions]Row = undefined;
    const list = self.sessions_cache orelse "";
    const total = filterList(list, "", &rows);
    const n = filterList(list, self.overlay_filter, &rows);
    return .{
        .title = try std.fmt.allocPrint(a, "Resume session › {s}\u{258B}", .{self.overlay_filter}),
        .note = try std.fmt.allocPrint(a, "{d}/{d}", .{ n, total }),
    };
}

pub fn render(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var rows: [max_sessions]Row = undefined;
    const list = self.sessions_cache orelse "";
    const n = filterList(list, self.overlay_filter, &rows);
    var out = std.array_list.Managed(u8).init(a);
    if (n == 0) {
        const why: []const u8 = if (self.sessions_cache == null)
            "  resume isn't available (offline)"
        else if (self.overlay_filter.len > 0)
            "  no matches — type to filter"
        else
            "  no saved sessions in cwd — /save creates one";
        try out.appendSlice(try theme_mod.paint(a, th.muted, why));
        try out.append('\n');
        return out.items;
    }
    const sel = self.overlay_sel % n;
    const vis = @min(visible_rows, n);
    const off = if (sel >= vis) sel - vis + 1 else 0;
    var i = off;
    while (i < n and i < off + vis) : (i += 1) {
        const mark = glyphs.frame(&glyphs.row_mark, @intFromBool(i != sel));
        const line = if (rows[i].desc.len > 0)
            try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, rows[i].label, rows[i].desc })
        else
            try std.fmt.allocPrint(a, "{s}{s}", .{ mark, rows[i].label });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    if (n > vis) try out.appendSlice(try panel.windowRow(a, th, off, vis, n));
    return out.items;
}

pub fn run(self: *app.Model, spec: []const u8) void {
    if (spec.len == 0) {
        open(self);
        return;
    }
    const callback = engine.g_resume_fn orelse {
        self.push(.system, "resume isn't available (offline)") catch {};
        return;
    };
    var out: engine.ResumeOut = .{};
    if (!callback(engine.g_turn_ctx, self.alloc, spec, &out)) {
        if (out.note.len > 0) {
            self.push(.err, out.note) catch {};
            self.alloc.free(out.note);
        } else self.push(.err, "resume failed") catch {};
        return;
    }
    self.clearHistory();
    for (out.turns) |turn| {
        self.push(if (turn.role == .user) .user else .assistant, turn.text) catch {};
        self.alloc.free(turn.text);
    }
    if (out.turns.len > 0) self.alloc.free(out.turns);
    self.turns = self.userTurnCount();
    if (self.session_name) |old| self.alloc.free(old);
    self.session_name = out.session_name;
    if (self.goal) |old| self.alloc.free(old);
    self.goal = if (out.goal.len > 0) out.goal else null;
    self.strict = out.strict;
    self.ultracode = out.ultracode;
    if (out.note.len > 0) {
        self.push(.system, out.note) catch {};
        self.alloc.free(out.note);
    }
}

fn fakeSessions(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8 {
    return gpa.dupe(u8, "alpha\tAlpha title\t2h ago\nbeta\tbeta\tjust now") catch null;
}

fn fakeResume(_: ?*anyopaque, gpa: std.mem.Allocator, spec: []const u8, out: *engine.ResumeOut) bool {
    if (std.mem.eql(u8, spec, "alpha")) {
        const turns = gpa.alloc(engine.Turn, 1) catch return false;
        turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "from alpha") catch return false };
        out.* = .{
            .turns = turns,
            .session_name = gpa.dupe(u8, "alpha") catch return false,
            .note = gpa.dupe(u8, "resumed alpha") catch return false,
        };
        return true;
    }
    if (!std.mem.eql(u8, spec, "base --branch child")) return false;
    const turns = gpa.alloc(engine.Turn, 2) catch return false;
    turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "baseline prompt") catch return false };
    turns[1] = .{ .role = .assistant, .text = gpa.dupe(u8, "baseline answer") catch return false };
    out.* = .{
        .turns = turns,
        .session_name = gpa.dupe(u8, "child") catch return false,
        .note = gpa.dupe(u8, "branched base → child") catch return false,
    };
    return true;
}

test "fullscreen resume replaces transcript and selects the branch" {
    const saved = engine.g_resume_fn;
    defer engine.g_resume_fn = saved;
    engine.g_resume_fn = fakeResume;
    var model: app.Model = undefined;
    model.setup(std.testing.allocator);
    defer model.deinit();
    try model.push(.user, "stale prompt");
    run(&model, "base --branch child");
    try std.testing.expectEqualStrings("child", model.session_name.?);
    try std.testing.expectEqual(@as(usize, 3), model.history.items.len);
    try std.testing.expectEqualStrings("baseline prompt", model.history.items[0].text);
    try std.testing.expectEqualStrings("baseline answer", model.history.items[1].text);
    try std.testing.expectEqualStrings("branched base → child", model.history.items[2].text);
}

test "bare /resume opens a list overlay and Enter resumes the highlighted session" {
    engine.g_sessions_fn = fakeSessions;
    defer engine.g_sessions_fn = null;
    engine.g_resume_fn = fakeResume;
    defer engine.g_resume_fn = null;
    var m: app.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "stale");
    open(&m);
    try std.testing.expectEqual(app.Overlay.sessions, m.overlay);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "Alpha title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2h ago") != null);
    _ = @import("overlays.zig").key(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("alpha", m.session_name.?);
    try std.testing.expectEqualStrings("from alpha", m.history.items[0].text);
}

test "clicking a /resume row selects then confirms" {
    engine.g_sessions_fn = fakeSessions;
    defer engine.g_sessions_fn = null;
    engine.g_resume_fn = fakeResume;
    defer engine.g_resume_fn = null;
    var term: @import("sim.zig").Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = @import("dispatch.zig").applyLine(&term.model, "/resume");
    try std.testing.expectEqual(app.Overlay.sessions, term.model.overlay);
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "Alpha title") != null);
    try std.testing.expect(try term.clickText("Alpha title"));
    try std.testing.expectEqual(app.Overlay.sessions, term.model.overlay);
    try std.testing.expect(try term.clickText("Alpha title"));
    try std.testing.expectEqual(app.Overlay.none, term.model.overlay);
    try std.testing.expectEqualStrings("alpha", term.model.session_name.?);
}

test "filterList matches title, base, and subsequence" {
    var buf: [8]Row = undefined;
    const list = "alpha\tAlpha title\t2h ago\nbeta\tbeta\tjust now";
    try std.testing.expectEqual(@as(usize, 2), filterList(list, "", &buf));
    try std.testing.expectEqual(@as(usize, 1), filterList(list, "alpha", &buf));
    try std.testing.expectEqualStrings("alpha", buf[0].base);
    try std.testing.expectEqual(@as(usize, 1), filterList(list, "title", &buf));
    try std.testing.expectEqualStrings("alpha", buf[0].base);
}
