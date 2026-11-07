//! `graff update`'s half of shipping nanocua (ADR 0314): a macOS release
//! tarball carries nanocua.app beside graff, and this puts it in
//! ~/Applications. The archive is already verified against SHA256SUMS. A tarball
//! without the app (one CI didn't sign) changes nothing, so a signed app already
//! installed is never swapped for no app.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("update_archive.zig");
const nanocua_default = @import("nanocua_default.zig");

const bundle = "nanocua.app";

/// `name`'s path inside the bundle, if it is in one. Nothing may climb out.
pub fn memberPath(name: []const u8) ?[]const u8 {
    const marker = bundle ++ "/";
    const at = if (std.mem.startsWith(u8, name, marker))
        0
    else if (std.mem.indexOf(u8, name, "/" ++ marker)) |i| i + 1 else return null;
    const rel = name[at + marker.len ..];
    if (rel.len == 0 or rel[0] == '/') return null;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return null;
    return rel;
}

fn modeFor(rel: []const u8) Io.File.Permissions {
    const executable = std.mem.startsWith(u8, rel, "Contents/MacOS/");
    return .fromMode(if (executable) 0o755 else 0o644);
}

/// Installs the app from a gzipped release tarball. True if it held one.
pub fn fromArchive(io: Io, gpa: Allocator, home: []const u8, gz: []const u8) !bool {
    if (home.len == 0) return false;
    const tar = try archive.gunzip(gpa, gz);
    defer gpa.free(tar);
    return fromTar(io, gpa, home, tar);
}

pub fn fromTar(io: Io, gpa: Allocator, home: []const u8, tar: []const u8) !bool {
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const root = nanocua_default.installRoot(a, home) orelse return false;
    const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, bundle });
    const stage = try std.fmt.allocPrint(a, "{s}/.{s}.new", .{ root, bundle });
    const old = try std.fmt.allocPrint(a, "{s}/.{s}.old", .{ root, bundle });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, stage) catch {};
    var any = false;
    errdefer cwd.deleteTree(io, stage) catch {};
    var members = archive.Members.init(tar);
    while (try members.next()) |m| {
        const rel = memberPath(m.name) orelse continue;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ stage, rel });
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        try cwd.writeFile(io, .{ .sub_path = path, .data = m.payload, .flags = .{ .permissions = modeFor(rel) } });
        any = true;
    }
    if (!any) return false;
    // Aside, in, then away: a failure between leaves the old app to put back
    // by hand, never half of a new one.
    cwd.deleteTree(io, old) catch {};
    const had = if (cwd.rename(dest, cwd, old, io)) true else |_| false;
    try cwd.rename(stage, cwd, dest, io);
    if (had) cwd.deleteTree(io, old) catch {};
    return true;
}

const testing = std.testing;

test "members inside the bundle, and nothing that climbs out" {
    try testing.expectEqualStrings("Contents/Info.plist", memberPath("graff-aarch64-macos/nanocua.app/Contents/Info.plist").?);
    try testing.expectEqualStrings("Contents/MacOS/nanocua", memberPath("nanocua.app/Contents/MacOS/nanocua").?);
    try testing.expect(memberPath("graff-aarch64-macos/graff") == null);
    try testing.expect(memberPath("graff-aarch64-macos/nanocua.app/") == null);
    try testing.expect(memberPath("x/nanocua.app/../../evil") == null);
    try testing.expect(memberPath("x/notnanocua.app/Contents/Info.plist") == null);
}

fn appendMember(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, data: []const u8, kind: u8) !void {
    var hdr: [512]u8 = @splat(0);
    @memcpy(hdr[0..name.len], name);
    _ = try std.fmt.bufPrint(hdr[124..136], "{o:0>11}", .{data.len});
    hdr[156] = kind;
    try out.appendSlice(gpa, &hdr);
    try out.appendSlice(gpa, data);
    try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, data.len, 512) - data.len);
}

test "the app lands in ~/Applications, replacing the old one; none in the tarball changes nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = buf[0..n];
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const stale = try std.fmt.allocPrint(a, "{s}/Applications/nanocua.app/Contents/stale", .{home});
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(stale).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = stale, .data = "old" });

    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(gpa);
    try appendMember(gpa, &none, "graff-aarch64-macos/graff", "bin", '0');
    try none.appendNTimes(gpa, 0, 1024);
    try testing.expect(!try fromTar(io, gpa, home, none.items));
    _ = try Io.Dir.cwd().statFile(io, stale, .{}); // still there

    var with: std.ArrayList(u8) = .empty;
    defer with.deinit(gpa);
    try appendMember(gpa, &with, "graff-aarch64-macos/graff", "bin", '0');
    try appendMember(gpa, &with, "graff-aarch64-macos/nanocua.app/", "", '5');
    try appendMember(gpa, &with, "graff-aarch64-macos/nanocua.app/Contents/MacOS/nanocua", "app", '0');
    try appendMember(gpa, &with, "graff-aarch64-macos/nanocua.app/Contents/Info.plist", "plist", '0');
    try with.appendNTimes(gpa, 0, 1024);
    try testing.expect(try fromTar(io, gpa, home, with.items));
    const exe = try std.fmt.allocPrint(a, "{s}/Applications/nanocua.app/Contents/MacOS/nanocua", .{home});
    const data = try Io.Dir.cwd().readFileAlloc(io, exe, a, .limited(16));
    try testing.expectEqualStrings("app", data);
    const stat = try Io.Dir.cwd().statFile(io, exe, .{});
    try testing.expect(stat.permissions.toMode() & 0o111 != 0);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, stale, .{}));
}
