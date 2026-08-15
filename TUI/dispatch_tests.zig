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
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8, _: engine.Params) ?[]const u8 {
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

test "/new /compact /rewind /resume are blocked while a job is pending (#521)" {
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
    _ = dispatch.runCommand(&m, "/resume");
    try std.testing.expectEqualStrings("hi", m.history.items[0].text);
}

test "cutting the transcript reaches the engine's conversation (#551)" {
    // The model's history lives in the engine now, so a TUI-local truncation
    // that never told it left the discarded turns in the next request body.
    const Seen = struct {
        var ops: std.ArrayList(engine.HistoryOp) = .empty;
        fn f(_: ?*anyopaque, op: engine.HistoryOp) void {
            ops.append(std.testing.allocator, op) catch {};
        }
    };
    Seen.ops = .empty;
    defer Seen.ops.deinit(std.testing.allocator);
    engine.g_history_fn = Seen.f;
    defer engine.g_history_fn = null;

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "alpha");
    try m.push(.assistant, "beta");

    _ = dispatch.applyLine(&m, "/rewind");
    try std.testing.expectEqual(@as(usize, 1), Seen.ops.items.len);
    try std.testing.expectEqual(engine.HistoryOp.rewind, Seen.ops.items[0]);

    _ = dispatch.applyLine(&m, "/new");
    try std.testing.expectEqual(@as(usize, 2), Seen.ops.items.len);
    try std.testing.expectEqual(engine.HistoryOp.reset, Seen.ops.items[1]);

    // /clear is the same command under another name, and Ctrl+N (twice) is the
    // same session reset from the keyboard.
    _ = dispatch.applyLine(&m, "/clear");
    try std.testing.expectEqual(engine.HistoryOp.reset, Seen.ops.items[Seen.ops.items.len - 1]);
    const before = Seen.ops.items.len;

    // Compaction must NOT come through here: it REWROTE the conversation, and
    // resetting on the replay would throw away the summary it just produced.
    engine.g_compact_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const engine.Turn, out: *engine.CompactOut) bool {
            out.note = gpa.dupe(u8, "history compacted") catch "";
            const turns = gpa.alloc(engine.Turn, 1) catch return false;
            turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "Context: earlier work") catch "" };
            out.turns = turns;
            return true;
        }
    }.f;
    defer engine.g_compact_fn = null;
    try m.push(.user, "gamma");
    _ = dispatch.applyLine(&m, "/compact");
    try settle(&m);
    try std.testing.expectEqual(before, Seen.ops.items.len);
}

test "a live engine call blocks every path that would free its history (#551)" {
    // The reset/rewind seam frees the arena the running turn allocates its
    // history from, so "just clear the screen" would be a use-after-free on
    // the turn thread. Ctrl+N never went through runCommand's #521 guard.
    const Seen = struct {
        var n: usize = 0;
        fn f(_: ?*anyopaque, _: engine.HistoryOp) void {
            n += 1;
        }
    };
    Seen.n = 0;
    engine.g_history_fn = Seen.f;
    defer engine.g_history_fn = null;

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "alpha");
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .threaded = false,
        .gpa = std.testing.allocator,
        .history = try std.testing.allocator.alloc(engine.Turn, 0),
        .params = .{},
        .stream = .{},
    };
    m.pending = job;

    try std.testing.expect(!m.newSession());
    dispatch.rewind(&m);
    try std.testing.expectEqual(@as(usize, 0), Seen.n);
    try std.testing.expectEqualStrings("alpha", m.history.items[0].text);

    m.pending = null;
    std.testing.allocator.free(job.history);
    std.testing.allocator.destroy(job);

    // With the engine idle both reach it again.
    try std.testing.expect(m.newSession());
    try std.testing.expectEqual(@as(usize, 1), Seen.n);
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

// --- input pacing: what one tick of a wheel storm dispatches ---------------
// The batch is built exactly as run.zig builds it and applied through the real
// keys.zig door, so these pin the DISPATCHED behaviour, not just the struct.

const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const pacing = @import("pacing.zig");

fn wheelUp() key_mod.Key {
    return .{ .mouse = .{ .btn = 64, .x = 4, .y = 4, .down = true } };
}

fn wheelDown() key_mod.Key {
    return .{ .mouse = .{ .btn = 65, .x = 4, .y = 4, .down = true } };
}

/// Feed a tick's worth of events through the coalescer and apply the batch the
/// way run.zig does.
fn tick(m: *Model, evs: []const key_mod.Key) void {
    var b: pacing.Batch = .{};
    for (evs) |k| std.debug.assert(b.push(k) == .ok);
    for (b.items()) |item| {
        _ = switch (item) {
            .key => |k| keys.handle(m, k),
            .wheel => |d| keys.wheelScroll(m, d),
        };
    }
}

test "5 wheel-up + a key + 3 wheel-down coalesce to +5, the key, then -3" {
    var b: pacing.Batch = .{};
    for (0..5) |_| _ = b.push(wheelUp());
    _ = b.push(.{ .char = 'z' });
    for (0..3) |_| _ = b.push(wheelDown());

    const it = b.items();
    try std.testing.expectEqual(@as(usize, 3), it.len);
    try std.testing.expectEqual(@as(i32, 5), it[0].wheel);
    try std.testing.expectEqual(@as(u8, 'z'), it[1].key.char);
    try std.testing.expectEqual(@as(i32, -3), it[2].wheel);
}

test "a coalesced tick lands on the same scroll a report-at-a-time tick would" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    var evs: [9]key_mod.Key = undefined;
    for (0..5) |k| evs[k] = wheelUp();
    evs[5] = .{ .char = 'z' };
    for (6..9) |k| evs[k] = wheelDown();
    tick(&m, &evs);
    // 5 notches back, 3 forward, 3 lines a notch: +6 lines, and the keystroke
    // reached the composer in its own place in the stream.
    try std.testing.expectEqual(@as(usize, 6), m.scroll);
    try std.testing.expect(!m.follow);
    try std.testing.expectEqualStrings("z", m.input.getValue());
}

test "typing is never starved behind a wheel flood" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    // 400 reports with three keystrokes buried in the middle of them — one
    // tick, and every character still arrives, in order.
    var b: pacing.Batch = .{};
    for (0..200) |_| _ = b.push(wheelUp());
    _ = b.push(.{ .char = 'h' });
    for (0..100) |_| _ = b.push(wheelUp());
    _ = b.push(.{ .char = 'i' });
    for (0..100) |_| _ = b.push(wheelDown());
    _ = b.push(.{ .char = '!' });
    // 400 wheel reports collapse into 3 units of scroll work.
    try std.testing.expectEqual(@as(usize, 6), b.len);
    for (b.items()) |item| {
        _ = switch (item) {
            .key => |k| keys.handle(&m, k),
            .wheel => |d| keys.wheelScroll(&m, d),
        };
    }
    try std.testing.expectEqualStrings("hi!", m.input.getValue());
    try std.testing.expectEqual(@as(usize, 600), m.scroll); // (200+100-100)*3
}

test "a mixed run at the bottom edge does not re-latch follow mid-tick" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    // Two notches from the bottom, then down-down-up: a net notch back. Applied
    // report by report the second down clamps at 0 and turns `follow` on, and
    // the trailing up then scrolls away from where the fingers stopped.
    keys.scrollBy(&m, 6);
    tick(&m, &.{ wheelDown(), wheelDown(), wheelUp() });
    try std.testing.expectEqual(@as(usize, 3), m.scroll);
    try std.testing.expect(!m.follow);
}

test "the same run reaching the bottom still lands there and follows" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    keys.scrollBy(&m, 3);
    tick(&m, &.{ wheelDown(), wheelDown() });
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
    try std.testing.expect(m.follow);
}

test "a single wheel report is unchanged by the coalescer" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    tick(&m, &.{wheelUp()});
    try std.testing.expectEqual(@as(usize, 3), m.scroll);
    var direct: Model = undefined;
    direct.setup(std.testing.allocator);
    defer direct.deinit();
    _ = keys.handle(&direct, wheelUp());
    try std.testing.expectEqual(m.scroll, direct.scroll);
    try std.testing.expectEqual(m.follow, direct.follow);
}
