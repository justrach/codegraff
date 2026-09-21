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
const agent_worktree = @import("agent_worktree.zig");
const worktree_prune = @import("worktree_prune.zig");

pub const CreateError = error{ NotAGitRepo, InvalidName, NameCollision, CreateFailed, Unsupported };
pub const ArchiveError = error{ InvalidName, NotFound, ArchiveFailed };

pub const AutoIsolate = union(enum) {
    skip,
    isolated: Workspace,
    failed: anyerror,
};

pub const ArchiveResult = struct {
    removed: bool,
    reason: agent_worktree.KeepReason,
    path: []const u8,
    branch: []const u8,
};

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

fn revExists(gpa: Allocator, io: Io, cwd: []const u8, rev: []const u8) bool {
    const r = runCapped(gpa, io, &.{ "git", "-C", cwd, "rev-parse", "--verify", "--quiet", rev }, 4096, 4096, 15_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return ranOk(r);
}

fn remoteHead(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8) []const u8 {
    const r = runCapped(gpa, io, &.{ "git", "-C", cwd, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" }, 4096, 4096, 15_000) catch return "";
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return "";
    const ref = std.mem.trim(u8, r.stdout, " \t\r\n");
    const prefix = "refs/remotes/";
    const short = if (std.mem.startsWith(u8, ref, prefix)) ref[prefix.len..] else ref;
    return arena.dupe(u8, short) catch "";
}

/// Conductor create: an explicit base wins; else origin/HEAD, origin/main, origin/master; else local HEAD.
pub fn preferRemoteBase(requested: []const u8, origin_head: []const u8, has_origin_main: bool, has_origin_master: bool) []const u8 {
    if (requested.len > 0) return requested;
    if (origin_head.len > 0) return origin_head;
    if (has_origin_main) return "origin/main";
    if (has_origin_master) return "origin/master";
    return "";
}

pub fn resolveCreateBase(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, requested: []const u8) []const u8 {
    if (requested.len > 0) return requested;
    if (runCapped(gpa, io, &.{ "git", "-C", cwd, "fetch", "--quiet", "origin" }, 4096, 4096, 60_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    return preferRemoteBase(
        requested,
        remoteHead(gpa, io, arena, cwd),
        revExists(gpa, io, cwd, "origin/main"),
        revExists(gpa, io, cwd, "origin/master"),
    );
}

pub fn envIsolationFallback(val: ?[]const u8) bool {
    const v = val orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
}

/// Shared-checkout fixtures / explicit same-tree work. Default remains isolate.
pub fn envSkipAutoIsolate(val: ?[]const u8) bool {
    const v = val orelse return false;
    return std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false");
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
    const base = resolveCreateBase(gpa, io, arena, opts.cwd, opts.base);
    try mintOnce(gpa, io, arena, opts.cwd, named.path, named.branch, base);
    const path = try absPath(io, arena, dest);
    return .{
        .name = named.name,
        .path = path,
        .branch = named.branch,
        .base = readHead(gpa, io, arena, path),
    };
}

/// Reuse an existing checkout, or mint one. `-w` tabs come through here.
pub fn ensure(gpa: Allocator, io: Io, arena: Allocator, opts: CreateOpts) (CreateError || Allocator.Error)!Workspace {
    if (!isGitAt(gpa, io, opts.cwd)) return error.NotAGitRepo;
    const named = try names(arena, opts.slug);
    const dest = try joinCwd(arena, opts.cwd, named.path);
    if (dirExists(io, dest)) {
        const path = try absPath(io, arena, dest);
        return .{
            .name = named.name,
            .path = path,
            .branch = named.branch,
            .base = readHead(gpa, io, arena, path),
        };
    }
    return create(gpa, io, arena, opts);
}

/// Archive removes a clean tree whose commits exist elsewhere. Dirty or unique-commit trees stay.
pub fn archive(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, slug: []const u8) (ArchiveError || Allocator.Error)!ArchiveResult {
    const named = try names(arena, slug);
    const dest = try joinCwd(arena, cwd, named.path);
    if (!dirExists(io, dest)) return error.NotFound;
    const path = try absPath(io, arena, dest);
    const kept = ArchiveResult{ .removed = false, .reason = .unverifiable, .path = path, .branch = named.branch };
    const st = runCapped(gpa, io, &.{ "git", "-C", dest, "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch return kept;
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }
    const head = readHead(gpa, io, arena, dest);
    const own = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{named.branch});
    const refs = runCapped(gpa, io, &.{ "git", "-C", cwd, "branch", "--all", "--contains", head, "--format=%(refname)" }, 1 << 16, 8192, 30_000) catch return kept;
    defer {
        gpa.free(refs.stdout);
        gpa.free(refs.stderr);
    }
    const contained = ranOk(refs) and worktree_prune.containedElsewhere(refs.stdout, own);
    const reason = agent_worktree.worktreeKeepReason(ranOk(st), st.stdout, worktree_prune.containmentBase(head, contained), head);
    if (reason != .removed) return .{ .removed = false, .reason = reason, .path = path, .branch = named.branch };
    if (runCapped(gpa, io, &.{ "git", "-C", cwd, "worktree", "remove", dest }, 8192, 8192, 30_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (!ranOk(r)) return error.ArchiveFailed;
    } else |_| return error.ArchiveFailed;
    if (runCapped(gpa, io, &.{ "git", "-C", cwd, "branch", "-D", named.branch }, 8192, 8192, 30_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    return .{ .removed = true, .reason = .removed, .path = path, .branch = named.branch };
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

pub fn enter(io: Io, arena: Allocator, wt: Workspace) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const z = try arena.dupeSentinel(u8, wt.path, 0);
    if (std.posix.system.chdir(z.ptr) != 0) return error.ChdirFailed;
    // Session arena outlives the process; GPA dupes leaked at shutdown.
    main_mod.g_cwd_display = try arena.dupe(u8, wt.path);
    main_mod.g_worktree_branch = try arena.dupe(u8, wt.branch);
    tool_spill.enable(.{ .io = io, .dir = .cwd(), .base_abs = main_mod.g_cwd_display });
}

/// Session-start hook: if another live session owns this checkout, mint and enter a tree.
/// A failed `git worktree add` is an isolation failure — do not stay on the claimed tree.
pub fn maybeAutoIsolate(gpa: Allocator, io: Io, arena: Allocator, home: []const u8, already_isolated: bool, lean: bool) AutoIsolate {
    if (builtin.os.tag == .windows) return .skip;
    const is_git = isGitAt(gpa, io, ".");
    const claimed = checkoutClaimed(gpa, io, arena, home);
    if (!shouldAutoIsolate(.{
        .already_isolated = already_isolated,
        .lean = lean,
        .is_git = is_git,
        .claimed = claimed,
        .windows = false,
    })) return .skip;
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const nonce = std.fmt.bytesToHex(raw, .lower);
    const slug = autoSlug(arena, proc_identity.selfPid(), nonce[0..8]) catch return .{ .failed = error.CreateFailed };
    const wt = create(gpa, io, arena, .{ .slug = slug, .unique = true }) catch |err| return .{ .failed = err };
    enter(io, arena, wt) catch |err| return .{ .failed = err };
    return .{ .isolated = wt };
}

pub fn createFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepo => "not a git repository — a task workspace needs a git repo; a plain folder stays a plain folder",
        error.InvalidName => "workspace name must be 1-64 letters, digits, '.', '_' or '-' (no slashes)",
        error.NameCollision => "that workspace name is already a worktree or branch — pick another name",
        error.CreateFailed => "git worktree add failed (dirty HEAD, a name collision, or a git error) — isolation failed; set GRAFF_ISOLATION_FALLBACK=1 only to stay on the shared checkout",
        else => "could not create a task workspace",
    };
}

pub fn archiveFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => createFailureText(error.InvalidName),
        error.NotFound => "no such task workspace — `graff worktree list` to see them",
        error.ArchiveFailed => "git worktree remove failed — the checkout was kept",
        else => "could not archive the task workspace",
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
    // std.testing.tmpDir lives inside this repo's cache, so git walks up to it.
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(a, "/tmp/graff-nongit-{s}", .{std.fmt.bytesToHex(raw, .lower)});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.NotAGitRepo, create(a, io, arena.allocator(), .{ .slug = "x", .cwd = root }));
    try std.testing.expect(std.mem.indexOf(u8, createFailureText(error.NotAGitRepo), "plain folder") != null);
}

test "preferRemoteBase: explicit wins, then origin, then empty (local HEAD)" {
    try std.testing.expectEqualStrings("feature", preferRemoteBase("feature", "origin/main", true, true));
    try std.testing.expectEqualStrings("origin/develop", preferRemoteBase("", "origin/develop", true, true));
    try std.testing.expectEqualStrings("origin/main", preferRemoteBase("", "", true, true));
    try std.testing.expectEqualStrings("origin/master", preferRemoteBase("", "", false, true));
    try std.testing.expectEqualStrings("", preferRemoteBase("", "", false, false));
    try std.testing.expect(envIsolationFallback("1"));
    try std.testing.expect(envIsolationFallback("true"));
    try std.testing.expect(!envIsolationFallback(null));
    try std.testing.expect(!envIsolationFallback("0"));
    try std.testing.expect(envSkipAutoIsolate("0"));
    try std.testing.expect(envSkipAutoIsolate("off"));
    try std.testing.expect(!envSkipAutoIsolate(null));
    try std.testing.expect(!envSkipAutoIsolate("1"));
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
    const stale = readHead(a, io, ar, clone);
    const remote_head = readHead(a, io, ar, seed);
    try std.testing.expect(!std.mem.eql(u8, stale, remote_head));
    const wt = try create(a, io, ar, .{ .slug = "from-origin", .cwd = clone });
    try std.testing.expectEqualStrings(remote_head, readHead(a, io, ar, wt.path));
    try std.testing.expectEqualStrings(remote_head, wt.base);
    const reused = try ensure(a, io, ar, .{ .slug = "from-origin", .cwd = clone });
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
    const dirty = try create(a, io, ar, .{ .slug = "dirty", .cwd = root });
    const extra = try std.fs.path.join(a, &.{ dirty.path, "extra" });
    defer a.free(extra);
    {
        const f = try Io.Dir.cwd().createFile(io, extra, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "y\n", 0);
    }
    const kept_dirty = try archive(a, io, ar, root, "dirty");
    try std.testing.expect(!kept_dirty.removed);
    try std.testing.expectEqual(agent_worktree.KeepReason.dirty, kept_dirty.reason);

    const unique = try create(a, io, ar, .{ .slug = "unique", .cwd = root });
    const extra2 = try std.fs.path.join(a, &.{ unique.path, "g" });
    defer a.free(extra2);
    {
        const f = try Io.Dir.cwd().createFile(io, extra2, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "z\n", 0);
    }
    try git(io, a, &.{ "-C", unique.path, "add", "g" });
    try git(io, a, &.{ "-C", unique.path, "commit", "-m", "only-here" });
    const kept_unique = try archive(a, io, ar, root, "unique");
    try std.testing.expect(!kept_unique.removed);
    try std.testing.expectEqual(agent_worktree.KeepReason.committed, kept_unique.reason);

    _ = try create(a, io, ar, .{ .slug = "clean", .cwd = root });
    const dropped = try archive(a, io, ar, root, "clean");
    try std.testing.expect(dropped.removed);
    try std.testing.expectEqual(agent_worktree.KeepReason.removed, dropped.reason);
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
