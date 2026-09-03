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

/// Commit-message trailer that credits the harness assist. The commit AUTHOR
/// stays the user's own git identity (their GitHub account) — graff never
/// overrides GIT_AUTHOR_*; codegraff is recorded as a co-author instead,
/// mirroring how Claude Code attributes commits.
const codegraff_coauthor = "Co-Authored-By: Codegraff <blackfloofie@codegraff.com>";
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

// #112 (list age column + `prune --older-than`) and #320 (canonical worktree
// identity) live in their own modules: jobs.zig is at the 600-line cap.
const worktree_prune = @import("worktree_prune.zig");

/// Per-turn checkpoint commit for `-w` sessions. The worktree branch is a
/// throwaway scratch branch, so committing every turn is free and gives durable
/// rewind points across restarts; `graff worktree merge` later --squashes the
/// whole trail into one clean commit. No-op outside a worktree or under
/// --no-autocommit. Best-effort: a clean tree (nothing to commit) or a missing
/// git identity just means no commit this turn, never a failed turn. --no-verify
/// so a slow or strict pre-commit hook can't block a checkpoint.
pub fn worktreeAutoCommit(gpa: Allocator, io: Io, msg: []const u8) void {
    if (root.g_worktree_branch == null or !root.g_worktree_autocommit) return;
    // Stage everything except graff's own runtime artifacts — trace/trajectory/
    // sessions/keys/MCP config must never ride into the squash-merge onto the
    // user's branch. .gitignore hides these in the graff repo, but a *target*
    // repo (the swarm's real use case) won't, so exclude them explicitly here.
    const add = runCapped(gpa, io, &.{
        "git",                       "add",
        "-A",                        "--",
        ":(exclude).graff",          ":(exclude).harness",
        ":(exclude)harness.*.jsonl", ":(exclude)*.session.json",
        ":(exclude).mcp.json",       ":(exclude).simple-harness-*",
    }, 4096, 4096, 30_000) catch return;
    gpa.free(add.stdout);
    gpa.free(add.stderr);
    // Author stays the user's git identity; codegraff rides as a co-author trailer.
    const full = std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ msg, codegraff_coauthor }) catch msg;
    defer if (full.ptr != msg.ptr) gpa.free(full);
    const c = runCapped(gpa, io, &.{ "git", "commit", "--no-verify", "-m", full }, 8192, 8192, 30_000) catch return;
    gpa.free(c.stdout);
    gpa.free(c.stderr);
}

/// `graff worktree <list|merge <name>>` — manage the per-tab scratch worktrees
/// that `-w` creates. `list` shows them; `merge <name>` squash-merges
/// worktree-<name> into the current branch as one clean commit, then removes the
/// worktree and deletes its branch. Run from the main checkout.
pub fn worktreeCommand(gpa: Allocator, io: Io, arena: Allocator, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    const action = if (args.len > 0) args[0] else "list";

    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "ls")) {
        return worktree_prune.listWithAge(gpa, io, arena, out);
    }

    if (std.mem.eql(u8, action, "merge")) {
        if (args.len < 2) {
            try out.writeAll("usage: graff worktree merge <name>\n");
            return;
        }
        const name = args[1];
        const wt_path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{name});
        const wt_branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{name});

        // Refuse to land into a dirty tree: the conflict-recovery below resets
        // tracked files, which would eat uncommitted work. Untracked files (the
        // worktrees, traces) are fine — reset --hard leaves them be.
        if (worktree_prune.treeDirty(gpa, io)) {
            try out.print("✗ your working tree has uncommitted changes — commit or stash them first, then `graff worktree merge {s}`\n", .{name});
            return;
        }

        // 1) squash-merge the scratch branch into the current branch (staged, not committed).
        const m = runCapped(gpa, io, &.{ "git", "merge", "--squash", wt_branch }, 1 << 16, 1 << 16, 60_000) catch {
            try out.writeAll("✗ could not run git merge (is this a git repository?)\n");
            return;
        };
        const merged = ranOk(m);
        gpa.free(m.stdout);
        gpa.free(m.stderr);
        if (!merged) {
            // Overlapping changes. A --squash merge leaves the index/worktree
            // half-merged with no MERGE_HEAD to --abort, so restore the branch to
            // clean ourselves (safe — we verified it was clean above) and leave
            // the worktree intact for the user to land another way.
            if (runCapped(gpa, io, &.{ "git", "reset", "--hard", "HEAD" }, 8192, 8192, 30_000)) |r| {
                gpa.free(r.stdout);
                gpa.free(r.stderr);
            } else |_| {}
            try out.print("✗ couldn't auto-land {s} — it overlaps changes already on this branch.\n  current branch left clean, worktree intact. Land it first, or merge by hand: git merge {s}\n", .{ wt_branch, wt_branch });
            return;
        }

        // 2) commit the squashed result as one clean commit on the current branch.
        const cmsg = std.fmt.allocPrint(arena, "{s}: land worktree\n\n{s}", .{ name, codegraff_coauthor }) catch "land worktree";
        const c = runCapped(gpa, io, &.{ "git", "commit", "--no-verify", "-m", cmsg }, 8192, 8192, 30_000) catch {
            try out.writeAll("✗ git commit failed — worktree left intact\n");
            return;
        };
        const committed = ranOk(c);
        gpa.free(c.stdout);
        gpa.free(c.stderr);
        if (!committed) {
            try out.print("⚠ nothing to land from {s} (empty or already merged) — worktree left intact\n", .{wt_branch});
            return;
        }

        // 3) clean up: remove the worktree dir, then delete its now-free branch.
        if (runCapped(gpa, io, &.{ "git", "worktree", "remove", "--force", wt_path }, 8192, 8192, 30_000)) |r| {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        } else |_| {}
        if (runCapped(gpa, io, &.{ "git", "branch", "-D", wt_branch }, 8192, 8192, 30_000)) |r| {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        } else |_| {}

        try out.print("✓ landed {s} → current branch as one commit, removed the worktree\n", .{wt_branch});
        return;
    }

    if (std.mem.eql(u8, action, "remove") or std.mem.eql(u8, action, "rm")) {
        if (args.len < 2) {
            try out.writeAll("usage: graff worktree remove <name>\n");
            return;
        }
        const name = args[1];
        const wt_path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{name});
        const wt_branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{name});
        // --force: discard any uncommitted scratch work — the whole point of
        // `remove` is to throw away an abandoned tab (#112).
        const rm = runCapped(gpa, io, &.{ "git", "worktree", "remove", "--force", wt_path }, 8192, 8192, 30_000) catch {
            try out.print("✗ could not remove {s} (not a git repository, or no such worktree)\n", .{wt_path});
            return;
        };
        defer {
            gpa.free(rm.stdout);
            gpa.free(rm.stderr);
        }
        if (!ranOk(rm)) {
            try out.print("✗ couldn't remove {s}: {s}", .{ wt_path, rm.stderr });
            return;
        }
        // -D (force) so an unmerged scratch branch is still deleted.
        if (runCapped(gpa, io, &.{ "git", "branch", "-D", wt_branch }, 8192, 8192, 30_000)) |r| {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        } else |_| {}
        try out.print("✓ removed {s} and branch {s}\n", .{ wt_path, wt_branch });
        return;
    }

    if (std.mem.eql(u8, action, "prune")) {
        // Drops git's registrations for worktrees whose dirs were deleted out of
        // band, and with `older-than <days>` the stale DIRECTORIES too (#112).
        return worktree_prune.pruneCommand(gpa, io, arena, out, args[1..]);
    }

    try out.print("unknown worktree command '{s}' — use: graff worktree list | merge <name> | remove <name> | prune [older-than <days>]\n", .{action});
}

const Job = struct { // session-global; pump drains pipes; survives Esc
    id: u32,
    cmd: []u8,
    child: std.process.Child,
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
fn jobDrain(job: *Job, gpa: Allocator, readers: []const *Io.Reader) void {
    for (readers, 0..) |r, i| {
        const b = r.buffered();
        if (b.len == 0) continue;
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
    var killed = false;
    loop: while (true) {
        mr.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break :loop,
            error.Timeout => {}, // poll tick: check for a kill request
            else => break :loop,
        };
        g_jobs.mutex.lockUncancelable(io);
        jobDrain(job, gpa, &readers);
        killed = job.kill_requested;
        g_jobs.mutex.unlock(io);
        if (killed) break :loop;
    }
    g_jobs.mutex.lockUncancelable(io);
    jobDrain(job, gpa, &readers); // final drain of anything left at EOF/kill
    killed = killed or job.kill_requested;
    g_jobs.mutex.unlock(io);
    var code: ?u8 = null;
    if (killed) {
        // #198: take the whole process group down first — a job's grandchildren
        // (ssh, xcodebuild, codedb) survive a bare child.kill and are then
        // reparented to init, where they sleep on for days.
        if (comptime posix_groups) if (job.child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
        job.child.kill(io); // also reaps (wait would assert afterwards)
    } else if (job.child.wait(io)) |term| {
        code = switch (term) {
            .exited => |c| c,
            else => null,
        };
    } else |_| {}
    g_jobs.mutex.lockUncancelable(io);
    job.exit_code = code;
    job.killed = killed;
    job.done = true;
    const id = job.id;
    const cmd = job.cmd;
    const quiet = job.quiet;
    g_jobs.mutex.unlock(io);
    if (!quiet) job_notify.record(io, id, code, killed, cmd);
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
    job.* = .{ .id = 0, .cmd = cmd_copy, .child = child, .stream = opts.stream, .stream_ctx = opts.stream_ctx, .quiet = opts.quiet };
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
        gpa.free(job.cmd);
        gpa.destroy(job);
        return e;
    };
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
        const fresh = job.buf.items[job.cursor..];
        if (job.done or interrupted or waited >= deadline) {
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            if (!job.done) {
                try job_notify.printRunning(w, id, waited, interrupted);
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
    for (jobs) |job| job.kill_requested = true;
    g_jobs.mutex.unlock(io);
    for (jobs) |job| freeJob(gpa, io, job);
    gpa.free(jobs);
    g_jobs.list.deinit(gpa);
}

test { // split-out modules: unreferenced, their tests silently never run
    _ = worktree_prune;
    _ = @import("worktree_lease.zig");
    _ = .{ job_wait, job_notify };
    _ = @import("jobs_tests.zig");
}
