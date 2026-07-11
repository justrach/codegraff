//! Subprocess execution: the capped-output runner (runCapped), git-worktree
//! management (`graff worktree` add/merge/remove + the -w auto-checkpoint
//! commits), and the background bash-job pool (spawn/output/kill/reap). Split
//! out of main.zig (600-line goal). Back-imports main for ToolOutput (the job
//! tools' result shape). main re-exports runCapped (hooks.zig back-imports it)
//! and aliases the worktree + job entry points back.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const ToolOutput = tools_mod.ToolOutput;

/// Commit-message trailer that credits the harness assist. The commit AUTHOR
/// stays the user's own git identity (their GitHub account) — graff never
/// overrides GIT_AUTHOR_*; codegraff is recorded as a co-author instead,
/// mirroring how Claude Code attributes commits.
const codegraff_coauthor = "Co-Authored-By: Codegraff <blackfloofie@codegraff.com>";
const Agent = agent_mod.Agent;

const CappedRun = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    timed_out: bool,
};

/// Like `std.process.run`, but hitting an output cap *truncates* instead of
/// failing the call: the first `cap` bytes are kept, the rest is discarded
/// as it streams (retained memory never exceeds the caps), and the child
/// still runs to completion so its exit code is real. A chatty `python`
/// (or an accidental `cat` of something huge) costs the child's own
/// process memory, never the harness's.
///
/// `deadline_ms` is a wall-clock kill switch: 0 means "no deadline" (the
/// root's Esc is the only stop), non-zero kills the child once it has run
/// that long and reports `timed_out`. Subagents pass a real deadline since
/// they have no Esc (#93).
pub fn runCapped(gpa: Allocator, io: Io, argv: []const []const u8, stdout_cap: usize, stderr_cap: usize, deadline_ms: u64) !CappedRun {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const readers = [2]*Io.Reader{ multi_reader.reader(0), multi_reader.reader(1) };
    const caps = [2]usize{ stdout_cap, stderr_cap };
    var saved: [2]?[]u8 = .{ null, null };
    errdefer for (saved) |s| if (s) |b| gpa.free(b);

    // Fill in 200ms ticks so a root Esc (Agent.esc_cancel, set by the
    // tool-join watcher) kills a long-running child instead of waiting it
    // out — this is where a hung `sleep`-style command actually dies. A
    // non-zero deadline_ms is the same kill switch on a wall clock, for
    // subagents that have no Esc to press (#93).
    var esc_killed = false;
    var timed_out = false;
    const t0: Io.Timestamp = .now(io, .awake);
    loop: while (true) {
        multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break :loop,
            error.Timeout => {}, // poll tick: no data, just check for cancel
            else => |e| return e,
        };
        for (readers, caps, &saved) |r, cap, *s| {
            const buf = r.buffered();
            if (s.* == null and buf.len > cap) s.* = try gpa.dupe(u8, buf[0..cap]);
            if (s.* != null) r.toss(buf.len); // past the cap: discard as it streams
        }
        if (Agent.esc_cancel.load(.acquire)) {
            esc_killed = true;
            child.kill(io);
            break :loop;
        }
        if (deadline_ms > 0 and t0.untilNow(io, .awake).toMilliseconds() >= deadline_ms) {
            timed_out = true;
            child.kill(io);
            break :loop;
        }
    }
    if (!esc_killed and !timed_out) try multi_reader.checkAnyError(); // killed streams error by design

    // kill() already reaped the child (wait would assert on id == null).
    const term: std.process.Child.Term = if (esc_killed or timed_out) .{ .signal = .TERM } else try child.wait(io);
    const stdout = if (saved[0]) |b| b else try gpa.dupe(u8, readers[0].buffered());
    errdefer gpa.free(stdout);
    const stderr = if (saved[1]) |b| b else try gpa.dupe(u8, readers[1].buffered());
    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = saved[0] != null,
        .stderr_truncated = saved[1] != null,
        .timed_out = timed_out,
    };
}

/// True if a CappedRun child exited cleanly (status 0).
fn ranOk(r: CappedRun) bool {
    return r.term == .exited and r.term.exited == 0;
}

/// True if the current git working tree has uncommitted *tracked* changes
/// (staged or unstaged). Untracked files (`?? …`) don't count — `git reset
/// --hard` leaves them alone, so they're safe around a worktree land.
fn gitTreeDirty(gpa: Allocator, io: Io) bool {
    const r = runCapped(gpa, io, &.{ "git", "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return false;
    var it = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len >= 2 and !std.mem.startsWith(u8, line, "??")) return true;
    }
    return false;
}

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
        const r = runCapped(gpa, io, &.{ "git", "worktree", "list" }, 1 << 16, 8192, 30_000) catch {
            try out.writeAll("not a git repository (no worktrees)\n");
            return;
        };
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (!ranOk(r)) {
            try out.writeAll(r.stderr);
            return;
        }
        try out.writeAll(r.stdout);
        return;
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
        if (gitTreeDirty(gpa, io)) {
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

    try out.print("unknown worktree command '{s}' — use: graff worktree list | graff worktree merge <name>\n", .{action});
}

/// One background bash job (`bash` with run_in_background:true). A pump task
/// continuously drains stdout+stderr into `buf` so the child never blocks on
/// a full pipe; bash_output returns the bytes past `cursor`; bash_kill stops
/// it. Jobs are session-global — they deliberately survive the turn (and the
/// Esc cancel) that started them — and are reaped at exit.
const Job = struct {
    id: u32,
    cmd: []u8, // gpa-owned, for /jobs display
    child: std.process.Child,
    buf: std.ArrayList(u8) = .empty, // interleaved stdout+stderr
    cursor: usize = 0, // start of unread output
    exit_code: ?u8 = null, // meaningful once done
    done: bool = false,
    killed: bool = false, // ended via bash_kill rather than naturally
    kill_requested: bool = false, // pump notices within one 200ms tick
    dropped: bool = false, // unread output overflowed job_unread_cap
    future: Io.Future(void) = undefined, // the pump; awaited only by jobsReap
};

const job_unread_cap = 256 * 1024;
const job_wait_cap_ms: u64 = 30_000;

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
    for (readers) |r| {
        const b = r.buffered();
        if (b.len == 0) continue;
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
    g_jobs.mutex.unlock(io);
}

/// Argv that runs a shell command string: `/bin/sh -c` on POSIX, `cmd.exe /c`
/// on Windows (which has no /bin/sh). The bash tool routes through this so the
/// model's shell commands run on every platform.
pub fn shellArgv(cmd: []const u8) [3][]const u8 {
    return if (builtin.os.tag == .windows)
        .{ "cmd.exe", "/c", cmd }
    else
        .{ "/bin/sh", "-c", cmd };
}

/// Spawn a background job and its pump. Uses io.concurrent (NOT io.async,
/// which may run inline and block this tool forever on a long-lived child);
/// no spare concurrency cleans up and surfaces the error to the model.
pub fn spawnJob(gpa: Allocator, io: Io, cmd: []const u8) !*Job {
    const argv = shellArgv(cmd);
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
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
    job.* = .{ .id = 0, .cmd = cmd_copy, .child = child };
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

/// bash_output: new output since the last read + status. With wait_ms > 0,
/// polls until new output, exit, Esc, or the (capped) deadline.
pub fn jobOutput(gpa: Allocator, io: Io, id: u32, wait_ms: u64) !ToolOutput {
    const deadline = @min(wait_ms, job_wait_cap_ms);
    var waited: u64 = 0;
    while (true) {
        g_jobs.mutex.lockUncancelable(io);
        const job = g_jobs.find(id) orelse {
            g_jobs.mutex.unlock(io);
            return .{ .text = try std.fmt.allocPrint(gpa, "no background job {d} — it may never have started; /jobs lists them", .{id}), .is_error = true };
        };
        const fresh = job.buf.items[job.cursor..];
        if (fresh.len > 0 or job.done or waited >= deadline) {
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            if (!job.done) {
                try w.print("[job {d}: running]", .{id});
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
            g_jobs.mutex.unlock(io);
            return .{ .text = try aw.toOwnedSlice() };
        }
        g_jobs.mutex.unlock(io);
        if (Agent.esc_cancel.load(.acquire)) {
            waited = deadline; // render current state on the next pass
            continue;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            waited = deadline;
            continue;
        };
        waited += 100;
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
            return .{ .text = try std.fmt.allocPrint(gpa, "job {d} killed ({d} unread byte(s) — bash_output reads them)", .{ id, unread }) };
        }
        io.sleep(.fromMilliseconds(100), .awake) catch break;
        waited += 100;
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "job {d}: kill requested (still shutting down — check bash_output)", .{id}) };
}

/// Session end: kill every job, await the pumps (sole owner of the futures),
/// free everything. Runs from main's defer, after the REPL/one-shot returns.
pub fn jobsReap(gpa: Allocator, io: Io) void {
    g_jobs.mutex.lockUncancelable(io);
    const jobs = g_jobs.list.toOwnedSlice(gpa) catch {
        g_jobs.mutex.unlock(io);
        return;
    };
    for (jobs) |job| job.kill_requested = true;
    g_jobs.mutex.unlock(io);
    for (jobs) |job| {
        job.future.await(io);
        job.buf.deinit(gpa);
        gpa.free(job.cmd);
        gpa.destroy(job);
    }
    gpa.free(jobs);
    g_jobs.list.deinit(gpa);
}
