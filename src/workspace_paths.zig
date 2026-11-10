//! Worktree path canonicalization, enclosing-tree resolution, subfolder offset
//! preservation, and `.git` backlink health checks.
//!
//! Split out of `workspace_switch.zig` to keep every module well below the
//! 600-line ceiling while supporting monorepo/subfolder sessions.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const policy = @import("harness_policy.zig");

pub const Entry = struct {
    path: []const u8,
    head: []const u8 = "",
    branch: []const u8 = "",
    prunable: bool = false,
};

pub const GitBacklinkHealth = enum {
    healthy,
    not_git_dir,
    missing_checkout,
    broken_gitdir,
};

fn branchShort(ref: []const u8) []const u8 {
    const prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref, prefix)) return ref[prefix.len..];
    return ref;
}

/// Copy `s` into the arena so a row does not alias the caller's buffer (#715).
fn own(arena: Allocator, s: []const u8) []const u8 {
    return arena.dupe(u8, s) catch "";
}

fn isPrunableAttr(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "prunable")) return false;
    return line.len == "prunable".len or line["prunable".len] == ' ' or line["prunable".len] == '\t';
}

/// Parse `git worktree list --porcelain`. Every row owns its bytes (#715).
pub fn parsePorcelain(arena: Allocator, text: []const u8) []Entry {
    var list: std.ArrayList(Entry) = .empty;
    var cur: Entry = .{ .path = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            if (cur.path.len > 0) list.append(arena, cur) catch {};
            cur = .{ .path = "" };
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (cur.path.len > 0) list.append(arena, cur) catch {};
            cur = .{ .path = own(arena, std.mem.trim(u8, line["worktree ".len..], " \t")) };
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            cur.head = own(arena, std.mem.trim(u8, line["HEAD ".len..], " \t"));
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            cur.branch = own(arena, branchShort(std.mem.trim(u8, line["branch ".len..], " \t")));
        } else if (isPrunableAttr(line)) {
            cur.prunable = true;
        }
    }
    if (cur.path.len > 0) list.append(arena, cur) catch {};
    return list.items;
}

pub fn trimTrailingSep(p: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, p, "/\\");
    if (trimmed.len == 0 and p.len > 0 and std.fs.path.isSep(p[0])) return p[0..1];
    return trimmed;
}

/// Resolve `path` via a freshly opened Dir — not `Dir.cwd().realPath`, which
/// Threaded Io can keep stale across posix.chdir (#721).
pub fn realpathOs(io: Io, path: []const u8, out: []u8) ?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    defer dir.close(io);
    const n = dir.realPath(io, out) catch return null;
    return out[0..n];
}

pub fn samePath(io: Io, a: []const u8, b: []const u8) bool {
    const left = trimTrailingSep(a);
    const right = trimTrailingSep(b);
    if (std.mem.eql(u8, left, right)) return true;
    if (left.len == 0 or right.len == 0) return false;
    var ab: [std.fs.max_path_bytes]u8 = undefined;
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const ar = realpathOs(io, left, &ab) orelse return false;
    const br = realpathOs(io, right, &bb) orelse return false;
    return std.mem.eql(u8, trimTrailingSep(ar), trimTrailingSep(br));
}

fn hasDotDot(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

fn canonicalOrTrimmed(io: Io, path: []const u8, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    const trimmed = trimTrailingSep(path);
    if (trimmed.len == 0) return "";
    if (realpathOs(io, trimmed, buf)) |real| return trimTrailingSep(real);
    return trimmed;
}

pub fn pathBeneath(child: []const u8, root: []const u8) bool {
    if (root.len == 0 or child.len == 0) return false;
    if (!std.mem.startsWith(u8, child, root)) return false;
    if (child.len == root.len) return true;
    return std.fs.path.isSep(root[root.len - 1]) or std.fs.path.isSep(child[root.len]);
}

/// True when `target` is equal to or a descendant directory inside `root`,
/// comparing canonical OS paths when mounted and lexical paths otherwise.
pub fn containsPath(io: Io, root: []const u8, target: []const u8) bool {
    if (root.len == 0 or target.len == 0) return false;
    if (hasDotDot(root) or hasDotDot(target)) return false;
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    var tb: [std.fs.max_path_bytes]u8 = undefined;
    const r = canonicalOrTrimmed(io, root, &rb);
    const t = canonicalOrTrimmed(io, target, &tb);
    return pathBeneath(t, r);
}

/// Index of the deepest worktree in `entries` enclosing `current`. Nested
/// `.graff/worktrees/<x>` and `.claude/worktrees/<x>` checkouts bind to the
/// inner worktree rather than the outer repository root.
pub fn enclosingIndex(entries: []const Entry, current: []const u8, io: Io) ?usize {
    if (current.len == 0 or entries.len == 0 or hasDotDot(current)) return null;
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    const canon_cur = canonicalOrTrimmed(io, current, &cb);
    if (canon_cur.len == 0) return null;

    var best_idx: ?usize = null;
    var best_len: usize = 0;
    for (entries, 0..) |e, idx| {
        if (e.path.len == 0 or hasDotDot(e.path)) continue;
        var eb: [std.fs.max_path_bytes]u8 = undefined;
        const canon_entry = canonicalOrTrimmed(io, e.path, &eb);
        if (!pathBeneath(canon_cur, canon_entry)) continue;
        if (best_idx == null or canon_entry.len > best_len) {
            best_idx = idx;
            best_len = canon_entry.len;
        }
    }
    return best_idx;
}

pub fn enclosingEntry(entries: []const Entry, current: []const u8, io: Io) ?Entry {
    const idx = enclosingIndex(entries, current, io) orelse return null;
    return entries[idx];
}

/// Rejects empty, absolute, `.` / `..`, `.git`, and nested worktree containers
/// (`.graff/worktrees`, `.claude/worktrees`) as transferable subfolder offsets.
pub fn isSafeWorktreeSubdir(rel: []const u8) bool {
    if (rel.len == 0 or std.fs.path.isAbsolute(rel)) return false;
    if (rel[0] == '/' or rel[0] == '\\' or rel[0] == '~') return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null or std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    var prev: []const u8 = "";
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return false;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".git")) return false;
        if (std.mem.eql(u8, comp, "worktrees") and (std.mem.eql(u8, prev, ".graff") or std.mem.eql(u8, prev, ".claude")))
            return false;
        prev = comp;
        count += 1;
    }
    return count > 0;
}

/// Safe relative subdirectory of `current` inside `wt_root`, or null when
/// `current` sits at `wt_root`, outside `wt_root`, or inside an internal dir.
pub fn relativeSubdir(io: Io, arena: Allocator, wt_root: []const u8, current: []const u8) ?[]const u8 {
    if (wt_root.len == 0 or current.len == 0) return null;
    if (hasDotDot(wt_root) or hasDotDot(current)) return null;
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    const r = canonicalOrTrimmed(io, wt_root, &rb);
    const c = canonicalOrTrimmed(io, current, &cb);
    if (!pathBeneath(c, r) or c.len == r.len) return null;
    const rel = std.mem.trim(u8, c[r.len..], "/");
    if (!isSafeWorktreeSubdir(rel)) return null;
    return arena.dupe(u8, rel) catch null;
}

/// Target directory to enter inside `target_wt`: `<target_wt>/<rel_subdir>` if
/// it exists as a real confined directory inside `target_wt`, else `target_wt`.
pub fn resolveTargetDir(io: Io, arena: Allocator, target_wt: []const u8, rel_subdir: ?[]const u8) []const u8 {
    const rel = rel_subdir orelse return target_wt;
    if (!isSafeWorktreeSubdir(rel)) return target_wt;
    if (!policy.confinedPath(rel) or !policy.noSymlinkEscape(io, rel, target_wt)) return target_wt;
    const candidate = std.fs.path.join(arena, &.{ target_wt, rel }) catch return target_wt;
    var dir = Io.Dir.cwd().openDir(io, candidate, .{}) catch return target_wt;
    defer dir.close(io);
    if (!containsPath(io, target_wt, candidate)) return target_wt;
    return candidate;
}

/// Verify `<wt_path>` exists and any `<wt_path>/.git` pointer resolves to a
/// live git directory (and live `commondir` when present).
pub fn checkGitBacklink(io: Io, arena: Allocator, wt_path: []const u8) GitBacklinkHealth {
    if (wt_path.len == 0) return .missing_checkout;
    var wt_dir = Io.Dir.cwd().openDir(io, wt_path, .{}) catch return .missing_checkout;
    defer wt_dir.close(io);

    const st = wt_dir.statFile(io, ".git", .{}) catch |err| return switch (err) {
        error.FileNotFound => .not_git_dir,
        else => .broken_gitdir,
    };
    if (st.kind == .directory) {
        var gd = wt_dir.openDir(io, ".git", .{}) catch return .broken_gitdir;
        gd.close(io);
        return .healthy;
    }
    if (st.kind != .file) return .broken_gitdir;

    const raw = wt_dir.readFileAlloc(io, ".git", arena, .limited(4096)) catch return .broken_gitdir;
    const first_line = blk: {
        var it = std.mem.splitScalar(u8, raw, '\n');
        break :blk std.mem.trim(u8, it.next() orelse "", " \t\r");
    };
    if (!std.mem.startsWith(u8, first_line, "gitdir:")) return .broken_gitdir;
    const gitdir_spec = std.mem.trim(u8, first_line["gitdir:".len..], " \t\r");
    if (gitdir_spec.len == 0) return .broken_gitdir;

    var gd = (if (std.fs.path.isAbsolute(gitdir_spec))
        Io.Dir.cwd().openDir(io, gitdir_spec, .{})
    else
        wt_dir.openDir(io, gitdir_spec, .{})) catch return .broken_gitdir;
    defer gd.close(io);

    if (gd.readFileAlloc(io, "commondir", arena, .limited(4096))) |common_raw| {
        const common_spec = std.mem.trim(u8, common_raw, " \t\r\n");
        if (common_spec.len == 0) return .broken_gitdir;
        var cd = (if (std.fs.path.isAbsolute(common_spec))
            Io.Dir.cwd().openDir(io, common_spec, .{})
        else
            gd.openDir(io, common_spec, .{})) catch return .broken_gitdir;
        cd.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return .broken_gitdir,
    }
    return .healthy;
}

pub fn isEntryMissing(io: Io, arena: Allocator, entry: Entry) bool {
    if (entry.prunable) return true;
    return checkGitBacklink(io, arena, entry.path) == .broken_gitdir;
}

test "enclosingIndex and relativeSubdir: deepest nested worktree wins; safe offsets only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const entries = [_]Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/repo/.graff/worktrees/feat-a", .branch = "worktree-feat-a" },
        .{ .path = "/repo/.claude/worktrees/peer-b", .branch = "peer-b" },
    };

    try std.testing.expectEqual(@as(?usize, 0), enclosingIndex(&entries, "/repo", io));
    try std.testing.expectEqual(@as(?usize, 0), enclosingIndex(&entries, "/repo/packages/api", io));
    try std.testing.expectEqual(@as(?usize, 1), enclosingIndex(&entries, "/repo/.graff/worktrees/feat-a", io));
    try std.testing.expectEqual(@as(?usize, 1), enclosingIndex(&entries, "/repo/.graff/worktrees/feat-a/packages/api", io));
    try std.testing.expectEqual(@as(?usize, 2), enclosingIndex(&entries, "/repo/.claude/worktrees/peer-b/src", io));
    try std.testing.expectEqual(@as(?usize, null), enclosingIndex(&entries, "/repo-sibling/packages/api", io));

    try std.testing.expect(relativeSubdir(io, a, "/repo", "/repo") == null);
    try std.testing.expectEqualStrings("packages/api", relativeSubdir(io, a, "/repo", "/repo/packages/api").?);
    try std.testing.expectEqualStrings(
        "packages/api",
        relativeSubdir(io, a, entries[1].path, "/repo/.graff/worktrees/feat-a/packages/api").?,
    );
    // Unlisted nested worktree or git metadata must never transfer as a subdir offset.
    try std.testing.expect(relativeSubdir(io, a, "/repo", "/repo/.graff/worktrees/unlisted/src") == null);
    try std.testing.expect(relativeSubdir(io, a, "/repo", "/repo/.claude/worktrees/unlisted/src") == null);
    try std.testing.expect(relativeSubdir(io, a, "/repo", "/repo/.git/hooks") == null);

    try std.testing.expect(!isSafeWorktreeSubdir(""));
    try std.testing.expect(!isSafeWorktreeSubdir("/abs/path"));
    try std.testing.expect(!isSafeWorktreeSubdir("../escape"));
    try std.testing.expect(!isSafeWorktreeSubdir("a/../b"));
    try std.testing.expect(!isSafeWorktreeSubdir("a//b"));
    try std.testing.expect(!isSafeWorktreeSubdir(".graff/worktrees/x"));
    try std.testing.expect(isSafeWorktreeSubdir(".github/workflows"));
}

test "resolveTargetDir: preserves existing subdir, falls back when absent or symlink-escaping" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "wt-target/packages/api");
    try tmp.dir.createDirPath(io, "outside-dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt-target/not-a-dir", .data = "file\n" });
    try tmp.dir.symLink(io, "../outside-dir", "wt-target/escaped-sub", .{ .is_directory = true });

    const target_wt = try tmp.dir.realPathFileAlloc(io, "wt-target", a);
    const expected_sub = try std.fs.path.join(a, &.{ target_wt, "packages/api" });
    try std.testing.expectEqualStrings(expected_sub, resolveTargetDir(io, a, target_wt, "packages/api"));
    // Missing subfolder in target worktree falls back cleanly to target_wt root.
    try std.testing.expectEqualStrings(target_wt, resolveTargetDir(io, a, target_wt, "packages/missing"));
    // Regular file with same name falls back to target_wt root.
    try std.testing.expectEqualStrings(target_wt, resolveTargetDir(io, a, target_wt, "not-a-dir"));
    // Escaping symlink directory falls back to target_wt root.
    try std.testing.expectEqualStrings(target_wt, resolveTargetDir(io, a, target_wt, "escaped-sub"));
    try std.testing.expectEqualStrings(target_wt, resolveTargetDir(io, a, target_wt, "../outside-dir"));
}

test "checkGitBacklink and parsePorcelain: healthy, relative gitdir, broken pointer, and prunable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main-repo/.git/worktrees/linked-ok");
    try tmp.dir.writeFile(io, .{ .sub_path = "main-repo/.git/worktrees/linked-ok/commondir", .data = "../..\n" });
    try tmp.dir.createDirPath(io, "plain-folder");
    try tmp.dir.createDirPath(io, "linked-ok");
    try tmp.dir.writeFile(io, .{ .sub_path = "linked-ok/.git", .data = "gitdir: ../main-repo/.git/worktrees/linked-ok\n" });
    try tmp.dir.createDirPath(io, "linked-broken");
    try tmp.dir.writeFile(io, .{ .sub_path = "linked-broken/.git", .data = "gitdir: ../main-repo/.git/worktrees/pruned-away\n" });
    try tmp.dir.createDirPath(io, "linked-malformed");
    try tmp.dir.writeFile(io, .{ .sub_path = "linked-malformed/.git", .data = "not a gitdir pointer\n" });

    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const main_repo = try std.fs.path.join(a, &.{ base, "main-repo" });
    const plain = try std.fs.path.join(a, &.{ base, "plain-folder" });
    const ok_wt = try std.fs.path.join(a, &.{ base, "linked-ok" });
    const broken_wt = try std.fs.path.join(a, &.{ base, "linked-broken" });
    const malformed_wt = try std.fs.path.join(a, &.{ base, "linked-malformed" });
    const missing_wt = try std.fs.path.join(a, &.{ base, "gone-wt" });

    try std.testing.expectEqual(GitBacklinkHealth.healthy, checkGitBacklink(io, a, main_repo));
    try std.testing.expectEqual(GitBacklinkHealth.not_git_dir, checkGitBacklink(io, a, plain));
    try std.testing.expectEqual(GitBacklinkHealth.healthy, checkGitBacklink(io, a, ok_wt));
    try std.testing.expectEqual(GitBacklinkHealth.broken_gitdir, checkGitBacklink(io, a, broken_wt));
    try std.testing.expectEqual(GitBacklinkHealth.broken_gitdir, checkGitBacklink(io, a, malformed_wt));
    try std.testing.expectEqual(GitBacklinkHealth.missing_checkout, checkGitBacklink(io, a, missing_wt));

    const porcelain =
        \\worktree /repo
        \\HEAD 1111
        \\branch refs/heads/main
        \\
        \\worktree /repo/.graff/worktrees/stale
        \\HEAD 2222
        \\branch refs/heads/worktree-stale
        \\prunable gitdir file points to non-existent location
        \\
    ;
    const rows = parsePorcelain(a, porcelain);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(!rows[0].prunable);
    try std.testing.expect(rows[1].prunable);
    try std.testing.expect(isEntryMissing(io, a, rows[1]));
    try std.testing.expect(isEntryMissing(io, a, .{ .path = broken_wt, .branch = "broken" }));
    try std.testing.expect(!isEntryMissing(io, a, .{ .path = ok_wt, .branch = "ok" }));
    try std.testing.expect(!isEntryMissing(io, a, .{ .path = plain, .branch = "plain" }));
}

test "workspace switch end-to-end: preserves subfolder across create/use, falls back when absent, and flags missing backlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const switcher = @import("workspace_switch.zig");
    const main_mod = @import("main.zig");
    const runner = @import("process_runner.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const repo = try std.fs.path.join(a, &.{ tmp_root, "repo" });
    const api_dir = try std.fs.path.join(a, &.{ repo, "packages/api" });
    const local_only = try std.fs.path.join(a, &.{ repo, "packages/local-only" });
    try Io.Dir.cwd().createDirPath(io, api_dir);
    try Io.Dir.cwd().createDirPath(io, local_only);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ api_dir, "mod.zig" }), .data = "pub const x = 1;\n" });

    const git = struct {
        fn exec(g: Allocator, git_io: Io, argv: []const []const u8) !void {
            const r = try runner.runCapped(g, git_io, argv, 8192, 8192, 15_000);
            defer {
                g.free(r.stdout);
                g.free(r.stderr);
            }
            if (!runner.ranOk(r)) return error.GitCommandFailed;
        }
    }.exec;

    try git(gpa, io, &.{ "git", "init", "-q", "-b", "main", repo });
    try git(gpa, io, &.{ "git", "-C", repo, "config", "user.email", "t@t" });
    try git(gpa, io, &.{ "git", "-C", repo, "config", "user.name", "t" });
    try git(gpa, io, &.{ "git", "-C", repo, "add", "packages/api/mod.zig" });
    try git(gpa, io, &.{ "git", "-C", repo, "commit", "-q", "-m", "init" });

    const saved = .{ main_mod.g_cwd_display, main_mod.g_worktree_branch };
    defer {
        main_mod.g_cwd_display = saved[0];
        main_mod.g_worktree_branch = saved[1];
        switcher.deinitDisplay(gpa);
        @import("tool_spill.zig").resetForTest();
    }

    // Enter `<repo>/packages/api` and verify `list` stars enclosing repo + notes subfolder.
    _ = try switcher.enterPath(gpa, io, a, api_dir);
    const listed1 = switcher.run(gpa, io, a, false, "list", "", "");
    try std.testing.expect(!listed1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, listed1.text, "* ") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed1.text, "(cwd: packages/api)") != null);

    // `resolve` on enclosing worktree from subfolder reports `already`.
    const already = switcher.run(gpa, io, a, false, "use", "main", "");
    try std.testing.expect(!already.is_error);
    try std.testing.expect(std.mem.indexOf(u8, already.text, "already at") != null);

    // `create` from `<repo>/packages/api` mints `<repo>/.graff/worktrees/feat-sub` and enters `packages/api` inside it!
    const created = switcher.run(gpa, io, a, false, "create", "feat-sub", "");
    try std.testing.expect(!created.is_error);
    const wt_sub = try std.fs.path.join(a, &.{ repo, ".graff/worktrees/feat-sub/packages/api" });
    try std.testing.expect(samePath(io, switcher.currentAbs(io, a), wt_sub));

    // `use` back to `main` preserves `packages/api` inside `<repo>`.
    const back = switcher.run(gpa, io, a, false, "use", "main", "");
    try std.testing.expect(!back.is_error);
    try std.testing.expect(samePath(io, switcher.currentAbs(io, a), api_dir));

    // Switch from untracked `packages/local-only` (absent in `feat-sub`) falls back cleanly to `feat-sub` root.
    _ = try switcher.enterPath(gpa, io, a, local_only);
    const fallback = switcher.run(gpa, io, a, false, "use", "feat-sub", "");
    try std.testing.expect(!fallback.is_error);
    const wt_root = try std.fs.path.join(a, &.{ repo, ".graff/worktrees/feat-sub" });
    try std.testing.expect(samePath(io, switcher.currentAbs(io, a), wt_root));

    // Return to `main`, corrupt `feat-sub/.git` backlink, and verify `list` marks `[missing]` and `use` suggests `action=gc`.
    _ = try switcher.enterPath(gpa, io, a, repo);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ wt_root, ".git" }), .data = "gitdir: /nonexistent/git/worktrees/feat-sub\n" });
    const listed_broken = switcher.run(gpa, io, a, false, "list", "", "");
    try std.testing.expect(std.mem.indexOf(u8, listed_broken.text, "[missing]") != null);
    const refused_broken = switcher.run(gpa, io, a, false, "use", "feat-sub", "");
    try std.testing.expect(refused_broken.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused_broken.text, "action=gc") != null);
}
