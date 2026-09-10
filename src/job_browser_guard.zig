//! Conservative automatic cleanup guard. Socket inventory is NOT browser-tab
//! inventory: even a silent listener may serve an open external browser tab.
const std = @import("std");
const builtin = @import("builtin");
const runner = @import("process_runner.zig");
const idle = @import("job_idle.zig");
pub const Probe = enum { closed, listening, unknown };
pub const retry_ms = 60 * std.time.ms_per_s;

/// Inventory the entire owned process group, not merely the shell leader.
/// Any internet socket protects the job (including UDP and connected sockets).
/// Empty/error/partial inventories are never evidence of absence.
pub fn classify(exit_ok: bool, incomplete: bool, output: []const u8, diagnostics: []const u8) Probe {
    if (!exit_ok or incomplete or diagnostics.len != 0) return .unknown;
    var process = false;
    var file = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            'p' => {
                if (process and !file) return .unknown;
                const pid = std.fmt.parseInt(u32, line[1..], 10) catch return .unknown;
                if (pid == 0) return .unknown;
                process = true;
                file = false;
            },
            't' => {
                if (!process) return .unknown;
                if (std.mem.eql(u8, line[1..], "IPv4") or std.mem.eql(u8, line[1..], "IPv6")) return .listening;
                // Unknown file types may be sockets on an unsupported platform.
                if (!std.mem.eql(u8, line[1..], "REG") and !std.mem.eql(u8, line[1..], "DIR") and
                    !std.mem.eql(u8, line[1..], "CHR") and !std.mem.eql(u8, line[1..], "FIFO") and
                    !std.mem.eql(u8, line[1..], "PIPE") and !std.mem.eql(u8, line[1..], "unix") and
                    !std.mem.eql(u8, line[1..], "systm")) return .unknown;
                file = true;
            },
            'f' => {}, // lsof always includes file descriptors with field output
            else => return .unknown,
        }
    }
    return if (process and file) .closed else .unknown;
}

pub fn probe(gpa: std.mem.Allocator, io: std.Io, pid: i32) Probe {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return .unknown;
    if (pid <= 0) return .unknown;
    var buf: [24]u8 = undefined;
    const group = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return .unknown;
    const result = runner.runCapped(gpa, io, &.{ "lsof", "-nP", "-a", "-g", group, "-Fpt" }, 256 * 1024, 4096, 1500) catch return .unknown;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return classify(ok, result.timed_out or result.cancelled or result.stdout_truncated or result.stderr_truncated, result.stdout, result.stderr);
}

/// Failed pipe handoff must keep the existing pump draining, not kill or
/// close the pipes. This can hold session shutdown until the job exits.
pub const ExitAction = enum { stop, detach, drain };
pub fn exitAction(result: Probe, pinned: bool, handoff_ok: bool) ExitAction {
    if (!pinned and result == .closed) return .stop;
    return if (handoff_ok) .detach else .drain;
}

pub fn touch(job: anytype, now: i64) void {
    job.last_active_ms = now;
    job.activity_revision +%= 1;
}

pub fn mayStop(result: Probe, pinned: bool, before: i64, after: i64, still_idle: bool) bool {
    return result == .closed and !pinned and before == after and still_idle;
}

/// Called with the pool locked; returns locked. The bounded subprocess runs
/// outside the mutex, then activity, pinning and shutdown are checked again.
pub fn checkIdle(pool: anytype, job: anytype, gpa: std.mem.Allocator, io: std.Io, pid: i32, now: i64) void {
    if (now < job.browser_probe_after_ms) return;
    job.browser_probe_after_ms = now + retry_ms;
    const activity = job.activity_revision;
    pool.mutex.unlock(io);
    const result = probe(gpa, io, pid);
    pool.mutex.lockUncancelable(io);
    const still_idle = idle.verdict(@intCast(@max(now - job.last_active_ms, 0)), job.idle_warned, job.pinned) == .stop;
    if (!job.kill_requested and !job.detach and !job.exit_cleanup and mayStop(result, job.pinned, activity, job.activity_revision, still_idle)) {
        job.kill_requested = true;
        job.stopped_idle = true;
    }
}

test "browser guard closed inventory allows ordinary idle jobs only" {
    try std.testing.expectEqual(Probe.closed, classify(true, false, "p12\nf1\ntREG\nf2\ntFIFO\n", ""));
    try std.testing.expect(mayStop(.closed, false, 1, 1, true));
    try std.testing.expect(!mayStop(.closed, true, 1, 1, true));
    try std.testing.expect(!mayStop(.closed, false, 1, 2, true));
    try std.testing.expect(!mayStop(.closed, false, 1, 1, false));
}

test "browser guard listeners and unknown never imply closed tabs" {
    try std.testing.expectEqual(Probe.listening, classify(true, false, "p12\nf4\ntIPv6\n", ""));
    try std.testing.expect(!mayStop(.listening, false, 1, 1, true));
    try std.testing.expect(!mayStop(.unknown, false, 1, 1, true));
}

test "browser guard failures and incomplete inventory fail closed" {
    for ([_]Probe{
        classify(false, false, "p12\ntREG\n", ""),
        classify(true, true, "p12\ntREG\n", ""),
        classify(true, false, "p12\ntREG\n", "permission denied"),
        classify(true, false, "", ""),
        classify(true, false, "p12\n", ""),
        classify(true, false, "p12\ntREG\np13\n", ""),
        classify(true, false, "p12\np13\ntREG\n", ""),
        classify(true, false, "p12\ntUNKNOWN\n", ""),
    }) |result| try std.testing.expectEqual(Probe.unknown, result);
}

test "browser guard exit handoff failure preserves draining without kill" {
    for ([_]Probe{ .listening, .unknown }) |result| {
        try std.testing.expectEqual(ExitAction.drain, exitAction(result, false, false));
        try std.testing.expectEqual(ExitAction.detach, exitAction(result, false, true));
    }
    try std.testing.expectEqual(ExitAction.drain, exitAction(.closed, true, false));
    try std.testing.expectEqual(ExitAction.detach, exitAction(.closed, true, true));
    try std.testing.expectEqual(ExitAction.stop, exitAction(.closed, false, false));
}

test "browser guard tracks same millisecond reads and pin changes" {
    var job = struct { last_active_ms: i64 = 42, activity_revision: i64 = 0 }{};
    const before = job.activity_revision;
    touch(&job, 42);
    try std.testing.expect(!mayStop(.closed, false, before, job.activity_revision, true));
}
