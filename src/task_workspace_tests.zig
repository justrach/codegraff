//! Isolation tests for `task_workspace.zig`. Production stays under the 600-line ceiling.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ws = @import("task_workspace.zig");
const claim_path = @import("artifact_claim_path.zig");
const agent_worktree = @import("agent_worktree.zig");
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

test "shouldAutoIsolate: only a claimed interactive git checkout isolates" {
    try std.testing.expect(!ws.shouldAutoIsolate(.{ .claimed = true, .is_git = true, .already_isolated = true }));
    try std.testing.expect(!ws.shouldAutoIsolate(.{ .claimed = true, .is_git = true, .lean = true }));
    try std.testing.expect(!ws.shouldAutoIsolate(.{ .claimed = true, .is_git = true, .windows = true }));
    try std.testing.expect(!ws.shouldAutoIsolate(.{ .claimed = true, .is_git = false }));
    try std.testing.expect(!ws.shouldAutoIsolate(.{ .claimed = false, .is_git = true }));
    try std.testing.expect(ws.shouldAutoIsolate(.{ .claimed = true, .is_git = true }));
}

test "sanitizeSlug and names: one workspace is one branch and one checkout path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(ws.sanitizeSlug("") == null);
    try std.testing.expect(ws.sanitizeSlug("a/b") == null);
    try std.testing.expect(ws.sanitizeSlug("..") == null);
    try std.testing.expect(ws.sanitizeSlug("ok_name-1") != null);
    const first = try ws.names(a, "task-a");
    try std.testing.expectEqualStrings(".graff/worktrees/task-a", first.path);
    try std.testing.expectEqualStrings("worktree-task-a", first.branch);
    const second = try ws.names(a, "task-b");
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    try std.testing.expect(!std.mem.eql(u8, first.branch, second.branch));
}

test "indexLockPath: two worktree git dirs never share a lock file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const main_lock = ws.indexLockPath(a, "/repo/.git") orelse return error.TestUnexpectedResult;
    const wt_lock = ws.indexLockPath(a, "/repo/.git/worktrees/session-1") orelse return error.TestUnexpectedResult;
    const expect_main = try std.fs.path.join(a, &.{ "/repo/.git", "index.lock" });
    const expect_wt = try std.fs.path.join(a, &.{ "/repo/.git/worktrees/session-1", "index.lock" });
    try std.testing.expectEqualStrings(expect_main, main_lock);
    try std.testing.expectEqualStrings(expect_wt, wt_lock);
    try std.testing.expect(!std.mem.eql(u8, main_lock, wt_lock));
}

test "create: two task workspaces get distinct checkouts and index.lock paths" {
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
    try git(io, a, &.{ "init", "-q", "-b", "main", root });
    try git(io, a, &.{ "-C", root, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", root, "config", "user.name", "t" });
    const tracked = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(tracked);
    {
        const f = try Io.Dir.cwd().createFile(io, tracked, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "x\n", 0);
    }
    try git(io, a, &.{ "-C", root, "add", "f" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "i" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const one = try ws.create(a, io, ar, .{ .slug = "agent-one", .cwd = root });
    const two = try ws.create(a, io, ar, .{ .slug = "agent-two", .cwd = root });
    try std.testing.expect(!std.mem.eql(u8, one.path, two.path));
    try std.testing.expect(!std.mem.eql(u8, one.branch, two.branch));
    try std.testing.expectEqualStrings("main", @import("worktree_base.zig").read(a, io, ar, root, one.branch));
    const git_one = ws.gitDirAt(a, io, ar, one.path);
    const git_two = ws.gitDirAt(a, io, ar, two.path);
    try std.testing.expect(git_one.len > 0 and git_two.len > 0);
    try std.testing.expect(!std.mem.eql(u8, git_one, git_two));
    const lock_one = ws.indexLockPath(ar, git_one) orelse return error.TestUnexpectedResult;
    const lock_two = ws.indexLockPath(ar, git_two) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, lock_one, lock_two));
    try std.testing.expect(std.mem.endsWith(u8, lock_one, "index.lock"));
    try std.testing.expect(std.mem.endsWith(u8, lock_two, "index.lock"));
    const claim_a = claim_path.canonicalFile(ar, io, one.path) orelse return error.TestUnexpectedResult;
    const claim_b = claim_path.canonicalFile(ar, io, two.path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(claim_a, claim_b);
    const collide = ws.create(a, io, ar, .{ .slug = "agent-one", .cwd = root });
    try std.testing.expectError(error.NameCollision, collide);
}

test "create: non-git folder is not a task workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    // std.testing.tmpDir lives inside this repo's cache, so git walks up to it.
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(a, "/tmp/graff-nongit-{s}", .{std.fmt.bytesToHex(raw, .lower)});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.NotAGitRepo, ws.create(a, io, arena.allocator(), .{ .slug = "x", .cwd = root }));
    try std.testing.expect(std.mem.indexOf(u8, ws.createFailureText(error.NotAGitRepo), "plain folder") != null);
}

test "preferRemoteBase: explicit wins, then origin, then empty (local HEAD)" {
    try std.testing.expectEqualStrings("feature", ws.preferRemoteBase("feature", "origin/main", true, true));
    try std.testing.expectEqualStrings("origin/develop", ws.preferRemoteBase("", "origin/develop", true, true));
    try std.testing.expectEqualStrings("origin/main", ws.preferRemoteBase("", "", true, true));
    try std.testing.expectEqualStrings("origin/master", ws.preferRemoteBase("", "", false, true));
    try std.testing.expectEqualStrings("", ws.preferRemoteBase("", "", false, false));
    try std.testing.expect(ws.envIsolationFallback("1"));
    try std.testing.expect(ws.envIsolationFallback("true"));
    try std.testing.expect(!ws.envIsolationFallback(null));
    try std.testing.expect(!ws.envIsolationFallback("0"));
    try std.testing.expect(ws.envSkipAutoIsolate("0"));
    try std.testing.expect(ws.envSkipAutoIsolate("off"));
    try std.testing.expect(!ws.envSkipAutoIsolate(null));
    try std.testing.expect(!ws.envSkipAutoIsolate("1"));
}

test "create: worktree starts from the remote base, not a stale local HEAD" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const remote = try std.fmt.allocPrint(a, "{s}/remote.git", .{tmp_root});
    defer a.free(remote);
    const seed = try std.fmt.allocPrint(a, "{s}/seed", .{tmp_root});
    defer a.free(seed);
    const clone = try std.fmt.allocPrint(a, "{s}/clone", .{tmp_root});
    defer a.free(clone);
    try git(io, a, &.{ "init", "-q", "-b", "main", "--bare", remote });
    try git(io, a, &.{ "clone", "-q", remote, seed });
    try git(io, a, &.{ "-C", seed, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", seed, "config", "user.name", "t" });
    const first = try std.fs.path.join(a, &.{ seed, "f" });
    defer a.free(first);
    {
        const f = try Io.Dir.cwd().createFile(io, first, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "old\n", 0);
    }
    try git(io, a, &.{ "-C", seed, "add", "f" });
    try git(io, a, &.{ "-C", seed, "commit", "-m", "old" });
    try git(io, a, &.{ "-C", seed, "push", "-q", "origin", "main" });
    try git(io, a, &.{ "clone", "-q", remote, clone });
    {
        const f = try Io.Dir.cwd().openFile(io, first, .{ .mode = .write_only });
        defer f.close(io);
        try f.writePositionalAll(io, "new\n", 0);
    }
    try git(io, a, &.{ "-C", seed, "add", "f" });
    try git(io, a, &.{ "-C", seed, "commit", "-m", "new" });
    try git(io, a, &.{ "-C", seed, "push", "-q", "origin", "main" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const stale = try headAt(io, a, ar, clone);
    const remote_head = try headAt(io, a, ar, seed);
    try std.testing.expect(!std.mem.eql(u8, stale, remote_head));
    const wt = try ws.create(a, io, ar, .{ .slug = "from-origin", .cwd = clone });
    try std.testing.expectEqualStrings(remote_head, try headAt(io, a, ar, wt.path));
    try std.testing.expectEqualStrings(remote_head, wt.base);
    const reused = try ws.ensure(a, io, ar, .{ .slug = "from-origin", .cwd = clone });
    try std.testing.expectEqualStrings(wt.path, reused.path);
}

test "archive: keeps dirty and unique-commit trees, removes a clean duplicate" {
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
    try git(io, a, &.{ "init", "-q", "-b", "main", root });
    try git(io, a, &.{ "-C", root, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", root, "config", "user.name", "t" });
    const tracked = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(tracked);
    {
        const f = try Io.Dir.cwd().createFile(io, tracked, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "x\n", 0);
    }
    try git(io, a, &.{ "-C", root, "add", "f" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "i" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const dirty = try ws.create(a, io, ar, .{ .slug = "dirty", .cwd = root });
    const extra = try std.fs.path.join(a, &.{ dirty.path, "extra" });
    defer a.free(extra);
    {
        const f = try Io.Dir.cwd().createFile(io, extra, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "y\n", 0);
    }
    const kept_dirty = try ws.archive(a, io, ar, root, "dirty");
    try std.testing.expect(!kept_dirty.removed);
    try std.testing.expectEqual(agent_worktree.KeepReason.dirty, kept_dirty.reason);

    const unique = try ws.create(a, io, ar, .{ .slug = "unique", .cwd = root });
    const extra2 = try std.fs.path.join(a, &.{ unique.path, "g" });
    defer a.free(extra2);
    {
        const f = try Io.Dir.cwd().createFile(io, extra2, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "z\n", 0);
    }
    try git(io, a, &.{ "-C", unique.path, "add", "g" });
    try git(io, a, &.{ "-C", unique.path, "commit", "-m", "only-here" });
    const kept_unique = try ws.archive(a, io, ar, root, "unique");
    try std.testing.expect(!kept_unique.removed);
    try std.testing.expectEqual(agent_worktree.KeepReason.committed, kept_unique.reason);

    _ = try ws.create(a, io, ar, .{ .slug = "clean", .cwd = root });
    const dropped = try ws.archive(a, io, ar, root, "clean");
    try std.testing.expect(dropped.removed);
    try std.testing.expectEqual(agent_worktree.KeepReason.removed, dropped.reason);
}

test "update: merges new main commits into a clean workspace" {
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
    try git(io, a, &.{ "init", "-q", "-b", "main", root });
    try git(io, a, &.{ "-C", root, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", root, "config", "user.name", "t" });
    const tracked = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(tracked);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tracked, .data = "old\n" });
    try git(io, a, &.{ "-C", root, "add", "f" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "old" });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const wt = try ws.create(a, io, ar, .{ .slug = "behind", .cwd = root });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tracked, .data = "new\n" });
    try git(io, a, &.{ "-C", root, "add", "f" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "new" });
    _ = try ws.update(a, io, ar, root, "behind");
    const got = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(ar, &.{ wt.path, "f" }), a, .limited(64));
    defer a.free(got);
    try std.testing.expectEqualStrings("new\n", got);
}

fn headAt(io: Io, a: Allocator, arena: Allocator, path: []const u8) ![]const u8 {
    const r = try runCapped(a, io, &.{ "git", "-C", path, "rev-parse", "HEAD" }, 4096, 4096, 15_000);
    defer {
        a.free(r.stdout);
        a.free(r.stderr);
    }
    if (!ranOk(r)) return error.TestUnexpectedResult;
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n"));
}

fn git(io: Io, a: Allocator, argv: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.append(a, "git");
    try args.appendSlice(a, argv);
    const r = try runCapped(a, io, args.items, 4096, 4096, 15_000);
    defer {
        a.free(r.stdout);
        a.free(r.stderr);
    }
    if (!ranOk(r)) return error.TestUnexpectedResult;
}
