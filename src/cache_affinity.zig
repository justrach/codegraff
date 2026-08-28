//! Sticky prompt-cache partition (`x-grok-conv-id` / `prompt_cache_key`).
//!
//! xAI caches prefix bytes on the server a key routes to. A cwd-derived key
//! made every sibling sandbox a cold ~8k write (rematch 2026-08-28: graff
//! first-call cache 0–512, grok 11k–43k already warm). The seed is the git
//! root when cwd sits in a repo — worktrees and eval sandboxes under that
//! tree share — else the constant `scratch_seed` so scratch `-p` shares too.
//! Prefix bytes still have to match; a repo CLAUDE.md does not hit another
//! repo. ADR 0011.

const std = @import("std");
const Io = std.Io;

pub const scratch_seed = "graff-scratch";
const salt = "graff-cache-affinity-v2";

var id_buf: [36]u8 = undefined;
var id_len: usize = 0;
var id_lock: std.atomic.Value(bool) = .init(false);

fn hasGit(io: Io, dir_abs: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.git", .{dir_abs}) catch return false;
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

/// Directory that contains `.git` (file or dir) at or above `start_abs`.
/// Worktree `.git` is a file; `access` sees it. Does not chdir.
pub fn gitRootOf(io: Io, start_abs: []const u8, out: []u8) ?[]const u8 {
    if (start_abs.len == 0 or start_abs.len > out.len) return null;
    @memcpy(out[0..start_abs.len], start_abs);
    var end = start_abs.len;
    while (end > 1 and out[end - 1] == '/') end -= 1;
    while (true) {
        const dir = out[0..end];
        if (hasGit(io, dir)) return dir;
        if (end == 1 and dir[0] == '/') return null;
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        if (slash == 0) {
            if (hasGit(io, out[0..1])) return out[0..1];
            return null;
        }
        end = slash;
    }
}

/// Git root of `cwd_abs`, or `scratch_seed` when the tree is not a repo.
pub fn affinitySeed(io: Io, cwd_abs: []const u8, buf: []u8) []const u8 {
    return gitRootOf(io, cwd_abs, buf) orelse scratch_seed;
}

pub fn uuid5(seed: []const u8) [36]u8 {
    var raw: [16]u8 = undefined;
    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(salt);
    h.update(seed);
    h.final(&digest);
    @memcpy(&raw, digest[0..16]);
    raw[6] = (raw[6] & 0x0f) | 0x50;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(raw, .lower);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

/// Process-cached root partition. First cwd realpath + walk wins for the
/// process (graff does not chdir). Tests that need a fresh mint call `reset`.
pub fn rootId(io: Io) []const u8 {
    while (id_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer id_lock.store(false, .release);
    if (id_len == 0) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch blk: {
            @memcpy(cwd_buf[0..1], ".");
            break :blk 1;
        };
        var seed_buf: [std.fs.max_path_bytes]u8 = undefined;
        const seed = affinitySeed(io, cwd_buf[0..n], &seed_buf);
        id_buf = uuid5(seed);
        id_len = 36;
    }
    return id_buf[0..id_len];
}

pub fn reset() void {
    while (id_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer id_lock.store(false, .release);
    id_len = 0;
}

fn tmpAbs(io: Io, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(io, buf)];
}

test "uuid5 is durable and version-5" {
    const a = uuid5("/repo");
    const b = uuid5("/repo");
    try std.testing.expectEqualStrings(&a, &b);
    try std.testing.expectEqual(@as(u8, '5'), a[14]);
    try std.testing.expect(!std.mem.eql(u8, &a, &uuid5("/other")));
    try std.testing.expect(!std.mem.eql(u8, &a, &uuid5(scratch_seed)));
}

test "nested dir under a repo shares the git root; a scratch tree does not use cwd" {
    const io = std.testing.io;
    var repo = std.testing.tmpDir(.{ .iterate = true });
    defer repo.cleanup();
    repo.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /somewhere\n" }) catch unreachable;
    repo.dir.createDirPath(io, "sandboxes/task-a") catch unreachable;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = try tmpAbs(io, &repo, &cwd_buf);
    var nest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nest = try std.fmt.bufPrint(&nest_buf, "{s}/sandboxes/task-a", .{root_abs});

    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(root_abs, gitRootOf(io, nest, &a).?);
    try std.testing.expectEqualStrings(root_abs, affinitySeed(io, nest, &b));
    try std.testing.expectEqualStrings(&uuid5(root_abs), &uuid5(affinitySeed(io, nest, &a)));

    // zig-cache tmp dirs sit inside this repo, so a no-git case has to start
    // on a path whose parents are not a checkout (`/proc/...` is enough).
    const outside = "/proc/graff-cache-affinity-missing";
    var seed_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(gitRootOf(io, outside, &seed_buf) == null);
    try std.testing.expectEqualStrings(scratch_seed, affinitySeed(io, outside, &seed_buf));
}

test "rootId matches uuid5 of this process's affinity seed" {
    reset();
    defer reset();
    const io = std.testing.io;
    const got = rootId(io);
    try std.testing.expectEqual(@as(usize, 36), got.len);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch return error.TestUnexpectedResult;
    var seed_buf: [std.fs.max_path_bytes]u8 = undefined;
    const seed = affinitySeed(io, cwd_buf[0..n], &seed_buf);
    try std.testing.expectEqualStrings(&uuid5(seed), got);
    try std.testing.expectEqualStrings(got, rootId(io)); // cached
}
