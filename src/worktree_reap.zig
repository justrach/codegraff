//! Reap auto-isolate session worktrees whose process is gone (#1118).
//! Named task workspaces and dirty/unique-commit trees stay (ADR 0147).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const proc_identity = @import("proc_identity.zig");
const prune = @import("worktree_prune.zig");

const session_prefix = "worktree-session-";

/// Pid encoded in `worktree-session-<pid>-<nonce>`, or null if this is not
/// an auto-isolate session tree.
pub fn sessionPid(branch: []const u8) ?i32 {
    const name = prune.shortBranch(branch);
    if (!std.mem.startsWith(u8, name, session_prefix)) return null;
    const rest = name[session_prefix.len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    if (dash == 0) return null;
    return std.fmt.parseInt(i32, rest[0..dash], 10) catch null;
}

fn pidGone(io: Io, pid: i32) bool {
    return proc_identity.probe(io, pid) == .gone;
}

fn hasIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// User asked to free disk. Unfold `workspace` so action=gc is callable.
/// Do not match a generic "clean up" — that is finish-is-not-archive.
pub fn userAskedToFreeTrees(text: []const u8) bool {
    const needles = [_][]const u8{
        "clear up space",
        "free space",
        "free disk",
        "clear unused",
        "unused worktree",
        "unused trees",
        "workspace gc",
        "/workspace gc",
        "worktree gc",
    };
    for (needles) |n| if (hasIgnoreCase(text, n)) return true;
    return false;
}

/// Drop registrations whose dirs are already gone, then remove clean
/// auto-isolate trees whose pid is dead. Returns how many directories went.
pub fn orphans(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8) usize {
    const dir = if (cwd.len > 0) cwd else ".";
    if (runCapped(gpa, io, &.{ "git", "-C", dir, "worktree", "prune" }, 4096, 4096, 15_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    const listed = runCapped(gpa, io, &.{ "git", "-C", dir, "worktree", "list", "--porcelain" }, 1 << 18, 8192, 15_000) catch return 0;
    defer {
        gpa.free(listed.stdout);
        gpa.free(listed.stderr);
    }
    const entries = prune.parseEntries(arena, listed.stdout) catch return 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const here_n = Io.Dir.cwd().realPathFile(io, ".", &buf) catch 0;
    const here = if (here_n > 0) buf[0..here_n] else "";
    var removed: usize = 0;
    for (entries) |e| {
        const pid = sessionPid(e.branch) orelse continue;
        if (!pidGone(io, pid)) continue;
        if (here.len > 0 and std.mem.eql(u8, e.path, here)) continue;
        if (prune.keepReasonFor(gpa, io, e) != .removed) continue;
        if (prune.removeWorktree(gpa, io, e)) removed += 1;
    }
    return removed;
}

fn prMerged(gpa: Allocator, io: Io, cwd: []const u8, branch: []const u8) bool {
    const name = prune.shortBranch(branch);
    const r = process_runner.runCappedWithOptions(gpa, io, &.{ "gh", "pr", "view", name, "--json", "state", "-q", ".state" }, 4096, 4096, 20_000, .{ .cwd = .{ .path = cwd } }) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!process_runner.ranOk(r)) return false;
    return std.mem.eql(u8, std.mem.trim(u8, r.stdout, " \t\r\n"), "MERGED");
}

fn treeDirty(gpa: Allocator, io: Io, path: []const u8) bool {
    const st = runCapped(gpa, io, &.{ "git", "-C", path, "status", "--porcelain" }, 1 << 16, 8192, 15_000) catch return true;
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }
    if (!process_runner.ranOk(st)) return true;
    return std.mem.trim(u8, st.stdout, " \t\r\n").len > 0;
}

/// Named task trees whose GitHub PR is MERGED and whose checkout is clean.
/// Dirty trees stay. `gh` missing or offline is a no-op.
pub fn mergedPulls(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8) usize {
    const dir = if (cwd.len > 0) cwd else ".";
    const listed = runCapped(gpa, io, &.{ "git", "-C", dir, "worktree", "list", "--porcelain" }, 1 << 18, 8192, 15_000) catch return 0;
    defer {
        gpa.free(listed.stdout);
        gpa.free(listed.stderr);
    }
    const entries = prune.parseEntries(arena, listed.stdout) catch return 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const here_n = Io.Dir.cwd().realPathFile(io, ".", &buf) catch 0;
    const here = if (here_n > 0) buf[0..here_n] else "";
    var removed: usize = 0;
    for (entries) |e| {
        const name = prune.shortBranch(e.branch);
        if (!std.mem.startsWith(u8, name, "worktree-")) continue;
        if (sessionPid(e.branch) != null) continue;
        if (here.len > 0 and std.mem.eql(u8, e.path, here)) continue;
        if (treeDirty(gpa, io, e.path)) continue;
        if (!prMerged(gpa, io, dir, e.branch)) continue;
        if (prune.removeWorktree(gpa, io, e)) removed += 1;
    }
    return removed;
}

test "userAskedToFreeTrees: space/gc wording, not generic cleanup" {
    try std.testing.expect(userAskedToFreeTrees("can we clear up space"));
    try std.testing.expect(userAskedToFreeTrees("Free disk please"));
    try std.testing.expect(userAskedToFreeTrees("run worktree gc"));
    try std.testing.expect(!userAskedToFreeTrees("clean up the worktree after you finish"));
    try std.testing.expect(!userAskedToFreeTrees("summarize the architecture"));
}

test "sessionPid: only auto-isolate session branches" {
    try std.testing.expectEqual(@as(?i32, 65043), sessionPid("refs/heads/worktree-session-65043-e9cc718d"));
    try std.testing.expectEqual(@as(?i32, 65043), sessionPid("worktree-session-65043-e9cc718d"));
    try std.testing.expectEqual(@as(?i32, null), sessionPid("worktree-task-a"));
    try std.testing.expectEqual(@as(?i32, null), sessionPid("graff/agents/sa-1-aa"));
    try std.testing.expectEqual(@as(?i32, null), sessionPid("feat/side-agent-steer"));
}

test "orphans: a dead-pid clean session tree is removed; a named workspace is not" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const root = try std.fmt.allocPrint(a, "{s}/repo", .{tmp_root});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    const ws = @import("task_workspace.zig");
    const runner = @import("process_runner.zig");
    const git = struct {
        fn run(gpa: Allocator, git_io: Io, argv: []const []const u8) !void {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.append(gpa, "git");
            try args.appendSlice(gpa, argv);
            const r = try runner.runCapped(gpa, git_io, args.items, 4096, 4096, 15_000);
            defer gpa.free(r.stdout);
            defer gpa.free(r.stderr);
            try std.testing.expect(runner.ranOk(r));
        }
    };
    try git.run(a, io, &.{ "init", "-q", "-b", "main", root });
    try git.run(a, io, &.{ "-C", root, "config", "user.email", "t@t" });
    try git.run(a, io, &.{ "-C", root, "config", "user.name", "t" });
    const tracked = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(tracked);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tracked, .data = "x\n" });
    try git.run(a, io, &.{ "-C", root, "add", "f" });
    try git.run(a, io, &.{ "-C", root, "commit", "-m", "i" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const live = try ws.create(a, io, ar, .{ .slug = "session-1-deadbeef", .cwd = root });
    const named = try ws.create(a, io, ar, .{ .slug = "task-keep", .cwd = root });
    const gone = try ws.create(a, io, ar, .{ .slug = "session-0-deadbeef", .cwd = root });
    const n = orphans(a, io, ar, root);
    try std.testing.expect(n >= 1);
    try std.testing.expect((Io.Dir.cwd().statFile(io, gone.path, .{}) catch null) == null);
    try std.testing.expect((Io.Dir.cwd().statFile(io, named.path, .{}) catch null) != null);
    try std.testing.expect((Io.Dir.cwd().statFile(io, live.path, .{}) catch null) != null);
}
