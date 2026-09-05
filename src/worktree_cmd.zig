//! `graff worktree <list|merge|remove|prune>` and the per-turn worktree
//! checkpoint commit for `-w` sessions. Moved out of jobs.zig (600-line cap)
//! when the background-job pool grew its idle lifecycle (#199); jobs.zig
//! re-exports both entry points, so callers are unchanged.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

/// Commit-message trailer that credits the harness assist. The commit AUTHOR
/// stays the user's own git identity (their GitHub account) — graff never
/// overrides GIT_AUTHOR_*; codegraff is recorded as a co-author instead,
/// mirroring how Claude Code attributes commits.
const codegraff_coauthor = "Co-Authored-By: Codegraff <blackfloofie@codegraff.com>";

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

test { // split-out module: unreferenced, its tests silently never run
    _ = worktree_prune;
}
