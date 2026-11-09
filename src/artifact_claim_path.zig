//! One claim ledger per canonical Git repository across linked worktrees and
//! same-remote clones (#1092, #1752).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const persist_rel = ".graff/artifact-claims.json";

/// Main checkout without remote: `.graff/artifact-claims.json` (#1092).
/// Linked worktree: `gitdir:` pointer → main checkout `.graff`.
/// Same-remote clones or explicit canonical repo (#1752): shared repository-keyed ledger.
pub fn canonicalFile(arena: Allocator, io: Io, cwd: []const u8) ?[]const u8 {
    return canonicalFileForRepo(arena, io, cwd, null);
}

pub fn canonicalFileForRepo(arena: Allocator, io: Io, cwd: []const u8, repo: ?[]const u8) ?[]const u8 {
    if (repo) |r| if (r.len > 0) return sharedRepoFile(arena, io, r);
    if (cwd.len == 0) return persist_rel;
    if (remoteIdentity(arena, io, cwd)) |remote_id| {
        return sharedRepoFile(arena, io, remote_id);
    }
    const root = checkoutRoot(arena, io, cwd) orelse {
        if (std.mem.eql(u8, cwd, ".")) return persist_rel;
        return std.fs.path.join(arena, &.{ cwd, persist_rel }) catch persist_rel;
    };
    if (std.mem.eql(u8, root, ".")) return persist_rel;
    return std.fs.path.join(arena, &.{ root, persist_rel }) catch persist_rel;
}

fn sharedRepoFile(arena: Allocator, io: Io, repo_id: []const u8) ?[]const u8 {
    var lower_buf: [512]u8 = undefined;
    const n = @min(repo_id.len, lower_buf.len);
    for (lower_buf[0..n], repo_id[0..n]) |*d, s| d.* = std.ascii.toLower(s);
    const h = std.hash.Wyhash.hash(0, lower_buf[0..n]);
    const dir = if (builtin.is_test)
        ".zig-cache/claims"
    else
        "/tmp/graff-claims";
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    return std.fmt.allocPrint(arena, "{s}/repo-{x:0>16}.json", .{ dir, h }) catch persist_rel;
}

fn checkoutRoot(arena: Allocator, io: Io, cwd: []const u8) ?[]const u8 {
    const common = commonGitDir(arena, io, cwd) orelse return null;
    return std.fs.path.dirname(common);
}

pub fn commonGitDir(arena: Allocator, io: Io, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0) return null;
    // If `cwd` is already a `.git` dir or worktree gitdir (from `presence.Owner.identity`).
    if (std.mem.endsWith(u8, cwd, "/.git") or std.mem.eql(u8, std.fs.path.basename(cwd), ".git")) {
        return resolveCommonFromGitDir(arena, io, cwd);
    }
    const direct_cfg = std.fs.path.join(arena, &.{ cwd, "config" }) catch return null;
    if (Io.Dir.cwd().statFile(io, direct_cfg, .{})) |st| {
        if (st.kind == .file) return resolveCommonFromGitDir(arena, io, cwd);
    } else |_| {}
    const d_commondir = std.fs.path.join(arena, &.{ cwd, "commondir" }) catch return null;
    if (Io.Dir.cwd().statFile(io, d_commondir, .{})) |st| {
        if (st.kind == .file) return resolveCommonFromGitDir(arena, io, cwd);
    } else |_| {}

    const git_here = std.fs.path.join(arena, &.{ cwd, ".git" }) catch return null;
    const st = Io.Dir.cwd().statFile(io, git_here, .{}) catch return null;
    if (st.kind == .directory) return git_here;
    if (st.kind != .file) return null;
    const text = Io.Dir.cwd().readFileAlloc(io, git_here, arena, .limited(4096)) catch return null;
    const line = std.mem.trim(u8, text, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const raw = std.mem.trim(u8, line[prefix.len..], " \t");
    const gitdir = if (std.fs.path.isAbsolute(raw))
        raw
    else
        (std.fs.path.resolve(arena, &.{ cwd, raw }) catch return null);
    return resolveCommonFromGitDir(arena, io, gitdir);
}

fn resolveCommonFromGitDir(arena: Allocator, io: Io, gitdir: []const u8) []const u8 {
    const marker = std.fs.path.join(arena, &.{ gitdir, "commondir" }) catch return gitdir;
    if (Io.Dir.cwd().readFileAlloc(io, marker, arena, .limited(256))) |cd| {
        const rel = std.mem.trim(u8, cd, " \t\r\n");
        if (rel.len == 0) return gitdir;
        if (std.fs.path.isAbsolute(rel)) return rel;
        return std.fs.path.resolve(arena, &.{ gitdir, rel }) catch gitdir;
    } else |_| return gitdir;
}

/// Extract canonical remote origin identity from `<common_git_dir>/config` (#1752).
pub fn remoteIdentity(arena: Allocator, io: Io, cwd: []const u8) ?[]const u8 {
    const common = commonGitDir(arena, io, cwd) orelse return null;
    const cfg_path = std.fs.path.join(arena, &.{ common, "config" }) catch return null;
    const cfg = Io.Dir.cwd().readFileAlloc(io, cfg_path, arena, .limited(16 * 1024)) catch return null;
    const raw_url = parseOriginUrl(cfg) orelse return null;
    return normalizeRemoteUrl(arena, common, raw_url);
}

fn parseOriginUrl(cfg: []const u8) ?[]const u8 {
    var in_origin = false;
    var lines = std.mem.splitScalar(u8, cfg, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            in_origin = std.mem.eql(u8, line, "[remote \"origin\"]");
            continue;
        }
        if (!in_origin) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(k, "url")) continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (v.len > 0) return v;
    }
    return null;
}

pub fn normalizeRemoteUrl(arena: Allocator, common_git_dir: []const u8, raw_url: []const u8) ?[]const u8 {
    var trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw_url, " \t\r\n"), "/");
    if (std.mem.endsWith(u8, trimmed, ".git")) trimmed = trimmed[0 .. trimmed.len - 4];
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")) {
        return (@import("artifact_repository.zig").fromUrl(arena, trimmed) catch null);
    }
    if (std.mem.startsWith(u8, trimmed, "git@")) {
        const after = trimmed["git@".len..];
        if (std.mem.indexOfScalar(u8, after, ':')) |colon| {
            const host = after[0..colon];
            const path = std.mem.trimStart(u8, after[colon + 1 ..], "/");
            const candidate = std.fmt.allocPrint(arena, "{s}/{s}", .{ host, path }) catch return null;
            if (@import("artifact_repository.zig").valid(candidate)) {
                return std.ascii.allocLowerString(arena, candidate) catch null;
            }
        }
    }
    if (std.fs.path.isAbsolute(trimmed)) return trimmed;
    const base = std.fs.path.dirname(common_git_dir) orelse common_git_dir;
    return std.fs.path.resolve(arena, &.{ base, trimmed }) catch trimmed;
}

/// True when `peer_identity` (from `presence.Owner.identity`) belongs to the
/// same canonical remote repository as `cwd` or `repo` (#1752).
pub fn sameRepositoryPeer(arena: Allocator, io: Io, cwd: []const u8, peer_identity: []const u8, repo: ?[]const u8) bool {
    if (peer_identity.len == 0) return false;
    const peer_remote = remoteIdentity(arena, io, peer_identity) orelse return false;
    if (repo) |r| {
        if (std.ascii.eqlIgnoreCase(peer_remote, r)) return true;
    }
    const my_remote = remoteIdentity(arena, io, cwd) orelse return false;
    return std.ascii.eqlIgnoreCase(peer_remote, my_remote);
}

pub fn legacyFile(arena: Allocator, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0) return null;
    return std.fs.path.join(arena, &.{ cwd, persist_rel }) catch null;
}

pub fn samePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "canonicalFile is identical across linked worktrees of one repo" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const root = try std.fmt.allocPrint(a, "{s}/repo-a", .{tmp_root});
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
    const other = try std.fmt.allocPrint(a, "{s}/repo-b", .{tmp_root});
    defer a.free(other);
    try git(io, a, &.{ "-C", root, "worktree", "add", "--detach", other });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const pa = canonicalFile(ar, io, root) orelse return error.TestUnexpectedResult;
    const pb = canonicalFile(ar, io, other) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(pa, pb);
    try std.testing.expect(std.mem.endsWith(u8, pa, persist_rel));
    const other_repo = try std.fmt.allocPrint(a, "{s}/other", .{tmp_root});
    defer a.free(other_repo);
    try Io.Dir.cwd().createDirPath(io, other_repo);
    try git(io, a, &.{ "init", "-q", "-b", "main", other_repo });
    const pc = canonicalFile(ar, io, other_repo) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, pa, pc));
}

test "claim follows a worktree switch and does not shadow another repo" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const claims = @import("artifact_claim.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const root = try std.fmt.allocPrint(a, "{s}/wt-main", .{tmp_root});
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
    const linked = try std.fmt.allocPrint(a, "{s}/wt-link", .{tmp_root});
    defer a.free(linked);
    try git(io, a, &.{ "-C", root, "worktree", "add", "--detach", linked });
    const other = try std.fmt.allocPrint(a, "{s}/wt-other", .{tmp_root});
    defer a.free(other);
    try Io.Dir.cwd().createDirPath(io, other);
    try git(io, a, &.{ "init", "-q", "-b", "main", other });
    try git(io, a, &.{ "-C", other, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", other, "config", "user.name", "t" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    claims.resetForTest();
    defer claims.resetForTest();
    claims.setTestResolveCwd(true);
    claims.setTestOwner(.{ .session = "s-a", .pid = 11, .start_id = 1 });
    claims.setTestOwnerLive(true);
    const claimed = try claims.handleToolIn(ar, io, "claim", "issue", "1092", "", root, null);
    try std.testing.expect(!claimed.is_error);
    const mine = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", linked, null);
    try std.testing.expect(std.mem.indexOf(u8, mine.text, "mine") != null);
    claims.setTestOwner(.{ .session = "s-b", .pid = 12, .start_id = 2 });
    const foreign = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", linked, null);
    try std.testing.expect(std.mem.indexOf(u8, foreign.text, "foreign") != null);
    const blocked = claims.gateCommandIn(ar, io, "gh issue comment 1092 --body x", "1092", linked);
    try std.testing.expect(blocked != null);
    claims.setTestOwner(.{ .session = "s-a", .pid = 11, .start_id = 1 });
    const released = try claims.handleToolIn(ar, io, "release", "issue", "1092", "", linked, null);
    try std.testing.expect(!released.is_error);
    const free_a = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", root, null);
    try std.testing.expectEqualStrings("no claim", free_a.text);
    const free_b = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", linked, null);
    try std.testing.expectEqualStrings("no claim", free_b.text);
    try std.testing.expect(claims.gateCommandIn(ar, io, "gh issue comment 1092 --body x", "1092", root) == null);
    const other_claim = try claims.handleToolIn(ar, io, "claim", "issue", "1092", "", other, null);
    try std.testing.expect(!other_claim.is_error);
    const still_free = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", root, null);
    try std.testing.expectEqualStrings("no claim", still_free.text);
}

pub fn git(io: Io, a: Allocator, argv: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.append(a, "git");
    try args.appendSlice(a, argv);
    const r = try runCapped(a, io, args.items, 4096, 4096, 15_000);
    defer {
        a.free(r.stdout);
        a.free(r.stderr);
    }
    if (!ranOk(r)) {
        std.debug.print("git {s} failed: {s}\n", .{ argv[0], r.stderr });
        return error.TestUnexpectedResult;
    }
}
