//! Background turn lifecycle — same thread+stream pattern as `graff repl`,
//! so a grok-style spinner can animate while the engine works.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const Model = app.Model;
const Effect = app.Effect;

/// What the session is currently asking the engine to do. Shared by a model
/// turn and by `!cmd` (bgop), because both run under the SAME policy — a /plan
/// that only reached one of them is the #551 bug in miniature.
pub fn paramsOf(self: *const Model) engine.Params {
    return .{
        .effort = self.effort,
        .fast = self.fast,
        .thinking = self.thinking_show,
        .ultracode = self.ultracode or self.effort == .ultra,
        .mode = self.mode,
        .strict = self.strict,
        .goal = self.goal orelse "",
    };
}

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
        // Policy travels WITH the turn (#551): the engine applies the plan gate
        // and the strict prompt from these, so the footer and the run can no
        // longer disagree.
        .params = paramsOf(self),
        .stream = .{ .buf = self.alloc.alloc(u8, 256 * 1024) catch &.{} },
        .raw = .{ .buf = self.alloc.alloc(u8, 64 * 1024) catch &.{} },
    };
    engine.g_raw = &job.raw;
    // The queue must own its copies before the turn thread can push: the
    // engine's payloads live in a per-turn arena that dies with the turn.
    job.events.attach(self.alloc);
    self.push(.pending, "") catch {};
    self.pending = job;
    if (std.Thread.spawn(.{}, engine.jobRun, .{job})) |th| {
        job.thread = th;
    } else |_| {
        job.threaded = false;
        engine.jobRun(job);
    }
}

/// grok-build notify: a finished background job starts a turn while idle.
pub fn maybeJobWake(self: *Model) void {
    if (self.pending != null or self.bg != null) return;
    const f = engine.g_idle_wake_fn orelse return;
    var buf: [512]u8 = undefined;
    const text = f(engine.g_turn_ctx, &buf) orelse return;
    self.push(.user, text) catch return;
    startJob(self);
}

pub fn finishJob(self: *Model) void {
    const job = self.pending orelse return;
    if (!job.done.load(.acquire)) return;
    if (job.threaded) job.thread.join();

    // Whatever the engine emitted after the last frame — the tail of the tool
    // run, a closing notice — before the answer row goes in, so the transcript
    // keeps its order.
    drainEvents(self);
    _ = removePendingRows(self);
    if (job.result) |r| {
        self.push(.assistant, r) catch {};
        self.alloc.free(r);
    } else if (self.cancel_requested) {
        if (!hasInterrupted(self)) self.push(.system, "■ interrupted") catch {};
    } else {
        self.push(.err, "model call failed — check /model and your API key") catch {};
    }
    for (job.history) |t| self.alloc.free(t.text);
    self.alloc.free(job.history);
    if (engine.g_raw == &job.raw) engine.g_raw = null;
    if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
    if (job.raw.buf.len > 0) self.alloc.free(job.raw.buf);
    job.events.deinit();
    self.alloc.destroy(job);
    self.pending = null;
    self.cancel_requested = false;
    self.scroll = 0;
    self.follow = true;
}

/// How long quit waits for a cancelled turn to unwind. The cancel normally
/// lands between two SSE chunks (~50-250 ms), so this only bites on a socket
/// that has stopped delivering bytes entirely.
pub const quit_drain_ms: u64 = 3000;

pub const QuitStep = enum { wait, reap, abandon };

/// One step of the quit-time settle. The TUI must never join a live turn
/// thread from Model.deinit: deinit runs AFTER the terminal defers have left
/// the alt screen and restored termios, so that join made graff look exited
/// while it silently held the tty for the rest of a stalled call (#534).
pub fn quitStep(self: *Model, elapsed_ms: u64) QuitStep {
    const job = self.pending orelse return .reap;
    if (!job.threaded or job.done.load(.acquire)) return .reap;
    return if (elapsed_ms >= quit_drain_ms) .abandon else .wait;
}

/// Give up on a turn thread that ignored the cancel. The job, its history and
/// its stream buffer are deliberately LEAKED: the detached thread still writes
/// job.result and job.done into them, so freeing here would hand it a
/// dangling pointer. The caller exits the process immediately after.
pub fn abandonJob(self: *Model) void {
    self.pending = null;
    self.cancel_requested = false;
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
    self.freeEntry(self.history.items[n - 1]);
    const text = self.alloc.dupe(u8, "■ interrupted") catch {
        self.history.shrinkRetainingCapacity(n - 1);
        return;
    };
    self.history.items[n - 1] = .{ .kind = .system, .text = text, .folded = false };
}

/// Did this turn already say it was interrupted? Scans back to the prompt
/// rather than looking only at the last row: a cancel collapses the pending
/// row immediately, and events that were already in flight land AFTER it, so
/// "is it the last row" would have written a second notice (#551).
fn hasInterrupted(self: *const Model) bool {
    var i = self.history.items.len;
    while (i > 0) {
        i -= 1;
        const e = self.history.items[i];
        if (e.kind == .user) return false;
        if (std.mem.eql(u8, e.text, "■ interrupted")) return true;
    }
    return false;
}

/// Apply everything the engine has emitted for the live turn. Called from the
/// render loop's poll point every frame, so tool rows, notices and failovers
/// appear *during* the turn and not only at finishJob.
///
/// This replaced the old harvestLiveTools, which reconstructed tool activity by
/// matching "⚙ /✓ /✗ /⊘ " prefixes in the sink's rendered bytes — an assistant
/// answer whose line began "✓ " became a phantom tool row, and every re-scan
/// re-counted the rows it had already made (#551).
pub fn drainEvents(self: *Model) void {
    const job = self.pending orelse return;
    const evs = job.events.drain();
    defer job.events.free(evs);
    if (evs.len == 0) return;
    // Events land BEFORE the live "Thinking" row, which is a presentation
    // artifact rather than transcript content.
    const had_pending = removePendingRows(self);
    for (evs) |ev| applyEvent(self, ev);
    if (had_pending) self.push(.pending, "") catch {};
}

fn applyEvent(self: *Model, ev: engine.Event) void {
    switch (ev) {
        .tool_started => |t| {
            if (std.mem.startsWith(u8, t.name, "internal_")) return;
            self.pushTool(.{ .name = t.name, .summary = t.detail, .detail = t.detail }) catch {};
        },
        .tool_finished => |t| {
            if (std.mem.startsWith(u8, t.name, "internal_")) return;
            self.pushTool(.{
                .name = t.name,
                .summary = t.detail,
                .detail = t.detail,
                .done = true,
                .is_error = t.is_error,
                .ms = t.ms,
            }) catch {};
        },
        .tool_rejected => |t| {
            if (std.mem.startsWith(u8, t.name, "internal_")) return;
            self.pushTool(.{
                .name = t.name,
                .summary = t.detail,
                .detail = t.detail,
                .done = true,
                .is_error = true,
                .denied = true,
            }) catch {};
        },
        .notice => |s| self.push(.system, s) catch {},
        .status => |st| self.setStatus(st),
        .model_changed => |s| if (self.alloc.dupe(u8, s)) |owned| {
            if (self.model_override) |old| self.alloc.free(old);
            self.model_override = owned;
            engine.g_model_name = owned;
            self.pushFmt(.system, "model → {s}", .{owned}) catch {};
        } else |_| {},
    }
}

/// Remove every .pending row wherever it sits. Steering pushes "↳ queued"
/// rows after the pending entry, so "pending is last" is not an invariant —
/// assuming it stranded a permanent thinking row in the transcript (#520).
pub fn removePendingRows(self: *Model) bool {
    var had = false;
    var i: usize = self.history.items.len;
    while (i > 0) {
        i -= 1;
        if (self.history.items[i].kind == .pending) {
            self.freeEntry(self.history.items[i]);
            _ = self.history.orderedRemove(i);
            had = true;
        }
    }
    return had;
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

test "finishJob turns queued events into field-backed tool rows" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    // Prose and structure arrive on SEPARATE channels now: the answer text
    // that happens to contain a "✓ " line is only ever an answer.
    const live = "hello\n✓ all good\nmore text";
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
    job.events.attach(std.testing.allocator);
    job.events.push(.{ .tool_started = .{ .name = "bash", .detail = "ls -la" } });
    job.events.push(.{ .tool_finished = .{ .name = "bash", .detail = "4 files" } });
    job.done.store(true, .release);
    try m.push(.pending, "");
    m.pending = job;
    finishJob(&m);
    try std.testing.expect(m.pending == null);
    try std.testing.expectEqual(@as(usize, 3), m.history.items.len);
    try std.testing.expectEqual(app.EntryKind.tool, m.history.items[0].kind);
    // The row carries FIELDS, not a rendered line to be taken apart again.
    const call = m.history.items[0].tool orelse return error.NotFieldBacked;
    try std.testing.expectEqualStrings("bash", call.name);
    try std.testing.expectEqualStrings("ls -la", call.detail);
    try std.testing.expect(!call.done);
    const outcome = m.history.items[1].tool orelse return error.NotFieldBacked;
    try std.testing.expectEqualStrings("4 files", outcome.detail);
    try std.testing.expect(outcome.done);
    try std.testing.expect(!outcome.is_error);
    try std.testing.expectEqual(app.EntryKind.assistant, m.history.items[2].kind);
    try std.testing.expectEqualStrings("all done", m.history.items[2].text);
}

test "a streamed line starting with a status glyph never becomes a tool row (#551)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    // Exactly the shape that produced phantom rows: the model's own answer,
    // formatted as a checklist, streaming through the live buffer.
    const live = "✓ tests pass\n✗ lint fails\n⚙ retrying\n";
    const buf = try std.testing.allocator.dupe(u8, live);
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{ .buf = buf },
        .threaded = false,
        .result = try std.testing.allocator.dupe(u8, "✓ tests pass\n✗ lint fails\n⚙ retrying"),
    };
    job.stream.len.store(live.len, .release);
    job.events.attach(std.testing.allocator);
    job.done.store(true, .release);
    try m.push(.pending, "");
    m.pending = job;
    finishJob(&m);
    var tools: usize = 0;
    for (m.history.items) |e| {
        if (e.kind == .tool) tools += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), tools);
    try std.testing.expectEqual(app.EntryKind.assistant, m.history.items[m.history.items.len - 1].kind);
    // And the answer is stored ONCE — the old harvest left a copy behind as
    // tool rows and then pushed the same text again as the answer.
    var copies: usize = 0;
    for (m.history.items) |e| {
        if (std.mem.indexOf(u8, e.text, "tests pass") != null) copies += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), copies);
}

test "a refusal and a failover reach the transcript instead of vanishing" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{},
        .threaded = false,
        .result = try std.testing.allocator.dupe(u8, "ok"),
    };
    job.events.attach(std.testing.allocator);
    job.events.push(.{ .tool_rejected = .{
        .name = "write_file",
        .detail = "plan mode forbids writes",
        .is_error = true,
        .denied = true,
    } });
    job.events.push(.{ .notice = "loaded 2 saved approval(s)" });
    job.events.push(.{ .model_changed = "sonnet" });
    job.done.store(true, .release);
    try m.push(.pending, "");
    m.pending = job;
    finishJob(&m);
    const refused = m.history.items[0].tool orelse return error.NotFieldBacked;
    try std.testing.expect(refused.denied);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(refused.done);
    try std.testing.expectEqual(app.EntryKind.system, m.history.items[1].kind);
    try std.testing.expectEqualStrings("loaded 2 saved approval(s)", m.history.items[1].text);
    // The failover updates what the status bar reads, not just the transcript.
    try std.testing.expectEqualStrings("sonnet", engine.g_model_name);
    try std.testing.expect(std.mem.indexOf(u8, m.history.items[2].text, "sonnet") != null);
}

test "a live tool row is visible mid-turn, straight off the event queue" {
    const scrollback = @import("scrollback.zig");
    const Hold = struct {
        var started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const engine.Turn, _: engine.Params, stream: *engine.StreamBuf, events: *engine.EventQueue) ?[]const u8 {
            // The turn thread pushes structure and streams prose, exactly as
            // the real sink does.
            events.push(.{ .tool_started = .{ .name = "bash", .detail = "ls" } });
            stream.appendBytes("working…\n");
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
    // Prose only in the live buffer — the tool row is on the other channel.
    try std.testing.expect(std.mem.indexOf(u8, snap, "working") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "bash") == null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    drainEvents(&m);
    const harvested = try scrollback.render(&m, arena_state.allocator(), 80, 0);
    // Mid-turn: the call is announced and has not come back, so the header
    // reads present-progressive.
    try std.testing.expect(std.mem.indexOf(u8, harvested, "Running bash\u{2026}") != null);

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
    // Events already in flight when the cancel landed still arrive, and they
    // land after the notice — which must not make finishJob write a second one.
    job.events.attach(std.testing.allocator);
    job.events.push(.{ .tool_finished = .{ .name = "bash", .detail = "cancelled", .is_error = true } });
    job.done.store(true, .release);
    finishJob(&m);
    try std.testing.expect(m.pending == null);
    var n: usize = 0;
    for (m.history.items) |e| {
        if (std.mem.eql(u8, e.text, "■ interrupted")) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "quit waits for a live turn, then abandons it instead of joining forever (#534)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const job = try std.testing.allocator.create(engine.Job);
    defer std.testing.allocator.destroy(job); // the real path leaks it on purpose
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{},
        .threaded = true, // pretend a thread is still in the provider call
    };
    m.pending = job;
    // Inside the drain window the quit path keeps painting instead of joining.
    try std.testing.expectEqual(QuitStep.wait, quitStep(&m, 0));
    try std.testing.expectEqual(QuitStep.wait, quitStep(&m, quit_drain_ms - 1));
    // Past it the job is given up on, never joined.
    try std.testing.expectEqual(QuitStep.abandon, quitStep(&m, quit_drain_ms));
    abandonJob(&m);
    try std.testing.expect(m.pending == null);
    // A turn that DID unwind is reaped normally, however long quit waited.
    m.pending = job;
    job.done.store(true, .release);
    try std.testing.expectEqual(QuitStep.reap, quitStep(&m, quit_drain_ms * 10));
    m.pending = null;
}

test "Model.deinit never joins a running turn thread (#534)" {
    const Hold = struct {
        var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const engine.Turn, _: engine.Params, _: *engine.StreamBuf, _: *engine.EventQueue) ?[]const u8 {
            started.store(true, .release);
            while (!release.load(.acquire)) std.Thread.yield() catch {};
            return gpa.dupe(u8, "late") catch null;
        }
    };
    Hold.release.store(false, .release);
    Hold.started.store(false, .release);
    engine.g_turn_fn = Hold.f;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    try m.push(.user, "hi");
    startJob(&m);
    const job = m.pending orelse return error.NoJob;
    var spins: usize = 0;
    while (!Hold.started.load(.acquire)) : (spins += 1) {
        if (spins > 1_000_000) return error.TurnNeverStarted;
        std.Thread.yield() catch {};
    }
    // deinit must return while the turn thread is still inside the call.
    m.deinit();
    try std.testing.expect(!job.done.load(.acquire));
    // Now let the thread finish and clean up what deinit deliberately left.
    Hold.release.store(true, .release);
    job.thread.join();
    engine.g_turn_fn = null;
    if (job.result) |r| std.testing.allocator.free(r);
    for (job.history) |t| std.testing.allocator.free(t.text);
    std.testing.allocator.free(job.history);
    if (job.stream.buf.len > 0) std.testing.allocator.free(job.stream.buf);
    if (job.raw.buf.len > 0) std.testing.allocator.free(job.raw.buf);
    std.testing.allocator.destroy(job);
}

test "finishJob strips a pending row buried under steer echoes (#520)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.push(.pending, "");
    try m.push(.system, "↳ queued (1 waiting)");
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{
        .threaded = false,
        .gpa = std.testing.allocator,
        .history = try std.testing.allocator.alloc(engine.Turn, 0),
        .params = .{},
        .stream = .{},
    };
    job.done.store(true, .release);
    m.pending = job;
    finishJob(&m);
    try std.testing.expect(m.pending == null);
    for (m.history.items) |e| try std.testing.expect(e.kind != .pending);
}
