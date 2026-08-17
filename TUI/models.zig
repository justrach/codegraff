//! Searchable model picker (same fuzzy feel as the line-REPL `/model`).

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub const max_models = 256;
/// Rows the picker draws at once. Public so the click map (overlays.rowSpan)
/// reads the same window the renderer draws rather than a second copy of it.
pub const visible_rows = 14;

/// Case-insensitive substring, else fzf-style subsequence ("gpt56" → gpt-5.6).
pub fn modelMatch(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (containsIgnoreCase(name, query)) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Split `engine.g_models` (", "-joined) and keep names matching `query`.
pub fn filterModels(list: []const u8, query: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, list, ", ");
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (!modelMatch(name, query)) continue;
        if (n >= out.len) break;
        out[n] = name;
        n += 1;
    }
    return n;
}

/// Unfiltered split (empty query). Kept so callers that do not search still work.
pub fn splitModels(list: []const u8, out: [][]const u8) usize {
    return filterModels(list, "", out);
}

pub fn render(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const w = @import("chrome.zig").rowCols(width);
    const th = self.theme();
    var names: [max_models][]const u8 = undefined;
    const total = splitModels(engine.g_models, &names);
    const n = filterModels(engine.g_models, self.overlay_filter, &names);
    var out = std.array_list.Managed(u8).init(a);

    const q = self.overlay_filter;
    const title = theme_mod.takeCols(try std.fmt.allocPrint(a, "Model › {s}▋", .{q}), w);
    try out.appendSlice(try theme_mod.paint(a, th.accent, title));
    try out.append('\n');
    try out.appendSlice(try theme_mod.paint(a, th.muted, try std.fmt.allocPrint(a, "{d}/{d}", .{ n, total })));
    try out.appendSlice("\n\n");

    if (n == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, theme_mod.takeCols("no matches — type to filter, Esc to close", w)));
        try out.append('\n');
        return out.items;
    }

    const sel = self.overlay_sel % n;
    const vis = @min(visible_rows, n);
    const off = if (sel >= vis) sel - vis + 1 else 0;
    var i = off;
    while (i < n and i < off + vis) : (i += 1) {
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const cur: []const u8 = if (std.mem.eql(u8, names[i], engine.g_model_name)) "  (current)" else "";
        const shown = tailId(names[i]);
        const line = theme_mod.takeCols(try std.fmt.allocPrint(a, "{s}{s}{s}", .{ mark, shown, cur }), w);
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    try out.append('\n');
    try out.appendSlice(try theme_mod.paint(a, th.muted, theme_mod.takeCols("type to search · ↑↓ move · click or Enter picks · Esc", w)));
    try out.append('\n');
    return out.items;
}

/// Fireworks ids share a long prefix; show the distinguishing tail.
fn tailId(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |sl| {
        if (sl + 1 < name.len) return name[sl + 1 ..];
    }
    return name;
}

test "modelMatch: substring and subsequence" {
    try std.testing.expect(modelMatch("gpt-5.6", "gpt"));
    try std.testing.expect(modelMatch("gpt-5.6", "gpt56"));
    try std.testing.expect(modelMatch("accounts/fireworks/models/deepseek-v4-pro", "deepseek"));
    try std.testing.expect(!modelMatch("gpt-5.6", "claude"));
}

test "filterModels ranks by query, not the first 32 only" {
    const list = "aaa, bbb, ccc, accounts/fireworks/models/deepseek-v4-pro, gpt-5.6";
    var buf: [8][]const u8 = undefined;
    const n = filterModels(list, "deepseek", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("accounts/fireworks/models/deepseek-v4-pro", buf[0]);
    try std.testing.expectEqual(@as(usize, 5), filterModels(list, "", &buf));
}

test "model overlay typed query is a filtered list, not the dump" {
    engine.g_models = "grok-4, gpt-5.5, accounts/fireworks/models/deepseek-v4-pro";
    engine.g_model_name = "grok-4";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    for ("deepseek") |c| m.typeOverlayFilter(c);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, text, "deepseek-v4-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gpt-5.5") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Model › deepseek") != null);
}
