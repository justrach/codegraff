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

/// Salt mixed into the durable project id. Keep in one place so a rename
/// here moves `prompt_cache_key` / `x-grok-conv-id` together.
pub const cache_salt = "graff-kimi-project-cache-v1";

/// UUIDv5-shaped project cache id from an already-resolved seed. Same bytes
/// `projectRootId` sends as `prompt_cache_key` / `x-grok-conv-id`.
pub fn projectIdFromSeed(seed: []const u8, out: *[36]u8) []const u8 {
    var raw: [16]u8 = undefined;
    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(cache_salt);
    h.update(seed);
    h.final(&digest);
    @memcpy(&raw, digest[0..16]);
    raw[6] = (raw[6] & 0x0f) | 0x50; // version 5: name-derived
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 1
    const hex = std.fmt.bytesToHex(raw, .lower);
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out[0..36];
}

/// Project cache id for an absolute cwd: git root when one exists, otherwise
/// the shared scratch seed. Never hashes the leaf of a throwaway tree.
pub fn projectIdForCwd(io: Io, cwd_abs: []const u8, out: *[36]u8) []const u8 {
    var seed_buf: [4096]u8 = undefined;
    return projectIdFromSeed(affinitySeed(io, cwd_abs, &seed_buf), out);
}

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

test "affinity: two scratch sandboxes share one project cache id" {
    // 289 list$: hashing the leaf cwd minted a unique prompt_cache_key per
    // eval sandbox, so the system+tools prefix never warmed. Offline — no
    // provider, no model. Would have failed on the cwd-hash.
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    const a_base = "/tmp/graff-aff-id-a";
    const b_base = "/tmp/graff-aff-id-b";
    Io.Dir.cwd().createDirPath(io, a_base ++ "/leaf") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, a_base) catch {};
    Io.Dir.cwd().createDirPath(io, b_base ++ "/other") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, b_base) catch {};

    var a_path: [160]u8 = undefined;
    var b_path: [160]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_path, "{s}/leaf", .{a_base});
    const b = try std.fmt.bufPrint(&b_path, "{s}/other", .{b_base});

    var id_a: [36]u8 = undefined;
    var id_b: [36]u8 = undefined;
    var id_seed: [36]u8 = undefined;
    try std.testing.expectEqualStrings(projectIdForCwd(io, a, &id_a), projectIdForCwd(io, b, &id_b));
    try std.testing.expectEqualStrings(projectIdFromSeed(scratch_seed, &id_seed), projectIdForCwd(io, a, &id_a));
}

test "affinity: hashing the leaf cwd is a forced miss" {
    // The 289 bug, spelled as ids: two sibling sandbox paths hash to
    // different UUIDs, and neither is the shared scratch id.
    const a = "/tmp/graff-evals/.sandboxes/task-a-r1";
    const b = "/tmp/graff-evals/.sandboxes/task-b-r1";
    var id_a: [36]u8 = undefined;
    var id_b: [36]u8 = undefined;
    var id_scratch: [36]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, projectIdFromSeed(a, &id_a), projectIdFromSeed(b, &id_b)));
    try std.testing.expect(!std.mem.eql(u8, projectIdFromSeed(a, &id_a), projectIdFromSeed(scratch_seed, &id_scratch)));
}

test "affinity: nested repo dirs share one project cache id" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "a/b");

    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var child_buf: [4096]u8 = undefined;
    const child = try std.fmt.bufPrint(&child_buf, "{s}/a/b", .{root});

    var id_root: [36]u8 = undefined;
    var id_child: [36]u8 = undefined;
    var id_leaf: [36]u8 = undefined;
    try std.testing.expectEqualStrings(projectIdForCwd(io, root, &id_root), projectIdForCwd(io, child, &id_child));
    // Old hash of the leaf path would have missed the root's warm prefix.
    try std.testing.expect(!std.mem.eql(u8, projectIdFromSeed(child, &id_leaf), projectIdForCwd(io, child, &id_child)));
}
