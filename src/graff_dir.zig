//! #1273: graff's `.graff/` run state stays out of git. Sessions, transcripts,
//! traces, trajectories, spilled tool output and nested worktrees all land in
//! the working tree, so in a repository that does not ignore `.graff/` they
//! showed up as untracked, and a model-run `git add -A` committed them.
//!
//! Whenever graff makes (or writes under) `.graff/`, it drops a
//! `.graff/.gitignore` there: only when the file is absent, never over a
//! user's own. The body ignores everything EXCEPT the few files a project is
//! meant to share: `workspace.toml` (ADR 0153 setup scripts), `tools/` (ADR
//! 0039 project-local tools), `policy.json` / `retrieval-policy` (ADR 0084)
//! and `.config.router` (endpoint metadata, no credentials). An allowlist
//! rather than a list of runtime dirs, because new run state keeps appearing
//! under `.graff/` and a denylist would silently fall behind. The file ignores
//! itself too, so a fresh run leaves `git status` empty.
//!
//! Nested worktrees under `.graff/worktrees/` are unaffected: git reads ignore
//! files only from inside a worktree's own root, never its parent directories.

const std = @import("std");
const Io = std.Io;

pub const name = ".graff";

pub const gitignore_body =
    \\# Written by graff: keeps sessions, traces and other run state out of git.
    \\# Shared project config below stays visible. Edit freely; graff never
    \\# rewrites this file once it exists.
    \\*
    \\!workspace.toml
    \\!policy.json
    \\!retrieval-policy
    \\!.config.router
    \\!tools/
    \\!tools/**
    \\
;

/// Create `<base>/.graff` if needed and make sure it has a `.gitignore`.
pub fn ensure(io: Io, base: Io.Dir) void {
    base.createDir(io, name, .default_dir) catch {};
    ensureIgnore(io, base);
}

/// Give an existing `<base>/.graff` its `.gitignore`. A `.graff` that is a
/// symlink is left alone: the write must never land outside the workspace.
pub fn ensureIgnore(io: Io, base: Io.Dir) void {
    var graff = base.openDir(io, name, .{ .follow_symlinks = false }) catch return;
    defer graff.close(io);
    ensureIgnoreIn(io, graff);
}

/// The same, given an already-open handle on `.graff` itself.
pub fn ensureIgnoreIn(io: Io, graff: Io.Dir) void {
    graff.writeFile(io, .{ .sub_path = ".gitignore", .data = gitignore_body, .flags = .{ .exclusive = true } }) catch {};
}

/// `ensureIgnore` for a writer that only has a path relative to `base`: a
/// no-op unless that path lives under `.graff/`.
pub fn ensureFor(io: Io, base: Io.Dir, rel: []const u8) void {
    if (std.mem.startsWith(u8, rel, name ++ "/")) ensureIgnore(io, base);
}

/// `ensureIgnore` for a directory named by path (a worktree creator's cwd).
pub fn ensureIgnoreAt(io: Io, base_path: []const u8) void {
    var base = Io.Dir.cwd().openDir(io, base_path, .{}) catch return;
    defer base.close(io);
    ensureIgnore(io, base);
}

fn gitStatus(gpa: std.mem.Allocator, root: []const u8) ![]u8 {
    const runner = @import("process_runner.zig");
    const r = try runner.runCapped(gpa, std.testing.io, &.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=all" }, 1 << 16, 4096, 15_000);
    defer gpa.free(r.stderr);
    if (!runner.ranOk(r)) {
        gpa.free(r.stdout);
        return error.GitFailed;
    }
    return r.stdout;
}

test "#1273: run state under .graff stays out of git status; shared config does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const init = @import("process_runner.zig").runCapped(gpa, io, &.{ "git", "init", "-q", root }, 4096, 4096, 15_000) catch return error.SkipZigTest;
    gpa.free(init.stdout);
    gpa.free(init.stderr);
    if (!@import("process_runner.zig").ranOk(init)) return error.SkipZigTest;

    ensure(io, tmp.dir);
    try tmp.dir.createDirPath(io, ".graff/sessions/s1/artifacts");
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/s1.session.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/s1/artifacts/tool-0.txt", .data = "x" });
    try tmp.dir.createDirPath(io, ".graff/traces");
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/traces/run.jsonl", .data = "{}\n" });
    const clean = try gitStatus(gpa, root);
    defer gpa.free(clean);
    try std.testing.expectEqualStrings("", clean);

    // A project's shared config is still something it can commit.
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/workspace.toml", .data = "[scripts]\n" });
    try tmp.dir.createDirPath(io, ".graff/tools/fmt");
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/tools/fmt/manifest.json", .data = "{}" });
    const shared = try gitStatus(gpa, root);
    defer gpa.free(shared);
    try std.testing.expect(std.mem.indexOf(u8, shared, ".graff/workspace.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared, ".graff/tools/fmt/manifest.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared, "sessions") == null);
}

test "#1273: a user's own .graff/.gitignore is never overwritten" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".graff");
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/.gitignore", .data = "sessions/\n" });
    ensure(io, tmp.dir);
    ensureFor(io, tmp.dir, ".graff/sessions/x.session.json");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("sessions/\n", try tmp.dir.readFile(io, ".graff/.gitignore", &buf));

    // A path outside .graff never creates one.
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    ensureFor(io, other.dir, "notes/x.md");
    try std.testing.expectError(error.FileNotFound, other.dir.statFile(io, ".graff", .{}));
}
