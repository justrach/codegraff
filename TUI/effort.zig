//! Searchable reasoning-effort picker — same shape as the model overlay.

const std = @import("std");
const app = @import("app.zig");
const engine = @import("engine.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub const all = std.meta.tags(engine.Effort);

fn blurb(e: engine.Effort) []const u8 {
    return switch (e) {
        .low => "faster, shorter thoughts",
        .medium => "default",
        .high => "deeper reasoning",
        .xhigh => "extra-deep",
        .max => "maximum",
        .ultra => "ultra + workflow",
    };
}

fn hidesMax() bool {
    const p = engine.g_model_provider;
    const m = engine.g_model_name;
    return std.mem.eql(u8, p, "xai") or std.mem.startsWith(u8, m, "grok");
}

pub fn filter(query: []const u8, out: []engine.Effort) usize {
    var n: usize = 0;
    for (all) |e| {
        if (hidesMax() and (e == .max or e == .ultra)) continue;
        const name = @tagName(e);
        if (query.len > 0 and std.mem.indexOf(u8, name, query) == null) continue;
        if (n >= out.len) break;
        out[n] = e;
        n += 1;
    }
    return n;
}

pub fn pick(self: *const Model) ?engine.Effort {
    var buf: [all.len]engine.Effort = undefined;
    const n = filter(self.overlay_filter, &buf);
    if (n == 0) return null;
    return buf[self.overlay_sel % n];
}

/// The panel's top-edge slots (overlaypane.zig places them).
pub fn head(self: *const Model, a: std.mem.Allocator) !panel.Head {
    var names: [all.len]engine.Effort = undefined;
    return .{
        .title = try std.fmt.allocPrint(a, "Effort › {s}\u{258B}", .{self.overlay_filter}),
        .note = try std.fmt.allocPrint(a, "{d}/{d}", .{ filter(self.overlay_filter, &names), all.len }),
    };
}

pub const hint = "type to filter · ↑↓ move · click or Enter picks · Esc";

/// The ROWS only — the frame carries the rest.
pub fn render(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var names: [all.len]engine.Effort = undefined;
    const n = filter(self.overlay_filter, &names);
    var out = std.array_list.Managed(u8).init(a);
    if (n == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "  no matches\n"));
        return out.items;
    }
    const sel = self.overlay_sel % n;
    for (names[0..n], 0..) |e, i| {
        const mark: []const u8 = if (i == sel) "› " else "  ";
        const cur: []const u8 = if (e == self.effort) "  (current)" else "";
        const line = try std.fmt.allocPrint(a, "{s}{s:<8}  {s}{s}", .{ mark, @tagName(e), blurb(e), cur });
        try out.appendSlice(if (i == sel) try theme_mod.paint(a, th.accent, line) else try theme_mod.paint(a, th.muted, line));
        try out.append('\n');
    }
    return out.items;
}

test "filter matches effort names" {
    var buf: [8]engine.Effort = undefined;
    try std.testing.expectEqual(@as(usize, 1), filter("low", &buf));
    try std.testing.expectEqual(engine.Effort.low, buf[0]);
    try std.testing.expectEqual(@as(usize, all.len), filter("", &buf));
}

test "grok seat hides max and ultra" {
    const saved_p = engine.g_model_provider;
    const saved_m = engine.g_model_name;
    defer {
        engine.g_model_provider = saved_p;
        engine.g_model_name = saved_m;
    }
    engine.g_model_provider = "xai";
    engine.g_model_name = "grok-4.6";
    var buf: [8]engine.Effort = undefined;
    const n = filter("", &buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    for (buf[0..n]) |e| try std.testing.expect(e != .max and e != .ultra);
}

test "effort overlay lists levels and marks current" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.effort = .high;
    m.openOverlay(.effort);
    m.overlay_sel = @intFromEnum(m.effort);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, (try head(&m, arena.allocator())).title, "Effort ›") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "low") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "high") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(current)") != null);
}
