//! dispatch.zig tests that outgrew the 600-line source cap.

const std = @import("std");

const app = @import("app.zig");
const bgop = @import("bgop.zig");
const dispatch = @import("dispatch.zig");
const engine = @import("engine.zig");
const Model = app.Model;

/// Spin until the background op finishes, then apply it — what run.zig's loop
/// does every frame while the frame keeps painting.
fn settle(m: *Model) !void {
    var spins: usize = 0;
    while (m.bg) |op| {
        if (op.done.load(.acquire)) break;
        spins += 1;
        if (spins > 1_000_000) return error.OpNeverFinished;
        std.Thread.yield() catch {};
    }
    bgop.finish(m);
}

test "! runs through the bash callback in the background and lands in the scrollback (#533)" {
    engine.g_bash_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
            return std.fmt.allocPrint(gpa, "ran: {s}", .{cmd}) catch null;
        }
    }.f;
    defer engine.g_bash_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = dispatch.applyLine(&m, "!git status");
    // The command is OFF the render thread: applyLine already returned.
    try std.testing.expect(m.bg != null);
    try settle(&m);
    try std.testing.expectEqual(@as(usize, 2), m.history.items.len);
    try std.testing.expectEqualStrings("$ git status", m.history.items[0].text);
    try std.testing.expectEqualStrings("ran: git status", m.history.items[1].text);
    try std.testing.expectEqual(app.EntryKind.system, m.history.items[1].kind);
}

test "a model turn cannot start while /compact is rewriting the history (#533)" {
    engine.g_compact_fn = struct {
        fn f(_: ?*anyopaque, _: std.mem.Allocator, _: []const engine.Turn, _: *engine.CompactOut) bool {
            return false;
        }
    }.f;
    defer engine.g_compact_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.chat = true;
    try m.push(.user, "one");
    dispatch.compact(&m);
    try std.testing.expect(m.bg != null);
    try std.testing.expectEqual(app.Effect.stay, dispatch.applyLine(&m, "next question"));
    try std.testing.expect(m.pending == null);
    const last = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, last, "still running") != null);
    try settle(&m);
    try std.testing.expect(m.bg == null);
}

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
    try settle(&m); // the engine call runs off the render thread now (#533)
    try std.testing.expectEqual(@as(usize, 2), m.history.items.len);
    try std.testing.expectEqual(app.EntryKind.system, m.history.items[0].kind);
    try std.testing.expectEqual(app.EntryKind.user, m.history.items[1].kind);
    try std.testing.expectEqualStrings("Context: earlier work", m.history.items[1].text);
}
