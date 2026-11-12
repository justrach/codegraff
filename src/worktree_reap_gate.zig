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
    const base = fx.scratch(io, ar) orelse return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
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
