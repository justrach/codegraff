//! Prompt-cache affinity seed (ADR 0069).
//!
//! xAI routes `prompt_cache_key` / `x-grok-conv-id` per server. Hashing the
//! leaf cwd made every eval sandbox and worktree a unique partition, so the
//! expensive system+tools prefix never warmed. The seed is the git root when
//! one exists, otherwise the constant scratch token — never the leaf of a
//! throwaway tree (the in-house `cache-gitroot` fixture).

const std = @import("std");
const Io = std.Io;

pub const scratch_seed = "graff-scratch";

/// Directory that owns `.git` (file or dir), walking parents of `cwd_abs`.
/// `buf` holds the returned path. Null if the walk hits the filesystem root.
pub fn gitRootOf(io: Io, cwd_abs: []const u8, buf: []u8) ?[]const u8 {
    if (cwd_abs.len == 0 or cwd_abs.len >= buf.len) return null;
    @memcpy(buf[0..cwd_abs.len], cwd_abs);
    var cur: []const u8 = buf[0..cwd_abs.len];
    while (cur.len > 1 and (cur[cur.len - 1] == '/' or cur[cur.len - 1] == '\\'))
        cur = cur[0 .. cur.len - 1];

    var git_buf: [4096]u8 = undefined;
    while (true) {
        const git_path = std.fmt.bufPrint(&git_buf, "{s}/.git", .{cur}) catch return null;
        if (Io.Dir.cwd().access(io, git_path, .{})) |_| {
            if (cur.ptr != buf.ptr) {
                if (cur.len > buf.len) return null;
                @memcpy(buf[0..cur.len], cur);
                return buf[0..cur.len];
            }
            return cur;
        } else |_| {}
        const parent = std.fs.path.dirname(cur) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
    }
}

/// Seed hashed into the durable project cache id. Repo trees share the git
/// root; a temp dir with no `.git` uses `scratch_seed`.
pub fn affinitySeed(io: Io, cwd_abs: []const u8, buf: []u8) []const u8 {
    return gitRootOf(io, cwd_abs, buf) orelse scratch_seed;
}

test "affinity: nested dirs under one repo share the git root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "a/b");

    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var child_buf: [4096]u8 = undefined;
    const child = try std.fmt.bufPrint(&child_buf, "{s}/a/b", .{root});

    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(root, gitRootOf(io, root, &a_buf).?);
    try std.testing.expectEqualStrings(root, gitRootOf(io, child, &b_buf).?);
    try std.testing.expectEqualStrings(
        affinitySeed(io, root, &a_buf),
        affinitySeed(io, child, &b_buf),
    );
}

test "affinity: a .git file counts as a repo root (worktree)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /tmp/main.git\n" });
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var seed_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(root, gitRootOf(io, root, &seed_buf).?);
}

test "affinity: scratch trees without .git share one seed, not the leaf cwd" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    // std.testing.tmpDir lives under the repo `.zig-cache`, so a parent walk
    // would find /workspace/.git. Use /tmp so the walk is a real scratch.
    const a_base = "/tmp/graff-aff-scratch-a";
    const b_base = "/tmp/graff-aff-scratch-b";
    Io.Dir.cwd().createDirPath(io, a_base ++ "/leaf") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, a_base) catch {};
    Io.Dir.cwd().createDirPath(io, b_base ++ "/other") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, b_base) catch {};

    var a_path: [160]u8 = undefined;
    var b_path: [160]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_path, "{s}/leaf", .{a_base});
    const b = try std.fmt.bufPrint(&b_path, "{s}/other", .{b_base});

    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    try std.testing.expect(gitRootOf(io, a, &a_buf) == null);
    try std.testing.expect(gitRootOf(io, b, &b_buf) == null);
    try std.testing.expectEqualStrings(scratch_seed, affinitySeed(io, a, &a_buf));
    try std.testing.expectEqualStrings(scratch_seed, affinitySeed(io, b, &b_buf));
    try std.testing.expect(!std.mem.eql(u8, a, scratch_seed));
}
