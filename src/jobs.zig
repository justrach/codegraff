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
const process_runner = @import("process_runner.zig");
pub const CappedRun = process_runner.CappedRun;
pub const CappedRunOptions = process_runner.CappedRunOptions;
pub const runCapped = process_runner.runCapped;
pub const runCappedWithOptions = process_runner.runCappedWithOptions;
const ranOk = process_runner.ranOk;

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

// ── Per-agent worktree isolation (#276 P0-1) ────────────────────────────────
// Extends the session-level `-w`/`graff worktree` mechanism (above) down to
// one worktree per fanned-out subagent, opt-in via `isolation:"worktree"` on
// a subagent/workflow-task spawn (see subagent.zig's `runSub`, fleet.zig's
// `resolveIsolation`). The critical difference from `-w`: nothing here ever
// chdirs the process. `agentWorktreeCreate` returns an absolute path that the
// caller threads through as the child `Agent`'s `agent_cwd` → `ToolCtx.agent_cwd`
// → per-tool-call `bash` cwd / file-op path prefix, so parallel siblings on the
// same pool each keep their own working tree with no shared-state race.

/// One agent's scratch worktree: an absolute path (resolved once at creation,
/// since every later use — bash cwd, file-op path join, `git -C` for status/
/// removal — runs from a pool thread that never chdirs) and its branch name.
pub const AgentWorktree = struct { path: []const u8, branch: []const u8 };

pub const AgentWorktreeError = error{ NotAGitRepo, CreateFailed };

/// User-facing explanation for a failed `isolation:"worktree"` request (#276
/// design point 5: "non-git repo → explicit, friendly error"). Takes `anyerror`
/// (not `AgentWorktreeError`) so the caller — catching the wider error set
/// `agentWorktreeCreate` actually returns (it's `Allocator.Error`-fallible too)
/// — never has to narrow the value first; unrecognized errors still get a
/// sensible fallback message instead of failing to compile/format.
pub fn isolationFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepo => "isolation:\"worktree\" requested but this isn't a git repository (or `git` isn't on PATH) — worktrees need a git repo; drop isolation, or set isolation_fallback:true to run in the shared working tree instead",
        error.CreateFailed => "isolation:\"worktree\" requested but `git worktree add` failed (dirty HEAD, a name collision, or a git error) — set isolation_fallback:true to run in the shared working tree instead, or retry",
        else => "isolation:\"worktree\" requested but setup failed — set isolation_fallback:true to run in the shared working tree instead, or retry",
    };
}

/// Deterministic name generator, kept separate from the git calls below so
/// it's unit-testable without a real `Io`: `.graff/worktrees/agent-<id>` on
/// branch `graff/agents/<id>`, `id = "<sub_id>-<nonce>"`. `sub_id` is already
/// unique within one `graff` process (subagentId's monotonic ordinal); the
/// caller-supplied `nonce` (fresh randomness from `io.random`, hex-encoded)
/// covers the cross-process case too — two concurrent `graff` invocations in
/// the same repo whose own per-process counters happen to line up still never
/// collide on a path or branch name.
pub fn agentWorktreeNames(arena: Allocator, sub_id: []const u8, nonce: []const u8) !AgentWorktree {
    return .{
        .path = try std.fmt.allocPrint(arena, ".graff/worktrees/agent-{s}-{s}", .{ sub_id, nonce }),
        .branch = try std.fmt.allocPrint(arena, "graff/agents/{s}-{s}", .{ sub_id, nonce }),
    };
}

/// Create a scratch git worktree, branched from HEAD, for one fanned-out
/// subagent. `error.NotAGitRepo` when the target isn't a git repository at
/// all (or `git` isn't on PATH); `error.CreateFailed` for anything else
/// `git worktree add` rejects.
pub fn agentWorktreeCreate(gpa: Allocator, io: Io, arena: Allocator, sub_id: []const u8) (AgentWorktreeError || Allocator.Error)!AgentWorktree {
    const probe = runCapped(gpa, io, &.{ "git", "rev-parse", "--is-inside-work-tree" }, 4096, 4096, 15_000) catch return error.NotAGitRepo;
    defer {
        gpa.free(probe.stdout);
        gpa.free(probe.stderr);
    }
    if (!ranOk(probe)) return error.NotAGitRepo;

    var raw: [4]u8 = undefined;
    io.random(&raw);
    const nonce = std.fmt.bytesToHex(raw, .lower);
    const names = try agentWorktreeNames(arena, sub_id, &nonce);
    const add = runCapped(gpa, io, &.{ "git", "worktree", "add", names.path, "-b", names.branch }, 8192, 8192, 60_000) catch return error.CreateFailed;
    defer {
        gpa.free(add.stdout);
        gpa.free(add.stderr);
    }
    if (!ranOk(add)) return error.CreateFailed;

    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, names.path, &buf) catch return .{ .path = names.path, .branch = names.branch };
    return .{ .path = try arena.dupe(u8, buf[0..n]), .branch = names.branch };
}

/// Pure decision extracted from `agentWorktreeFinish`: any `git status
/// --porcelain` output (tracked OR untracked — unlike the session-level
/// `gitTreeDirty` above, a subagent's brand-new untracked file is real work
/// worth keeping, not noise to auto-discard) means the worktree is dirty.
pub fn isWorktreeStatusDirty(porcelain: []const u8) bool {
    return std.mem.trim(u8, porcelain, " \t\r\n").len > 0;
}

pub const AgentWorktreeOutcome = struct { kept: bool };

/// Called when a worktree-isolated subagent finishes normally (#276 design
/// point 3): an unchanged worktree is removed with its branch — no trace left
/// in `git worktree list` — a changed one is kept for the orchestrator to
/// inspect/land. Never called on a crash (see subagent.zig's runSub): a
/// worktree this function didn't get to run against is left in place,
/// unconditionally, so a crash never silently discards changes. If the status
/// check itself fails to run, this also keeps the worktree rather than guess.
pub fn agentWorktreeFinish(gpa: Allocator, io: Io, wt: AgentWorktree) AgentWorktreeOutcome {
    const st = runCapped(gpa, io, &.{ "git", "-C", wt.path, "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch return .{ .kept = true };
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }
    if (!ranOk(st) or isWorktreeStatusDirty(st.stdout)) return .{ .kept = true };

    if (runCapped(gpa, io, &.{ "git", "worktree", "remove", "--force", wt.path }, 8192, 8192, 30_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    if (runCapped(gpa, io, &.{ "git", "branch", "-D", wt.branch }, 8192, 8192, 30_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    return .{ .kept = false };
}

test "agentWorktreeNames: unique path/branch per nonce, never collide across repeated spawns (#276)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const first = try agentWorktreeNames(a, "sa-001-dead", "aa11bb22");
    try std.testing.expectEqualStrings(".graff/worktrees/agent-sa-001-dead-aa11bb22", first.path);
    try std.testing.expectEqualStrings("graff/agents/sa-001-dead-aa11bb22", first.branch);

    // Same sub_id (e.g. two processes whose own counters line up) but a
    // different nonce — the collision case the nonce exists to prevent —
    // still produces distinct names.
    const second = try agentWorktreeNames(a, "sa-001-dead", "cc33dd44");
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    try std.testing.expect(!std.mem.eql(u8, first.branch, second.branch));
}

test "isWorktreeStatusDirty: clean drives auto-cleanup, tracked or untracked changes drive retention (#276)" {
    try std.testing.expect(!isWorktreeStatusDirty("")); // clean → agentWorktreeFinish removes it
    try std.testing.expect(!isWorktreeStatusDirty("\n  \n")); // whitespace-only porcelain output is still clean
    try std.testing.expect(isWorktreeStatusDirty(" M src/foo.zig\n")); // tracked edit → kept
    try std.testing.expect(isWorktreeStatusDirty("?? new_file.zig\n")); // untracked-only still counts as changes → kept
}

test "isolationFailureText: friendly, distinct messages for the non-git and create-failed error paths (#276)" {
    const not_git = isolationFailureText(error.NotAGitRepo);
    try std.testing.expect(std.mem.indexOf(u8, not_git, "isn't a git repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_git, "isolation_fallback") != null);

    const create_failed = isolationFailureText(error.CreateFailed);
    try std.testing.expect(std.mem.indexOf(u8, create_failed, "git worktree add") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_failed, "isolation_fallback") != null);
    try std.testing.expect(!std.mem.eql(u8, not_git, create_failed));
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
        // Drop git's registrations for worktrees whose dirs were deleted out of band.
        const r = runCapped(gpa, io, &.{ "git", "worktree", "prune" }, 8192, 8192, 30_000) catch {
            try out.writeAll("not a git repository (nothing to prune)\n");
            return;
        };
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        try out.writeAll("✓ pruned stale worktree registrations\n");
        return;
    }

    try out.print("unknown worktree command '{s}' — use: graff worktree list | merge <name> | remove <name> | prune\n", .{action});
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

test "isolated capped runs clean descendants after timeout and normal exit" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const timed = try runCappedWithOptions(
        std.testing.allocator,
        io,
        &.{ "/bin/sh", "-c", "(sleep 0.8; printf survived > timeout-marker) >/dev/null 2>&1 & sleep 30" },
        1024,
        1024,
        50,
        .{ .cwd = .{ .dir = tmp.dir }, .kill_process_tree = true },
    );
    defer {
        std.testing.allocator.free(timed.stdout);
        std.testing.allocator.free(timed.stderr);
    }
    try std.testing.expect(timed.timed_out);

    const completed = try runCappedWithOptions(
        std.testing.allocator,
        io,
        &.{ "/bin/sh", "-c", "(sleep 0.8; printf survived > completed-marker) >/dev/null 2>&1 & exit 0" },
        1024,
        1024,
        2_000,
        .{ .cwd = .{ .dir = tmp.dir }, .kill_process_tree = true },
    );
    defer {
        std.testing.allocator.free(completed.stdout);
        std.testing.allocator.free(completed.stderr);
    }
    try std.testing.expect(ranOk(completed));
    io.sleep(.fromMilliseconds(1_000), .awake) catch {};
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "timeout-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "completed-marker", .{}));
}
