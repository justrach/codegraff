//! The tool-neutral project setup convention in `.agents/` (the directory
//! graff already reads skills from): what a fresh worktree needs before an
//! agent works in it.
//!
//! - `.agents/prepare`: an executable script run from the new checkout's root
//!   once it exists. It should be fast and safe to repeat (install
//!   dependencies, point tools at a shared cache). `.graff/workspace.toml`'s
//!   `setup` still wins when it names one.
//! - `.agents/linked`: one repository-relative path per line (`#` comments and
//!   blank lines ignored, a leading `/` allowed). Each listed path must be
//!   gitignored; the new checkout gets a symlink to the main checkout's copy,
//!   so a `.env` edited once is current in every worktree.
//!
//! Linking only ever adds a symlink where nothing exists: a path the main
//! checkout lacks, or one the new checkout already has, is left alone, and
//! nothing is moved or deleted.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");

/// Shell command that runs the checkout's prepare script, or null when it has none.
pub fn setupCommand(arena: Allocator, io: Io, checkout: []const u8) ?[]const u8 {
    const abs = std.fs.path.join(arena, &.{ checkout, ".agents/prepare" }) catch return null;
    const st = Io.Dir.cwd().statFile(io, abs, .{}) catch return null;
    if (st.kind != .file) return null;
    return "if [ -x .agents/prepare ]; then ./.agents/prepare; else sh ./.agents/prepare; fi";
}

/// The linked list's text: the checkout's committed copy, else the main checkout's.
fn linkedText(arena: Allocator, io: Io, checkout: []const u8, root: []const u8) ?[]const u8 {
    for ([_][]const u8{ checkout, root }) |base| {
        const path = std.fs.path.join(arena, &.{ base, ".agents/linked" }) catch return null;
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |t| return t else |_| {}
    }
    return null;
}

/// One entry as a safe repository-relative path, or null to skip it.
pub fn entryPath(line: []const u8) ?[]const u8 {
    var p = std.mem.trim(u8, line, " \t\r");
    if (p.len == 0 or p[0] == '#') return null;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return null;
        if (std.mem.indexOfAny(u8, part, "*?[\\") != null) return null; // literal paths, never globs
    }
    return p;
}

fn ignoredInRoot(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) bool {
    const r = process_runner.runCapped(gpa, io, &.{ "git", "-C", root, "check-ignore", "-q", "--", rel }, 256, 256, 15_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return process_runner.ranOk(r);
}

/// Symlink each listed gitignored path from the main checkout into a new
/// checkout. Returns how many links were made. Windows needs privileges for
/// symlinks, so it links nothing there (the `.env*` copy still applies).
pub fn linkShared(gpa: Allocator, io: Io, arena: Allocator, root: []const u8, checkout: []const u8) usize {
    if (builtin.os.tag == .windows) return 0;
    if (std.mem.eql(u8, root, checkout)) return 0;
    const text = linkedText(arena, io, checkout, root) orelse return 0;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rel = entryPath(line) orelse continue;
        const shared = std.fs.path.join(arena, &.{ root, rel }) catch continue;
        const local = std.fs.path.join(arena, &.{ checkout, rel }) catch continue;
        _ = Io.Dir.cwd().statFile(io, shared, .{}) catch continue; // the main checkout lacks it
        if (Io.Dir.cwd().statFile(io, local, .{ .follow_symlinks = false })) |_| continue else |_| {}
        if (!ignoredInRoot(gpa, io, root, rel)) continue; // tracked files are never redirected
        if (std.fs.path.dirname(local)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch continue;
        Io.Dir.cwd().symLink(io, shared, local, .{}) catch continue;
        n += 1;
    }
    return n;
}

test "entryPath keeps literal repo-relative paths and drops the rest" {
    try std.testing.expectEqualStrings(".env", entryPath("/.env").?);
    try std.testing.expectEqualStrings("config/local", entryPath("  config/local/ \r").?);
    for ([_][]const u8{ "", "   ", "# shared secrets", "/", "../outside", "a/../b", "./x", "*.env", "certs/**", "a//b" }) |bad|
        try std.testing.expect(entryPath(bad) == null);
}
