//! Find a program on PATH the way the platform does.
//!
//! Splitting PATH on ':' broke on Windows, where the delimiter is ';' and every
//! entry holds a drive colon: `C:\Program Files\Git\bin;D:\tools` became
//! fragments like `\Program Files\Git\bin;D`, and the probe of each built path
//! could take seconds (a fragment that reads as a network path) and printed an
//! error trace in debug builds. A bare name also never matched `codedb.exe`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const windows_exts = [_][]const u8{ ".exe", ".cmd", ".bat", ".com" };

/// First `name` on `path_env` that exists, written into `buf`; null when none.
pub fn resolve(io: Io, path_env: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const exts: []const []const u8 = if (builtin.os.tag == .windows) &windows_exts else &.{};
    return resolveWith(io, path_env, std.fs.path.delimiter, exts, name, buf);
}

/// `resolve` with the delimiter and extensions passed in, so both platforms' rules are testable anywhere.
pub fn resolveWith(io: Io, path_env: []const u8, delimiter: u8, exts: []const []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    const has_ext = std.fs.path.extension(name).len > 0;
    var it = std.mem.splitScalar(u8, path_env, delimiter);
    while (it.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \"");
        if (dir.len == 0) continue;
        if (exts.len == 0 or has_ext) {
            if (exists(io, buf, dir, name, "")) |full| return full;
            if (exts.len == 0) continue;
        }
        for (exts) |ext| if (exists(io, buf, dir, name, ext)) |full| return full;
    }
    return null;
}

fn exists(io: Io, buf: []u8, dir: []const u8, name: []const u8, ext: []const u8) ?[]const u8 {
    const sep: []const u8 = if (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\') "" else "/";
    const full = std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ dir, sep, name, ext }) catch return null;
    const st = Io.Dir.cwd().statFile(io, full, .{}) catch return null;
    if (st.kind == .directory) return null;
    return full;
}

test "resolveWith splits on the platform delimiter and tries Windows extensions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "win");
    try tmp.dir.createDirPath(io, "codedb"); // a directory with the program's name is not the program
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/codedb", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "win/codedb.exe", .data = "" });
    var buf: [1024]u8 = undefined;

    // POSIX: ':' separated, the bare name. (Windows temp paths hold a drive colon.)
    if (builtin.os.tag != .windows) {
        const posix = try std.fmt.allocPrint(a, "{s}/missing:{s}:{s}/bin", .{ root, root, root });
        defer a.free(posix);
        const p = resolveWith(io, posix, ':', &.{}, "codedb", &buf) orelse return error.TestExpectedResolve;
        try std.testing.expect(std.mem.endsWith(u8, p, "bin/codedb"));
    }

    // Windows: ';' separated (each entry may hold a colon), quoted entries, and `.exe` found for a bare name.
    const win = try std.fmt.allocPrint(a, "{s}/missing;\"{s}/win\"", .{ root, root });
    defer a.free(win);
    const w = resolveWith(io, win, ';', &windows_exts, "codedb", &buf) orelse return error.TestExpectedResolve;
    try std.testing.expect(std.mem.endsWith(u8, w, "win/codedb.exe"));
    // An explicit extension is used as given.
    try std.testing.expect(resolveWith(io, win, ';', &windows_exts, "codedb.exe", &buf) != null);

    // Splitting a ';' PATH on ':' (the old bug) finds nothing.
    if (builtin.os.tag != .windows) try std.testing.expect(resolveWith(io, win, ':', &windows_exts, "codedb", &buf) == null);
    try std.testing.expect(resolveWith(io, "", ':', &.{}, "codedb", &buf) == null);
}
