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

const supports_process_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi;
const default_server_pause_ms: u64 = 30 * std.time.ms_per_min;
const default_server_stop_ms: u64 = 2 * std.time.ms_per_hour;

/// Managed localhost jobs use these process-wide defaults. Minutes are used in
/// the environment so the values stay friendly to shell users; zero disables
/// that transition. `GRAFF_SERVER_IDLE=off` disables the policy entirely.
pub var g_server_idle_enabled = true;
pub var g_server_pause_ms = default_server_pause_ms;
pub var g_server_stop_ms = default_server_stop_ms;

pub fn configureIdlePolicy(environ: anytype) void {
    g_server_idle_enabled = true;
    if (environ.get("GRAFF_SERVER_IDLE")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "off") or std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no"))
            g_server_idle_enabled = false;
    }
    g_server_pause_ms = envMinutes(environ, "GRAFF_SERVER_PAUSE_MINUTES", default_server_pause_ms);
    g_server_stop_ms = envMinutes(environ, "GRAFF_SERVER_STOP_MINUTES", default_server_stop_ms);
    // A pause at/after stop has no useful observable state; go straight to stop.
    if (g_server_stop_ms > 0 and g_server_pause_ms >= g_server_stop_ms) g_server_pause_ms = 0;
}

fn envMinutes(environ: anytype, key: []const u8, fallback_ms: u64) u64 {
    const raw = environ.get(key) orelse return fallback_ms;
    const minutes = std.fmt.parseInt(u64, raw, 10) catch return fallback_ms;
    return std.math.mul(u64, minutes, std.time.ms_per_min) catch fallback_ms;
}

fn processGroupId() ?std.posix.pid_t {
    return if (supports_process_groups) 0 else null;
}

/// Every shell gets its own POSIX process group. Signalling the group is what
/// reaches npm -> node, xcodebuild -> XCTest, and similar grandchildren; killing
/// only `/bin/sh` is how stale localhost/test trees escaped in #198.
fn signalProcessGroup(child: *const std.process.Child, sig: std.posix.SIG) void {
    if (comptime supports_process_groups) {
        const pid = child.id orelse return;
        std.posix.kill(-pid, sig) catch {};
    }
}

fn pauseProcessGroup(child: *const std.process.Child) void {
    if (comptime supports_process_groups) signalProcessGroup(child, .STOP);
}

fn resumeProcessGroup(child: *const std.process.Child) void {
    if (comptime supports_process_groups) signalProcessGroup(child, .CONT);
}

fn terminateProcessTree(child: *std.process.Child, io: Io) void {
    if (child.id == null) return;
    if (comptime supports_process_groups) {
        signalProcessGroup(child, .TERM);
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        signalProcessGroup(child, .KILL);
    }
    child.kill(io); // reaps the direct child and closes its pipes
}

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
        .pgid = processGroupId(),
    });
    defer terminateProcessTree(&child, io);

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
            terminateProcessTree(&child, io);
            break :loop;
        }
        if (deadline_ms > 0 and t0.untilNow(io, .awake).toMilliseconds() >= deadline_ms) {
            timed_out = true;
            terminateProcessTree(&child, io);
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
pub const Job = struct {
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
    managed_server: bool = false,
    keep_alive: bool = false,
    paused: bool = false,
    resume_requested: bool = false,
    idle_stopped: bool = false,
    last_activity: Io.Timestamp,
    future: Io.Future(void) = undefined, // the pump; awaited only by jobsReap
};

pub const JobOptions = struct {
    managed_server: bool = false,
    keep_alive: bool = false,
};

const IdleAction = enum { none, pause, stop };

fn idleAction(paused: bool, idle_ms: u64, pause_ms: u64, stop_ms: u64) IdleAction {
    if (stop_ms > 0 and idle_ms >= stop_ms) return .stop;
    if (!paused and pause_ms > 0 and idle_ms >= pause_ms) return .pause;
    return .none;
}

/// Conservative recognizer for commands that are expected to bind localhost
/// and run forever. Compound shell programs are excluded: auto-managing an
/// entire `build && test` pipeline because one token says `dev` is surprising.
pub fn looksLikeLocalServer(command: []const u8) bool {
    const cmd = std.mem.trim(u8, command, " \t\r\n");
    if (cmd.len == 0 or std.mem.indexOfAny(u8, cmd, ";|&\n<>`$") != null) return false;

    var words = std.mem.tokenizeAny(u8, cmd, " \t");
    const first_raw = words.next() orelse return false;
    const first = std.fs.path.basename(first_raw);
    const second = words.next();
    const third = words.next();

    if (std.mem.eql(u8, first, "npm") or std.mem.eql(u8, first, "pnpm") or std.mem.eql(u8, first, "yarn") or std.mem.eql(u8, first, "bun"))
        return packageServerScript(second, third);
    if (std.mem.eql(u8, first, "next")) return second != null and (std.mem.eql(u8, second.?, "dev") or std.mem.eql(u8, second.?, "start"));
    if (std.mem.eql(u8, first, "vite")) return second == null or std.mem.eql(u8, second.?, "dev") or std.mem.eql(u8, second.?, "preview");
    if (std.mem.eql(u8, first, "astro") or std.mem.eql(u8, first, "nuxt") or std.mem.eql(u8, first, "wrangler"))
        return second != null and (std.mem.eql(u8, second.?, "dev") or std.mem.eql(u8, second.?, "preview"));
    if (std.mem.eql(u8, first, "webpack")) return second != null and std.mem.eql(u8, second.?, "serve");
    if (std.mem.eql(u8, first, "python") or std.mem.eql(u8, first, "python3"))
        return second != null and std.mem.eql(u8, second.?, "-m") and third != null and std.mem.eql(u8, third.?, "http.server");
    if (std.mem.eql(u8, first, "php")) return second != null and std.mem.eql(u8, second.?, "-S");
    return false;
}

fn packageServerScript(second: ?[]const u8, third: ?[]const u8) bool {
    const script = second orelse return false;
    if (std.mem.eql(u8, script, "run")) return third != null and serverScript(third.?);
    return serverScript(script);
}

fn serverScript(word: []const u8) bool {
    return std.mem.eql(u8, word, "dev") or std.mem.eql(u8, word, "serve") or std.mem.eql(u8, word, "preview") or std.mem.eql(u8, word, "start");
}

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
fn jobDrain(job: *Job, gpa: Allocator, io: Io, readers: []const *Io.Reader) void {
    var received = false;
    for (readers) |r| {
        const b = r.buffered();
        if (b.len == 0) continue;
        job.buf.appendSlice(gpa, b) catch {};
        r.toss(b.len);
        received = true;
    }
    if (received) job.last_activity = .now(io, .awake);
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
        var pause = false;
        var idle_stop = false;
        var should_resume = false;
        g_jobs.mutex.lockUncancelable(io);
        jobDrain(job, gpa, io, &readers);
        if (job.resume_requested) {
            job.resume_requested = false;
            if (job.paused) {
                job.paused = false;
                should_resume = true;
                job.buf.appendSlice(gpa, "\n[resumed by bash_resume]\n") catch {};
            }
        }
        if (job.managed_server and !job.keep_alive and g_server_idle_enabled and !job.kill_requested) {
            const idle_ms: u64 = @intCast(@max(job.last_activity.untilNow(io, .awake).toMilliseconds(), 0));
            switch (idleAction(job.paused, idle_ms, g_server_pause_ms, g_server_stop_ms)) {
                .none => {},
                .pause => if (supports_process_groups) {
                    job.paused = true;
                    pause = true;
                    job.buf.appendSlice(gpa, "\n[managed localhost server paused after idle timeout; use bash_resume to continue]\n") catch {};
                },
                .stop => {
                    job.idle_stopped = true;
                    job.kill_requested = true;
                    idle_stop = true;
                    job.buf.appendSlice(gpa, "\n[managed localhost server stopped after idle timeout]\n") catch {};
                },
            }
        }
        killed = job.kill_requested;
        g_jobs.mutex.unlock(io);
        if (should_resume) resumeProcessGroup(&job.child);
        if (pause) {
            pauseProcessGroup(&job.child);
            std.debug.print("\n[job {d}] managed localhost server paused after inactivity; use bash_resume to continue\n", .{job.id});
        }
        if (idle_stop) std.debug.print("\n[job {d}] managed localhost server stopped after inactivity\n", .{job.id});
        if (killed) break :loop;
    }
    g_jobs.mutex.lockUncancelable(io);
    jobDrain(job, gpa, io, &readers); // final drain of anything left at EOF/kill
    killed = killed or job.kill_requested;
    g_jobs.mutex.unlock(io);
    var code: ?u8 = null;
    if (killed) {
        if (job.paused) resumeProcessGroup(&job.child);
        terminateProcessTree(&job.child, io); // also reaps (wait would assert afterwards)
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
pub fn spawnJob(gpa: Allocator, io: Io, cmd: []const u8, options: JobOptions) !*Job {
    const argv = shellArgv(cmd);
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = processGroupId(),
    });
    const cmd_copy = gpa.dupe(u8, cmd) catch |e| {
        terminateProcessTree(&child, io);
        return e;
    };
    const job = gpa.create(Job) catch |e| {
        gpa.free(cmd_copy);
        terminateProcessTree(&child, io);
        return e;
    };
    job.* = .{
        .id = 0,
        .cmd = cmd_copy,
        .child = child,
        .managed_server = options.managed_server,
        .keep_alive = options.keep_alive,
        .last_activity = .now(io, .awake),
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
        terminateProcessTree(&job.child, io);
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
        terminateProcessTree(&job.child, io);
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
        if (!job.done) job.last_activity = .now(io, .awake);
        if (fresh.len > 0 or job.done or waited >= deadline) {
            var aw: Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const w = &aw.writer;
            if (!job.done and job.paused) {
                try w.print("[job {d}: paused]", .{id});
            } else if (!job.done) {
                try w.print("[job {d}: running]", .{id});
            } else if (job.idle_stopped) {
                try w.print("[job {d}: stopped after idle timeout]", .{id});
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

/// bash_resume: continue a managed server paused by the idle policy.
pub fn jobResume(gpa: Allocator, io: Io, id: u32) !ToolOutput {
    g_jobs.mutex.lockUncancelable(io);
    defer g_jobs.mutex.unlock(io);
    const job = g_jobs.find(id) orelse return .{ .text = try std.fmt.allocPrint(gpa, "no background job {d} — /jobs lists them", .{id}), .is_error = true };
    if (job.done) return .{ .text = try std.fmt.allocPrint(gpa, "job {d} already finished", .{id}), .is_error = true };
    job.last_activity = .now(io, .awake);
    if (!job.paused) return .{ .text = try std.fmt.allocPrint(gpa, "job {d} is already running", .{id}) };
    job.resume_requested = true;
    return .{ .text = try std.fmt.allocPrint(gpa, "job {d}: resume requested", .{id}) };
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

test "localhost server recognizer is conservative" {
    try std.testing.expect(looksLikeLocalServer("npm run dev -- --port 3002"));
    try std.testing.expect(looksLikeLocalServer("pnpm preview"));
    try std.testing.expect(looksLikeLocalServer("bun run dev"));
    try std.testing.expect(looksLikeLocalServer("npm start"));
    try std.testing.expect(looksLikeLocalServer("next start -p 3000"));
    try std.testing.expect(looksLikeLocalServer("python3 -m http.server 8000"));
    try std.testing.expect(looksLikeLocalServer("php -S localhost:8080"));
    try std.testing.expect(!looksLikeLocalServer("npm test"));
    try std.testing.expect(!looksLikeLocalServer("npm run develop"));
    try std.testing.expect(!looksLikeLocalServer("npm run build && npm run dev"));
    try std.testing.expect(!looksLikeLocalServer("echo next dev"));
}

test "idle lifecycle pauses once then stops" {
    try std.testing.expectEqual(IdleAction.none, idleAction(false, 99, 100, 200));
    try std.testing.expectEqual(IdleAction.pause, idleAction(false, 100, 100, 200));
    try std.testing.expectEqual(IdleAction.none, idleAction(true, 150, 100, 200));
    try std.testing.expectEqual(IdleAction.stop, idleAction(true, 200, 100, 200));
    try std.testing.expectEqual(IdleAction.stop, idleAction(false, 200, 0, 200));
}

test "runCapped timeout terminates the child process group" {
    if (comptime !supports_process_groups) return error.SkipZigTest;

    const r = try runCapped(
        std.testing.allocator,
        std.testing.io,
        &.{ "/bin/sh", "-c", "sleep 30 & echo $!; wait" },
        4096,
        4096,
        200,
    );
    defer {
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
    }
    try std.testing.expect(r.timed_out);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, r.stdout, " \t\r\n"), 10);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, .CONT));
}
