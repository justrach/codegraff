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
const agent_worktree = @import("agent_worktree.zig");
const worktree_prune = @import("worktree_prune.zig");
const workspace_prepare = @import("workspace_prepare.zig");

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
    copied: usize = 0,
    setup_ran: bool = false,
    setup_ok: bool = true,
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
    const prep = workspace_prepare.afterCreate(gpa, io, arena, opts.cwd, path, named.name);
    return .{
        .name = named.name,
        .path = path,
        .branch = named.branch,
        .base = readHead(gpa, io, arena, path),
        .copied = prep.copied,
        .setup_ran = prep.setup_ran,
        .setup_ok = prep.setup_ok,
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
    workspace_prepare.beforeArchive(gpa, io, arena, cwd, path, named.name);
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
