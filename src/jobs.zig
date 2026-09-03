//! Capped runner, worktree commands, and the background bash-job pool.
//! Split out of main.zig (600-line goal). Back-imports main for ToolOutput.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const ToolOutput = tools_mod.ToolOutput;
const process_runner = @import("process_runner.zig");
pub const CappedRun = process_runner.CappedRun;
pub const CappedRunOptions = process_runner.CappedRunOptions;
pub const runCapped = process_runner.runCapped;
pub const runCappedWithOptions = process_runner.runCappedWithOptions;
pub const ranOk = process_runner.ranOk;

const Agent = agent_mod.Agent;

/// Same as `runCapped`, but spawns the child with an explicit working
/// directory instead of inheriting the process's (#276 P0-1: a worktree-
/// isolated subagent's `bash` calls need their own cwd — per-spawn, via
/// `std.process.Child.Cwd`, never a process-wide chdir, so parallel sibling
/// agents on the same pool each keep their own).
pub fn runCappedCwd(gpa: Allocator, io: Io, argv: []const []const u8, stdout_cap: usize, stderr_cap: usize, deadline_ms: u64, cwd: std.process.Child.Cwd) !CappedRun {
    return runCappedWithOptions(gpa, io, argv, stdout_cap, stderr_cap, deadline_ms, .{ .cwd = cwd });
}

/// Run options for a FOREGROUND tool subprocess (the `bash` and `codedb`
/// tools). kill_process_tree is always on here: the child leads its own
/// process group, so an Esc cancel or a deadline takes the grandchildren down
/// with it instead of orphaning them onto init — the `ssh` left running after
/// an interrupt in #266, the `codedb search` / `xcodebuild` trees that
/// outlived their session for days in #198. `cwd` is null unless the caller is
/// a worktree-isolated agent (#276 P0-1).
pub fn toolRunOptions(cwd: ?[]const u8) CappedRunOptions {
    return .{
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .kill_process_tree = true,
    };
}

// `graff worktree …` + the per-turn checkpoint commit live in worktree_cmd.zig
// (moved out when the pool grew its idle lifecycle, #199); callers still reach
// them through jobs.
const worktree_cmd = @import("worktree_cmd.zig");
pub const worktreeAutoCommit = worktree_cmd.worktreeAutoCommit;
pub const worktreeCommand = worktree_cmd.worktreeCommand;

const agent_worktree = @import("agent_worktree.zig");
pub const AgentWorktree = agent_worktree.AgentWorktree;
pub const AgentWorktreeError = agent_worktree.AgentWorktreeError;
pub const AgentWorktreeOutcome = agent_worktree.AgentWorktreeOutcome;
pub const isolationFailureText = agent_worktree.isolationFailureText;
pub const agentWorktreeNames = agent_worktree.agentWorktreeNames;
pub const agentWorktreeCreate = agent_worktree.agentWorktreeCreate;
pub const isWorktreeStatusDirty = agent_worktree.isWorktreeStatusDirty;
pub const agentWorktreeFinish = agent_worktree.agentWorktreeFinish;
pub const KeepReason = agent_worktree.KeepReason;
pub const keepReasonText = agent_worktree.keepReasonText;

const Job = struct { // session-global; pump drains pipes; survives Esc
    id: u32,
    cmd: []u8,
    child: std.process.Child,
    // #199 idle lifecycle + ownership record (job_idle.zig, job_registry.zig)
    cwd: ?[]u8 = null, // owned copy: /jobs restart reruns in the same place
    started_ms: i64 = 0, // unix ms, for age columns and the record
    last_active_ms: i64 = 0, // awake ms: last output byte, read, wait tick, or pin
    pinned: bool = false, // /jobs keep: no idle stop, retained at session end
    idle_warned: bool = false,
    stopped_idle: bool = false, // the idle policy killed it, not bash_kill
    detach: bool = false, // session end kept it: the pump exits without a kill
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    exit_code: ?u8 = null,
    done: bool = false,
    killed: bool = false,
    kill_requested: bool = false,
    dropped: bool = false,
    quiet: bool = false, // skip job_notify until auto-bg (#620)
    future: Io.Future(void) = undefined,
    stream: ?process_runner.StreamFn = null,
    stream_ctx: ?*anyopaque = null,
};

pub const job_unread_cap = 256 * 1024;
const job_wait = @import("job_wait.zig");
const job_notify = @import("job_notify.zig");
const job_idle = @import("job_idle.zig"); // #199
const job_registry = @import("job_registry.zig"); // #199
const proc_identity = @import("proc_identity.zig");
const util = @import("util.zig");
const tool_pulse = @import("tool_pulse.zig"); // silence heartbeat during waitForeground

/// POSIX process groups; windows/wasi have none, so the group kills below and
/// the job's own pgid are compiled out there (#198).
const posix_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const Jobs = struct {
    mutex: Io.Mutex = .init,
    list: std.ArrayList(*Job) = .empty,
    next_id: u32 = 1,

    /// Caller holds the mutex.
    fn find(self: *Jobs, id: u32) ?*Job {
        for (self.list.items) |j| if (j.id == id) return j;
        return null;
    }
};

pub var g_jobs: Jobs = .{};

/// Drain whatever the MultiReader has buffered into the job's output buffer,
/// dropping the oldest *unread* bytes past the cap (a chatty server must not
/// grow memory unboundedly between bash_output polls). Caller holds the mutex.
fn jobDrain(job: *Job, gpa: Allocator, readers: []const *Io.Reader, now_ms: i64) void {
    for (readers, 0..) |r, i| {
        const b = r.buffered();
        if (b.len == 0) continue;
        job.last_active_ms = now_ms; // output is activity (#199)
        if (job.stream) |emit| emit(job.stream_ctx, @intCast(i), b);
        job.buf.appendSlice(gpa, b) catch {};
        r.toss(b.len);
    }
    if (job.buf.items.len - job.cursor > job_unread_cap) {
        const drop = job.buf.items.len - job.cursor - job_unread_cap;
        job.buf.replaceRange(gpa, job.cursor, drop, &.{}) catch return;
        job.dropped = true;
    }
}

/// Pump task (one per job, on its own unit of concurrency): same MultiReader
/// loop as runCapped, but appending into the job buffer under the jobs mutex
/// and ignoring Esc — background jobs outlive turn cancellation by design.
fn jobPump(job: *Job, gpa: Allocator, io: Io) void {
    var mrb: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mrb.toStreams(), &.{ job.child.stdout.?, job.child.stderr.? });
    defer mr.deinit();
    const readers = [2]*Io.Reader{ mr.reader(0), mr.reader(1) };
    // The leader's pid, taken now: kill/wait reap the child and clear `id`.
    const pid: i32 = if (comptime posix_groups) (job.child.id orelse 0) else 0;
    var killed = false;
    var detached = false;
    loop: while (true) {
        mr.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break :loop,
            error.Timeout => {}, // poll tick: check for a kill request
            else => break :loop,
        };
        const now = nowMs(io);
        g_jobs.mutex.lockUncancelable(io);
        jobDrain(job, gpa, &readers, now);
        // #199: silence is the idle clock — no bytes, no read, no pin.
        const idle_ms: u64 = @intCast(@max(now - job.last_active_ms, 0));
        var warn = false;
        if (!job.kill_requested and !job.detach) {
            switch (job_idle.verdict(idle_ms, job.idle_warned, job.pinned)) {
                .none => {},
                .warn => {
                    job.idle_warned = true;
                    warn = true;
                },
                .stop => {
                    job.kill_requested = true;
                    job.stopped_idle = true;
                },
            }
        }
        killed = job.kill_requested;
        detached = job.detach;
        g_jobs.mutex.unlock(io);
        if (warn) job_idle.warn(io, job.id, idle_ms, job.cmd);
        if (killed or detached) break :loop;
    }
    g_jobs.mutex.lockUncancelable(io);
    jobDrain(job, gpa, &readers, nowMs(io)); // final drain of anything left at EOF/kill
    killed = killed or job.kill_requested;
    detached = detached or job.detach;
    g_jobs.mutex.unlock(io);
    var code: ?u8 = null;
    if (detached) {
        // Session end kept this pinned job: no kill, no wait. Its pipes now
        // drain into a detached cat and its record says retained (#199).
    } else if (killed) {
        // #198: take the whole process group down first — a job's grandchildren
        // (ssh, xcodebuild, codedb) survive a bare child.kill and are then
        // reparented to init, where they sleep on for days.
        if (comptime posix_groups) if (pid != 0) std.posix.kill(-pid, .KILL) catch {};
        job.child.kill(io); // also reaps (wait would assert afterwards)
    } else if (job.child.wait(io)) |term| {
        code = switch (term) {
            .exited => |c| c,
            else => null,
        };
    } else |_| {}
    g_jobs.mutex.lockUncancelable(io);
    job.exit_code = code;
    job.killed = killed and !detached;
    job.done = true;
    const id = job.id;
    const cmd = job.cmd;
    const quiet = job.quiet;
    const idle = job.stopped_idle;
    g_jobs.mutex.unlock(io);
    if (detached) return;
    if (pid != 0) job_registry.forget(io, job_registry.home, pid);
    if (!quiet) job_notify.record(io, id, code, killed, cmd, idle);
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// The leader's start identity (#413), so a recycled pid is never mistaken
/// for the job. 0 where the platform has no source.
fn startIdOf(io: Io, pid: i32) u64 {
    return switch (proc_identity.probe(io, pid)) {
        .id => |v| v,
        else => 0,
    };
}

/// Caller holds the mutex (or owns the job outright).
fn recordOf(io: Io, job: *Job) job_registry.Record {
    const pid: i32 = if (comptime posix_groups) (job.child.id orelse 0) else 0;
    return .{
        .pid = pid,
        .start_id = startIdOf(io, pid),
        .owner_pid = proc_identity.selfPid(),
        .owner_start_id = proc_identity.selfStartId(io),
        .cmd = job.cmd,
        .cwd = job.cwd orelse "",
        .started_ms = job.started_ms,
        .pinned = job.pinned,
    };
}

/// /jobs keep|unkeep (#199): exempt from the idle stop, retained at session
/// end. Null for an unknown id, false for one that already finished.
pub fn setPinned(io: Io, id: u32, pinned: bool) ?bool {
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    const job = g_jobs.find(id) orelse return null;
    if (job.done) return false;
    job.pinned = pinned;
    job.last_active_ms = nowMs(io);
    if (comptime posix_groups) job_registry.write(io, job_registry.home, recordOf(io, job));
    return true;
}

/// /jobs restart (#199): rerun a finished job's command in its cwd, as a new
/// job. The finished record stays listed until reaped.
pub fn restartJob(gpa: Allocator, io: Io, id: u32) !*Job {
    var cmd: []const u8 = "";
    var cwd: ?[]const u8 = null;
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        const job = g_jobs.find(id) orelse return error.NoSuchJob;
        if (!job.done) return error.StillRunning;
        cmd = job.cmd;
        cwd = job.cwd;
    }
    return spawnJobOpts(gpa, io, cmd, .{ .cwd = cwd });
}

/// Session end for a pinned job (#199): hand its pipes to a detached drainer
/// and keep its record, instead of killing it. False = kill it after all.
fn retainAtExit(io: Io, job: *Job) bool {
    if (comptime !posix_groups) return false;
    const rec = recordOf(io, job);
    if (!job_registry.retain(io, job_registry.home, rec, job.child.stdout, job.child.stderr)) return false;
    std.debug.print("kept alive: job {d} (pid {d}) {s} — `graff servers` lists it; `graff servers stop {d}` ends it\n", .{ job.id, rec.pid, job.cmd, rec.pid });
    return true;
}

pub fn shellArgv(cmd: []const u8) [3][]const u8 { // /bin/sh -c, or cmd.exe /c on Windows
    return if (builtin.os.tag == .windows)
        .{ "cmd.exe", "/c", cmd }
    else
        .{ "/bin/sh", "-c", cmd };
}

pub const SpawnOpts = struct {
    cwd: ?[]const u8 = null,
    stream: ?process_runner.StreamFn = null,
    stream_ctx: ?*anyopaque = null,
    quiet: bool = false,
};

pub fn spawnJob(gpa: Allocator, io: Io, cmd: []const u8) !*Job {
    return spawnJobOpts(gpa, io, cmd, .{});
}

pub fn spawnJobOpts(gpa: Allocator, io: Io, cmd: []const u8, opts: SpawnOpts) !*Job {
    const argv = shellArgv(cmd);
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .cwd = if (opts.cwd) |path| .{ .path = path } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (posix_groups) 0 else null, // #198: bash_kill reaches grandchildren
    });
    const cmd_copy = gpa.dupe(u8, cmd) catch |e| {
        child.kill(io);
        return e;
    };
    const job = gpa.create(Job) catch |e| {
        gpa.free(cmd_copy);
        child.kill(io);
        return e;
    };
    const cwd_copy: ?[]u8 = if (opts.cwd) |c| (gpa.dupe(u8, c) catch null) else null;
    job.* = .{
        .id = 0,
        .cmd = cmd_copy,
        .child = child,
        .stream = opts.stream,
        .stream_ctx = opts.stream_ctx,
        .quiet = opts.quiet,
        .cwd = cwd_copy,
        .started_ms = util.unixMs(io),
        .last_active_ms = nowMs(io),
    };
    g_jobs.mutex.lockUncancelable(io);
    job.id = g_jobs.next_id;
    g_jobs.next_id += 1;
    const appended = blk: {
        g_jobs.list.append(gpa, job) catch break :blk false;
        break :blk true;
    };
    g_jobs.mutex.unlock(io);
    if (!appended) {
        job.child.kill(io);
        if (job.cwd) |c| gpa.free(c);
        gpa.free(job.cmd);
        gpa.destroy(job);
        return error.OutOfMemory;
    }
    job.future = io.concurrent(jobPump, .{ job, gpa, io }) catch |e| {
        g_jobs.mutex.lockUncancelable(io);
        for (g_jobs.list.items, 0..) |j, i| {
            if (j == job) {
                _ = g_jobs.list.swapRemove(i);
                break;
            }
        }
        g_jobs.mutex.unlock(io);
        job.child.kill(io);
        if (job.cwd) |c| gpa.free(c);
        gpa.free(job.cmd);
        gpa.destroy(job);
        return e;
    };
    // #199: the ownership record outlives a graff that dies without its defers.
    if (comptime posix_groups) job_registry.write(io, job_registry.home, recordOf(io, job));
    return job;
}

/// bash_output: unread output + status. wait_ms=0 is a snapshot. wait_ms>0
/// blocks until the job exits (or Esc), not until the next byte (ADR 0010).
pub fn jobOutput(gpa: Allocator, io: Io, id: u32, wait_ms: u64) !ToolOutput {
    const deadline = job_wait.resolveDeadline(wait_ms);
    var waited: u64 = 0;
    var interrupted = false; // Esc: report what was waited, not the 10h cap (ADR 0061)
    var still = tool_pulse.Pulse{}; // #607: dim chrome per silence threshold; ADR 0010 keeps the wait single-hop
    while (true) {
        g_jobs.mutex.lockUncancelable(io);
        const job = g_jobs.find(id) orelse {
            g_jobs.mutex.unlock(io);
            return .{ .text = try std.fmt.allocPrint(gpa, "no background job {d} — it may never have started; /jobs lists them", .{id}), .is_error = true };
        };
        job.last_active_ms = nowMs(io); // a read or a blocking wait is activity (#199)
        const fresh = job.buf.items[job.cursor..];
        if (job.done or interrupted or waited >= deadline) {
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            if (!job.done) {
                try job_notify.printRunning(w, id, waited, interrupted);
            } else if (job.stopped_idle) {
                try job_idle.printStopped(w, id, job_idle.policy.stop_ms);
            } else if (job.killed) {
                try w.print("[job {d}: killed]", .{id});
            } else if (job.exit_code) |c| {
                try w.print("[job {d}: exited with code {d}]", .{ id, c });
            } else {
                try w.print("[job {d}: terminated abnormally]", .{id});
            }
            if (job.dropped) {
                try w.print("\n[oldest unread output was dropped at the {d} KB cap]", .{job_unread_cap / 1024});
                job.dropped = false;
            }
            if (fresh.len > 0) {
                try w.writeAll("\n");
                try w.writeAll(fresh);
            } else {
                try w.writeAll("\n(no new output)");
            }
            job.cursor = job.buf.items.len;
            if (job.done) job_notify.dismiss(io, id); // the exit was just read here; no wake for it (ADR 0061)
            g_jobs.mutex.unlock(io);
            return .{ .text = try aw.toOwnedSlice() };
        }
        g_jobs.mutex.unlock(io);
        if (Agent.esc_cancel.load(.acquire)) {
            interrupted = true; // render current state on the next pass
            continue;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            interrupted = true;
            continue;
        };
        waited += 100;
        if (still.due(waited)) job_notify.stillRunning(io, id, waited);
    }
}

/// bash_kill: flag the job and wait (bounded) for the pump to kill + reap it.
/// The pump's future is never awaited here — jobsReap owns it — so two
/// racing kills are harmless.
pub fn jobKill(gpa: Allocator, io: Io, id: u32) !ToolOutput {
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        const job = g_jobs.find(id) orelse return .{ .text = try std.fmt.allocPrint(gpa, "no background job {d} — /jobs lists them", .{id}), .is_error = true };
        if (job.done) {
            const unread = job.buf.items.len - job.cursor;
            return .{ .text = try std.fmt.allocPrint(gpa, "job {d} already finished ({d} unread byte(s) — bash_output reads them)", .{ id, unread }) };
        }
        job.kill_requested = true;
    }
    // The pump notices within one 200ms tick; give it a generous 2s.
    var waited: u64 = 0;
    while (waited < 2000) {
        g_jobs.mutex.lockUncancelable(io);
        const done = if (g_jobs.find(id)) |job| job.done else true;
        g_jobs.mutex.unlock(io);
        if (done) {
            g_jobs.mutex.lockUncancelable(io);
            defer g_jobs.mutex.unlock(io);
            const unread = if (g_jobs.find(id)) |job| job.buf.items.len - job.cursor else 0;
            job_notify.dismiss(io, id); // the model just learned the job is dead (ADR 0061)
            return .{ .text = try std.fmt.allocPrint(gpa, "job {d} killed ({d} unread byte(s) — bash_output reads them)", .{ id, unread }) };
        }
        io.sleep(.fromMilliseconds(100), .awake) catch break;
        waited += 100;
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "job {d}: kill requested (still shutting down — check bash_output)", .{id}) };
}

/// Outcome of a root foreground wait (#620 / grok-build auto-background).
pub const FgDone = struct { exit_code: ?u8, killed: bool, output: []u8, dropped: bool };
pub const FgPartial = struct { id: u32, output: []u8, dropped: bool };
pub const FgWait = union(enum) { done: FgDone, running: FgPartial, cancelled: FgPartial };

fn takeUnread(gpa: Allocator, job: *Job) error{OutOfMemory}!struct { []u8, bool } {
    job.stream = null;
    job.stream_ctx = null;
    const out = try gpa.dupe(u8, job.buf.items[job.cursor..]);
    job.cursor = job.buf.items.len;
    const dropped = job.dropped;
    job.dropped = false;
    return .{ out, dropped };
}

fn freeJob(gpa: Allocator, io: Io, job: *Job) void {
    job.future.await(io);
    job.buf.deinit(gpa);
    if (job.cwd) |c| gpa.free(c);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

pub fn reapFinished(gpa: Allocator, io: Io, id: u32) void {
    g_jobs.mutex.lockUncancelable(io);
    var found: ?*Job = null;
    for (g_jobs.list.items, 0..) |j, i| {
        if (j.id == id) {
            if (j.done) found = g_jobs.list.swapRemove(i);
            break;
        }
    }
    if (g_jobs.list.items.len == 0) {
        g_jobs.list.deinit(gpa);
        g_jobs.list = .empty;
    }
    g_jobs.mutex.unlock(io);
    if (found) |job| freeJob(gpa, io, job);
}

pub fn waitForeground(gpa: Allocator, io: Io, id: u32, wait_ms: u64) !FgWait {
    const deadline = if (wait_ms == 0) job_wait.wait_cap_ms else @min(wait_ms, job_wait.wait_cap_ms);
    var waited: u64 = 0;
    var still = tool_pulse.Pulse{};
    while (true) {
        g_jobs.mutex.lockUncancelable(io);
        const job = g_jobs.find(id) orelse {
            g_jobs.mutex.unlock(io);
            return error.NoSuchJob;
        };
        job.last_active_ms = nowMs(io); // the foreground wait is activity (#199)
        if (job.done) {
            const pair = takeUnread(gpa, job) catch {
                g_jobs.mutex.unlock(io);
                return error.OutOfMemory;
            };
            const result: FgWait = .{ .done = .{ .exit_code = job.exit_code, .killed = job.killed, .output = pair[0], .dropped = pair[1] } };
            g_jobs.mutex.unlock(io);
            return result;
        }
        if (waited >= deadline) {
            const pair = takeUnread(gpa, job) catch {
                g_jobs.mutex.unlock(io);
                return error.OutOfMemory;
            };
            job.quiet = false; // completion should now notify (#620)
            const result: FgWait = .{ .running = .{ .id = id, .output = pair[0], .dropped = pair[1] } };
            g_jobs.mutex.unlock(io);
            return result;
        }
        g_jobs.mutex.unlock(io);
        if (Agent.esc_cancel.load(.acquire)) {
            _ = jobKill(gpa, io, id) catch {};
            g_jobs.mutex.lockUncancelable(io);
            if (g_jobs.find(id)) |j| {
                const pair = takeUnread(gpa, j) catch {
                    g_jobs.mutex.unlock(io);
                    return error.OutOfMemory;
                };
                g_jobs.mutex.unlock(io);
                return .{ .cancelled = .{ .id = id, .output = pair[0], .dropped = pair[1] } };
            }
            g_jobs.mutex.unlock(io);
            return .{ .cancelled = .{ .id = id, .output = try gpa.dupe(u8, ""), .dropped = false } };
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            waited = deadline;
            continue;
        };
        waited += 100;
        if (still.due(waited)) {
            var ebuf: [16]u8 = undefined;
            tool_pulse.emitNotice(io, "· bash still running · {s}", .{tool_pulse.formatElapsed(&ebuf, waited)});
        }
    }
}

/// Session end: kill every job, await pumps, free. From main's defer.
pub fn jobsReap(gpa: Allocator, io: Io) void {
    g_jobs.mutex.lockUncancelable(io);
    const jobs = g_jobs.list.toOwnedSlice(gpa) catch {
        g_jobs.mutex.unlock(io);
        return;
    };
    for (jobs) |job| {
        // #199: a pinned, still-running job is kept, not killed — its pipes
        // go to a detached drainer, its record stays for `graff servers`.
        if (job.pinned and !job.done and retainAtExit(io, job)) job.detach = true else job.kill_requested = true;
    }
    g_jobs.mutex.unlock(io);
    for (jobs) |job| freeJob(gpa, io, job);
    gpa.free(jobs);
    g_jobs.list.deinit(gpa);
}

test { // split-out modules: unreferenced, their tests silently never run
    _ = worktree_cmd;
    _ = @import("worktree_lease.zig");
    _ = .{ job_wait, job_notify, job_idle, job_registry };
    _ = @import("jobs_tests.zig");
}
