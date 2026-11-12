//! git_dirs.zig against real `git rev-parse`, and the identity memo.
//! Fixtures live under the system temp dir, outside any checkout, so the
//! "no repository" row really is one. Every row skips when git is missing.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const git_dirs = @import("git_dirs.zig");
const lease = @import("worktree_lease.zig");
const process_runner = @import("process_runner.zig");

const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

/// Run git with hermetic init/commit settings; true on exit 0.
pub fn git(io: Io, argv: []const []const u8) bool {
    const gpa = std.testing.allocator;
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    full.appendSlice(gpa, &.{ "git", "-c", "init.defaultObjectFormat=sha1", "-c", "init.defaultRefFormat=files", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" }) catch return false;
    full.appendSlice(gpa, argv) catch return false;
    const r = process_runner.runCapped(gpa, io, full.items, 1 << 16, 1 << 16, 30_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return process_runner.ranOk(r);
}

/// A fresh physical scratch dir outside any checkout, or null without git.
pub fn scratch(io: Io, arena: Allocator) ?[]const u8 {
    if (!supported or !git(io, &.{"--version"})) return null;
    const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = std.fmt.allocPrint(arena, "{s}/graff-git-dirs-{x}", .{ std.mem.trimEnd(u8, tmp, "/"), raw }) catch return null;
    Io.Dir.cwd().createDirPath(io, dir) catch return null;
    return Io.Dir.cwd().realPathFileAlloc(io, dir, arena) catch null;
}

pub fn repoWithCommit(io: Io, arena: Allocator, root: []const u8) !void {
    _ = arena;
    if (!git(io, &.{ "init", "-q", "-b", "main", root })) return error.GitInitFailed;
    if (!git(io, &.{ "-C", root, "commit", "-q", "--allow-empty", "-m", "i" })) return error.GitCommitFailed;
}

fn gitAnswer(io: Io, arena: Allocator, path: []const u8) ?git_dirs.Dirs {
    const gpa = std.testing.allocator;
    const r = process_runner.runCapped(gpa, io, &.{ "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }, 8192, 8192, 15_000) catch return null;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!process_runner.ranOk(r)) return null;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\r\n"), '\n');
    const g = arena.dupe(u8, lines.next() orelse return null) catch return null;
    const c = arena.dupe(u8, lines.next() orelse return null) catch return null;
    return .{ .git_dir = g, .common_dir = c };
}

const Want = enum { not_git, found, fallback };

/// The in-process answer is the expected kind, equals git's when it answers,
/// and the full identity equals the one built from git's output.
fn expectRow(io: Io, arena: Allocator, path: []const u8, want: Want) !void {
    const truth = gitAnswer(io, arena, path);
    const got = git_dirs.resolve(io, arena, path);
    errdefer std.debug.print("git_dirs row {s}: got {t}, git {?s}\n", .{ path, got, if (truth) |t| t.git_dir else null });
    try std.testing.expectEqual(want, @as(Want, switch (got) {
        .not_git => .not_git,
        .found => .found,
        .fallback => .fallback,
    }));
    switch (got) {
        .not_git => try std.testing.expect(truth == null),
        .found => |d| {
            const t = truth orelse return error.GitSawNoRepo;
            try std.testing.expectEqualStrings(t.git_dir, d.git_dir);
            try std.testing.expectEqualStrings(t.common_dir, d.common_dir);
        },
        .fallback => {},
    }
    const t = truth orelse git_dirs.Dirs{ .git_dir = "", .common_dir = "" };
    const want_id = lease.canonicalIdentity(t.git_dir, t.common_dir, path);
    const id = lease.identityAt(std.testing.allocator, io, arena, path);
    try std.testing.expectEqualStrings(want_id.id, id.id);
    try std.testing.expectEqual(want_id.kind, id.kind);
}

test "git_dirs: fixture matrix matches git rev-parse byte for byte" {
    if (git_dirs.envOverride()) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = scratch(io, a) orelse return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    const p = struct {
        fn at(ar: Allocator, b: []const u8, rel: []const u8) []const u8 {
            return std.fmt.allocPrint(ar, "{s}/{s}", .{ b, rel }) catch unreachable;
        }
    };

    // No .git anywhere up to the filesystem boundary.
    try Io.Dir.cwd().createDirPath(io, p.at(a, base, "plain/deep"));
    try expectRow(io, a, p.at(a, base, "plain/deep"), .not_git);

    // `.git` directory: the checkout root and a nested subdirectory.
    const repo = p.at(a, base, "repo");
    try repoWithCommit(io, a, repo);
    try Io.Dir.cwd().createDirPath(io, p.at(a, base, "repo/sub/deep"));
    try expectRow(io, a, repo, .found);
    try expectRow(io, a, p.at(a, base, "repo/sub/deep"), .found);

    // `.git` file with gitdir: + commondir (linked worktree), and inside it.
    try std.testing.expect(git(io, &.{ "-C", repo, "worktree", "add", "-q", "--detach", p.at(a, base, "wt") }));
    try Io.Dir.cwd().createDirPath(io, p.at(a, base, "wt/sub"));
    try expectRow(io, a, p.at(a, base, "wt"), .found);
    try expectRow(io, a, p.at(a, base, "wt/sub"), .found);

    // `.git` file without commondir (separate git dir).
    try std.testing.expect(git(io, &.{ "init", "-q", "--separate-git-dir", p.at(a, base, "sep.git"), p.at(a, base, "sepwt") }));
    try expectRow(io, a, p.at(a, base, "sepwt"), .found);

    // Bare repository and a cwd inside a git dir: git's call.
    try std.testing.expect(git(io, &.{ "init", "-q", "--bare", p.at(a, base, "bare.git") }));
    try expectRow(io, a, p.at(a, base, "bare.git"), .fallback);
    try expectRow(io, a, p.at(a, base, "repo/.git/refs"), .fallback);

    // A gitdir reached through a symlink: realpath semantics could differ.
    try Io.Dir.cwd().symLink(io, p.at(a, base, "sep.git"), p.at(a, base, "sep-link"), .{ .is_directory = true });
    try Io.Dir.cwd().createDirPath(io, p.at(a, base, "symwt"));
    const gitfile = try std.fmt.allocPrint(a, "gitdir: {s}\n", .{p.at(a, base, "sep-link")});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p.at(a, base, "symwt/.git"), .data = gitfile });
    try expectRow(io, a, p.at(a, base, "symwt"), .fallback);

    // Repository format extensions: older git may refuse the repo.
    const ext = p.at(a, base, "ext");
    try std.testing.expect(git(io, &.{ "init", "-q", ext }));
    try std.testing.expect(git(io, &.{ "-C", ext, "config", "extensions.worktreeConfig", "true" }));
    try expectRow(io, a, ext, .fallback);

    // A discovery env var (GIT_DIR and friends) always defers to git.
    git_dirs.env_override_for_test = true;
    defer git_dirs.env_override_for_test = null;
    try std.testing.expect(git_dirs.resolve(io, a, repo) == .fallback);
}

var stub_calls: u32 = 0;
fn stubRevParse(gpa: Allocator, io: Io, arena: Allocator, dir: ?[]const u8) lease.RevParse {
    _ = .{ gpa, io, arena, dir };
    stub_calls += 1;
    return .{ .git_dir = "/stub/.git", .common_dir = "/stub/.git" };
}

/// Swap the identity spawn for a counter; restore with the returned value.
pub fn countSpawns() lease.RevParseFn {
    const saved = lease.rev_parse_hook;
    lease.rev_parse_hook = &stubRevParse;
    stub_calls = 0;
    return saved;
}

pub fn spawnCalls() u32 {
    return stub_calls;
}

test "currentIdentity: one git answer per cwd, forgotten on chdir and invalidate" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gpa = std.testing.allocator;
    git_dirs.env_override_for_test = true; // force the git path
    defer git_dirs.env_override_for_test = null;
    const saved = countSpawns();
    defer lease.rev_parse_hook = saved;
    lease.invalidateIdentity();
    defer lease.invalidateIdentity();

    const first = lease.currentIdentity(gpa, io, a);
    try std.testing.expectEqualStrings("/stub/.git", first.id);
    try std.testing.expectEqual(lease.Identity.Kind.main_checkout, first.kind);
    try std.testing.expectEqual(@as(u32, 1), stub_calls);
    _ = lease.currentIdentity(gpa, io, a);
    try std.testing.expectEqual(@as(u32, 1), stub_calls);
    lease.invalidateIdentity();
    _ = lease.currentIdentity(gpa, io, a);
    try std.testing.expectEqual(@as(u32, 2), stub_calls);
    _ = lease.freshIdentity(gpa, io, a);
    try std.testing.expectEqual(@as(u32, 3), stub_calls);

    // A different cwd is a different key; coming back is another miss.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    {
        defer _ = std.posix.system.fchdir(orig.handle);
        _ = lease.currentIdentity(gpa, io, a);
        _ = lease.currentIdentity(gpa, io, a);
        try std.testing.expectEqual(@as(u32, 4), stub_calls);
    }
    _ = lease.currentIdentity(gpa, io, a);
    try std.testing.expectEqual(@as(u32, 5), stub_calls);
}

test {
    _ = @import("worktree_reap_gate.zig");
}
