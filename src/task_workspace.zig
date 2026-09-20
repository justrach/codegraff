//! Task workspace = one Git worktree + one branch + one checkout.
//! Concurrent root sessions auto-isolate so they never share `index.lock`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;
const lease = @import("worktree_lease.zig");
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");
const main_mod = @import("main.zig");
const tool_spill = @import("tool_spill.zig");
const claim_path = @import("artifact_claim_path.zig");

pub const CreateError = error{ NotAGitRepo, InvalidName, NameCollision, CreateFailed, Unsupported };

pub const CreateOpts = struct {
    slug: []const u8,
    base: []const u8 = "",
    cwd: []const u8 = ".",
    unique: bool = false,
};

pub const Workspace = struct {
    name: []const u8,
    path: []const u8,
    branch: []const u8,
    base: []const u8 = "",
};

pub const AutoOpts = struct {
    already_isolated: bool = false,
    lean: bool = false,
    is_git: bool = false,
    claimed: bool = false,
    windows: bool = false,
};

/// Concurrent interactive sessions isolate. Lean/-p oneshots stay put (ADR 0024).
/// `-w` already isolated. Non-git folders stay plain folders. Windows has no chdir.
pub fn shouldAutoIsolate(opts: AutoOpts) bool {
    if (opts.windows or opts.already_isolated or opts.lean or !opts.is_git) return false;
    return opts.claimed;
}

pub fn sanitizeSlug(s: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0 or t.len > 64) return null;
    if (std.mem.indexOfScalar(u8, t, '/') != null or std.mem.indexOfScalar(u8, t, '\\') != null) return null;
    if (std.mem.eql(u8, t, ".") or std.mem.eql(u8, t, "..")) return null;
    for (t) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return null;
    }
    return t;
}

pub fn names(arena: Allocator, slug: []const u8) !Workspace {
    const name = sanitizeSlug(slug) orelse return error.InvalidName;
    return .{
        .name = name,
        .path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{name}),
        .branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{name}),
    };
}

pub fn autoSlug(arena: Allocator, pid: i32, nonce: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "session-{d}-{s}", .{ pid, nonce });
}

/// `{git-dir}/index.lock` — distinct per worktree, shared object DB is fine.
pub fn indexLockPath(arena: Allocator, git_dir: []const u8) ?[]const u8 {
    const dir = std.mem.trimEnd(u8, git_dir, "/");
    if (dir.len == 0) return null;
    return std.fs.path.join(arena, &.{ dir, "index.lock" }) catch null;
}

pub fn gitDirAt(gpa: Allocator, io: Io, arena: Allocator, checkout: []const u8) []const u8 {
    return lease.identityAt(gpa, io, arena, checkout).id;
}

fn isGitAt(gpa: Allocator, io: Io, cwd: []const u8) bool {
    const r = runCapped(gpa, io, &.{ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" }, 4096, 4096, 15_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return ranOk(r);
}

fn dirExists(io: Io, path: []const u8) bool {
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

fn joinCwd(arena: Allocator, cwd: []const u8, rel: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return arena.dupe(u8, rel);
    if (std.mem.eql(u8, cwd, ".") or cwd.len == 0) return arena.dupe(u8, rel);
    return std.fs.path.join(arena, &.{ cwd, rel });
}

fn refExists(gpa: Allocator, io: Io, cwd: []const u8, branch: []const u8) bool {
    const ref = std.fmt.allocPrint(gpa, "refs/heads/{s}", .{branch}) catch return false;
    defer gpa.free(ref);
    const r = runCapped(gpa, io, &.{ "git", "-C", cwd, "show-ref", "--verify", "--quiet", ref }, 4096, 4096, 15_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return ranOk(r);
}

fn absPath(io: Io, arena: Allocator, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return arena.dupe(u8, path);
    return arena.dupe(u8, buf[0..n]);
}

fn readHead(gpa: Allocator, io: Io, arena: Allocator, path: []const u8) []const u8 {
    const r = runCapped(gpa, io, &.{ "git", "-C", path, "rev-parse", "HEAD" }, 4096, 4096, 15_000) catch return "";
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return "";
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch "";
}

fn mintOnce(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, rel: []const u8, branch: []const u8, base: []const u8) !void {
    const dest = try joinCwd(arena, cwd, rel);
    const parent = std.fs.path.dirname(dest) orelse dest;
    Io.Dir.cwd().createDirPath(io, parent) catch {};
    const add = if (base.len > 0)
        runCapped(gpa, io, &.{ "git", "-C", cwd, "worktree", "add", dest, "-b", branch, base }, 8192, 8192, 60_000)
    else
        runCapped(gpa, io, &.{ "git", "-C", cwd, "worktree", "add", dest, "-b", branch }, 8192, 8192, 60_000);
    const r = add catch return error.CreateFailed;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return error.CreateFailed;
}

pub fn create(gpa: Allocator, io: Io, arena: Allocator, opts: CreateOpts) (CreateError || Allocator.Error)!Workspace {
    if (!isGitAt(gpa, io, opts.cwd)) return error.NotAGitRepo;
    var named = try names(arena, opts.slug);
    var dest = try joinCwd(arena, opts.cwd, named.path);
    if (dirExists(io, dest) or refExists(gpa, io, opts.cwd, named.branch)) {
        if (!opts.unique) return error.NameCollision;
        var raw: [4]u8 = undefined;
        io.random(&raw);
        const nonce = std.fmt.bytesToHex(raw, .lower);
        const slug = try std.fmt.allocPrint(arena, "{s}-{s}", .{ named.name, nonce[0..8] });
        named = try names(arena, slug);
        dest = try joinCwd(arena, opts.cwd, named.path);
        if (dirExists(io, dest) or refExists(gpa, io, opts.cwd, named.branch)) return error.NameCollision;
    }
    try mintOnce(gpa, io, arena, opts.cwd, named.path, named.branch, opts.base);
    const path = try absPath(io, arena, dest);
    return .{
        .name = named.name,
        .path = path,
        .branch = named.branch,
        .base = readHead(gpa, io, arena, path),
    };
}

/// Live foreign owner of THIS checkout, if any. Read-only: does not announce.
pub fn checkoutClaimed(gpa: Allocator, io: Io, arena: Allocator, home: []const u8) bool {
    if (home.len == 0) return false;
    const identity = lease.currentIdentity(gpa, io, arena);
    if (identity.id.len == 0 or identity.kind == .not_git) return false;
    const dir_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, presence.registry_subdir }) catch return false;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    const peers = presence.listPeers(io, arena, dir);
    const self = proc_identity.selfPid();
    return lease.duplicateOwner(peers.records, peers.probes, identity.id, self) != null;
}

pub fn enter(gpa: Allocator, io: Io, arena: Allocator, wt: Workspace) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const z = try arena.dupeSentinel(u8, wt.path, 0);
    if (std.posix.system.chdir(z.ptr) != 0) return error.ChdirFailed;
    const owned_path = try gpa.dupe(u8, wt.path);
    const owned_branch = try gpa.dupe(u8, wt.branch);
    main_mod.g_cwd_display = owned_path;
    main_mod.g_worktree_branch = owned_branch;
    tool_spill.enable(.{ .io = io, .dir = .cwd(), .base_abs = main_mod.g_cwd_display });
}

/// Session-start hook: if another live session owns this checkout, mint and enter a tree.
pub fn maybeAutoIsolate(gpa: Allocator, io: Io, arena: Allocator, home: []const u8, already_isolated: bool, lean: bool) ?Workspace {
    if (builtin.os.tag == .windows) return null;
    const is_git = isGitAt(gpa, io, ".");
    const claimed = checkoutClaimed(gpa, io, arena, home);
    if (!shouldAutoIsolate(.{
        .already_isolated = already_isolated,
        .lean = lean,
        .is_git = is_git,
        .claimed = claimed,
        .windows = false,
    })) return null;
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const nonce = std.fmt.bytesToHex(raw, .lower);
    const slug = autoSlug(arena, proc_identity.selfPid(), nonce[0..8]) catch return null;
    const wt = create(gpa, io, arena, .{ .slug = slug, .unique = true }) catch return null;
    enter(gpa, io, arena, wt) catch return null;
    return wt;
}

pub fn createFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepo => "not a git repository — a task workspace needs a git repo; a plain folder stays a plain folder",
        error.InvalidName => "workspace name must be 1-64 letters, digits, '.', '_' or '-' (no slashes)",
        error.NameCollision => "that workspace name is already a worktree or branch — pick another name",
        error.CreateFailed => "git worktree add failed (dirty HEAD, a name collision, or a git error)",
        else => "could not create a task workspace",
    };
}

test "shouldAutoIsolate: only a claimed interactive git checkout isolates" {
    try std.testing.expect(!shouldAutoIsolate(.{ .claimed = true, .is_git = true, .already_isolated = true }));
    try std.testing.expect(!shouldAutoIsolate(.{ .claimed = true, .is_git = true, .lean = true }));
    try std.testing.expect(!shouldAutoIsolate(.{ .claimed = true, .is_git = true, .windows = true }));
    try std.testing.expect(!shouldAutoIsolate(.{ .claimed = true, .is_git = false }));
    try std.testing.expect(!shouldAutoIsolate(.{ .claimed = false, .is_git = true }));
    try std.testing.expect(shouldAutoIsolate(.{ .claimed = true, .is_git = true }));
}

test "sanitizeSlug and names: one workspace is one branch and one checkout path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(sanitizeSlug("") == null);
    try std.testing.expect(sanitizeSlug("a/b") == null);
    try std.testing.expect(sanitizeSlug("..") == null);
    try std.testing.expect(sanitizeSlug("ok_name-1") != null);
    const first = try names(a, "task-a");
    try std.testing.expectEqualStrings(".graff/worktrees/task-a", first.path);
    try std.testing.expectEqualStrings("worktree-task-a", first.branch);
    const second = try names(a, "task-b");
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    try std.testing.expect(!std.mem.eql(u8, first.branch, second.branch));
}

test "indexLockPath: two worktree git dirs never share a lock file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const main_lock = indexLockPath(a, "/repo/.git") orelse return error.TestUnexpectedResult;
    const wt_lock = indexLockPath(a, "/repo/.git/worktrees/session-1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/repo/.git/index.lock", main_lock);
    try std.testing.expectEqualStrings("/repo/.git/worktrees/session-1/index.lock", wt_lock);
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
    const one = try create(a, io, ar, .{ .slug = "agent-one", .cwd = root });
    const two = try create(a, io, ar, .{ .slug = "agent-two", .cwd = root });
    try std.testing.expect(!std.mem.eql(u8, one.path, two.path));
    try std.testing.expect(!std.mem.eql(u8, one.branch, two.branch));
    const git_one = gitDirAt(a, io, ar, one.path);
    const git_two = gitDirAt(a, io, ar, two.path);
    try std.testing.expect(git_one.len > 0 and git_two.len > 0);
    try std.testing.expect(!std.mem.eql(u8, git_one, git_two));
    const lock_one = indexLockPath(ar, git_one) orelse return error.TestUnexpectedResult;
    const lock_two = indexLockPath(ar, git_two) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, lock_one, lock_two));
    try std.testing.expect(std.mem.endsWith(u8, lock_one, "index.lock"));
    try std.testing.expect(std.mem.endsWith(u8, lock_two, "index.lock"));
    const claim_a = claim_path.canonicalFile(ar, io, one.path) orelse return error.TestUnexpectedResult;
    const claim_b = claim_path.canonicalFile(ar, io, two.path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(claim_a, claim_b);
    const collide = create(a, io, ar, .{ .slug = "agent-one", .cwd = root });
    try std.testing.expectError(error.NameCollision, collide);
}

test "create: non-git folder is not a task workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.NotAGitRepo, create(a, io, arena.allocator(), .{ .slug = "x", .cwd = tmp_root }));
    try std.testing.expect(std.mem.indexOf(u8, createFailureText(error.NotAGitRepo), "plain folder") != null);
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
