//! Per-agent git-worktree isolation for fanned-out subagents.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const warm_cache_dirs = [_][]const u8{ ".zig-cache", "zig-cache", "node_modules" };

const darwin_clone = if (builtin.os.tag == .macos) struct {
    extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
} else struct {};

/// Zero-copy CoW directory clone (`clonefile` on macOS APFS, `cp --reflink=always`
/// on Linux Btrfs/XFS). Returns false without falling back to a slow deep copy
/// when the filesystem does not support reflinks/CoW.
pub fn cloneCowTree(gpa: Allocator, io: Io, src_path: []const u8, dst_path: []const u8) bool {
    if (comptime builtin.os.tag == .macos) {
        const src_z = std.posix.toPosixPath(src_path) catch return false;
        const dst_z = std.posix.toPosixPath(dst_path) catch return false;
        return darwin_clone.clonefile(&src_z, &dst_z, 0) == 0;
    }
    if (comptime builtin.os.tag == .linux) {
        const r = runCapped(gpa, io, &.{ "cp", "--reflink=always", "-R", src_path, dst_path }, 1024, 1024, 10_000) catch return false;
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (!ranOk(r)) {
            Io.Dir.cwd().deleteTree(io, dst_path) catch {};
            return false;
        }
        return true;
    }
    return false;
}

/// Seed a newly created git worktree with CoW clones of gitignored build/dep
/// caches from the parent workspace (`src_cwd`), returning how many caches were
/// seeded. Only directories confirmed gitignored by `git check-ignore -q` are
/// seeded so `git status --porcelain` in the worktree stays clean.
pub fn seedWarmCaches(gpa: Allocator, io: Io, arena: Allocator, src_cwd: []const u8, dst_wt: []const u8) usize {
    var seeded: usize = 0;
    var argv_buf: [24][]const u8 = undefined;
    for (warm_cache_dirs) |name| {
        const src_dir = std.fs.path.join(arena, &.{ src_cwd, name }) catch continue;
        const st = Io.Dir.cwd().statFile(io, src_dir, .{}) catch continue;
        if (st.kind != .directory) continue;
        const dst_dir = std.fs.path.join(arena, &.{ dst_wt, name }) catch continue;
        if (Io.Dir.cwd().statFile(io, dst_dir, .{})) |_| continue else |_| {}
        const ign = runCapped(gpa, io, safeGitArgv(&argv_buf, dst_wt, &.{ "check-ignore", "-q", name }), 1024, 1024, 5_000) catch continue;
        defer {
            gpa.free(ign.stdout);
            gpa.free(ign.stderr);
        }
        if (!ranOk(ign)) continue;
        if (cloneCowTree(gpa, io, src_dir, dst_dir)) seeded += 1;
    }
    return seeded;
}

fn cleanWarmCaches(io: Io, wt_path: []const u8) void {
    var dir = Io.Dir.cwd().openDir(io, wt_path, .{}) catch return;
    defer dir.close(io);
    for (warm_cache_dirs) |name| {
        dir.deleteTree(io, name) catch {};
    }
}

pub const AgentWorktree = struct { path: []const u8, branch: []const u8, base: []const u8 = "" };
pub const AgentWorktreeError = error{ NotAGitRepo, CreateFailed };
pub const AgentWorktreeOutcome = struct { kept: bool, reason: KeepReason = .removed };

pub const KeepReason = enum { removed, dirty, committed, unverifiable };

/// Hardened git `-c` flags for isolated subagent worktree operations:
/// - `core.hooksPath=/dev/null`: never run untrusted repository hooks (`post-checkout`, etc.).
/// - `core.fsmonitor=false`: never spawn background `fsmonitor` daemons inside `.graff/worktrees/`.
/// - `filter.lfs.smudge=`, `filter.lfs.process=`, `filter.lfs.required=false`: never hang on Git LFS smudge filters.
pub const safe_git_config_args = [_][]const u8{
    "-c", "safe.directory=*",
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "filter.lfs.smudge=",
    "-c", "filter.lfs.process=",
    "-c", "filter.lfs.required=false",
};

pub fn safeGitArgv(buf: *[24][]const u8, cwd: ?[]const u8, tail: []const []const u8) []const []const u8 {
    var i: usize = 0;
    buf[i] = "git";
    i += 1;
    if (cwd) |dir| {
        buf[i] = "-C";
        buf[i + 1] = dir;
        i += 2;
    }
    for (safe_git_config_args) |arg| {
        buf[i] = arg;
        i += 1;
    }
    for (tail) |arg| {
        buf[i] = arg;
        i += 1;
    }
    return buf[0..i];
}

/// Pure removal decision. `status_ok`/`porcelain` are the `git status --porcelain`
/// result in the worktree; `head` is `git rev-parse HEAD` there (empty when it
/// could not be read); `base` is the commit the worktree was created at (empty
/// when unknown). Removal requires positive proof on every axis - anything we
/// could not establish keeps the worktree, because `git branch -D` on a branch
/// whose commits nothing else references destroys the child's work silently.
pub fn worktreeKeepReason(status_ok: bool, porcelain: []const u8, base: []const u8, head: []const u8) KeepReason {
    if (!status_ok) return .unverifiable;
    if (isWorktreeStatusDirty(porcelain)) return .dirty;
    if (base.len == 0 or head.len == 0) return .unverifiable;
    if (!std.mem.eql(u8, base, head)) return .committed;
    return .removed;
}

pub fn keepReasonText(reason: KeepReason) []const u8 {
    return switch (reason) {
        .dirty => "has changes",
        .committed => "has commits that exist ONLY on this branch — keep this tree; merge or cherry-pick later, do not spawn a cleanup child",
        .unverifiable => "could not verify it is safe to remove",
        .removed => "",
    };
}

pub fn isolationFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepo => "isolation:\"worktree\" requested but this isn't a git repository (or `git` isn't on PATH) — worktrees need a git repo; drop isolation, or set isolation_fallback:true to run in the shared working tree instead",
        error.CreateFailed => "isolation:\"worktree\" requested but `git worktree add` failed (dirty HEAD, a name collision, or a git error) — set isolation_fallback:true to run in the shared working tree instead, or retry",
        else => "isolation:\"worktree\" requested but setup failed — set isolation_fallback:true to run in the shared working tree instead, or retry",
    };
}

pub fn agentWorktreeNames(arena: Allocator, sub_id: []const u8, nonce: []const u8) !AgentWorktree {
    return .{
        .path = try std.fmt.allocPrint(arena, ".graff/worktrees/agent-{s}-{s}", .{ sub_id, nonce }),
        .branch = try std.fmt.allocPrint(arena, "graff/agents/{s}-{s}", .{ sub_id, nonce }),
    };
}

pub fn agentWorktreeCreate(gpa: Allocator, io: Io, arena: Allocator, sub_id: []const u8) (AgentWorktreeError || Allocator.Error)!AgentWorktree {
    return agentWorktreeCreateAt(gpa, io, arena, sub_id, ".");
}

pub fn agentWorktreeCreateAt(gpa: Allocator, io: Io, arena: Allocator, sub_id: []const u8, cwd: []const u8) (AgentWorktreeError || Allocator.Error)!AgentWorktree {
    var argv_buf: [24][]const u8 = undefined;
    const probe = runCapped(gpa, io, safeGitArgv(&argv_buf, cwd, &.{ "rev-parse", "--is-inside-work-tree" }), 4096, 4096, 15_000) catch return error.NotAGitRepo;
    defer {
        gpa.free(probe.stdout);
        gpa.free(probe.stderr);
    }
    if (!ranOk(probe)) return error.NotAGitRepo;

    var raw: [4]u8 = undefined;
    io.random(&raw);
    const nonce = std.fmt.bytesToHex(raw, .lower);
    var names = try agentWorktreeNames(arena, sub_id, &nonce);
    names.path = try std.fs.path.join(arena, &.{ cwd, names.path });
    var absolute: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_abs = absolute[0 .. Io.Dir.cwd().realPathFile(io, cwd, &absolute) catch return error.NotAGitRepo];
    names.path = try std.fs.path.resolve(arena, &.{ cwd_abs, ".graff/worktrees", std.fs.path.basename(names.path) });
    const add = runCapped(gpa, io, safeGitArgv(&argv_buf, cwd, &.{ "worktree", "add", names.path, "-b", names.branch }), 8192, 8192, 60_000) catch return error.CreateFailed;
    defer {
        gpa.free(add.stdout);
        gpa.free(add.stderr);
    }
    if (!ranOk(add)) return error.CreateFailed;
    @import("graff_dir.zig").ensureIgnoreAt(io, cwd); // #1273: hide .graff/worktrees
    _ = seedWarmCaches(gpa, io, arena, cwd_abs, names.path);

    var base: []const u8 = "";
    if (runCapped(gpa, io, safeGitArgv(&argv_buf, names.path, &.{ "rev-parse", "HEAD" }), 4096, 4096, 15_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (ranOk(r)) base = try arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n"));
    } else |_| {}

    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, names.path, &buf) catch return .{ .path = names.path, .branch = names.branch, .base = base };
    return .{ .path = try arena.dupe(u8, buf[0..n]), .branch = names.branch, .base = base };
}

pub fn isWorktreeStatusDirty(porcelain: []const u8) bool {
    return std.mem.trim(u8, porcelain, " \t\r\n").len > 0;
}

pub fn agentWorktreeFinish(gpa: Allocator, io: Io, wt: AgentWorktree) AgentWorktreeOutcome {
    var argv_buf: [24][]const u8 = undefined;
    const st = runCapped(gpa, io, safeGitArgv(&argv_buf, wt.path, &.{ "status", "--porcelain" }), 1 << 16, 8192, 30_000) catch return .{ .kept = true, .reason = .unverifiable };
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }

    var head: []const u8 = "";
    var head_buf: [4096]u8 = undefined;
    var head_len: usize = 0;
    if (runCapped(gpa, io, safeGitArgv(&argv_buf, wt.path, &.{ "rev-parse", "HEAD" }), 4096, 4096, 15_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (ranOk(r)) {
            const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
            head_len = @min(trimmed.len, head_buf.len);
            @memcpy(head_buf[0..head_len], trimmed[0..head_len]);
            head = head_buf[0..head_len];
        }
    } else |_| {}

    const reason = worktreeKeepReason(ranOk(st), st.stdout, wt.base, head);
    if (reason != .removed) return .{ .kept = true, .reason = reason };

    // Remove untracked CoW-seeded cache directories before `git worktree remove`
    // so clean worktrees aren't rejected by git for containing untracked cache trees.
    cleanWarmCaches(io, wt.path);

    if (runCapped(gpa, io, safeGitArgv(&argv_buf, null, &.{ "worktree", "remove", wt.path }), 8192, 8192, 30_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (!ranOk(r)) return .{ .kept = true, .reason = .unverifiable };
    } else |_| return .{ .kept = true, .reason = .unverifiable };

    if (runCapped(gpa, io, safeGitArgv(&argv_buf, null, &.{ "branch", "-D", wt.branch }), 8192, 8192, 30_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    return .{ .kept = false, .reason = .removed };
}

test "agentWorktreeNames: unique path/branch per nonce, never collide across repeated spawns (#276)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const first = try agentWorktreeNames(a, "sa-001-dead", "aa11bb22");
    try std.testing.expectEqualStrings(".graff/worktrees/agent-sa-001-dead-aa11bb22", first.path);
    try std.testing.expectEqualStrings("graff/agents/sa-001-dead-aa11bb22", first.branch);

    const second = try agentWorktreeNames(a, "sa-001-dead", "cc33dd44");
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    try std.testing.expect(!std.mem.eql(u8, first.branch, second.branch));
}

test "isWorktreeStatusDirty: clean drives auto-cleanup, tracked or untracked changes drive retention (#276)" {
    try std.testing.expect(!isWorktreeStatusDirty(""));
    try std.testing.expect(!isWorktreeStatusDirty("\n  \n"));
    try std.testing.expect(isWorktreeStatusDirty(" M src/foo.zig\n"));
    try std.testing.expect(isWorktreeStatusDirty("?? new_file.zig\n"));
}

test "isolationFailureText: friendly, distinct messages for the non-git and create-failed error paths (#276)" {
    const not_git = isolationFailureText(error.NotAGitRepo);
    try std.testing.expect(std.mem.indexOf(u8, not_git, "isn't a git repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_git, "isolation_fallback") != null);

    const create_failed = isolationFailureText(error.CreateFailed);
    try std.testing.expect(std.mem.indexOf(u8, create_failed, "git worktree add") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_failed, "isolation_fallback") != null);
    try std.testing.expect(!std.mem.eql(u8, not_git, create_failed));
}

test "worktreeKeepReason: committed work is never removable, and every unproven axis keeps the worktree" {
    try std.testing.expectEqual(KeepReason.removed, worktreeKeepReason(true, "", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.dirty, worktreeKeepReason(true, " M src/foo.zig\n", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.dirty, worktreeKeepReason(true, "?? new.zig\n", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.committed, worktreeKeepReason(true, "", "abc123", "def456"));
    try std.testing.expectEqual(KeepReason.committed, worktreeKeepReason(true, "\n  \n", "abc123", "def456"));
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(false, "", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(true, "", "", "def456"));
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(true, "", "abc123", ""));
}

test "keepReasonText: each kept reason names its cause, and .dirty keeps its historical wording" {
    try std.testing.expectEqualStrings("has changes", keepReasonText(.dirty));
    const committed = keepReasonText(.committed);
    try std.testing.expect(std.mem.indexOf(u8, committed, "commits") != null);
    try std.testing.expect(std.mem.indexOf(u8, committed, "cherry-pick") != null);
    try std.testing.expect(!std.mem.eql(u8, keepReasonText(.committed), keepReasonText(.unverifiable)));
    try std.testing.expect(!std.mem.eql(u8, keepReasonText(.unverifiable), keepReasonText(.dirty)));
    try std.testing.expect(!std.mem.eql(u8, keepReasonText(.committed), keepReasonText(.dirty)));
}

test "safeGitArgv: prefixes git commands with hooksPath=/dev/null, fsmonitor=false, and disabled LFS smudge filters" {
    var buf: [24][]const u8 = undefined;
    const argv = safeGitArgv(&buf, "/tmp/repo", &.{ "worktree", "add", "/tmp/wt", "-b", "graff/agents/x" });
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("-C", argv[1]);
    try std.testing.expectEqualStrings("/tmp/repo", argv[2]);
    const joined = try std.mem.join(std.testing.allocator, " ", argv);
    defer std.testing.allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-c core.hooksPath=/dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-c core.fsmonitor=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-c filter.lfs.smudge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-c filter.lfs.process=") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "-c filter.lfs.required=false") != null);
    try std.testing.expect(std.mem.endsWith(u8, joined, "worktree add /tmp/wt -b graff/agents/x"));
}

test "cloneCowTree: clones existing cache directory into worktree via CoW/reflink" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = abs_buf[0..try tmp.dir.realPathFile(io, ".", &abs_buf)];
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src_cache = try std.fs.path.join(arena, &.{ root, ".zig-cache" });
    const dst_wt = try std.fs.path.join(arena, &.{ root, "wt" });
    const dst_cache = try std.fs.path.join(arena, &.{ dst_wt, ".zig-cache" });
    try Io.Dir.cwd().createDirPath(io, src_cache);
    try Io.Dir.cwd().createDirPath(io, dst_wt);
    const probe_src = try std.fs.path.join(arena, &.{ src_cache, "stamp.txt" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = probe_src, .data = "warm-cache" });

    const cloned = cloneCowTree(gpa, io, src_cache, dst_cache);
    if (comptime builtin.os.tag == .macos) {
        try std.testing.expect(cloned);
    }
    if (cloned) {
        const probe_dst = try std.fs.path.join(arena, &.{ dst_cache, "stamp.txt" });
        const read_back = try Io.Dir.cwd().readFileAlloc(io, probe_dst, arena, .limited(64));
        try std.testing.expectEqualStrings("warm-cache", read_back);
    } else {
        // Non-CoW filesystems (e.g. Linux ext4, Windows NTFS) must return false
        // without falling back to a slow deep copy.
        try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, dst_cache, .{}));
        try Io.Dir.cwd().createDirPath(io, dst_cache);
    }

    cleanWarmCaches(io, dst_wt);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, dst_cache, .{}));
}
