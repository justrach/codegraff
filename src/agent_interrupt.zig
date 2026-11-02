//! Esc-cancel handling: escWatchTask polls stdin from the pool while the
//! root awaits tool futures (postStream only watches stdin during a live
//! HTTP stream, so a long tool join used to be Esc-deaf); escPressed is
//! the non-blocking stdin scanner shared by both paths — it also captures
//! steering text typed ahead into main_mod.g_steer_buf/main_mod.g_steer_queue and toggles
//! the live Thinking-block fold on a mouse click. sleepInterruptible lets
//! a retry backoff be cancelled the same way. Split out of the Agent
//! struct (#123, 600-line goal).
//!
//! Agent.esc_cancel/Agent.esc_watch_done are struct-level `pub var`s that stay
//! declared directly inside the Agent struct in main.zig — aliasing a
//! `var` with `const x = mod.x;` would freeze a copy of its value instead
//! of sharing the live storage, silently breaking cross-file state
//! sharing. Reached here as `Agent.Agent.esc_cancel`/`Agent.Agent.esc_watch_done`.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const steer_input = @import("steer_input.zig");
const Agent = agent_mod.Agent;
const cancel_source = @import("cancel_source.zig"); // #728
const terminal = @import("term.zig");
const tty = terminal.tty;

const Stdin = struct {
    pub fn read(_: *Stdin, buf: []u8) usize {
        return tty.readStdin(buf);
    }

    pub fn poll(_: *Stdin, timeout_ms: i32) bool {
        return tty.poll(timeout_ms);
    }
};

pub fn escWatchTask() void {
    while (!Agent.esc_watch_done.load(.acquire)) {
        if (tty.poll(100) and escPressed(false)) {
            cancel_source.cancelFromStdin();
            return;
        }
    }
}

/// Non-blocking scan of stdin (terminal must be in VMIN=0 raw mode). A
/// lone Esc cancels the turn (returns true); CSI sequences (arrows:
/// ESC[…/ESC O…) are swallowed and don't cancel. Printable bytes are
/// captured into the steering buffer and echoed when `echo` (main thread
/// only — the esc watch task runs on the pool and must not race tool
/// output); Enter flushes the line to main_mod.g_steer_queue, which the REPL
/// drains as follow-up turns after the current one finishes. A second
/// Enter on an empty line (double-enter) with a non-empty queue
/// force-interrupts the current turn so the queue drains immediately.
pub fn escPressed(echo: bool) bool {
    var input: Stdin = .{};
    return escPressedFrom(&input, echo);
}

/// Testable scanner core. The stateful parser owns bracketed-paste framing;
/// the fake-input regressions exercise this same path as the live TTY.
pub fn escPressedFrom(input: anytype, echo: bool) bool {
    return steer_input.scan(input, echo);
}

/// Process any bytes queued on stdin (terminal must be in VMIN=0 raw
/// mode) so typed-ahead steering text is preserved instead of leaking into
/// the next prompt or being blindly discarded. Returns true if Esc/force
/// was seen while draining.
pub fn drainSteerStdin(echo: bool) bool {
    var esc_found = false;
    while (true) {
        if (!tty.poll(0)) return esc_found;
        if (escPressed(echo)) esc_found = true;
    }
}

pub fn drainStdin() void {
    _ = drainSteerStdin(false);
}

/// Put stdin into raw non-blocking no-echo mode (VMIN=0) for Esc
/// watching. Returns the termios to restore, or null off-tty.
pub fn rawNonblockStdin() ?tty.RawState {
    return tty.enterRaw(false);
}

/// Undo rawNonblockStdin. Lives here so the transport loop needs no terminal
/// import of its own (#422: engine files never import term.zig).
pub fn restoreStdin(orig: tty.RawState) void {
    tty.restore(orig);
}

/// Sleep `ms` watching both the engine cancel flag (ACP/JSON/hosted clients)
/// and stdin Esc when the root is on a TTY. Never wait out a cancelled backoff.
pub fn sleepInterruptible(self: *Agent, ms: u64) error{Interrupted}!void {
    if (Agent.esc_cancel.load(.acquire)) return error.Interrupted;
    const watch = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig_tio: ?tty.RawState = if (watch) rawNonblockStdin() else null;
    defer if (orig_tio) |o| tty.restore(o);
    var left = ms;
    while (left > 0) {
        const chunk = @min(left, 100);
        self.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch return error.Interrupted;
        left -= chunk;
        if (Agent.esc_cancel.load(.acquire) or (orig_tio != null and escPressed(true))) return error.Interrupted;
    }
}

/// The `data: {...}` payload of one SSE line, or null for anything else
/// (event: lines, keep-alive blanks, [DONE]).
pub fn ssePayload(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \r");
    if (!std.mem.startsWith(u8, line, "data:")) return null;
    const payload = std.mem.trim(u8, line["data:".len..], " ");
    if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) return null;
    return payload;
}

pub fn sseIndex(obj: std.json.ObjectMap) ?usize {
    const ix = obj.get("index") orelse return null;
    if (ix != .integer or ix.integer < 0) return null;
    return @intCast(ix.integer);
}

const BackoffSleepProbe = struct {
    calls: u64 = 0,
    total_ms: u64 = 0,
    max_ms: u64 = 0,
    cancel_at: u64 = 0,
    cancel_io: bool = false,

    fn sleep(ctx: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const ms: u64 = @intCast(timeout.duration.raw.toMilliseconds());
        std.debug.assert(timeout.duration.clock == .awake);
        self.calls += 1;
        self.total_ms += ms;
        self.max_ms = @max(self.max_ms, ms);
        if (self.cancel_io) return error.Canceled;
        if (self.calls == self.cancel_at) Agent.esc_cancel.store(true, .release);
    }
};

test "retry backoff preserves its full duration in bounded sleep chunks" {
    const previous = Agent.esc_cancel.swap(false, .acq_rel);
    defer Agent.esc_cancel.store(previous, .release);
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = BackoffSleepProbe.sleep;
    var agent: Agent = undefined;
    agent.in = null;
    agent.sub = false;
    for ([_]u64{ 0, 1, 99, 100, 101, 250, 65_535 }) |ms| {
        var probe: BackoffSleepProbe = .{};
        agent.io = .{ .userdata = &probe, .vtable = &vtable };
        try sleepInterruptible(&agent, ms);
        try std.testing.expectEqual(ms, probe.total_ms);
        try std.testing.expectEqual((ms + 99) / 100, probe.calls);
        try std.testing.expect(probe.max_ms <= 100);
    }
}

test "retry backoff stops when cancellation arrives during a sleep chunk" {
    const previous = Agent.esc_cancel.load(.acquire);
    defer Agent.esc_cancel.store(previous, .release);
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = BackoffSleepProbe.sleep;
    var agent: Agent = undefined;
    agent.in = null;
    for ([_]bool{ false, true }) |sub| {
        agent.sub = sub;
        for ([_]u64{ 1, 2 }) |cancel_at| {
            Agent.esc_cancel.store(false, .release);
            var probe: BackoffSleepProbe = .{ .cancel_at = cancel_at };
            agent.io = .{ .userdata = &probe, .vtable = &vtable };
            try std.testing.expectError(error.Interrupted, sleepInterruptible(&agent, 10_000));
            try std.testing.expectEqual(cancel_at, probe.calls);
            try std.testing.expectEqual(cancel_at * 100, probe.total_ms);
        }
    }
}

test "retry backoff propagates I/O cancellation without another sleep" {
    const previous = Agent.esc_cancel.swap(false, .acq_rel);
    defer Agent.esc_cancel.store(previous, .release);
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = BackoffSleepProbe.sleep;
    var agent: Agent = undefined;
    agent.in = null;
    agent.sub = false;
    var probe: BackoffSleepProbe = .{ .cancel_io = true };
    agent.io = .{ .userdata = &probe, .vtable = &vtable };
    try std.testing.expectError(error.Interrupted, sleepInterruptible(&agent, 10_000));
    try std.testing.expectEqual(@as(u64, 1), probe.calls);
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
}

test "retry backoff respects a pending non-TTY cancellation without sleeping" {
    const previous = Agent.esc_cancel.swap(true, .acq_rel);
    defer Agent.esc_cancel.store(previous, .release);
    var agent: Agent = undefined;
    agent.in = null;
    for ([_]bool{ false, true }) |sub| {
        agent.sub = sub;
        // io is deliberately undefined: even a long wait must return before
        // touching it, including for a child or a zero-duration backoff.
        try std.testing.expectError(error.Interrupted, sleepInterruptible(&agent, 60_000));
        try std.testing.expectError(error.Interrupted, sleepInterruptible(&agent, 0));
    }
}

test { // #728: cancel_source has no other path into the test root
    _ = cancel_source;
    _ = @import("agent_interrupt_repl_tests.zig");
    _ = @import("agent_interrupt_escape_edges_tests.zig");
}
