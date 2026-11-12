//! In-process precheck for `worktree_reap.orphans` at boot (#1118).
//!
//! `orphans` costs two git spawns (`worktree prune` + `worktree list`, plus
//! more per candidate) and changes something only when git would prune a
//! registration or a listed tree belongs to a dead auto-isolate session.
//! `mayHaveOrphans` answers that from `<common>/worktrees` without a spawn.
//! It may say true when nothing would happen; it must never say false when
//! `orphans` would remove or prune anything. Every unclear case says true.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const git_dirs = @import("git_dirs.zig");
const proc_identity = @import("proc_identity.zig");
const reap = @import("worktree_reap.zig");

fn join(arena: Allocator, a: []const u8, b: []const u8) ?[]const u8 {
    return std.fs.path.join(arena, &.{ a, b }) catch null;
}

fn exists(io: Io, path: []const u8) bool {
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

/// HEAD of one worktree git dir names `worktree-session-<pid>-…` and that pid
/// is gone. Unreadable HEAD is treated as possibly dead.
fn deadSessionHead(io: Io, arena: Allocator, git_dir: []const u8) bool {
    const p = join(arena, git_dir, "HEAD") orelse return true;
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4096)) catch return true;
    if (!std.mem.startsWith(u8, bytes, "ref:")) return false; // detached: no branch line
    const ref = std.mem.trim(u8, bytes[4..], " \t\r\n");
    const pid = reap.sessionPid(ref) orelse return false;
    return proc_identity.probe(io, pid) == .gone;
}

/// git's `should_prune_worktree` and `prune_dups`, conservatively.
fn prunable(io: Io, arena: Allocator, base: []const u8, common: []const u8, seen: *std.StringHashMapUnmanaged(void)) bool {
    const locked = join(arena, base, "locked") orelse return true;
    if (exists(io, locked)) return false; // git never prunes a locked tree
    const gitdir = join(arena, base, "gitdir") orelse return true;
    const bytes = Io.Dir.cwd().readFileAlloc(io, gitdir, arena, .limited(4096)) catch return true;
    const path = std.mem.trimEnd(u8, bytes, "\r\n");
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return true;
    if (!exists(io, path)) return true;
    if (std.mem.eql(u8, path, common)) return true;
    const gop = seen.getOrPut(arena, path) catch return true;
    return gop.found_existing;
}

/// False only when `orphans(cwd)` would provably change nothing.
pub fn mayHaveOrphans(io: Io, arena: Allocator, cwd: []const u8) bool {
    const dir = if (cwd.len > 0) cwd else ".";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const start: []const u8 = if (std.mem.eql(u8, dir, "."))
        (if (std.process.currentPath(io, &buf)) |n| buf[0..n] else |_| return true)
    else
        (if (Io.Dir.cwd().realPathFile(io, dir, &buf)) |n| buf[0..n] else |_| return true);
    const common = switch (git_dirs.resolve(io, arena, start)) {
        .found => |d| d.common_dir,
        .not_git => return false, // both git calls fail outside a repo
        .fallback => return true,
    };
    if (deadSessionHead(io, arena, common)) return true; // the main worktree's own entry
    const root = join(arena, common, "worktrees") orelse return true;
    var wt_dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| return err != error.FileNotFound;
    defer wt_dir.close(io);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var any = false;
    var it = wt_dir.iterate();
    while (it.next(io) catch return true) |e| {
        any = true;
        if (e.kind != .directory) return true;
        const base = join(arena, root, e.name) orelse return true;
        if (prunable(io, arena, base, common, &seen)) return true;
        if (deadSessionHead(io, arena, base)) return true;
    }
    return !any; // prune also removes an empty worktrees/ directory
}

test "mayHaveOrphans: only stale registrations or dead session trees need git" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    if (git_dirs.envOverride()) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fx = @import("git_dirs_tests.zig");
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const base = try fx.scratch(io, ar);
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    const saved = fx.hermetic();
    defer git_dirs.user_configs_for_test = saved;
    const root = try std.fmt.allocPrint(ar, "{s}/repo", .{base});
    try fx.repoWithCommit(io, ar, root);
    const ws = @import("task_workspace.zig");

    // No linked trees: nothing to prune, nothing to reap.
    try std.testing.expect(!mayHaveOrphans(io, ar, root));
    const named = try ws.create(a, io, ar, .{ .slug = "task-keep", .cwd = root });
    _ = try ws.create(a, io, ar, .{ .slug = "session-1-deadbeef", .cwd = root }); // pid 1 lives
    try std.testing.expect(!mayHaveOrphans(io, ar, root));
    try std.testing.expectEqual(@as(usize, 0), reap.orphans(a, io, ar, root));

    // A dead session's clean tree is reapable.
    _ = try ws.create(a, io, ar, .{ .slug = "session-0-deadbeef", .cwd = root });
    try std.testing.expect(mayHaveOrphans(io, ar, root));
    try std.testing.expect(reap.orphans(a, io, ar, root) >= 1);
    try std.testing.expect(!mayHaveOrphans(io, ar, root));

    // A checkout deleted out of band leaves a registration git would prune.
    try Io.Dir.cwd().deleteTree(io, named.path);
    try std.testing.expect(mayHaveOrphans(io, ar, root));
    _ = reap.orphans(a, io, ar, root);
    try std.testing.expect(!mayHaveOrphans(io, ar, root));

    // Outside any repo there is nothing for git to do.
    try std.testing.expect(!mayHaveOrphans(io, ar, base));
}

/// `git worktree prune --dry-run --verbose` names something to prune.
fn pruneWould(io: Io, root: []const u8) bool {
    const gpa = std.testing.allocator;
    const r = @import("process_runner.zig").runCapped(gpa, io, &.{ "git", "-C", root, "worktree", "prune", "-n", "-v" }, 8192, 8192, 15_000) catch return true;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return r.stdout.len + r.stderr.len > 0;
}

test "mayHaveOrphans: locked, duplicate, relative, empty worktrees/ and a main HEAD on a dead session" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    if (git_dirs.envOverride()) return error.SkipZigTest;
    const io = std.testing.io;
    const fx = @import("git_dirs_tests.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const base = try fx.scratch(io, ar);
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    const saved = fx.hermetic();
    defer git_dirs.user_configs_for_test = saved;
    const T = struct {
        fn repo(b: []const u8, a: Allocator, name: []const u8) ![]const u8 {
            const r = try std.fmt.allocPrint(a, "{s}/{s}", .{ b, name });
            try fx.repoWithCommit(std.testing.io, a, r);
            return r;
        }
        fn tree(a: Allocator, root: []const u8, name: []const u8) ![]const u8 {
            const p = try std.fmt.allocPrint(a, "{s}/.graff/worktrees/{s}", .{ root, name });
            const br = try std.fmt.allocPrint(a, "worktree-{s}", .{name});
            if (!fx.git(std.testing.io, &.{ "-C", root, "worktree", "add", "-q", "-b", br, p })) return error.WorktreeAddFailed;
            return p;
        }
    };

    // Locked and deleted out of band: git keeps the registration, so no spawn.
    const locked = try T.repo(base, ar, "locked");
    const kept = try T.tree(ar, locked, "task-kept");
    try std.testing.expect(fx.git(io, &.{ "-C", locked, "worktree", "lock", kept }));
    try Io.Dir.cwd().deleteTree(io, kept);
    try std.testing.expect(!pruneWould(io, locked));
    try std.testing.expect(!mayHaveOrphans(io, ar, locked));
    // A lock does not hide a dead session's tree from the reaper.
    const dead = try T.tree(ar, locked, "session-0-locked");
    try std.testing.expect(fx.git(io, &.{ "-C", locked, "worktree", "lock", dead }));
    try std.testing.expect(mayHaveOrphans(io, ar, locked));

    // Two registrations naming one checkout: git prunes the duplicate.
    const dup = try T.repo(base, ar, "dup");
    _ = try T.tree(ar, dup, "task-a");
    _ = try T.tree(ar, dup, "task-b");
    const a_gitdir = try std.fmt.allocPrint(ar, "{s}/.git/worktrees/task-a/gitdir", .{dup});
    const b_gitdir = try std.fmt.allocPrint(ar, "{s}/.git/worktrees/task-b/gitdir", .{dup});
    const same = try Io.Dir.cwd().readFileAlloc(io, a_gitdir, ar, .limited(4096));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = b_gitdir, .data = same });
    try std.testing.expect(pruneWould(io, dup));
    try std.testing.expect(mayHaveOrphans(io, ar, dup));

    // A relative gitdir (worktree.useRelativePaths) is git's call.
    const rel = try T.repo(base, ar, "rel");
    _ = try T.tree(ar, rel, "task-rel");
    const rel_gitdir = try std.fmt.allocPrint(ar, "{s}/.git/worktrees/task-rel/gitdir", .{rel});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rel_gitdir, .data = "../../../.graff/worktrees/task-rel/.git\n" });
    try std.testing.expect(mayHaveOrphans(io, ar, rel));

    // An empty worktrees/ directory: prune removes it, then nothing is left.
    const empty = try T.repo(base, ar, "empty");
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(ar, "{s}/.git/worktrees", .{empty}));
    try std.testing.expect(mayHaveOrphans(io, ar, empty));
    try std.testing.expect(fx.git(io, &.{ "-C", empty, "worktree", "prune" }));
    try std.testing.expect(!mayHaveOrphans(io, ar, empty));

    // The main checkout itself sits on a dead session's branch.
    const main_dead = try T.repo(base, ar, "maindead");
    try std.testing.expect(!mayHaveOrphans(io, ar, main_dead));
    try std.testing.expect(fx.git(io, &.{ "-C", main_dead, "checkout", "-q", "-b", "worktree-session-0-main" }));
    try std.testing.expect(mayHaveOrphans(io, ar, main_dead));
}
