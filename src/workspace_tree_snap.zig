//! Content-addressed working-tree snapshot without mutating `.git/index`.
//!
//! Why not `git status --porcelain` alone?
//! If `src/foo.zig` is ALREADY dirty (` M src/foo.zig`) before an `implement`
//! or `repair` worker starts, and the worker edits `src/foo.zig`, plain
//! `git status --porcelain` still outputs ` M src/foo.zig` — byte-identical to
//! `before` — so `changed(before, after)` falsely reports `false` and rejects
//! a valid edit.
//!
//! Why hash dirty files in-process instead of `git add -A` + `git write-tree`?
//! It needs only ONE `git status --porcelain --untracked-files=normal`
//! subprocess (zero extra git subprocesses, zero `.git/objects` writes, zero
//! index lock contention, and works under a read-only `.git`), while
//! guaranteeing that any edit to an already-dirty file alters `#dirty-hash:`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");

pub const max_dirty_files: usize = 64;
pub const max_file_bytes: usize = 256 * 1024;

/// Compute a 64-bit Wyhash digest over up to `max_dirty_files` paths listed in
/// `git status --porcelain` output, folding in each line's status code, path,
/// file size/mtime (when stat succeeds), and up to `max_file_bytes` of content.
pub fn dirtyContentDigest(gpa: Allocator, io: Io, cwd: ?[]const u8, status_out: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var lines = std.mem.splitScalar(u8, status_out, '\n');
    var count: usize = 0;
    while (lines.next()) |raw_line| {
        if (count >= max_dirty_files) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len <= 3 or std.mem.startsWith(u8, line, "#dirty-")) continue;
        const after_xy = line[3..];
        const rel_raw = if (std.mem.indexOf(u8, after_xy, " -> ")) |arrow| after_xy[arrow + 4 ..] else after_xy;
        const rel = std.mem.trim(u8, rel_raw, "\"");
        if (rel.len == 0) continue;
        count += 1;
        hasher.update(line);
        const full = if (cwd) |p| (std.fs.path.join(gpa, &.{ p, rel }) catch continue) else rel;
        defer if (cwd != null) gpa.free(full);
        if (Io.Dir.cwd().statFile(io, full, .{})) |st| {
            hasher.update(std.mem.asBytes(&st.size));
            hasher.update(std.mem.asBytes(&st.mtime.nanoseconds));
        } else |_| {}
        if (Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(max_file_bytes))) |bytes| {
            defer gpa.free(bytes);
            hasher.update(bytes);
        } else |_| {}
    }
    return hasher.final();
}

/// Enrich non-empty `git status --porcelain` output with `\n#dirty-hash:<16-hex>\n`.
/// Empty/whitespace-only porcelain output is returned as `""`.
pub fn appendDirtyContentHashes(io: Io, a: Allocator, cwd: ?[]const u8, porcelain_out: []const u8) ![]u8 {
    if (std.mem.trim(u8, porcelain_out, " \t\r\n").len == 0) return a.dupe(u8, "");
    const digest = dirtyContentDigest(a, io, cwd, porcelain_out);
    return std.fmt.allocPrint(a, "{s}\n#dirty-hash:{x:0>16}\n", .{
        std.mem.trimEnd(u8, porcelain_out, "\r\n"),
        digest,
    });
}

fn runPorcelain(gpa: Allocator, io: Io, cwd: ?[]const u8) ?[]u8 {
    const r = if (cwd) |p|
        process_runner.runCapped(
            gpa,
            io,
            &.{ "git", "-C", p, "-c", "core.fsmonitor=false", "status", "--porcelain", "--untracked-files=normal" },
            1 << 16,
            8192,
            15_000,
        ) catch return null
    else
        process_runner.runCapped(
            gpa,
            io,
            &.{ "git", "-c", "core.fsmonitor=false", "status", "--porcelain", "--untracked-files=normal" },
            1 << 16,
            8192,
            15_000,
        ) catch return null;
    defer gpa.free(r.stderr);
    if (!process_runner.ranOk(r)) {
        gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

/// Porcelain snapshot for `edit_contract`: returns `""` when the tree is clean,
/// or `<porcelain>\n#dirty-hash:<hex>\n` when dirty. Returns `null` if `git` fails.
pub fn porcelainSnapshot(gpa: Allocator, io: Io, cwd: ?[]const u8) ?[]u8 {
    const raw = runPorcelain(gpa, io, cwd) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return raw;
    const enriched = appendDirtyContentHashes(io, gpa, cwd, raw) catch return raw;
    gpa.free(raw);
    return enriched;
}

/// Content-addressed workspace fingerprint at `cwd` (or current directory when `null`).
/// Returns `"clean"` when `git status --porcelain --untracked-files=normal` is empty,
/// or `<porcelain>\n#dirty-hash:<hex>\n` when dirty.
pub fn fingerprintAt(io: Io, a: Allocator, cwd: ?[]const u8) ?[]const u8 {
    const raw = runPorcelain(a, io, cwd) orelse return null;
    defer a.free(raw);
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return a.dupe(u8, "clean") catch null;
    return appendDirtyContentHashes(io, a, cwd, raw) catch null;
}

/// Content-addressed workspace fingerprint of the process working directory.
pub fn fingerprint(io: Io, a: Allocator) ?[]const u8 {
    return fingerprintAt(io, a, null);
}

/// Pure predicate: did the working tree move into a dirty state distinct from `before`?
pub fn changed(before: []const u8, after: []const u8) bool {
    const b = std.mem.trim(u8, before, " \t\r\n");
    const a = std.mem.trim(u8, after, " \t\r\n");
    if (a.len == 0 or std.mem.eql(u8, a, "clean")) return false;
    return !std.mem.eql(u8, b, a);
}

test "workspace_tree_snap: clean tree and identical dirty trees report changed == false" {
    try std.testing.expect(!changed("clean", "clean"));
    try std.testing.expect(!changed("", ""));
    try std.testing.expect(!changed(" M src/foo.zig\n#dirty-hash:0123456789abcdef\n", " M src/foo.zig\n#dirty-hash:0123456789abcdef\n"));
    try std.testing.expect(changed("clean", " M src/foo.zig\n#dirty-hash:0123456789abcdef\n"));
    try std.testing.expect(changed(" M src/foo.zig\n#dirty-hash:0123456789abcdef\n", " M src/foo.zig\n#dirty-hash:fedcba9876543210\n"));
}

test "workspace_tree_snap: editing an already-dirty file changes fingerprint while porcelain line stays M" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const init = try process_runner.runCapped(gpa, io, &.{ "git", "-C", repo, "init", "-q" }, 4096, 4096, 15_000);
    defer {
        gpa.free(init.stdout);
        gpa.free(init.stderr);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "committed\n" });
    const add = try process_runner.runCapped(gpa, io, &.{ "git", "-C", repo, "add", "file.txt" }, 4096, 4096, 15_000);
    defer {
        gpa.free(add.stdout);
        gpa.free(add.stderr);
    }
    const commit = try process_runner.runCapped(gpa, io, &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" }, 4096, 4096, 15_000);
    defer {
        gpa.free(commit.stdout);
        gpa.free(commit.stderr);
    }

    const clean_1 = fingerprintAt(io, a, repo) orelse return error.NullFingerprint;
    const clean_2 = fingerprintAt(io, a, repo) orelse return error.NullFingerprint;
    try std.testing.expectEqualStrings("clean", clean_1);
    try std.testing.expect(!changed(clean_1, clean_2));

    // Dirty `file.txt` before the worker starts.
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "dirty-before-worker\n" });
    const snap_before = fingerprintAt(io, a, repo) orelse return error.NullFingerprint;
    const snap_same = fingerprintAt(io, a, repo) orelse return error.NullFingerprint;
    try std.testing.expect(std.mem.indexOf(u8, snap_before, "#dirty-hash:") != null);
    try std.testing.expect(!changed(snap_before, snap_same));

    // Worker modifies the already-dirty `file.txt`.
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "dirty-edited-by-worker\n" });
    const snap_after = fingerprintAt(io, a, repo) orelse return error.NullFingerprint;
    try std.testing.expect(changed(snap_before, snap_after));
}
