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

/// `runCapped` with an explicit cwd (#276: per-spawn, never process-wide chdir).
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
        .environ_map = @import("tool_env.zig").get(), // #1267: no provider keys
        .kill_process_tree = true,
    };
}

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

pub const Job = struct { // session-global; pump drains pipes or capture files; survives Esc
    id: u64,
    cmd: []u8,
    child: std.process.Child,
    // #199 idle lifecycle + ownership record (job_idle.zig, job_registry.zig)
    cwd: ?[]u8 = null, // owned copy: /jobs restart reruns in the same place
    started_ms: i64 = 0, // unix ms, for age columns and the record
    last_active_ms: i64 = 0, // awake ms: last output byte, read, wait tick, or pin
    browser_probe_after_ms: i64 = 0,
    activity_revision: i64 = 0,
    group_pid: i32 = 0,
    exit_cleanup: bool = false,
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
    persistent: bool = false, // started with run_in_background (#810)
    parked: bool = false, // #1486: a parked foreground command keeps a record of its outcome
    future: Io.Future(void) = undefined,
    stream: ?process_runner.StreamFn = null,
    stream_ctx: ?*anyopaque = null,
    capture: ?*job_capture.Capture = null, // ADR 0218: output in files, not pipes
};

pub const job_unread_cap = 256 * 1024;
const job_wait = @import("job_wait.zig");
const job_notify = @import("job_notify.zig");
const browser_guard = @import("job_browser_guard.zig");
const job_idle = @import("job_idle.zig"); // #199
const job_registry = @import("job_registry.zig"); // #199
const job_capture = @import("job_capture.zig"); // ADR 0218
const job_parked = @import("job_parked.zig"); // #1486
const proc_identity = @import("proc_identity.zig");
const util = @import("util.zig");
const tool_pulse = @import("tool_pulse.zig"); // silence heartbeat during waitForeground

/// POSIX process groups; windows/wasi have none, so the group kills below and
/// the job's own pgid are compiled out there (#198).
const posix_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const Jobs = struct {
    mutex: Io.Mutex = .init,
    list: std.ArrayList(*Job) = .empty,

    /// Caller holds the mutex.
    pub fn find(self: *Jobs, id: u64) ?*Job {
        for (self.list.items) |j| if (j.id == id) return j;
        return null;
    }
};

pub var g_jobs: Jobs = .{};

/// #1486: the foreground wait parked this job; record it so its handle
/// keeps an answer after this graff is gone.
pub fn markParked(io: Io, id: u64) void {
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    const job = g_jobs.find(id) orelse return;
    job.parked = true;
    job_parked.begin(io, job.id, job.cmd);
}

pub fn markPersistent(io: Io, id: u64) void {
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    if (g_jobs.find(id)) |job| job.persistent = true;
}

/// Deterministic test pause after done becomes observable, before UI publish.
pub var completion_test_hook: ?*const fn (Io, u64) void = null;

/// New output into the job buffer (both pumps). Caller holds the mutex.
pub fn appendOutput(job: *Job, gpa: Allocator, which: u8, bytes: []const u8, now_ms: i64) void {
    if (bytes.len == 0) return;
    if (!job.persistent) browser_guard.touch(job, now_ms);
    if (job.stream) |emit| emit(job.stream_ctx, which, bytes);
    job.buf.appendSlice(gpa, bytes) catch {};
}

/// Drop the oldest unread output past the cap. Caller holds the mutex.
pub fn capUnread(job: *Job, gpa: Allocator) void {
    if (job.buf.items.len - job.cursor <= job_unread_cap) return;
    const drop = job.buf.items.len - job.cursor - job_unread_cap;
    job.buf.replaceRange(gpa, job.cursor, drop, &.{}) catch return;
    job.dropped = true;
}

/// Drain MultiReader bytes into the job buffer; drop oldest unread past the cap.
fn jobDrain(job: *Job, gpa: Allocator, readers: []const *Io.Reader, now_ms: i64) void {
    for (readers, 0..) |r, i| {
        const b = r.buffered();
        appendOutput(job, gpa, @intCast(i), b, now_ms);
        r.toss(b.len);
    }
    capUnread(job, gpa);
}

/// #199: silence is the idle clock — no bytes, no read, no pin. Caller holds
/// the mutex. Returns the idle time when the warning is due; print it after
/// unlocking.
pub fn idleTick(job: *Job, gpa: Allocator, io: Io, pid: i32, now: i64) ?u64 {
    if (job.kill_requested or job.detach or job.exit_cleanup) return null;
    const idle_ms: u64 = @intCast(@max(now - job.last_active_ms, 0));
    switch (job_idle.verdict(idle_ms, job.idle_warned, job.pinned)) {
        .none => {},
        .warn => {
            job.idle_warned = true;
            return idle_ms;
        },
        .stop => browser_guard.checkIdle(&g_jobs, job, gpa, io, pid, now),
    }
    return null;
}

/// Pump task (one per job, on its own unit of concurrency): same MultiReader
/// loop as runCapped, but appending into the job buffer under the jobs mutex
/// and ignoring Esc — background jobs outlive turn cancellation by design.
fn jobPump(job: *Job, gpa: Allocator, io: Io) void {
    if (comptime job_capture.enabled) if (job.capture != null) return @import("job_durable.zig").pump(job, gpa, io);
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
        const warn = idleTick(job, gpa, io, pid, now);
        killed = job.kill_requested;
        detached = job.detach;
        g_jobs.mutex.unlock(io);
        if (warn) |idle_ms| job_idle.warn(io, job.id, idle_ms, job.cmd);
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
    finish(job, io, code, killed, detached, pid);
}

/// A job ended (both pumps). Done + queue publish atomically against
/// jobOutput/jobKill consuming it: a bounded dismissed-id cache cannot close
/// a queue-after-unlock race. A detached job publishes nothing.
pub fn finish(job: *Job, io: Io, code: ?u8, killed: bool, detached: bool, pid: i32) void {
    g_jobs.mutex.lockUncancelable(io);
    job.exit_code = code;
    job.killed = killed and !detached;
    job.done = true;
    const id = job.id;
    const quiet = job.quiet;
    const idle = job.stopped_idle;
    if (!quiet and !detached) job_notify.queue(io, id, code, killed, job.cmd, idle, job.buf.items[job.cursor..]);
    g_jobs.mutex.unlock(io);
    if (detached) return;
    if (builtin.is_test) if (completion_test_hook) |hook| hook(io, id);
    if (pid != 0) job_registry.forget(io, job_registry.home, pid);
    if (!quiet) job_notify.publish(io, id, code, killed);
}

/// The model just learned how the job ended: no wake for it (ADR 0061), and
/// no second report after a restart (ADR 0218). Caller holds the mutex.
fn consumed(io: Io, job: *Job) void {
    job_notify.dismiss(io, job.id);
    if (job.capture) |c| job_capture.markReported(io, c);
}

/// A completion notice reached the model (job_notify drain, ADR 0218).
pub fn markReported(io: Io, id: u64) void {
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    const job = g_jobs.find(id) orelse return;
    if (job.capture) |c| job_capture.markReported(io, c);
}

pub fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

const admin = @import("jobs_admin.zig");
pub const setPinned = admin.setPinned;
pub const restartJob = admin.restartJob;

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
    persistent: bool = false,
    /// ADR 0218: the session a finite job reports back to after a restart.
    /// Non-empty puts its output in files that outlive graff.
    session: []const u8 = "",
};

pub fn spawnJob(gpa: Allocator, io: Io, cmd: []const u8) !*Job {
    return spawnJobOpts(gpa, io, cmd, .{});
}

pub fn spawnJobOpts(gpa: Allocator, io: Io, cmd: []const u8, opts: SpawnOpts) !*Job {
    const id = try @import("shell_identity.zig").forJob(io);
    var setup: ?job_capture.Setup = null; // best-effort: pipes without it
    if (comptime job_capture.enabled) {
        if (opts.session.len > 0 and !opts.persistent) setup = job_capture.prepare(io, gpa, id, cmd);
    }
    const sh = shellArgv(cmd);
    const argv: []const []const u8 = if (setup) |*s| &s.argv else &sh;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = @import("tool_env.zig").get(), // #1267: no provider keys
        .stdin = .ignore,
        .stdout = if (setup) |s| .{ .file = s.out } else .pipe,
        .stderr = if (setup) |s| .{ .file = s.err } else .pipe,
        .pgid = if (posix_groups) 0 else null, // #198: bash_kill reaches grandchildren
    }) catch |e| {
        if (setup) |*s| s.abandon(gpa, io);
        return e;
    };
    const capture: ?*job_capture.Capture = if (setup) |*s| blk: {
        s.spawned(gpa, io);
        break :blk s.capture;
    } else null;
    const cmd_copy = gpa.dupe(u8, cmd) catch |e| {
        abortSpawn(gpa, io, &child, capture);
        return e;
    };
    const job = gpa.create(Job) catch |e| {
        gpa.free(cmd_copy);
        abortSpawn(gpa, io, &child, capture);
        return e;
    };
    const cwd_copy: ?[]u8 = if (opts.cwd) |c| (gpa.dupe(u8, c) catch null) else null;
    job.* = .{
        .id = 0,
        .cmd = cmd_copy,
        .child = child,
        .group_pid = if (comptime posix_groups) (child.id orelse 0) else 0,
        .stream = opts.stream,
        .stream_ctx = opts.stream_ctx,
        .quiet = opts.quiet,
        .persistent = opts.persistent,
        .cwd = cwd_copy,
        .started_ms = util.unixMs(io),
        .last_active_ms = nowMs(io),
        .capture = capture,
    };
    g_jobs.mutex.lockUncancelable(io);
    job.id = id;
    const appended = blk: {
        g_jobs.list.append(gpa, job) catch break :blk false;
        break :blk true;
    };
    g_jobs.mutex.unlock(io);
    if (!appended) {
        abortSpawn(gpa, io, &job.child, capture);
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
        abortSpawn(gpa, io, &job.child, capture);
        if (job.cwd) |c| gpa.free(c);
        gpa.free(job.cmd);
        gpa.destroy(job);
        return e;
    };
    // #199: the ownership record outlives a graff that dies without its defers.
    if (comptime posix_groups) job_registry.write(io, job_registry.home, admin.recordOf(io, job));
    if (capture) |c| @import("job_durable.zig").record(io, job, c, opts.session);
    return job;
}

/// A spawned job that never joined the pool: stop its group (#198), drop
/// its capture.
fn abortSpawn(gpa: Allocator, io: Io, child: *std.process.Child, capture: ?*job_capture.Capture) void {
    if (comptime posix_groups) if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
    child.kill(io); // reaps the leader (a zombie by now accepts the TERM)
    if (capture) |c| job_capture.release(gpa, io, c, true);
}

/// bash_output: unread output + status. wait_ms=0 is a snapshot. wait_ms>0
/// blocks until the job exits (or Esc) for finite jobs (ADR 0010). Persistent
/// servers snapshot immediately; wait_ms is ignored (ADR 0152).
pub fn jobOutput(gpa: Allocator, io: Io, id: u64, wait_ms: u64) !ToolOutput {
    var waited: u64 = 0;
    var interrupted = false; // Esc: report what was waited, not the 10h cap (ADR 0061)
    var still = tool_pulse.Pulse{ .interval_ms = 15_000 }; // #807: pulse often enough to tell hang from work
    var unread: usize = 0;
    while (true) {
        g_jobs.mutex.lockUncancelable(io);
        const job = g_jobs.find(id) orelse {
            g_jobs.mutex.unlock(io);
            if (job_parked.describe(gpa, io, id)) |known| return .{ .text = known.text, .is_error = known.is_error };
            return .{ .text = try std.fmt.allocPrint(gpa, "background job {d} has no live owner in this process — interrupted or unknown outcome; do not assume it never ran or rerun it automatically; /jobs lists current jobs", .{id}), .is_error = true };
        };
        browser_guard.touch(job, nowMs(io)); // a read or a blocking wait is activity (#199)
        const deadline = job_wait.resolveDeadlineFor(wait_ms, job.persistent);
        unread = job.buf.items.len - job.cursor;
        const fresh = job.buf.items[job.cursor..];
        if (job.done or interrupted or waited >= deadline) {
            errdefer g_jobs.mutex.unlock(io);
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            if (!job.done) {
                try job_notify.printRunning(w, id, waited, interrupted, job.persistent);
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
            const text = try aw.toOwnedSlice();
            job.cursor = job.buf.items.len;
            if (job.done) consumed(io, job); // the exit was just read here
            const result: ToolOutput = .{ .text = text, .pending = !job.done, .is_error = job.done and (job.stopped_idle or job.killed or (job.exit_code orelse 1) != 0), .cancelled = job.killed };
            g_jobs.mutex.unlock(io);
            return result;
        }
        g_jobs.mutex.unlock(io);
        // #1522 (ADR 0262): a queued follow-up ends the wait the way it
        // promotes a foreground one — the job keeps running, the user is heard.
        if (Agent.esc_cancel.load(.acquire) or job_wait.followup_pending.load(.acquire)) {
            interrupted = true; // render current state on the next pass
            continue;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            interrupted = true;
            continue;
        };
        waited += 100;
        if (still.due(waited)) job_notify.stillRunning(io, id, waited, unread);
    }
}

/// bash_kill: flag the job and wait (bounded) for the pump to kill + reap it.
/// The pump's future is never awaited here — jobsReap owns it — so two
/// racing kills are harmless.
pub fn jobKill(gpa: Allocator, io: Io, id: u64) !ToolOutput {
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        const job = g_jobs.find(id) orelse {
            if (job_parked.describe(gpa, io, id)) |known| return .{ .text = known.text, .is_error = known.is_error };
            return .{ .text = try std.fmt.allocPrint(gpa, "background job {d} has no live owner in this process — interrupted or unknown outcome; no process was stopped; /jobs lists current jobs", .{id}), .is_error = true };
        };
        if (job.done) {
            consumed(io, job); // already-finished also reports the exit
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
            const found = g_jobs.find(id);
            const unread = if (found) |job| job.buf.items.len - job.cursor else 0;
            if (found) |job| consumed(io, job) else job_notify.dismiss(io, id); // the model just learned the job is dead
            return .{ .text = try std.fmt.allocPrint(gpa, "job {d} killed ({d} unread byte(s) — bash_output reads them)", .{ id, unread }) };
        }
        io.sleep(.fromMilliseconds(100), .awake) catch break;
        waited += 100;
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "job {d}: kill requested (still shutting down — check bash_output)", .{id}) };
}

const job_foreground = @import("job_foreground.zig");
pub const FgDone = job_foreground.FgDone;
pub const FgPartial = job_foreground.FgPartial;
pub const FgWait = job_foreground.FgWait;
pub const waitForeground = job_foreground.waitForeground;

fn freeJob(gpa: Allocator, io: Io, job: *Job) void {
    job.future.await(io);
    if (job.parked) job_parked.finish(io, job.id, job.cmd, .{ .exit_code = job.exit_code, .done = job.done, .killed = job.killed, .session_end = job.exit_cleanup, .unread = job.buf.items[job.cursor..] });
    // A kept job still writes to its capture: a later resume re-attaches it.
    if (job.capture) |c| job_capture.release(gpa, io, c, !job.detach);
    job.buf.deinit(gpa);
    if (job.cwd) |c| gpa.free(c);
    gpa.free(job.cmd);
    gpa.destroy(job);
}

pub fn reapFinished(gpa: Allocator, io: Io, id: u64) void {
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

pub fn jobsReap(gpa: Allocator, io: Io) void {
    g_jobs.mutex.lockUncancelable(io);
    const jobs = g_jobs.list.toOwnedSlice(gpa) catch {
        g_jobs.mutex.unlock(io);
        return;
    };
    for (jobs) |job| job.exit_cleanup = true;
    g_jobs.mutex.unlock(io);
    for (jobs) |job| {
        const result = browser_guard.probe(gpa, io, job.group_pid);
        g_jobs.mutex.lockUncancelable(io);
        if (!job.done and !job.kill_requested) {
            if (browser_guard.exitAction(result, job.pinned, false) != .stop) {
                job.detach = browser_guard.exitAction(result, job.pinned, admin.retainAtExit(io, job)) == .detach;
                if (!job.detach) std.debug.print("retained job pipe handoff failed; cleanup waits while the pump keeps draining (no kill)\n", .{});
            } else job.kill_requested = true;
        }
        g_jobs.mutex.unlock(io);
    }
    for (jobs) |job| freeJob(gpa, io, job);
    gpa.free(jobs);
    // toOwnedSlice already emptied the pool; deinit would poison reuse.
    _ = @import("sim_ledger.zig").g.release(gpa, io); // #407: after the jobs that may use them
}

test { // split-out modules: unreferenced, their tests silently never run
    _ = worktree_cmd;
    _ = @import("worktree_lease.zig");
    _ = .{ job_wait, job_notify, job_idle, job_registry, browser_guard, job_capture };
    _ = @import("job_durable.zig");
    _ = job_parked;
    _ = @import("job_recover.zig");
    _ = @import("jobs_tests.zig");
}
