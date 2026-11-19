//! Session allowlist of loaded skill directories for read-only `read_file`
//! inspection. `skill_docs.render` points the model at helper/reference files
//! inside a skill's directory (`[this skill lives in <dir>/ — read anything
//! it references from there with read_file]`). Personal and plugin skills live
//! outside cwd, so tracking canonical loaded skill directories here lets
//! `read_file` honor that promise without opening writes or arbitrary paths.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const max_dirs = 32;

var g_lock: Io.Mutex = .init;
var g_bufs: [max_dirs][std.fs.max_path_bytes]u8 = undefined;
var g_lens: [max_dirs]usize = @splat(0);
var g_count: usize = 0;

pub fn resetForTest(io: Io) void {
    g_lock.lockUncancelable(io);
    defer g_lock.unlock(io);
    g_count = 0;
}

fn hasDotDot(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

fn pathEqlChar(a: u8, b: u8, case_insensitive: bool) bool {
    if ((a == '/' or a == '\\') and (b == '/' or b == '\\')) return true;
    if (case_insensitive) return std.ascii.toLower(a) == std.ascii.toLower(b);
    return a == b;
}

pub fn underRootPlatform(path: []const u8, root: []const u8, case_insensitive: bool) bool {
    const clean = std.mem.trimEnd(u8, root, "/\\");
    if (clean.len == 0 or path.len < clean.len) return false;
    for (clean, path[0..clean.len]) |rc, pc| {
        if (!pathEqlChar(rc, pc, case_insensitive)) return false;
    }
    if (path.len == clean.len) return true;
    return path[clean.len] == '/' or path[clean.len] == '\\';
}

/// Record a skill directory that was loaded via the `skill` tool so `read_file`
/// can read its sibling reference docs read-only.
pub fn remember(io: Io, dir: []const u8) void {
    if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, dir, &real_buf) catch return;
    const canon = std.mem.trimEnd(u8, real_buf[0..n], "/\\");
    if (canon.len == 0) return;

    g_lock.lockUncancelable(io);
    defer g_lock.unlock(io);
    for (0..g_count) |i| {
        const existing = g_bufs[i][0..g_lens[i]];
        if (existing.len == canon.len and underRootPlatform(canon, existing, builtin.os.tag == .windows)) return;
    }
    if (g_count >= max_dirs) return;
    @memcpy(g_bufs[g_count][0..canon.len], canon);
    g_lens[g_count] = canon.len;
    g_count += 1;
}

/// True when `raw_path` is an absolute path without `..` whose canonical target
/// stays inside a skill directory loaded earlier in this session.
pub fn isAllowedRead(io: Io, raw_path: []const u8) bool {
    if (raw_path.len == 0 or !std.fs.path.isAbsolute(raw_path) or hasDotDot(raw_path)) return false;

    var snap: [max_dirs][std.fs.max_path_bytes]u8 = undefined;
    var lens: [max_dirs]usize = undefined;
    var n_dirs: usize = 0;
    {
        g_lock.lockUncancelable(io);
        defer g_lock.unlock(io);
        n_dirs = g_count;
        for (0..n_dirs) |i| {
            @memcpy(snap[i][0..g_lens[i]], g_bufs[i][0..g_lens[i]]);
            lens[i] = g_lens[i];
        }
    }
    if (n_dirs == 0) return false;

    const ci = builtin.os.tag == .windows;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = blk: {
        const rn = Io.Dir.cwd().realPathFile(io, raw_path, &real_buf) catch return false;
        break :blk real_buf[0..rn];
    };
    for (0..n_dirs) |i| {
        const root = snap[i][0..lens[i]];
        if (underRootPlatform(target, root, ci)) return true;
    }
    return false;
}

test "loaded personal skill references are readable while escapes remain refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest(io);
    defer resetForTest(io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/api.md", .data = "endpoint docs\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "secret\n" });
    try tmp.dir.symLink(io, "../../outside.txt", "skill/references/escape.md", .{});

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const skill_dir = try std.fmt.allocPrint(gpa, "{s}/skill", .{root});
    defer gpa.free(skill_dir);
    const ref_file = try std.fmt.allocPrint(gpa, "{s}/skill/references/api.md", .{root});
    defer gpa.free(ref_file);
    const traversal = try std.fmt.allocPrint(gpa, "{s}/skill/../outside.txt", .{root});
    defer gpa.free(traversal);
    const symlink_escape = try std.fmt.allocPrint(gpa, "{s}/skill/references/escape.md", .{root});
    defer gpa.free(symlink_escape);
    const outside = try std.fmt.allocPrint(gpa, "{s}/outside.txt", .{root});
    defer gpa.free(outside);

    // Before the skill is loaded, even its reference file is not allowlisted.
    try std.testing.expect(!isAllowedRead(io, ref_file));

    remember(io, skill_dir);
    try std.testing.expect(isAllowedRead(io, ref_file));
    try std.testing.expect(!isAllowedRead(io, traversal));
    try std.testing.expect(!isAllowedRead(io, symlink_escape));
    try std.testing.expect(!isAllowedRead(io, outside));

    // Windows slash/case helper check runs on all platforms.
    try std.testing.expect(underRootPlatform("c:/Users/u/.harness/skills/demo/references/api.md", "C:\\Users\\u\\.harness\\skills\\demo", true));
    try std.testing.expect(!underRootPlatform("C:\\Users\\u\\.harness\\skills\\demo2\\api.md", "C:\\Users\\u\\.harness\\skills\\demo", true));
}
