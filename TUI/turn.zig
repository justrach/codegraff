//! Background turn lifecycle — same thread+stream pattern as `graff repl`,
//! so a grok-style spinner can animate while the engine works.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const Model = app.Model;
const Effect = app.Effect;

pub fn startJob(self: *Model) void {
    var turns = std.array_list.Managed(engine.Turn).init(self.alloc);
    for (self.history.items) |e| {
        const role: ?engine.Turn.Role = switch (e.kind) {
            .user => .user,
            .assistant => .assistant,
            else => null,
        };
        if (role) |r| {
            const t = self.alloc.dupe(u8, e.text) catch continue;
            turns.append(.{ .role = r, .text = t }) catch {
                self.alloc.free(t);
                continue;
            };
        }
    }
    const job = self.alloc.create(engine.Job) catch {
        for (turns.items) |t| self.alloc.free(t.text);
        turns.deinit();
        self.push(.err, "out of memory") catch {};
        return;
    };
    job.* = .{
        .gpa = self.alloc,
        .history = turns.toOwnedSlice() catch &.{},
        .params = .{
            .effort = self.effort,
            .fast = self.fast,
            .thinking = self.thinking_show,
            .ultracode = self.ultracode or self.effort == .ultra,
            .goal = self.goal orelse "",
        },
        .stream = .{ .buf = self.alloc.alloc(u8, 256 * 1024) catch &.{} },
    };
    self.push(.pending, "") catch {};
    self.pending = job;
    if (std.Thread.spawn(.{}, engine.jobRun, .{job})) |th| {
        job.thread = th;
    } else |_| {
        job.threaded = false;
        engine.jobRun(job);
    }
}

pub fn finishJob(self: *Model) void {
    const job = self.pending orelse return;
    if (!job.done.load(.acquire)) return;
    if (job.threaded) job.thread.join();

    const n = self.history.items.len;
    if (n > 0 and self.history.items[n - 1].kind == .pending) {
        self.alloc.free(self.history.items[n - 1].text);
        self.history.shrinkRetainingCapacity(n - 1);
    }
    // The live stream carries ⚙/✓/✗ lines; the result is only the final
    // answer. Keep the tool rows so they don't vanish with the pending entry.
    if (job.stream.snapshot(self.alloc)) |live| {
        defer self.alloc.free(live);
        persistToolLines(self, live);
    }
    if (job.result) |r| {
        self.chars_out += r.len;
        self.push(.assistant, r) catch {};
        self.alloc.free(r);
    } else if (self.cancel_requested) {
        if (!hasInterrupted(self)) self.push(.system, "■ interrupted") catch {};
    } else {
        self.push(.err, "model call failed — check /model and your API key") catch {};
    }
    for (job.history) |t| self.alloc.free(t.text);
    self.alloc.free(job.history);
    if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
    self.alloc.destroy(job);
    self.pending = null;
    self.cancel_requested = false;
    self.scroll = 0;
    self.follow = true;
}

pub fn drainSteer(self: *Model) Effect {
    if (self.steer_queue.items.len == 0) return .stay;
    const text = self.steer_queue.orderedRemove(0);
    defer self.alloc.free(text);
    return @import("dispatch.zig").applyLine(self, text);
}

pub fn steerEnter(self: *Model) void {
    const v = std.mem.trim(u8, self.input.getValue(), " \t\r\n");
    if (v.len > 0) {
        if (self.alloc.dupe(u8, v)) |dup| {
            self.steer_queue.append(dup) catch self.alloc.free(dup);
            self.input.setValue("") catch {};
            self.pushFmt(.system, "↳ queued ({d} waiting)", .{self.steer_queue.items.len}) catch {};
        } else |_| {}
    } else if (self.steer_queue.items.len > 0) {
        cancelTurn(self);
        self.push(.system, "↳ force › interrupting…") catch {};
    }
}

pub fn cancelTurn(self: *Model) void {
    if (self.pending == null) return;
    self.cancel_requested = true;
    if (engine.g_cancel_fn) |f| f(engine.g_turn_ctx);
    collapseThinking(self);
}

fn collapseThinking(self: *Model) void {
    const n = self.history.items.len;
    if (n == 0 or self.history.items[n - 1].kind != .pending) return;
    self.alloc.free(self.history.items[n - 1].text);
    const text = self.alloc.dupe(u8, "■ interrupted") catch {
        self.history.shrinkRetainingCapacity(n - 1);
        return;
    };
    self.history.items[n - 1] = .{ .kind = .system, .text = text, .folded = false };
}

fn hasInterrupted(self: *const Model) bool {
    if (self.history.items.len == 0) return false;
    return std.mem.eql(u8, self.history.items[self.history.items.len - 1].text, "■ interrupted");
}

pub fn isToolLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "⚙ ") or
        std.mem.startsWith(u8, line, "✓ ") or
        std.mem.startsWith(u8, line, "✗ ") or
        std.mem.startsWith(u8, line, "⊘ ");
}

/// Pull new ⚙/✓/✗ lines out of the live stream so they become clickable
/// folded history *during* the turn, not only after finishJob.
pub fn harvestLiveTools(self: *Model) void {
    if (self.cancel_requested) return;
    const job = self.pending orelse return;
    const live = job.stream.snapshot(self.alloc) orelse return;
    defer self.alloc.free(live);
    var held: ?app.Entry = null;
    const n = self.history.items.len;
    if (n > 0 and self.history.items[n - 1].kind == .pending) {
        held = self.history.items[n - 1];
        self.history.shrinkRetainingCapacity(n - 1);
    }
    persistToolLines(self, live);
    if (held) |e| self.history.append(e) catch {};
}

fn persistToolLines(self: *Model, stream: []const u8) void {
    var have: usize = 0;
    var hi = self.history.items.len;
    while (hi > 0) {
        hi -= 1;
        if (self.history.items[hi].kind == .user) break;
        if (self.history.items[hi].kind == .tool) have += 1;
    }
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or !isToolLine(line)) continue;
        if (seen < have) {
            seen += 1;
            continue;
        }
        self.push(.tool, line) catch {};
        seen += 1;
    }
}

test "startJob without a turn_fn finishes as a failed call" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    engine.g_turn_fn = null;
    try m.push(.user, "hi");
    startJob(&m);
    const job = m.pending orelse return error.NoJob;
    while (!job.done.load(.acquire)) std.Thread.yield() catch {};
    finishJob(&m);
    try std.testing.expect(m.pending == null);
    try std.testing.expect(m.history.items[m.history.items.len - 1].kind == .err);
}

test "finishJob keeps tool lines from the live stream" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const live = "hello\n⚙ bash\n✓ bash\nmore text";
    const buf = try std.testing.allocator.dupe(u8, live);
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{ .buf = buf },
        .threaded = false,
        .result = try std.testing.allocator.dupe(u8, "all done"),
    };
    job.stream.len.store(live.len, .release);
    job.done.store(true, .release);
    try m.push(.pending, "");
    m.pending = job;
    finishJob(&m);
    try std.testing.expect(m.pending == null);
    try std.testing.expectEqual(@as(usize, 3), m.history.items.len);
    try std.testing.expectEqual(app.EntryKind.tool, m.history.items[0].kind);
    try std.testing.expectEqualStrings("⚙ bash", m.history.items[0].text);
    try std.testing.expectEqual(app.EntryKind.tool, m.history.items[1].kind);
    try std.testing.expectEqualStrings("✓ bash", m.history.items[1].text);
    try std.testing.expectEqual(app.EntryKind.assistant, m.history.items[2].kind);
    try std.testing.expectEqualStrings("all done", m.history.items[2].text);
}

test "hosted tool line is visible on the live tail before finishJob" {
    const scrollback = @import("scrollback.zig");
    const Hold = struct {
        var started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const engine.Turn, _: engine.Params, stream: *engine.StreamBuf) ?[]const u8 {
            stream.appendBytes("⚙ bash\n");
            started.store(true, .release);
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            return gpa.dupe(u8, "all done") catch null;
        }
    };
    Hold.started.store(false, .release);
    Hold.release.store(false, .release);
    engine.g_turn_fn = Hold.f;
    defer {
        Hold.release.store(true, .release);
        engine.g_turn_fn = null;
    }

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "run it");
    startJob(&m);
    const job = m.pending orelse return error.NoJob;
    var spins: usize = 0;
    while (!Hold.started.load(.acquire)) : (spins += 1) {
        if (spins > 100_000) return error.TurnNeverPublishedStream;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!job.done.load(.acquire));
    const snap = job.stream.snapshot(std.testing.allocator) orelse return error.LiveTailEmpty;
    defer std.testing.allocator.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "⚙ bash") != null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    harvestLiveTools(&m);
    const harvested = try scrollback.render(&m, arena_state.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, harvested, "Called") != null);

    Hold.release.store(true, .release);
    spins = 0;
    while (!job.done.load(.acquire)) : (spins += 1) {
        if (spins > 100_000) return error.TurnNeverFinished;
        std.Thread.yield() catch {};
    }
    finishJob(&m);
    try std.testing.expectEqual(app.EntryKind.tool, m.history.items[m.history.items.len - 2].kind);
    try std.testing.expectEqual(app.EntryKind.assistant, m.history.items[m.history.items.len - 1].kind);
}

test "Ctrl+C during a turn cancels once then quits" {
    var m: @import("app.zig").Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .threaded = false,
        .gpa = std.testing.allocator,
        .history = try std.testing.allocator.alloc(engine.Turn, 0),
        .params = .{},
        .stream = .{},
    };
    m.pending = job;
    const keys = @import("keys.zig");
    try std.testing.expectEqual(@import("app.zig").Effect.stay, keys.handle(&m, .{ .ctrl = 'c' }));
    try std.testing.expect(m.cancel_requested);
    try std.testing.expect(m.pending != null);
    try std.testing.expectEqual(@import("app.zig").Effect.quit, keys.handle(&m, .{ .ctrl = 'c' }));
}

test "cancelTurn collapses thinking immediately" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{ .buf = &.{} },
        .threaded = false,
        .done = std.atomic.Value(bool).init(false),
    };
    try m.push(.pending, "");
    m.pending = job;
    cancelTurn(&m);
    try std.testing.expect(m.cancel_requested);
    try std.testing.expect(m.history.items.len == 1);
    try std.testing.expect(m.history.items[0].kind == .system);
    try std.testing.expectEqualStrings("■ interrupted", m.history.items[0].text);
    job.done.store(true, .release);
    finishJob(&m);
    try std.testing.expect(m.pending == null);
    var n: usize = 0;
    for (m.history.items) |e| {
        if (std.mem.eql(u8, e.text, "■ interrupted")) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}
