//! @-mention file picker: fuzzy filter over the session file list.

const std = @import("std");

const app = @import("app.zig");
const models = @import("models.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub const max_files = 512;
const visible_rows = 10;

/// Newline-joined `list` filtered by substring-or-subsequence `query`.
pub fn filterList(list: []const u8, query: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r");
        if (name.len == 0) continue;
        if (!models.modelMatch(name, query)) continue;
        if (n >= out.len) break;
        out[n] = name;
        n += 1;
    }
    return n;
}

pub fn render(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var names: [max_files][]const u8 = undefined;
    const list = self.files_cache orelse "";
    const total = filterList(list, "", &names);
    const n = filterList(list, self.overlay_filter, &names);
    var out = std.array_list.Managed(u8).init(a);
    const title = try std.fmt.allocPrint(a, "File › {s}▋", .{self.overlay_filter});
    try out.appendSlice(try theme_mod.paint(a, th.accent, title));
    try out.append('\n');
    try out.appendSlice(try theme_mod.paint(a, th.muted, try std.fmt.allocPrint(a, "{d}/{d}", .{ n, total })));
    try out.appendSlice("\n\n");
    if (n == 0) {
        const hint = if (list.len == 0) "no file list (offline?) — Esc" else "no matches — type to filter, Esc";
        try out.appendSlice(try theme_mod.paint(a, th.muted, hint));
        try out.append('\n');
        return out.items;
    }
    const sel = self.overlay_sel % n;
    const vis = @min(visible_rows, n);
    const off = if (sel >= vis) sel - vis + 1 else 0;
    var i = off;
    while (i < n and i < off + vis) : (i += 1) {
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const line = try std.fmt.allocPrint(a, "{s}{s}", .{ mark, names[i] });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    try out.append('\n');
    try out.appendSlice(try theme_mod.paint(a, th.muted, "type to search · ↑↓ · Enter insert · Esc"));
    try out.append('\n');
    return out.items;
}

test "filterList matches substring and subsequence" {
    var buf: [8][]const u8 = undefined;
    const list = "src/main.zig\nTUI/key.zig\nREADME.md";
    try std.testing.expectEqual(@as(usize, 3), filterList(list, "", &buf));
    try std.testing.expectEqual(@as(usize, 1), filterList(list, "tuikey", &buf));
    try std.testing.expectEqualStrings("TUI/key.zig", buf[0]);
    try std.testing.expectEqual(@as(usize, 1), filterList(list, "readme", &buf));
}

test "render shows the filtered file rows" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.files_cache = try std.testing.allocator.dupe(u8, "src/a.zig\ndocs/b.md");
    m.openOverlay(.file);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "docs/b.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "File ›") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2/2") != null);
}
