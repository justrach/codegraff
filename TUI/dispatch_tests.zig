//! dispatch.zig tests that outgrew the 600-line source cap.

const std = @import("std");

const app = @import("app.zig");
const dispatch = @import("dispatch.zig");
const engine = @import("engine.zig");
const Model = app.Model;

test "/new /compact /rewind are blocked while a job is pending (#521)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .threaded = false,
        .gpa = std.testing.allocator,
        .history = try std.testing.allocator.alloc(engine.Turn, 0),
        .params = .{},
        .stream = .{},
    };
    m.pending = job;
    _ = dispatch.runCommand(&m, "/new");
    try std.testing.expect(m.pending != null);
    try std.testing.expectEqualStrings("hi", m.history.items[0].text);
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[1].text, "still running") != null);
    _ = dispatch.runCommand(&m, "/rewind");
    _ = dispatch.runCommand(&m, "/compact");
    try std.testing.expectEqualStrings("hi", m.history.items[0].text);
}

test "/compact never crops locally; engine stub rewrites history" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "alpha");
    try m.push(.assistant, "beta");
    try m.push(.user, "gamma");
    _ = dispatch.applyLine(&m, "/compact");
    try std.testing.expectEqual(@as(usize, 4), m.history.items.len); // 3 + notice
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[3].text, "live session") != null);

    engine.g_compact_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const engine.Turn, out: *engine.CompactOut) bool {
            out.note = gpa.dupe(u8, "history compacted to a 12-char summary") catch "";
            const turns = gpa.alloc(engine.Turn, 1) catch return false;
            turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "Context: earlier work") catch "" };
            out.turns = turns;
            return true;
        }
    }.f;
    defer engine.g_compact_fn = null;
    _ = dispatch.applyLine(&m, "/compact");
    try std.testing.expectEqual(@as(usize, 2), m.history.items.len);
    try std.testing.expectEqual(app.EntryKind.system, m.history.items[0].kind);
    try std.testing.expectEqual(app.EntryKind.user, m.history.items[1].kind);
    try std.testing.expectEqualStrings("Context: earlier work", m.history.items[1].text);
}
