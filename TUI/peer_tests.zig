//! #563 Slice B: TUI `/tell` / `/peek` are catalogued and route through the
//! engine. Drive the pager with `sim.Term` — no PTY, no Ghostty window.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const dispatch = @import("dispatch.zig");
const engine = @import("engine.zig");
const peer_cmd = @import("peer_cmd.zig");
const sim = @import("sim.zig");

test "catalog lists /tell and /peek" {
    try std.testing.expect(catalog.lookup("/tell") != null);
    try std.testing.expect(catalog.lookup("/peek") != null);
    try std.testing.expectEqualStrings("/tell", catalog.lookup("/tell").?.name);
    try std.testing.expectEqualStrings("/peek", catalog.lookup("/peek").?.name);
}

test "bare /tell and /peek print usage when the engine is offline" {
    var m: app.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = dispatch.applyLine(&m, "/tell");
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[m.history.items.len - 1].text, "usage: /tell") != null);
    _ = dispatch.applyLine(&m, "/peek");
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[m.history.items.len - 1].text, "usage: /peek") != null);
}

test "/tell from the pager reaches the engine and shows the posted line" {
    const Seen = struct {
        var line: []u8 = &.{};
        var room: std.ArrayList(u8) = .empty;
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, raw: []const u8) ?[]const u8 {
            if (line.len > 0) gpa.free(line);
            line = gpa.dupe(u8, raw) catch return null;
            room.appendSlice(gpa, raw) catch {};
            room.append(gpa, '\n') catch {};
            return gpa.dupe(u8, "⇢ posted to the device-wide room") catch null;
        }
    };
    Seen.line = &.{};
    Seen.room = .empty;
    engine.g_peer_fn = Seen.f;
    defer {
        engine.g_peer_fn = null;
        if (Seen.line.len > 0) std.testing.allocator.free(Seen.line);
        Seen.room.deinit(std.testing.allocator);
    }

    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("/tell all hold the tree");
    _ = term.enter();

    try std.testing.expectEqualStrings("/tell all hold the tree", Seen.line);
    try std.testing.expect(std.mem.indexOf(u8, Seen.room.items, "hold the tree") != null);
    try std.testing.expect(term.model.history.items.len > 0);
    const last = term.model.history.items[term.model.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, last, "posted to the device-wide room") != null);

    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "posted to the device-wide room") != null);
}

test "/peek from the pager reaches the engine" {
    const Seen = struct {
        var line: []u8 = &.{};
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, raw: []const u8) ?[]const u8 {
            if (line.len > 0) gpa.free(line);
            line = gpa.dupe(u8, raw) catch return null;
            return gpa.dupe(u8, "⚡ other · pid 9 · goal: refactor") catch null;
        }
    };
    Seen.line = &.{};
    engine.g_peer_fn = Seen.f;
    defer {
        engine.g_peer_fn = null;
        if (Seen.line.len > 0) std.testing.allocator.free(Seen.line);
    }

    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("/peek other");
    _ = term.enter();
    try std.testing.expectEqualStrings("/peek other", Seen.line);
    const last = term.model.history.items[term.model.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, last, "goal: refactor") != null);
}

test "offline /tell with a payload explains instead of posting" {
    engine.g_peer_fn = null;
    var m: app.Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = dispatch.applyLine(&m, "/tell all hi");
    try std.testing.expectEqualStrings(peer_cmd.offline_note, m.history.items[m.history.items.len - 1].text);
}
