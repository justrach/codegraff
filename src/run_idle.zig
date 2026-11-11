//! Run until idle. A root reply that would end the run while work it started
//! in the background is still running does not end it: the run waits for that
//! work to report, then continues with the result. Only a reply with nothing
//! running ends the run.
//!
//! Headless surfaces only: `-p`, and the non-interactive mainloop behind
//! `--json`, `graff serve` and piped stdin. Nothing else wakes those sessions
//! again, so a background build's exit notice used to die with the process.
//! The TUI, the line REPL and ACP start a new turn when background work
//! reports (idle_wake_sources.zig), so they end the turn instead.
//!
//! Live work is a running shell job that will post an exit notice, and a
//! background subagent the root started. A server never reports, so a job
//! that is persistent, pinned, detached or listening on a TCP port does not
//! count. While waiting, a heartbeat wakes the model after `heartbeat_ms`
//! without news so it can check on work that may be stuck; after
//! `max_quiet_beats` heartbeats in a row with no result and no tool call, the
//! run stops waiting.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const jobs = @import("jobs.zig");
const subagent = @import("subagent.zig");
const job_notify = @import("job_notify.zig");
const session_wake = @import("session_wake.zig");
const tool_pulse = @import("tool_pulse.zig");
const util = @import("util.zig");

/// Set by the headless entry points (session_run.runOneshotPrompt, mainloop.run).
pub var enabled: bool = false;

/// Silence before a heartbeat. GRAFF_HEARTBEAT_SECS overrides; 0 turns it off.
pub var heartbeat_ms: u64 = 10 * std.time.ms_per_min;

/// Heartbeats in a row with no result and no tool call before the run stops
/// waiting: the model has looked that many times and only chose to wait.
const max_quiet_beats: u8 = 3;
const poll_ms = 200;
/// A finished subagent's report rides its wake up to this size.
const report_cap: usize = 6 * 1024;

/// Seconds; unparseable values are ignored, 0 disables, a week is the cap.
pub fn applyEnv(environ_map: anytype) void {
    const v = environ_map.get("GRAFF_HEARTBEAT_SECS") orelse return;
    const secs = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch return;
    heartbeat_ms = @min(secs, 7 * 24 * 3600) * std.time.ms_per_s;
}

/// The run's state across the waits of one root turn.
pub const Hold = struct {
    quiet_beats: u8 = 0,
    calls_at_beat: u64 = 0,

    /// Where a final reply would end the root turn. True continues the turn:
    /// a result or a heartbeat is queued for the next request.
    pub fn wait(self: *Hold, agent: *Agent) !bool {
        if (!enabled or agent.sub or agent.review_mode or agent.text_only or agent.completed != null) return false;
        const io = agent.io;
        if (agent.tool_calls_this_turn != self.calls_at_beat) self.quiet_beats = 0; // it acted since the last beat
        var scratch = std.heap.ArenaAllocator.init(agent.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const work = try Work.snapshot(agent.gpa, io, a);
        var since: ?i64 = null;
        while (true) {
            if (Agent.esc_cancel.load(.acquire)) return error.Interrupted;
            // The client sent its next request: the turn ends and that request
            // runs; its first step boundary delivers whatever has reported.
            if (@import("json_inbox.zig").waiting()) return false;
            // Read before the notices: work that ends after this read is caught
            // on the next pass, and work that ended before it already queued its
            // notice (done and the notice share the jobs lock).
            const live = work.live(io);
            if (job_notify.pending(io) or try deliver(agent)) {
                self.quiet_beats = 0;
                return true;
            }
            if (!live) return false;
            const now = util.unixMs(io);
            const started = since orelse blk: {
                if (self.quiet_beats >= max_quiet_beats) {
                    try agent.say("[stopped waiting: background work is still running after {d} heartbeats with no news]\n", .{max_quiet_beats});
                    if (agent.tracer) |t| t.note("run_idle", "quiet cap");
                    return false;
                }
                try agent.say("[waiting for background work to report: {s}]\n", .{try work.describe(io, a)});
                if (agent.tracer) |t| t.note("run_idle", "waiting");
                since = now;
                break :blk now;
            };
            if (heartbeat_ms > 0 and now - started >= @as(i64, @intCast(heartbeat_ms))) {
                self.quiet_beats += 1;
                self.calls_at_beat = agent.tool_calls_this_turn;
                session_wake.inject(agent, try heartbeatText(a, @intCast(now - started), try work.describe(io, a)));
                if (agent.tracer) |t| t.note("run_idle", "heartbeat");
                return true;
            }
            io.sleep(.fromMilliseconds(poll_ms), .awake) catch return false;
        }
    }
};

/// Step boundary (turn_inbox) and the wait: a finished background subagent
/// the root started wakes the run with its report. Interactive roots own
/// their children and get subagent_interactive's wake instead.
pub fn deliver(agent: *Agent) !bool {
    if (!enabled or agent.sub) return false;
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| agent.gpa.free(t);
        texts.deinit(agent.gpa);
    }
    try takeReports(agent.gpa, agent.io, &texts);
    for (texts.items) |t| session_wake.inject(agent, t);
    return texts.items.len > 0;
}

/// Unread reports of finished root children, marked read. `agent_output`
/// still returns a report in full after this.
fn takeReports(gpa: Allocator, io: Io, texts: *std.ArrayList([]u8)) !void {
    const reg = &subagent.g_agent_jobs;
    reg.mutex.lockUncancelable(io);
    defer reg.mutex.unlock(io);
    for (reg.list.items) |job| {
        if (!rootChild(job) or !job.done or job.notified) continue;
        const status = try subagent.agentStatusText(gpa, job.id, true, job.is_error, job.usage, job.result);
        defer gpa.free(status);
        try texts.ensureUnusedCapacity(gpa, 1);
        texts.appendAssumeCapacity(try reportWake(gpa, job.id, status));
        job.notified = true;
    }
}

fn reportWake(gpa: Allocator, id: u32, status: []const u8) ![]u8 {
    if (status.len <= report_cap)
        return std.fmt.allocPrint(gpa, "{s}\nContinue the task from this result.", .{status});
    return std.fmt.allocPrint(gpa, "{s}\n[report cut at {d} bytes; agent_output id {d} returns all of it]\nContinue the task from this result.", .{ util.utf8Prefix(status, report_cap), report_cap, id });
}

/// A background child of a headless root: interactive roots set `owner`,
/// and a child's own children belong to it.
fn rootChild(job: *const subagent.AgentJob) bool {
    return job.owner == null and !job.ctx.from_sub;
}

fn heartbeatText(a: Allocator, silent_ms: u64, running: []const u8) ![]const u8 {
    var ebuf: [16]u8 = undefined;
    return std.fmt.allocPrint(a, "[heartbeat: no news from background work for {s}. Still running: {s}. Check on anything that may be stuck (action=output or agent_output for a snapshot, action=kill to stop a job), or end your reply to keep waiting.]", .{ tool_pulse.formatElapsed(&ebuf, silent_ms), running });
}

/// True when `cmd` is a standalone `sleep <N>[s|m|h]` polling wait with no
/// chained commands or redirection (#1888).
pub fn isStandaloneSleep(cmd: []const u8) bool {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (!@import("harness_policy.zig").isSimple(trimmed)) return false;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const verb = it.next() orelse return false;
    if (!std.mem.eql(u8, verb, "sleep") and !std.mem.eql(u8, verb, "/bin/sleep")) return false;
    const dur = it.next() orelse return false;
    if (it.next() != null) return false;
    const num = if (dur.len > 1 and (dur[dur.len - 1] == 's' or dur[dur.len - 1] == 'm' or dur[dur.len - 1] == 'h'))
        dur[0 .. dur.len - 1]
    else
        dur;
    const secs = std.fmt.parseFloat(f64, num) catch return false;
    return secs >= 0 and std.math.isFinite(secs);
}

/// Returns a short description of active background work (`job 3` or `agent 1`)
/// when any finite background job or root subagent is currently running.
pub fn firstLiveBackgroundLabel(io: Io, buf: *[64]u8) ?[]const u8 {
    {
        const reg = &jobs.g_jobs;
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        for (reg.list.items) |job| {
            if (job.done or job.quiet or job.persistent or job.pinned or job.detach) continue;
            if (isStandaloneSleep(job.cmd)) continue;
            return std.fmt.bufPrint(buf, "job {d}", .{job.id}) catch "background job";
        }
    }
    const reg = &subagent.g_agent_jobs;
    reg.mutex.lockUncancelable(io);
    defer reg.mutex.unlock(io);
    for (reg.list.items) |job| {
        if (!job.done and !job.ctx.from_sub) {
            return std.fmt.bufPrint(buf, "agent {d}", .{job.id}) catch "background agent";
        }
    }
    return null;
}

/// The background work a run waits on, captured when it starts waiting.
const Work = struct {
    jobs: std.ArrayList(JobRef) = .empty,
    agents: std.ArrayList(AgentRef) = .empty,

    const JobRef = struct { id: u64, cmd: []const u8, started_ms: i64 };
    const AgentRef = struct { id: u32, label: []const u8 };

    fn snapshot(gpa: Allocator, io: Io, a: Allocator) !Work {
        var w: Work = .{};
        var candidates: std.ArrayList(struct { ref: JobRef, pid: i32 }) = .empty;
        {
            const reg = &jobs.g_jobs;
            reg.mutex.lockUncancelable(io);
            defer reg.mutex.unlock(io);
            for (reg.list.items) |job| {
                // quiet: still in its foreground wait, the tool call is live.
                if (job.done or job.quiet or job.persistent or job.pinned or job.detach) continue;
                if (isStandaloneSleep(job.cmd)) continue; // #1888: never hold session open for polling sleep
                try candidates.append(a, .{ .ref = .{ .id = job.id, .cmd = try a.dupe(u8, job.cmd), .started_ms = job.started_ms }, .pid = job.group_pid });
            }
        }
        // lsof runs outside the lock. A listening process group is a server.
        for (candidates.items) |c| {
            if (c.pid != 0 and @import("job_registry.zig").listenPorts(gpa, io, a, c.pid).len > 0) continue;
            try w.jobs.append(a, c.ref);
        }
        const reg = &subagent.g_agent_jobs;
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        for (reg.list.items) |job| {
            if (rootChild(job) and !job.done) try w.agents.append(a, .{ .id = job.id, .label = try a.dupe(u8, job.label) });
        }
        return w;
    }

    fn live(w: Work, io: Io) bool {
        {
            const reg = &jobs.g_jobs;
            reg.mutex.lockUncancelable(io);
            defer reg.mutex.unlock(io);
            for (w.jobs.items) |ref| {
                for (reg.list.items) |job| if (job.id == ref.id and !job.done) return true;
            }
        }
        const reg = &subagent.g_agent_jobs;
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        for (w.agents.items) |ref| if (reg.find(ref.id)) |job| if (!job.done) return true;
        return false;
    }

    /// `job 3 (zig build test, 12m)` style, for the waiting line and the heartbeat.
    fn describe(w: Work, io: Io, a: Allocator) ![]const u8 {
        var aw: Io.Writer.Allocating = .init(a);
        const now = util.unixMs(io);
        for (w.jobs.items, 0..) |ref, i| {
            var ebuf: [16]u8 = undefined;
            const age: u64 = @intCast(@max(0, now - ref.started_ms));
            try aw.writer.print("{s}job {d} ({s}, {s})", .{ if (i == 0) "" else ", ", ref.id, util.utf8Prefix(ref.cmd, 48), tool_pulse.formatElapsed(&ebuf, age) });
        }
        for (w.agents.items, 0..) |ref, i| {
            try aw.writer.print("{s}agent {d} ({s})", .{ if (i == 0 and w.jobs.items.len == 0) "" else ", ", ref.id, util.utf8Prefix(ref.label, 48) });
        }
        return aw.written();
    }
};

test "GRAFF_HEARTBEAT_SECS: seconds, 0 turns it off, junk is ignored" {
    const saved = heartbeat_ms;
    defer heartbeat_ms = saved;
    const Env = struct {
        v: ?[]const u8,
        pub fn get(self: @This(), name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "GRAFF_HEARTBEAT_SECS")) self.v else null;
        }
    };
    applyEnv(Env{ .v = "90" });
    try std.testing.expectEqual(@as(u64, 90_000), heartbeat_ms);
    applyEnv(Env{ .v = "junk" });
    try std.testing.expectEqual(@as(u64, 90_000), heartbeat_ms);
    applyEnv(Env{ .v = "0" });
    try std.testing.expectEqual(@as(u64, 0), heartbeat_ms);
}

test "a running background job is live work until it ends, and then its notice is queued" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    jobs.g_jobs = .{};
    defer jobs.jobsReap(gpa, io);
    var buf: [4096]u8 = undefined;
    while (job_notify.takeWake(io, &buf) != null) {}
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const id = (try jobs.spawnJob(gpa, io, "sleep 0.3; echo run-idle-done")).id;
    const work = try Work.snapshot(gpa, io, scratch.allocator());
    try std.testing.expectEqual(@as(usize, 1), work.jobs.items.len);
    try std.testing.expect(work.live(io));
    const line = try work.describe(io, scratch.allocator());
    try std.testing.expect(std.mem.indexOf(u8, line, "sleep 0.3") != null);
    var waited: u32 = 0;
    while (work.live(io) and waited < 100) : (waited += 1) io.sleep(.fromMilliseconds(50), .awake) catch {};
    try std.testing.expect(!work.live(io));
    try std.testing.expect(job_notify.pending(io));
    const wake = job_notify.takeWake(io, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, wake, "run-idle-done") != null);
    _ = id;
}

test "only the root's own background children are waited on and reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const saved = subagent.g_agent_jobs;
    subagent.g_agent_jobs = .{};
    defer {
        subagent.g_agent_jobs.list.deinit(gpa);
        subagent.g_agent_jobs = saved;
    }
    var label = "review parser".*;
    const ctx: @import("tools.zig").ToolCtx = .{ .gpa = gpa, .io = io, .client = undefined, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    var mine: subagent.AgentJob = .{ .id = 1, .label = &label, .prompt = &label, .niche = &label, .isolation = .shared_cwd, .isolation_fallback = false, .ctx = ctx };
    var nested_ctx = ctx;
    nested_ctx.from_sub = true;
    var nested: subagent.AgentJob = .{ .id = 2, .label = &label, .prompt = &label, .niche = &label, .isolation = .shared_cwd, .isolation_fallback = false, .ctx = nested_ctx };
    var owned: subagent.AgentJob = .{ .id = 3, .label = &label, .prompt = &label, .niche = &label, .isolation = .shared_cwd, .isolation_fallback = false, .ctx = ctx, .owner = "tui-session" };
    try subagent.g_agent_jobs.list.appendSlice(gpa, &.{ &mine, &nested, &owned });

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const work = try Work.snapshot(gpa, io, scratch.allocator());
    try std.testing.expectEqual(@as(usize, 1), work.agents.items.len);
    try std.testing.expectEqual(@as(u32, 1), work.agents.items[0].id);
    try std.testing.expect(work.live(io));

    var result = "PARSER_OK".*;
    for ([_]*subagent.AgentJob{ &mine, &nested, &owned }) |job| {
        job.done = true;
        job.result = &result;
    }
    try std.testing.expect(!work.live(io));
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    try takeReports(gpa, io, &texts);
    try std.testing.expectEqual(@as(usize, 1), texts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, texts.items[0], "[agent 1: completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, texts.items[0], "PARSER_OK") != null);
    try std.testing.expect(mine.notified and !nested.notified and !owned.notified);
    for (texts.items) |t| gpa.free(t);
    texts.clearRetainingCapacity();
    try takeReports(gpa, io, &texts); // read once
    try std.testing.expectEqual(@as(usize, 0), texts.items.len);
}

test "a long report is cut at the cap and points at agent_output" {
    const gpa = std.testing.allocator;
    const long = try gpa.alloc(u8, report_cap + 100);
    defer gpa.free(long);
    @memset(long, 'x');
    const text = try reportWake(gpa, 9, long);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "agent_output id 9 returns all of it") != null);
    try std.testing.expect(text.len < report_cap + 200);
}

test "the heartbeat names the silence, the work and both ways forward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try heartbeatText(arena.allocator(), 10 * std.time.ms_per_min, "job 3 (zig build test, 12m)");
    try std.testing.expect(std.mem.indexOf(u8, text, "10m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "job 3 (zig build test, 12m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "action=kill") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keep waiting") != null);
}

test "#1888: isStandaloneSleep detects pure polling sleeps and ignores compound commands" {
    try std.testing.expect(isStandaloneSleep("sleep 90"));
    try std.testing.expect(isStandaloneSleep("  /bin/sleep 120s  "));
    try std.testing.expect(isStandaloneSleep("sleep 0.5"));
    try std.testing.expect(!isStandaloneSleep("sleep 0.3; echo run-idle-done"));
    try std.testing.expect(!isStandaloneSleep("sleep 5 && pytest"));
    try std.testing.expect(!isStandaloneSleep("pytest"));
}
