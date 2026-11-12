//! git_dirs.zig against real `git rev-parse`, and the identity memo.
//! Fixtures live under the system temp dir, outside any checkout, so the
//! "no repository" row really is one. Without git every row skips locally
//! and fails under CI (`CI` set and non-empty), so CI never passes vacuously.
//! git runs with no system or global config and git_dirs checks none, so a
//! developer's own config cannot move a row.

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

fn inCi() bool {
    const v = std.c.getenv("CI") orelse return false;
    return std.mem.span(v).len > 0;
}

/// A fresh physical scratch dir outside any checkout. Without git: skip
/// locally, fail under CI.
pub fn scratch(io: Io, arena: Allocator) ![]const u8 {
    if (comptime !supported) return error.SkipZigTest;
    if (!git(io, &.{"--version"})) return if (inCi()) error.GitMissingInCi else error.SkipZigTest;
    const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(arena, "{s}/graff-git-dirs-{x}", .{ std.mem.trimEnd(u8, tmp, "/"), raw });
    try Io.Dir.cwd().createDirPath(io, dir);
    return Io.Dir.cwd().realPathFileAlloc(io, dir, arena);
}

/// git_dirs checks no system or global config file; `gitAnswer` runs git
/// without them. Restore with the returned value.
pub fn hermetic() ?[]const []const u8 {
    const saved = git_dirs.user_configs_for_test;
    git_dirs.user_configs_for_test = &.{};
    return saved;
}

pub fn repoWithCommit(io: Io, arena: Allocator, root: []const u8) !void {
    _ = arena;
    if (!git(io, &.{ "init", "-q", "-b", "main", root })) return error.GitInitFailed;
    if (!git(io, &.{ "-C", root, "commit", "-q", "--allow-empty", "-m", "i" })) return error.GitCommitFailed;
}

fn gitAnswer(io: Io, arena: Allocator, path: []const u8) ?git_dirs.Dirs {
    return gitAnswerWith(io, arena, path, "/dev/null");
}

/// git's answer with `global` as its only global config and no system one.
fn gitAnswerWith(io: Io, arena: Allocator, path: []const u8, global: []const u8) ?git_dirs.Dirs {
    const gpa = std.testing.allocator;
    const env_global = std.fmt.allocPrint(arena, "GIT_CONFIG_GLOBAL={s}", .{global}) catch return null;
    const r = process_runner.runCapped(gpa, io, &.{ "env", env_global, "GIT_CONFIG_NOSYSTEM=1", "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }, 8192, 8192, 15_000) catch return null;
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
    if (comptime !supported) return error.SkipZigTest;
    if (git_dirs.envOverride()) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try scratch(io, a);
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    const saved = hermetic();
    defer git_dirs.user_configs_for_test = saved;
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

    // A config git refuses to parse: both say "not a usable checkout".
    const corrupt = p.at(a, base, "corrupt");
    try std.testing.expect(git(io, &.{ "init", "-q", corrupt }));
    try appendFile(io, p.at(a, base, "corrupt/.git/config"), "[core\nbroken\n");
    try std.testing.expect(gitAnswer(io, a, corrupt) == null);
    try expectRow(io, a, corrupt, .fallback);

    // Relative `gitdir:` through `..`, and a CRLF `.git` file.
    try Io.Dir.cwd().createDirPath(io, p.at(a, base, "relwt"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p.at(a, base, "relwt/.git"), .data = "gitdir: ../repo/sub/../.git\n" });
    try expectRow(io, a, p.at(a, base, "relwt"), .found);
    try Io.Dir.cwd().createDirPath(io, p.at(a, base, "crlfwt"));
    const crlf = try std.fmt.allocPrint(a, "gitdir: {s}\r\n", .{p.at(a, base, "sep.git")});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p.at(a, base, "crlfwt/.git"), .data = crlf });
    try expectRow(io, a, p.at(a, base, "crlfwt"), .found);

    // A submodule (`.git` file into the superproject's modules/) and a repo
    // nested inside another checkout.
    try repoWithCommit(io, a, p.at(a, base, "subsrc"));
    try std.testing.expect(git(io, &.{ "-c", "protocol.file.allow=always", "-C", repo, "submodule", "add", "-q", p.at(a, base, "subsrc"), "mod" }));
    try expectRow(io, a, p.at(a, base, "repo/mod"), .found);
    try std.testing.expect(git(io, &.{ "init", "-q", p.at(a, base, "repo/sub/inner") }));
    try expectRow(io, a, p.at(a, base, "repo/sub/inner"), .found);

    // A discovery env var (GIT_DIR and friends) always defers to git.
    if (setenv("GIT_DIR", "/nonexistent", 1) != 0) return error.SetenvFailed;
    defer _ = unsetenv("GIT_DIR");
    try std.testing.expect(git_dirs.envOverride());
    try std.testing.expect(git_dirs.resolve(io, a, repo) == .fallback);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn appendFile(io: Io, path: []const u8, data: []const u8) !void {
    const gpa = std.testing.allocator;
    const old = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16));
    defer gpa.free(old);
    const both = try std.mem.concat(gpa, u8, &.{ old, data });
    defer gpa.free(both);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = both });
}

const ConfigRow = struct { text: []const u8, found: bool, git_ok: ?bool = null };

/// Rows appended to a fresh repository's config. `found: false` rows are ones
/// git rejects (or that are not modelled); git must agree whenever we answer.
const config_rows = [_]ConfigRow{
    .{ .text = "[core\nbroken\n", .found = false },
    .{ .text = "[core]\n\tfilemode = maybe\n", .found = false },
    .{ .text = "[core]\n\teditor\n", .found = false },
    .{ .text = "[core]\n\tcompression = 42\n", .found = false },
    .{ .text = "[core]\n\texcludesfile = ~nosuchuser-graff/x\n", .found = false },
    .{ .text = "[user]\n\tname\n", .found = false },
    .{ .text = "[push]\n\tdefault = bogus\n", .found = false },
    .{ .text = "[foo]\n\tbar = \"unterminated\n", .found = false },
    .{ .text = "[foo]\n\tbar = a\\qb\n", .found = false },
    .{ .text = "[foo]\n\tbar # c\n", .found = false },
    .{ .text = "[foo]\n\tb_ar = 1\n", .found = false },
    .{ .text = "[ core ]\n", .found = false },
    .{ .text = "[foo \"bar\"x]\n", .found = false },
    .{ .text = "[include]\n\tpath\n", .found = false },
    .{ .text = "[core]\n\trepositoryformatversion = 2\n", .found = false },
    .{ .text = "[remote \"origin\"]\n\turl = git@x:y.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n[branch \"main\"]\n\tremote = origin\n", .found = true },
    .{ .text = "; c\n# c\n\n[alias]\n\tst = \"status ; -s\" # trailing\n[foo] bar = 1\n", .found = true },
    .{ .text = "[foo \"a\\\"b\"]\n\tx = 1\n[foo.bar]\n\tx=1\n[foo]\n\tbar = a\\\n b\n", .found = true },
    .{ .text = "[core]\r\n\teditor = vim # c\r\n\tautocrlf = input\r\n\tlogallrefupdates = always\r\n", .found = true },
    .{ .text = "[user]\n\tname = A B\n[push]\n\tdefault = current\n[advice]\n\tdetachedHead = false\n", .found = true },
    .{ .text = "[include]\n\tpath = /nonexistent/graff\n[includeIf \"gitdir:/x/\"]\n\tpath = missing\n", .found = true },
};

test "git_dirs: a config git rejects is never answered in-process" {
    if (git_dirs.envOverride()) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try scratch(io, a);
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    const saved = hermetic();
    defer git_dirs.user_configs_for_test = saved;
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    try repoWithCommit(io, a, repo);
    const cfg = try std.fmt.allocPrint(a, "{s}/.git/config", .{repo});
    const pristine = try Io.Dir.cwd().readFileAlloc(io, cfg, a, .limited(1 << 16));
    for (config_rows) |row| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg, .data = pristine });
        try appendFile(io, cfg, row.text);
        try expectConfig(io, a, repo, "/dev/null", row);
    }

    // The global config counts too, includes followed whatever their condition.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg, .data = pristine });
    const global = try std.fmt.allocPrint(a, "{s}/gitconfig", .{base});
    const inc = try std.fmt.allocPrint(a, "{s}/inc", .{base});
    git_dirs.user_configs_for_test = &.{global};
    const rows = [_]struct { global: []const u8, inc: []const u8, row: ConfigRow }{
        .{ .global = "[user\n", .inc = "", .row = .{ .text = "", .found = false } },
        .{ .global = "[include]\n\tpath = inc\n", .inc = "[user]\n\tname = x\n", .row = .{ .text = "", .found = true } },
        .{ .global = "[include]\n\tpath = inc\n", .inc = "[core]\n\tfilemode = maybe\n", .row = .{ .text = "", .found = false } },
        .{ .global = "[includeIf \"gitdir:/nowhere/\"]\n\tpath = inc\n", .inc = "[x\n", .row = .{ .text = "", .found = false, .git_ok = true } },
    };
    for (rows) |r| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = global, .data = r.global });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = inc, .data = r.inc });
        try expectConfig(io, a, repo, global, r.row);
    }
}

fn expectConfig(io: Io, a: Allocator, repo: []const u8, global: []const u8, row: ConfigRow) !void {
    const truth = gitAnswerWith(io, a, repo, global);
    const got = git_dirs.resolve(io, a, repo);
    errdefer std.debug.print("config row {s}: got {t}, git {s}\n", .{ row.text, got, if (truth == null) "fails" else "answers" });
    try std.testing.expectEqual(row.found, got == .found);
    try std.testing.expectEqual(row.git_ok orelse row.found, truth != null);
    if (!row.found) return;
    const t = truth orelse return error.GitSawNoRepo;
    try std.testing.expectEqualStrings(t.git_dir, got.found.git_dir);
    try std.testing.expectEqualStrings(t.common_dir, got.found.common_dir);
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

/// A git that, like git < 2.31, rejects `--path-format` and runs the rest.
pub fn oldGit(gpa: Allocator, io: Io, argv: []const []const u8) anyerror!process_runner.CappedRun {
    for (argv) |arg| if (std.mem.startsWith(u8, arg, "--path-format")) return .{
        .term = .{ .exited = 129 },
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, "error: unknown option `path-format=absolute'\n"),
        .stdout_truncated = false,
        .stderr_truncated = false,
        .timed_out = false,
    };
    return process_runner.runCapped(gpa, io, argv, 8192, 8192, 15_000);
}

test "currentIdentity: a git answer of \"no repository\" is asked again, so a later git init is seen" {
    if (comptime !supported) return error.SkipZigTest;
    if (git_dirs.envOverride()) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gpa = std.testing.allocator;
    const base = try scratch(io, a);
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    git_dirs.env_override_for_test = true; // every answer comes from a real spawn
    defer git_dirs.env_override_for_test = null;
    lease.invalidateIdentity();
    defer lease.invalidateIdentity();
    var dir = try Io.Dir.cwd().openDir(io, base, .{});
    defer dir.close(io);
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    if (std.posix.system.fchdir(dir.handle) != 0) return error.ChdirFailed;
    defer _ = std.posix.system.fchdir(orig.handle);

    // The spawn fails (no repository): not_git, named by the live cwd.
    const before = lease.currentIdentity(gpa, io, a);
    try std.testing.expectEqual(lease.Identity.Kind.not_git, before.kind);
    try std.testing.expectEqualStrings(base, before.id);
    // A git that cannot answer at all (older than 2.31) is not remembered either.
    const saved_run = lease.run_git_hook;
    lease.run_git_hook = &oldGit;
    try std.testing.expectEqual(lease.Identity.Kind.not_git, lease.currentIdentity(gpa, io, a).kind);
    lease.run_git_hook = saved_run;

    // Same cwd, now a repository: the next call sees it.
    try std.testing.expect(git(io, &.{ "init", "-q", base }));
    const after = lease.currentIdentity(gpa, io, a);
    try std.testing.expectEqual(lease.Identity.Kind.main_checkout, after.kind);
    const want = try std.fmt.allocPrint(a, "{s}/.git", .{base});
    try std.testing.expectEqualStrings(want, after.id);
}

test {
    _ = @import("worktree_reap_gate.zig");
}
