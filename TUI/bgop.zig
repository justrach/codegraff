//! Background engine ops. `/compact`, `!cmd` and the @-file list used to call
//! straight into the engine from keys.handle, i.e. from inside run.zig's byte
//! parse loop: no render, no poll, no key handling, no cancel for the whole
//! round trip — a 5-60 s freeze indistinguishable from a hang (#533).
//!
//! They now take the same route a model turn takes (turn.zig): one thread, one
//! done flag, polled from the top of the loop. Nothing here reimplements
//! engine behavior — each op is exactly one engine callback, moved off the
//! render+input thread, with the result applied on the main thread.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const turn = @import("turn.zig");
const Model = app.Model;
const Op = engine.BgOp;

/// Spawn `kind` in the background, taking ownership of `turns` and `cmd`.
/// A non-empty `label` pushes a live row so the wait is visible. Returns false
/// when a turn or another op already holds the engine — the caller still owns
/// its inputs then.
pub fn start(self: *Model, kind: Op.Kind, turns: []engine.Turn, cmd: []const u8, label: []const u8) bool {
    if (self.bg != null or self.pending != null) return false;
    const op = self.alloc.create(Op) catch return false;
    // The op carries the same policy a turn does: `!cmd` goes through the
    // engine's gate now, and /plan has to reach it (#551).
    op.* = .{ .kind = kind, .gpa = self.alloc, .turns = turns, .cmd = cmd, .params = turn.paramsOf(self) };
    if (label.len > 0) self.push(.pending, label) catch {};
    self.bg = op;
    if (std.Thread.spawn(.{}, engine.bgRun, .{op})) |th| {
        op.thread = th;
    } else |_| {
        // No thread available: run it inline rather than dropping the command.
        op.threaded = false;
        engine.bgRun(op);
    }
    return true;
}

/// Esc / Ctrl+C during an op. The engine-side cancel is the same one a turn
/// uses: process_runner kills a running `!cmd` child within 200 ms, and the
/// compaction request's stall watchdogs abort between polls.
pub fn cancel(self: *Model) void {
    const op = self.bg orelse return;
    if (op.cancelled) return;
    op.cancelled = true;
    if (engine.g_cancel_fn) |f| f(engine.g_turn_ctx);
}

/// Apply a finished op on the main thread. No-op while it is still running.
pub fn finish(self: *Model) void {
    const op = self.bg orelse return;
    if (!op.done.load(.acquire)) return;
    if (op.threaded) op.thread.join();
    op.threaded = false; // release() must not join a second time
    _ = turn.removePendingRows(self);
    switch (op.kind) {
        .compact => applyCompact(self, op),
        .bash => applyBash(self, op),
        .files => applyFiles(self, op),
    }
    release(self, op);
    self.scroll = 0;
    self.follow = true;
}

/// Free a finished op without applying it — Model.deinit's path.
pub fn reap(self: *Model) void {
    const op = self.bg orelse return;
    release(self, op);
}

/// Give up on an op whose thread ignored the cancel. Everything it owns is
/// leaked on purpose: the detached worker still writes into it. Callers exit
/// the process straight after (same contract as turn.abandonJob).
pub fn abandon(self: *Model) void {
    self.bg = null;
}

/// One step of the quit-time settle, mirroring turn.quitStep so run.zig can
/// wait for a turn and an op with a single deadline.
pub fn quitStep(self: *Model, elapsed_ms: u64) turn.QuitStep {
    const op = self.bg orelse return .reap;
    if (!op.threaded or op.done.load(.acquire)) return .reap;
    return if (elapsed_ms >= turn.quit_drain_ms) .abandon else .wait;
}

/// True while the @-file list is still loading, so the picker can say so
/// instead of claiming there is no file list.
pub fn loadingFiles(self: *const Model) bool {
    const op = self.bg orelse return false;
    return op.kind == .files;
}

fn release(self: *Model, op: *Op) void {
    if (op.threaded) op.thread.join();
    for (op.turns) |t| self.alloc.free(t.text);
    if (op.turns.len > 0) self.alloc.free(op.turns);
    if (op.cmd.len > 0) self.alloc.free(op.cmd);
    if (op.compact.note.len > 0) self.alloc.free(op.compact.note);
    for (op.compact.turns) |t| self.alloc.free(t.text);
    if (op.compact.turns.len > 0) self.alloc.free(op.compact.turns);
    if (op.text) |t| self.alloc.free(t);
    self.alloc.destroy(op);
    self.bg = null;
}

fn applyCompact(self: *Model, op: *Op) void {
    if (!op.ok) {
        const why: []const u8 = if (op.cancelled)
            "compaction cancelled, history unchanged"
        else if (op.compact.note.len > 0)
            op.compact.note
        else
            "compaction failed, history unchanged";
        self.push(.system, why) catch {};
        return;
    }
    self.clearHistory();
    if (op.compact.note.len > 0) self.push(.system, op.compact.note) catch {};
    for (op.compact.turns) |t| {
        self.push(switch (t.role) {
            .user => .user,
            .assistant => .assistant,
        }, t.text) catch {};
    }
}

fn applyBash(self: *Model, op: *Op) void {
    if (op.text) |out| {
        self.push(.system, @import("dispatch.zig").lastLines(out, 40)) catch {};
    } else if (op.cancelled) {
        self.push(.system, "■ interrupted") catch {};
    } else {
        self.push(.err, "command failed to start") catch {};
    }
}

fn applyFiles(self: *Model, op: *Op) void {
    if (self.files_cache != null) return;
    const t = op.text orelse return;
    self.files_cache = self.alloc.dupe(u8, t) catch null;
}

const testing = std.testing;

fn drain(m: *Model) !void {
    var spins: usize = 0;
    while (m.bg) |op| {
        if (op.done.load(.acquire)) break;
        spins += 1;
        if (spins > 1_000_000) return error.OpNeverFinished;
        std.Thread.yield() catch {};
    }
    finish(m);
}

test "a bash op runs off the render thread and its output lands in the scrollback (#533)" {
    engine.g_bash_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8, _: engine.Params) ?[]const u8 {
            return std.fmt.allocPrint(gpa, "ran: {s}", .{cmd}) catch null;
        }
    }.f;
    defer engine.g_bash_fn = null;
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    const cmd = try testing.allocator.dupe(u8, "git status");
    try testing.expect(start(&m, .bash, &.{}, cmd, "running"));
    // The op is in flight: the model is usable and a live row is showing.
    try testing.expect(m.bg != null);
    try testing.expectEqual(app.EntryKind.pending, m.history.items[0].kind);
    try drain(&m);
    try testing.expect(m.bg == null);
    for (m.history.items) |e| try testing.expect(e.kind != .pending);
    try testing.expectEqualStrings("ran: git status", m.history.items[m.history.items.len - 1].text);
}

test "a compact op replaces the history only when the engine says it worked (#533)" {
    engine.g_compact_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, history: []const engine.Turn, out: *engine.CompactOut) bool {
            if (history.len == 0) return false;
            var turns = gpa.alloc(engine.Turn, 1) catch return false;
            turns[0] = .{ .role = .user, .text = gpa.dupe(u8, "summary") catch return false };
            out.turns = turns;
            out.note = gpa.dupe(u8, "history compacted") catch "";
            return true;
        }
    }.f;
    defer engine.g_compact_fn = null;
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try m.push(.user, "one");
    try m.push(.assistant, "two");
    const turns = try testing.allocator.alloc(engine.Turn, 1);
    turns[0] = .{ .role = .user, .text = try testing.allocator.dupe(u8, "one") };
    try testing.expect(start(&m, .compact, turns, "", "compacting"));
    try drain(&m);
    try testing.expect(m.bg == null);
    try testing.expectEqualStrings("history compacted", m.history.items[0].text);
    try testing.expectEqualStrings("summary", m.history.items[1].text);
    try testing.expectEqual(@as(usize, 2), m.history.items.len);
}

test "a second op is refused while one is in flight, and Esc cancels the live one" {
    const Gate = struct {
        var go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var saw_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn bash(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, _: engine.Params) ?[]const u8 {
            entered.store(true, .release);
            while (!go.load(.acquire)) std.Thread.yield() catch {};
            return gpa.dupe(u8, "done") catch null;
        }
        fn cancelled(_: ?*anyopaque) void {
            saw_cancel.store(true, .release);
            go.store(true, .release);
        }
    };
    Gate.go.store(false, .release);
    Gate.entered.store(false, .release);
    Gate.saw_cancel.store(false, .release);
    engine.g_bash_fn = Gate.bash;
    engine.g_cancel_fn = Gate.cancelled;
    defer {
        Gate.go.store(true, .release);
        engine.g_bash_fn = null;
        engine.g_cancel_fn = null;
    }
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    const cmd = try testing.allocator.dupe(u8, "sleep 30");
    try testing.expect(start(&m, .bash, &.{}, cmd, "running"));
    var spins: usize = 0;
    while (!Gate.entered.load(.acquire)) : (spins += 1) {
        if (spins > 1_000_000) return error.OpNeverStarted;
        std.Thread.yield() catch {};
    }
    // The engine is busy: a second op must not stack on top of it.
    try testing.expect(!start(&m, .bash, &.{}, "", "running"));
    // Esc reaches the engine — which is the whole point of the thread.
    cancel(&m);
    try testing.expect(Gate.saw_cancel.load(.acquire));
    try drain(&m);
    try testing.expect(m.bg == null);
}

test "quit gives a stuck op a bounded wait, then abandons it (#533/#534)" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    const op = try testing.allocator.create(Op);
    defer testing.allocator.destroy(op); // the real path leaks it on purpose
    op.* = .{ .kind = .bash, .gpa = testing.allocator, .threaded = true };
    m.bg = op;
    try testing.expectEqual(turn.QuitStep.wait, quitStep(&m, 0));
    try testing.expectEqual(turn.QuitStep.abandon, quitStep(&m, turn.quit_drain_ms));
    op.done.store(true, .release);
    try testing.expectEqual(turn.QuitStep.reap, quitStep(&m, turn.quit_drain_ms));
    abandon(&m);
    try testing.expect(m.bg == null);
}
