//! Idle lifecycle for background bash jobs (#199). A dev server graff
//! started can outlive the turn, the session's attention, and — per the
//! postmortem on #199 — three days of a machine's memory and a port. The
//! activity graff can see without proxying traffic: bytes the job wrote, a
//! bash_output read or blocking wait, a /jobs touch. Past `warn_ms` of that
//! silence the user gets one dim notice naming the stop and the pin; past
//! `stop_ms` the job's whole process group is killed and the job stays
//! listed as stopped-idle with its command, so `/jobs restart` or a plain
//! rerun brings it back. Pinned jobs (`/jobs keep`) are exempt.
//!
//! No SIGSTOP "pause" state: it keeps the memory and the port and cannot
//! notice a request. Stopped-with-the-command-kept is the honest pause.

const std = @import("std");
const Io = std.Io;
const tool_pulse = @import("tool_pulse.zig");
const util = @import("util.zig");

pub const Policy = struct {
    warn_ms: u64 = 30 * std.time.ms_per_min,
    stop_ms: u64 = 2 * std.time.ms_per_hour,
};

/// Session policy. GRAFF_JOB_IDLE_WARN_MINS / GRAFF_JOB_IDLE_STOP_MINS
/// override the defaults; 0 turns that step off.
pub var policy: Policy = .{};

pub const Verdict = enum { none, warn, stop };

pub fn verdict(idle_ms: u64, warned: bool, pinned: bool) Verdict {
    return verdictUnder(policy, idle_ms, warned, pinned);
}

pub fn verdictUnder(p: Policy, idle_ms: u64, warned: bool, pinned: bool) Verdict {
    if (pinned) return .none;
    if (p.stop_ms != 0 and idle_ms >= p.stop_ms) return .stop;
    if (!warned and p.warn_ms != 0 and idle_ms >= p.warn_ms) return .warn;
    return .none;
}

/// Minutes; unparseable values are ignored, 0 disables, a week is the cap.
pub fn applyEnv(environ_map: anytype) void {
    if (environ_map.get("GRAFF_JOB_IDLE_WARN_MINS")) |v| {
        if (parseMins(v)) |ms| policy.warn_ms = ms;
    }
    if (environ_map.get("GRAFF_JOB_IDLE_STOP_MINS")) |v| {
        if (parseMins(v)) |ms| policy.stop_ms = ms;
    }
}

fn parseMins(v: []const u8) ?u64 {
    const mins = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch return null;
    const capped: u64 = @min(mins, 7 * 24 * 60);
    return capped * std.time.ms_per_min;
}

/// The one dim chrome line at the warn threshold.
pub fn warnLine(buf: []u8, id: u32, idle_ms: u64, stop_ms: u64, cmd: []const u8) []const u8 {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "· job {d} idle {s} ({s}) · stops after {s} idle · /jobs keep {d} pins it", .{
        id, tool_pulse.formatElapsed(&a, idle_ms), util.utf8Prefix(cmd, 32), tool_pulse.formatElapsed(&b, stop_ms), id,
    }) catch buf[0..0];
}

/// Pump thread: paint the warn line (hosted sink or line-REPL stdout).
pub fn warn(io: Io, id: u32, idle_ms: u64, cmd: []const u8) void {
    var buf: [160]u8 = undefined;
    const line = warnLine(&buf, id, idle_ms, policy.stop_ms, cmd);
    if (line.len > 0) tool_pulse.emitNotice(io, "{s}", .{line});
}

/// The bash_output status line for a job the policy stopped.
pub fn printStopped(w: *Io.Writer, id: u32, stop_ms: u64) !void {
    var b: [16]u8 = undefined;
    try w.print("[job {d}: stopped after {s} with no output and no reads — rerun it if it is still needed; the user pins a long-lived server with /jobs keep {d}]", .{ id, tool_pulse.formatElapsed(&b, stop_ms), id });
}

test "verdict: warn once past warn_ms, stop past stop_ms, nothing before" {
    const p: Policy = .{ .warn_ms = 1000, .stop_ms = 5000 };
    try std.testing.expectEqual(Verdict.none, verdictUnder(p, 999, false, false));
    try std.testing.expectEqual(Verdict.warn, verdictUnder(p, 1000, false, false));
    try std.testing.expectEqual(Verdict.none, verdictUnder(p, 4999, true, false)); // already warned
    try std.testing.expectEqual(Verdict.stop, verdictUnder(p, 5000, true, false));
    try std.testing.expectEqual(Verdict.stop, verdictUnder(p, 5000, false, false)); // a stop needs no prior warn
}

test "verdict: a pinned job is never warned or stopped; 0 turns a step off" {
    const p: Policy = .{ .warn_ms = 1000, .stop_ms = 5000 };
    try std.testing.expectEqual(Verdict.none, verdictUnder(p, 1_000_000, false, true));
    const no_stop: Policy = .{ .warn_ms = 1000, .stop_ms = 0 };
    try std.testing.expectEqual(Verdict.warn, verdictUnder(no_stop, 1_000_000, false, false));
    try std.testing.expectEqual(Verdict.none, verdictUnder(no_stop, 1_000_000, true, false));
    const off: Policy = .{ .warn_ms = 0, .stop_ms = 0 };
    try std.testing.expectEqual(Verdict.none, verdictUnder(off, 1_000_000, false, false));
}

test "applyEnv: minutes to ms, 0 disables, junk ignored, a week caps" {
    const saved = policy;
    defer policy = saved;
    const Env = struct {
        warn: ?[]const u8,
        stop: ?[]const u8,
        pub fn get(self: @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "GRAFF_JOB_IDLE_WARN_MINS")) return self.warn;
            if (std.mem.eql(u8, name, "GRAFF_JOB_IDLE_STOP_MINS")) return self.stop;
            return null;
        }
    };
    policy = .{};
    applyEnv(Env{ .warn = "5", .stop = "0" });
    try std.testing.expectEqual(@as(u64, 5 * std.time.ms_per_min), policy.warn_ms);
    try std.testing.expectEqual(@as(u64, 0), policy.stop_ms);
    applyEnv(Env{ .warn = "junk", .stop = "99999999" });
    try std.testing.expectEqual(@as(u64, 5 * std.time.ms_per_min), policy.warn_ms);
    try std.testing.expectEqual(@as(u64, 7 * 24 * 60 * std.time.ms_per_min), policy.stop_ms);
}

test "warnLine names the job, the idle time, the stop, and the pin" {
    var buf: [160]u8 = undefined;
    const line = warnLine(&buf, 3, 30 * std.time.ms_per_min, 2 * std.time.ms_per_hour, "npm run dev -p 3002");
    try std.testing.expectEqualStrings("· job 3 idle 30m00s (npm run dev -p 3002) · stops after 2h00m idle · /jobs keep 3 pins it", line);
}

test "printStopped tells the model the job is gone and how it comes back" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printStopped(&aw.writer, 7, 2 * std.time.ms_per_hour);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "[job 7: stopped after 2h00m") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "/jobs keep 7") != null);
}
