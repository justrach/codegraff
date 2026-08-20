//! Extra workspace roots (`--add-dir`). Complementary to the `workspace`
//! tool: these are additional trees file tools may touch, not a cwd switch.
//! Max 16. Extra roots never contribute skills or sessions — those stay on
//! the primary checkout and `$HOME`. Fits PathConfine: an absolute path is
//! confined only when it stays under one of these roots with no `..`.

const std = @import("std");
const Io = std.Io;

pub const max_roots: usize = 16;

var g_roots: [max_roots][]const u8 = undefined;
var g_n: usize = 0;

pub fn resetForTest() void {
    g_n = 0;
}

pub fn count() usize {
    return g_n;
}

pub fn items() []const []const u8 {
    return g_roots[0..g_n];
}

fn hasDotDot(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

fn under(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    const next = path[root.len];
    return next == '/' or next == '\\';
}

/// True when `path` is an absolute path under `roots` and has no `..`.
pub fn confinedUnder(path: []const u8, roots: []const []const u8) bool {
    if (roots.len == 0) return false;
    if (path.len == 0) return false;
    if (!std.fs.path.isAbsolute(path)) return false;
    if (hasDotDot(path)) return false;
    for (roots) |root| {
        if (under(path, root)) return true;
    }
    return false;
}

/// True when `path` is an absolute path under a registered extra root and
/// has no `..` components. Relative paths stay on the cwd jail.
pub fn confined(path: []const u8) bool {
    return confinedUnder(path, g_roots[0..g_n]);
}

/// Extra roots are file-tool allow-lists only. Skills, sessions, plugins,
/// and MCP config never scan them.
pub fn contributesSkills(_: []const u8) bool {
    return false;
}

pub fn contributesSessions(_: []const u8) bool {
    return false;
}

fn realDir(io: Io, arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var dir = Io.Dir.cwd().openDir(io, raw, .{}) catch return error.NotADir;
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch return error.NotADir;
    return arena.dupe(u8, buf[0..n]);
}

/// Register one extra root. Resolves to a real directory now so later
/// `--worktree` chdir cannot rewrite a relative `--add-dir`.
pub fn add(io: Io, arena: std.mem.Allocator, raw: []const u8) !void {
    if (g_n >= max_roots) return error.TooManyRoots;
    const owned = try realDir(io, arena, raw);
    // De-dupe: adding the same tree twice is harmless.
    for (g_roots[0..g_n]) |r| if (std.mem.eql(u8, r, owned)) return;
    g_roots[g_n] = owned;
    g_n += 1;
}

/// Pure seat of add(): cap + de-dupe, no filesystem. Used by the test so
/// parallel cases do not share g_n.
pub fn accept(n: usize, existing: []const []const u8, candidate: []const u8) error{TooManyRoots}!bool {
    if (n >= max_roots) return error.TooManyRoots;
    for (existing) |r| if (std.mem.eql(u8, r, candidate)) return false;
    return true;
}

test "extra roots allow a lexical child and refuse escape" {
    const roots = [_][]const u8{"/work/docs"};
    try std.testing.expect(confinedUnder("/work/docs/readme.md", &roots));
    try std.testing.expect(confinedUnder("/work/docs", &roots));
    try std.testing.expect(!confinedUnder("/work/docs/../secret", &roots));
    try std.testing.expect(!confinedUnder("/etc/passwd", &roots));
    try std.testing.expect(!confinedUnder("src/main.zig", &roots)); // relative stays on the cwd jail
    try std.testing.expect(!contributesSkills("/work/docs"));
    try std.testing.expect(!contributesSessions("/work/docs"));
}

test "add refuses a 17th root and skips a duplicate" {
    const existing = [_][]const u8{"/work/docs"};
    try std.testing.expect(!(try accept(1, &existing, "/work/docs")));
    try std.testing.expect(try accept(1, &existing, "/work/other"));
    try std.testing.expectError(error.TooManyRoots, accept(max_roots, &existing, "/work/other"));
}

test "add stores a live path that confined accepts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = "marker.txt", .data = "ok" }) catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    defer resetForTest();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = try a.dupe(u8, buf[0..n]);
    try add(io, a, root);
    try std.testing.expectEqual(@as(usize, 1), count());
    const child = try std.fmt.allocPrint(a, "{s}/marker.txt", .{items()[0]});
    try std.testing.expect(confined(child));
    try std.testing.expect(confined(items()[0]));
    try std.testing.expect(!confined("/etc/passwd"));
}
