//! Idle auto-turn sources shared by the line REPL, TUI, and graff acp.
//! Order matches the TUI poll: interactive-subagent, job idle-stop (#199),
//! schedule, channel-worker, then peer mail (#1001). Accord ping is a side
//! drain, not a wake. `subagent_interactive.takeWake` is engine-side (job
//! registry + session owner) — it does not need a TTY. The TTY-only path is
//! `stealIdleLine`, which the line REPL already calls separately.

const std = @import("std");
const Io = std.Io;

const channel_worker = @import("channel_worker.zig");
const job_notify = @import("job_notify.zig");
const peer_idle = @import("peer_idle.zig");
const peer_inbox = @import("peer_inbox.zig");
const presence_accord = @import("presence_accord.zig");
const presence_chan = @import("presence_chan.zig");
const schedule = @import("schedule.zig");
const subagent_interactive = @import("subagent_interactive.zig");

/// Single-fire poll used by every surface's idle callback. Busy / completion
/// latches stay inside `peer_idle.takeIdleWake` (#1137 / #1138); this helper
/// only unifies which sources run and in which order.
pub fn takeIdleWake(io: Io, session_name: []const u8, buf: []u8) ?[]const u8 {
    if (subagent_interactive.takeWake(io, session_name, buf)) |t| return t;
    if (job_notify.takeIdleWake(io, buf)) |t| return t; // idle-stop waits for a real step boundary (#199)
    if (schedule.takeWake(io, buf)) |t| return t;
    if (channel_worker.takeWake(io, buf)) |t| return t;
    _ = presence_accord.takePing(); // standing link; JSONL is still the drain
    return peer_idle.takeIdleWake(io, buf);
}

fn sourcePin(src: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, src, needle) orelse return error.MissingPin;
}

fn expectBefore(src: []const u8, earlier: []const u8, later: []const u8) !void {
    const a = try sourcePin(src, earlier);
    const b = try sourcePin(src, later);
    try std.testing.expect(a < b);
}

fn helperBody() []const u8 {
    const src = @embedFile("idle_wake_sources.zig");
    const start = std.mem.indexOf(u8, src, "pub fn takeIdleWake").?;
    const rest = src[start..];
    const end = std.mem.indexOf(u8, rest, "\n}").?;
    return rest[0 .. end + 1];
}

test "idle wake helper polls sources in TUI order" {
    const body = helperBody();
    try expectBefore(body, "subagent_interactive.takeWake", "job_notify.takeIdleWake");
    try expectBefore(body, "job_notify.takeIdleWake", "schedule.takeWake");
    try expectBefore(body, "schedule.takeWake", "channel_worker.takeWake");
    try expectBefore(body, "channel_worker.takeWake", "presence_accord.takePing");
    try expectBefore(body, "presence_accord.takePing", "peer_idle.takeIdleWake");
}

test "REPL TUI and ACP idle callbacks delegate to the shared helper" {
    const helper = "idle_wake_sources.zig";
    const tui = @embedFile("tui_launch.zig");
    const repl = @embedFile("readline.zig");
    const acp = @embedFile("acp_idle.zig");
    try std.testing.expect(std.mem.indexOf(u8, tui, helper) != null);
    try std.testing.expect(std.mem.indexOf(u8, repl, helper) != null);
    try std.testing.expect(std.mem.indexOf(u8, acp, helper) != null);
    try std.testing.expect(std.mem.indexOf(u8, tui, "takeIdleWake(") != null);
    try std.testing.expect(std.mem.indexOf(u8, repl, "takeIdleWake(") != null);
    try std.testing.expect(std.mem.indexOf(u8, acp, "takeIdleWake(") != null);
    try std.testing.expect(std.mem.indexOf(u8, tui, "job_notify.takeIdleWake") == null);
    try std.testing.expect(std.mem.indexOf(u8, tui, "schedule.takeWake") == null);
    try std.testing.expect(std.mem.indexOf(u8, tui, "channel_worker.takeWake") == null);
    try std.testing.expect(std.mem.indexOf(u8, tui, "peer_idle.takeIdleWake") == null);
    try std.testing.expect(std.mem.indexOf(u8, repl, "peer_idle.takeIdleWake") == null);
    try std.testing.expect(std.mem.indexOf(u8, acp, "peer_idle.takeIdleWake") == null);
}

test "ACP frontend exit runs finalizeSession like REPL and TUI" {
    const src = @embedFile("session_run.zig");
    const fn_start = std.mem.indexOf(u8, src, "pub fn runFrontendCommands").?;
    const body = src[fn_start..];
    const acp = try sourcePin(body, "runAcpCommand");
    const after_acp = body[acp..];
    const finalize = try sourcePin(after_acp, "finalizeSession(");
    const ret = try sourcePin(after_acp, "return true;");
    try std.testing.expect(finalize < ret);
    try std.testing.expect(std.mem.indexOf(u8, body[0..acp], "finalizeSession(") != null);
    const tui = try sourcePin(body, "tui_launch.maybeRun");
    try std.testing.expect(std.mem.indexOf(u8, body[tui..], "finalizeSession(") != null);
}

test "job notify wins over parked peer mail" {
    peer_inbox.resetForTest();
    peer_idle.resetForTest();
    defer {
        peer_inbox.resetForTest();
        peer_idle.resetForTest();
    }
    const io = std.testing.io;
    var buf: [512]u8 = undefined;
    while (job_notify.takeIdleWake(io, &buf)) |_| {}
    job_notify.record(io, 99, 0, false, "true", false);
    const msg: presence_chan.Message = .{
        .from_pid = 2,
        .from_start = 1,
        .from_session = "s-peer",
        .text = "hold gui/src",
        .to = "s-me",
    };
    _ = peer_inbox.parkHeard(&.{msg}, &.{});
    const first = takeIdleWake(io, "s", &buf) orelse return error.ExpectedJob;
    try std.testing.expect(std.mem.indexOf(u8, first, "[job 99") != null);
    const second = takeIdleWake(io, "s", &buf) orelse return error.ExpectedPeer;
    try std.testing.expect(std.mem.indexOf(u8, second, "[peer]") != null);
}
