//! `graff worktree <list|create|run|archive|merge|remove|prune>` and the per-turn worktree
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

fn landSourceClean(gpa: Allocator, io: Io, path: []const u8) bool {
    // A leftover directory can resolve to its parent repository. It is not
    // the source checkout unless Git reports this path as its own root.
    const prefix = runCapped(gpa, io, &.{ "git", "-C", path, "rev-parse", "--show-prefix" }, 8192, 8192, 30_000) catch return false;
    defer gpa.free(prefix.stdout);
    defer gpa.free(prefix.stderr);
    if (!ranOk(prefix) or std.mem.trim(u8, prefix.stdout, " \t\r\n").len != 0) return false;
    const status = runCapped(gpa, io, &.{ "git", "-C", path, "status", "--porcelain", "--untracked-files=all" }, 1 << 16, 8192, 30_000) catch return false;
    defer gpa.free(status.stdout);
    defer gpa.free(status.stderr);
    return ranOk(status) and std.mem.trim(u8, status.stdout, " \t\r\n").len == 0;
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
        return worktree_prune.listWithAge(gpa, io, arena, out);
    }

    if (std.mem.eql(u8, action, "merge") or std.mem.eql(u8, action, "land")) {
        if (args.len < 2) {
            try out.writeAll("usage: graff worktree merge <name>\n       graff worktree land <name>\n");
            return;
        }
        const name = args[1];
        const wt_path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{name});
        const wt_branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{name});

        const metadata = @import("worktree_base.zig");
        const base = metadata.read(gpa, io, arena, ".", wt_branch);
        if (base.len > 0 and !std.mem.eql(u8, base, metadata.branch(gpa, io, arena, "."))) {
            try out.print("✗ workspace targets {s} — land from that branch's checkout\n", .{base});
            return;
        }
        if (!std.mem.eql(u8, wt_branch, metadata.branch(gpa, io, arena, wt_path))) {
            try out.writeAll("✗ workspace branch changed — restore its owned branch before landing\n");
            return;
        }

        // Squash reads committed history, not this checkout's local edits.
        // Refuse before touching the destination, including untracked files.
        if (!landSourceClean(gpa, io, wt_path)) {
            try out.writeAll("✗ workspace has uncommitted files or could not be verified — commit or stash its changes before landing\n");
            return;
        }

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

        // 3) teardown, then remove the checkout before deleting its branch.
        if (!@import("workspace_prepare.zig").beforeArchive(gpa, io, arena, ".", wt_path, name)) {
            try out.writeAll("✓ landed committed changes; archive script failed, checkout and branch kept\n");
            return;
        }
        if (runCapped(gpa, io, &.{ "git", "worktree", "remove", wt_path }, 8192, 8192, 30_000)) |r| {
            const removed = ranOk(r);
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            if (!removed) {
                try out.writeAll("✓ landed committed changes; workspace checkout and branch kept because removal was refused\n");
                return;
            }
        } else |_| {
            try out.writeAll("✓ landed committed changes; workspace checkout and branch kept because removal failed\n");
            return;
        }
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
        if (args.len < 3 or !std.mem.eql(u8, args[2], "--discard")) {
            try out.writeAll("✗ removal may discard unique work — confirm with `graff worktree remove <name> --discard`, or use archive to keep unmerged changes\n");
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

    if (std.mem.eql(u8, action, "create")) {
        if (args.len < 2) {
            try out.writeAll("usage: graff worktree create <name> [base]\n");
            return;
        }
        const name = args[1];
        const base = if (args.len > 2) args[2] else "";
        const wt = @import("task_workspace.zig").create(gpa, io, arena, .{ .slug = name, .base = base }) catch |err| {
            try out.print("✗ {s}\n", .{@import("task_workspace.zig").createFailureText(err)});
            return;
        };
        try out.print("✓ workspace {s}\n  path {s}\n  branch {s}\n", .{ wt.name, wt.path, wt.branch });
        if (wt.copied > 0) try out.print("  copied {d} gitignored file(s)\n", .{wt.copied});
        if (wt.setup_ran) try out.print("  setup {s}\n", .{if (wt.setup_ok) "ok" else "failed (workspace kept)"});
        return;
    }

    if (std.mem.eql(u8, action, "run")) {
        const name = if (args.len > 1) args[1] else "";
        if (name.len == 0) {
            try out.writeAll("usage: graff worktree run <name>\n");
            return;
        }
        const dest = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{name});
        if ((Io.Dir.cwd().statFile(io, dest, .{}) catch null) == null) {
            try out.print("✗ no such task workspace {s} — `graff worktree list`\n", .{name});
            return;
        }
        const path = blk: {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().realPathFile(io, dest, &path_buf) catch 0;
            break :blk if (n > 0) try arena.dupe(u8, path_buf[0..n]) else dest;
        };
        if (!@import("workspace_prepare.zig").runNamed(gpa, io, arena, ".", path, name)) {
            try out.writeAll("✗ run script missing or failed — check scripts.run in .graff/workspace.toml\n");
            return;
        }
        try out.print("✓ run finished in {s}\n", .{path});
        return;
    }

    if (std.mem.eql(u8, action, "archive") or std.mem.eql(u8, action, "archive-merged")) {
        if (args.len < 2) {
            try out.writeAll("usage: graff worktree archive <name>\n");
            return;
        }
        const tw = @import("task_workspace.zig");
        const operation = if (std.mem.eql(u8, action, "archive-merged")) &tw.archiveMerged else &tw.archive;
        const result = operation(gpa, io, arena, ".", args[1]) catch |err| {
            try out.print("✗ {s}\n", .{tw.archiveFailureText(err)});
            return;
        };
        if (result.removed) {
            try out.print("✓ archived {s} (removed checkout and branch {s})\n", .{ result.path, result.branch });
        } else {
            try out.print("kept {s} — {s}\n", .{ result.path, @import("agent_worktree.zig").keepReasonText(result.reason) });
        }
        return;
    }

    if (std.mem.eql(u8, action, "update")) {
        if (args.len < 2) {
            try out.writeAll("usage: graff worktree update <name>\n");
            return;
        }
        const tw = @import("task_workspace.zig");
        const wt = tw.update(gpa, io, arena, ".", args[1]) catch |err| {
            try out.print("✗ {s}\n", .{tw.updateFailureText(err)});
            return;
        };
        try out.print("✓ updated {s} from the remote base\n  path {s}\n  branch {s}\n", .{ wt.name, wt.path, wt.branch });
        return;
    }

    if (std.mem.eql(u8, action, "gc")) {
        const n = @import("worktree_reap.zig").orphans(gpa, io, arena, ".");
        const m = @import("worktree_reap.zig").mergedPulls(gpa, io, arena, ".");
        try out.print("✓ gc: removed {d} idle session tree(s), {d} merged-PR tree(s)\n", .{ n, m });
        return;
    }

    if (std.mem.eql(u8, action, "prune")) {
        // `unused` is the explicit stale-checkout sweep (#1118). Bare prune
        // still only drops registrations unless an age window is named.
        if (args.len > 1 and std.mem.eql(u8, args[1], "unused")) {
            const n = @import("worktree_reap.zig").orphans(gpa, io, arena, ".");
            const m = @import("worktree_reap.zig").mergedPulls(gpa, io, arena, ".");
            try out.print("✓ swept unused worktrees — removed {d} idle session tree(s), {d} merged-PR tree(s)\n", .{ n, m });
            return;
        }
        // Drops git's registrations for worktrees whose dirs were deleted out of
        // band, and with `older-than <days>` the stale DIRECTORIES too (#112).
        return worktree_prune.pruneCommand(gpa, io, arena, out, args[1..]);
    }

    try out.print("unknown worktree command '{s}' — use: graff worktree list | create <name> [base] | run <name> | update <name> | land <name> | archive <name> | merge <name> | remove <name> | gc | prune [older-than <days>]\n", .{action});
}

test "land source gate preserves untracked staged and unstaged work and fails closed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    const Git = struct {
        fn run(a: Allocator, test_io: Io, cwd: []const u8, args: []const []const u8) !void {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(a);
            try argv.appendSlice(a, &.{ "git", "-C", cwd });
            try argv.appendSlice(a, args);
            const result = try runCapped(a, test_io, argv.items, 8192, 8192, 30_000);
            defer a.free(result.stdout);
            defer a.free(result.stderr);
            try std.testing.expect(ranOk(result));
        }
    };
    try std.testing.expect(!landSourceClean(gpa, io, path));
    try Git.run(gpa, io, path, &.{ "init", "-q" });
    try std.testing.expect(landSourceClean(gpa, io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "work.txt", .data = "original\n" });
    try std.testing.expect(!landSourceClean(gpa, io, path));
    try Git.run(gpa, io, path, &.{ "add", "work.txt" });
    try std.testing.expect(!landSourceClean(gpa, io, path));
    try Git.run(gpa, io, path, &.{ "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial" });
    try std.testing.expect(landSourceClean(gpa, io, path));
    try tmp.dir.createDir(io, "not-a-worktree", .default_dir);
    const nested = try std.fs.path.join(gpa, &.{ path, "not-a-worktree" });
    defer gpa.free(nested);
    try std.testing.expect(!landSourceClean(gpa, io, nested)); // clean parent
    try tmp.dir.writeFile(io, .{ .sub_path = "work.txt", .data = "keep this edit\n" });
    try std.testing.expect(!landSourceClean(gpa, io, path));
    try std.testing.expect(!landSourceClean(gpa, io, nested)); // dirty parent
    const retained = try tmp.dir.readFileAlloc(io, "work.txt", gpa, .limited(1024));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings("keep this edit\n", retained);
}

test { // split-out module: unreferenced, its tests silently never run
    _ = worktree_prune;
    _ = @import("worktree_reap.zig");
}
