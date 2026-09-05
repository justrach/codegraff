//! grok-build TaskCompleted / system-reminder for background bash (ADR 0010
//! follow-up). A finished job queues one notice. `deliver` injects a wake at
//! the next root step boundary; `takeWake` is the idle TUI auto-turn.

const std = @import("std");
const Io = std.Io;

const agent_mod = @import("agent.zig");
const engine_sink = @import("engine_sink.zig");
const tool_pulse = @import("tool_pulse.zig");
const Agent = agent_mod.Agent;

pub const Notice = struct {
    id: u32,
    exit_code: ?u8 = null,
    killed: bool = false,
    idle: bool = false, // the idle policy stopped it (#199): no auto-turn wake
    preview: [48]u8 = undefined,
    preview_len: u8 = 0,
};

const cap: usize = 16;
var mu: Io.Mutex = .init;
var ring: [cap]Notice = undefined;
var count: usize = 0;
/// Legacy bounded dismiss-before-record credits (ADR 0061). The production
/// pump no longer relies on these: done + queue and consumption share the
/// jobs mutex, so eviction cannot resurrect a consumed completion (#728).
var dismissed: [cap]u32 = undefined;
var dismissed_len: usize = 0;

fn clipCmd(cmd: []const u8) struct { buf: [48]u8, len: u8 } {
    const t = std.mem.trim(u8, cmd, " \t\r\n");
    const keep: u8 = @intCast(@min(t.len, 48));
    var buf: [48]u8 = @splat(0);
    @memcpy(buf[0..keep], t[0..keep]);
    return .{ .buf = buf, .len = keep };
}

/// One human/model line for a finished job.
pub fn line(buf: []u8, n: Notice) []const u8 {
    const cmd = n.preview[0..n.preview_len];
    if (n.idle) {
        return std.fmt.bufPrint(buf, "[job {d} stopped idle: {s}]", .{ n.id, cmd }) catch buf[0..0];
    }
    if (n.killed) {
        return std.fmt.bufPrint(buf, "[job {d} killed: {s}]", .{ n.id, cmd }) catch buf[0..0];
    }
    if (n.exit_code) |c| {
        return std.fmt.bufPrint(buf, "[job {d} exited {d}: {s}]", .{ n.id, c, cmd }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "[job {d} ended: {s}]", .{ n.id, cmd }) catch buf[0..0];
}

fn wakeLine(buf: []u8, n: Notice) []const u8 {
    var head: [96]u8 = undefined;
    const h = line(&head, n);
    if (n.idle) return std.fmt.bufPrint(buf, "{s} — silent and unread past the idle stop; rerun it only if it is still needed.", .{h}) catch h;
    return std.fmt.bufPrint(buf, "{s} — unread output via bash_output; do not poll.", .{h}) catch h;
}

/// Standalone notification convenience (tests). The job pump MUST split
/// queue (under jobs mutex) from publish (outside it); calling this after
/// exposing done reintroduces #728. Publication is UI, not a model wake.
pub fn record(io: Io, id: u32, exit_code: ?u8, killed: bool, cmd: []const u8, idle: bool) void {
    queue(io, id, exit_code, killed, cmd, idle);
    publish(io, id, exit_code, killed);
}

/// Queue while holding the jobs mutex, in the same critical section as done.
/// Consumers hold jobs -> notification mutex in that same order. Never call
/// a frontend here: it may re-enter jobOutput.
pub fn queue(io: Io, id: u32, exit_code: ?u8, killed: bool, cmd: []const u8, idle: bool) void {
    const clipped = clipCmd(cmd);
    const n = Notice{ .id = id, .exit_code = exit_code, .killed = killed, .idle = idle, .preview = clipped.buf, .preview_len = clipped.len };
    mu.lockUncancelable(io);
    if (dismissedIndex(id)) |i| {
        std.mem.copyForwards(u32, dismissed[i .. dismissed_len - 1], dismissed[i + 1 .. dismissed_len]);
        dismissed_len -= 1;
    } else {
        if (count == cap) {
            std.mem.copyForwards(Notice, ring[0 .. cap - 1], ring[1..cap]);
            count = cap - 1;
        }
        ring[count] = n;
        count += 1;
    }
    mu.unlock(io);
}

/// Frontend-only publication AFTER releasing the jobs mutex. No wake is queued.
pub fn publish(io: Io, id: u32, exit_code: ?u8, killed: bool) void {
    if (engine_sink.hostedSink()) |sink| {
        sink.emit(io, .{ .job_completed = .{ .id = id, .exit_code = exit_code, .killed = killed } });
    }
}

/// Caller holds `mu`.
fn dismissedIndex(id: u32) ?usize {
    for (dismissed[0..dismissed_len], 0..) |d, i| if (d == id) return i;
    return null;
}

/// bash_output just handed the model this job's exit status and remaining
/// output (or bash_kill told it the job is dead), so the wake would only
/// repeat what it has read — and on an idle TUI that wake is a whole model
/// turn, which the model then spends on a `bash_output` snapshot that says
/// "(no new output)". Drop the queued notice; if the pump has not queued it
/// yet, remember the id so `record` skips it. ADR 0061.
pub fn dismiss(io: Io, id: u32) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    var i: usize = 0;
    var found = false;
    while (i < count) {
        if (ring[i].id != id) {
            i += 1;
            continue;
        }
        std.mem.copyForwards(Notice, ring[i .. count - 1], ring[i + 1 .. count]);
        count -= 1;
        found = true;
    }
    if (found or dismissedIndex(id) != null) return;
    if (dismissed_len == cap) {
        std.mem.copyForwards(u32, dismissed[0 .. cap - 1], dismissed[1..cap]);
        dismissed_len = cap - 1;
    }
    dismissed[dismissed_len] = id;
    dismissed_len += 1;
}

/// The tool result for a bash_output wait that ended before the job did.
/// An Esc used to be rendered by setting the elapsed counter to the 10-hour
/// deadline, so the model read "36000s elapsed" for a 36-second wait.
pub fn printRunning(w: *Io.Writer, id: u32, waited_ms: u64, interrupted: bool) !void {
    var ebuf: [16]u8 = undefined;
    const el = tool_pulse.formatElapsed(&ebuf, waited_ms);
    if (interrupted) {
        try w.print("[job {d}: running · {s} waited, then interrupted — you are notified on exit; do not call bash_output again]", .{ id, el });
    } else {
        try w.print("[job {d}: running · {s} elapsed — you are notified on exit; do not call bash_output again]", .{ id, el });
    }
}

/// One dim chrome line per tool_pulse threshold while a blocking bash_output
/// wait runs long (#607). ADR 0010 keeps the wait single-hop; this only tells
/// the human it is alive. Presentation pulse: --json drops it, and a session
/// with no bound sink (subagents) stays quiet.
pub fn stillRunning(io: Io, id: u32, waited_ms: u64) void {
    var ebuf: [16]u8 = undefined;
    tool_pulse.emitNotice(io, "· bash_output · job {d} still running · {s}", .{ id, tool_pulse.formatElapsed(&ebuf, waited_ms) });
}

/// Drain queued notices into `buf` (step boundary: everything). Null when
/// nothing finished.
pub fn takeWake(io: Io, buf: []u8) ?[]const u8 {
    return drain(io, buf, true);
}

/// The idle-TUI auto-turn: an exit or a kill wakes the model; an idle stop
/// does not — nobody was there for the whole idle budget, and a wake would
/// spend a turn telling nobody (ADR 0061). It waits in the ring for the next
/// real step boundary, where `deliver` hands it over.
pub fn takeIdleWake(io: Io, buf: []u8) ?[]const u8 {
    return drain(io, buf, false);
}

fn drain(io: Io, buf: []u8, idle_too: bool) ?[]const u8 {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (count == 0) return null;
    var used: usize = 0;
    var keep: usize = 0; // notices left in the ring, compacted in order
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!idle_too and ring[i].idle) {
            ring[keep] = ring[i];
            keep += 1;
            continue;
        }
        var one: [200]u8 = undefined;
        const w = wakeLine(&one, ring[i]);
        if (used > 0) {
            if (used + 1 >= buf.len) break;
            buf[used] = '\n';
            used += 1;
        }
        const n = @min(w.len, buf.len - used);
        @memcpy(buf[used .. used + n], w[0..n]);
        used += n;
    }
    while (i < count) : (i += 1) { // what did not fit stays for next time
        ring[keep] = ring[i];
        keep += 1;
    }
    count = keep;
    if (used == 0) return null;
    return buf[0..used];
}

/// Root step-boundary inject (same moment as peer deliverInbound).
pub fn deliver(root: *Agent) void {
    if (root.sub) return;
    var buf: [512]u8 = undefined;
    const text = takeWake(root.io, &buf) orelse return;
    const owned = root.arena.dupe(u8, text) catch return;
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = owned }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
    engine_sink.forAgent(root).emit(root.io, .{ .session_notice = .{ .text = owned, .tone = .dim } });
}

test "line names exit, kill, and abnormal end" {
    const clipped = clipCmd("sleep 5");
    var n = Notice{ .id = 3, .exit_code = 0, .preview = clipped.buf, .preview_len = clipped.len };
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("[job 3 exited 0: sleep 5]", line(&buf, n));
    n.killed = true;
    try std.testing.expectEqualStrings("[job 3 killed: sleep 5]", line(&buf, n));
    n.killed = false;
    n.exit_code = null;
    try std.testing.expectEqualStrings("[job 3 ended: sleep 5]", line(&buf, n));
}

test "dismiss drops a queued notice, or the one the pump has not queued yet (ADR 0061)" {
    const io = std.testing.io;
    count = 0;
    dismissed_len = 0;
    var buf: [256]u8 = undefined;
    // Queued, then read through bash_output: no wake.
    record(io, 7, 0, false, "sleep 1", false);
    dismiss(io, 7);
    try std.testing.expect(takeWake(io, &buf) == null);
    // Read through bash_output BEFORE the pump queued it: still no wake, and
    // the remembered id is spent by that one record.
    dismiss(io, 8);
    dismiss(io, 8); // a second read of the same finished job is not a second credit
    record(io, 8, 1, false, "false", false);
    try std.testing.expect(takeWake(io, &buf) == null);
    try std.testing.expectEqual(@as(usize, 0), dismissed_len);
    record(io, 8, 1, false, "false", false);
    try std.testing.expect(std.mem.indexOf(u8, takeWake(io, &buf) orelse "", "[job 8 exited 1: false]") != null);
    // Only the dismissed id is dropped; a neighbour in the ring survives.
    record(io, 9, 0, false, "a", false);
    record(io, 10, 0, false, "b", false);
    record(io, 11, 0, false, "c", false);
    dismiss(io, 10);
    const text = takeWake(io, &buf) orelse return error.Empty;
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 9 exited 0: a]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "job 10") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 11 exited 0: c]") != null);
}

test "printRunning reports the wait that happened, not the deadline (ADR 0061)" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printRunning(&aw.writer, 181, 36_000, true);
    try std.testing.expectEqualStrings("[job 181: running · 36s waited, then interrupted — you are notified on exit; do not call bash_output again]", aw.written());
    aw.clearRetainingCapacity();
    try printRunning(&aw.writer, 5, 125_000, false);
    try std.testing.expectEqualStrings("[job 5: running · 2m05s elapsed — you are notified on exit; do not call bash_output again]", aw.written());
}

test "takeWake drains and formats the grok-build do-not-poll reminder" {
    const io = std.testing.io;
    count = 0;
    dismissed_len = 0;
    record(io, 1, 0, false, "true", false);
    record(io, 2, 1, false, "false", false);
    var buf: [256]u8 = undefined;
    const text = takeWake(io, &buf) orelse return error.Empty;
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 1 exited 0: true]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "do not poll") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 2 exited 1: false]") != null);
    try std.testing.expect(takeWake(io, &buf) == null);
}

test "#199: an idle stop is a step-boundary notice, not an auto-turn wake" {
    const io = std.testing.io;
    count = 0;
    dismissed_len = 0;
    var buf: [512]u8 = undefined;
    record(io, 3, null, true, "npm run dev", true);
    try std.testing.expect(takeIdleWake(io, &buf) == null); // the idle TUI stays idle
    record(io, 4, 0, false, "make", false);
    const idle_text = takeIdleWake(io, &buf) orelse return error.Empty;
    try std.testing.expect(std.mem.indexOf(u8, idle_text, "[job 4 exited 0: make]") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle_text, "job 3") == null); // still queued
    const step_text = takeWake(io, &buf) orelse return error.Empty;
    try std.testing.expect(std.mem.indexOf(u8, step_text, "[job 3 stopped idle: npm run dev]") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "rerun it only if it is still needed") != null);
    try std.testing.expect(takeWake(io, &buf) == null);
}
