//! `/jobs` — background bash jobs and background agents, plus the #199
//! controls: `keep`/`unkeep` pin a server (no idle stop, kept alive when the
//! session ends), `stop` kills one, `restart` reruns a finished one in its
//! cwd. Split out of commands_misc.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const jobs = @import("jobs.zig");
const job_idle = @import("job_idle.zig");
const job_registry = @import("job_registry.zig");
const subagent = @import("subagent.zig"); // #276 P0-3: g_agent_jobs
const util = @import("util.zig");
const tool_pulse = @import("tool_pulse.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;

const posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

pub const usage = "usage: /jobs [keep|unkeep|stop|restart <id>]";

pub fn tryHandle(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/jobs") and !std.mem.startsWith(u8, line, "/jobs ")) return false;
    const rest = std.mem.trim(u8, line["/jobs".len..], " \t");
    if (rest.len == 0) try list(root, out) else try control(root, rest, out);
    try out.flush();
    return true;
}

fn control(root: *Agent, rest: []const u8, out: *Io.Writer) !void {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const verb = it.next() orelse return out.print("{s}\n", .{usage});
    const id = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return out.print("{s}\n", .{usage});
    if (std.mem.eql(u8, verb, "keep") or std.mem.eql(u8, verb, "unkeep")) {
        const keep = verb[0] == 'k';
        const ok = jobs.setPinned(root.io, id, keep) orelse return out.print("no background job {d} — /jobs lists them\n", .{id});
        if (!ok) return out.print("job {d} has already finished\n", .{id});
        if (keep) {
            try out.print("✓ job {d} pinned: no idle stop, kept alive when this session ends (`graff servers` finds it; /jobs unkeep {d} undoes)\n", .{ id, id });
        } else {
            try out.print("✓ job {d} unpinned: the idle stop applies again and it ends with the session\n", .{id});
        }
        return;
    }
    if (std.mem.eql(u8, verb, "stop")) {
        const r = try jobs.jobKill(root.gpa, root.io, id);
        defer root.gpa.free(r.text);
        return out.print("{s}\n", .{r.text});
    }
    if (std.mem.eql(u8, verb, "restart")) {
        const job = jobs.restartJob(root.gpa, root.io, id) catch |err| return switch (err) {
            error.NoSuchJob => out.print("no background job {d} — /jobs lists them\n", .{id}),
            error.StillRunning => out.print("job {d} is still running — /jobs stop {d} first\n", .{ id, id }),
            else => out.print("could not restart job {d} ({t})\n", .{ id, err }),
        };
        return out.print("✓ job {d} started: {s} (restart of job {d})\n", .{ job.id, util.utf8Prefix(job.cmd, 60), id });
    }
    try out.print("{s}\n", .{usage});
}

const Row = struct {
    id: u32,
    pid: i32,
    running: bool,
    status: []const u8,
    age_ms: u64,
    unread: usize,
    cmd: []const u8,
};

/// Rows are snapshotted under the pool mutex and printed after it: the port
/// lookup spawns lsof, and the pumps need the mutex every 200ms.
fn list(root: *Agent, out: *Io.Writer) !void {
    const io = root.io;
    const arena = root.scratchAlloc();
    const now = util.unixMs(io);
    var rows: std.ArrayList(Row) = .empty;
    jobs.g_jobs.mutex.lockUncancelable(io);
    for (jobs.g_jobs.list.items) |job| {
        const status: []const u8 = if (!job.done)
            (if (job.pinned) "pinned" else "running")
        else if (job.stopped_idle)
            "idle-stop"
        else if (job.killed)
            "killed"
        else if (job.exit_code) |c|
            (std.fmt.allocPrint(arena, "exit {d}", .{c}) catch "exited")
        else
            "abnormal";
        rows.append(arena, .{
            .id = job.id,
            .pid = if (comptime posix) (job.child.id orelse 0) else 0,
            .running = !job.done,
            .status = status,
            .age_ms = @intCast(@max(now - job.started_ms, 0)),
            .unread = job.buf.items.len - job.cursor,
            .cmd = arena.dupe(u8, util.utf8Prefix(job.cmd, 60)) catch "",
        }) catch break;
    }
    jobs.g_jobs.mutex.unlock(io);

    if (rows.items.len == 0) {
        try out.writeAll("no background bash jobs — the model starts one with bash {run_in_background: true}\n");
    } else {
        var sbuf: [16]u8 = undefined;
        const stop: []const u8 = if (job_idle.policy.stop_ms == 0) "off" else tool_pulse.formatElapsed(&sbuf, job_idle.policy.stop_ms);
        try out.print("{s}background jobs{s}  (idle stop: {s}; /jobs keep <id> pins one, /jobs restart <id> reruns one)\n", .{ style.bold, style.reset, stop });
        for (rows.items) |row| {
            var abuf: [16]u8 = undefined;
            const ports = if (row.running and row.pid != 0) job_registry.listenPorts(root.gpa, io, arena, row.pid) else "";
            try out.print("  {s}{d:>3}{s}  {s}{s:<9}{s} {s:>7} {d:>7} unread B  {s}{s}{s}\n", .{
                style.accent,                                row.id,     style.reset,
                if (row.running) style.green else style.dim, row.status, style.reset,
                tool_pulse.formatElapsed(&abuf, row.age_ms), row.unread, row.cmd,
                if (ports.len > 0) "  ⇢ " else "",
                ports,
            });
        }
    }

    // #276 P0-3: background subagents (subagent {run_in_background:true}),
    // same listing shape as bash jobs above.
    subagent.g_agent_jobs.mutex.lockUncancelable(io);
    defer subagent.g_agent_jobs.mutex.unlock(io);
    if (subagent.g_agent_jobs.list.items.len == 0) {
        try out.writeAll("no background agents — the model starts one with subagent {run_in_background: true}\n");
        return;
    }
    try out.print("{s}background agents{s}\n", .{ style.bold, style.reset });
    for (subagent.g_agent_jobs.list.items) |job| {
        const status: []const u8 = if (!job.admitted)
            "queued"
        else if (!job.done)
            "running"
        else if (job.is_error)
            "failed"
        else
            "done";
        try out.print("  {s}{d:>3}{s}  {s}{s:<8}{s} {d:>7}ms  {s}\n", .{
            style.accent,                             job.id,                    style.reset,
            if (job.done) style.dim else style.green, status,                    style.reset,
            job.usage.duration_ms,                    utf8Prefix(job.label, 60),
        });
    }
}

const utf8Prefix = util.utf8Prefix;
