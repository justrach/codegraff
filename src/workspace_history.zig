//! Successful session saves register exact folders for device-local discovery.
//! A marker is a lookup hint, never evidence that a live/saved consumer is gone.
const std = @import("std");
const Io = std.Io;
const gpa = std.heap.page_allocator;
pub const directory = ".graff/workspace-history";
pub const Row = struct { version: u8 = 1, path: []const u8 };

pub fn record(io: Io, workspace: Io.Dir, home: []const u8) !void {
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    const root = try workspace.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var home_dir = try Io.Dir.cwd().openDir(io, home, .{});
    defer home_dir.close(io);
    try home_dir.createDirPath(io, directory);
    var records = try home_dir.openDir(io, directory, .{ .follow_symlinks = false, .iterate = true });
    defer records.close(io);
    // Linux needs a readable descriptor (not O_PATH) for fchmod. Windows
    // inherits home ACLs; its directory chmod operation is unimplemented.
    if (Io.File.Permissions.has_executable_bit) try records.setPermissions(io, .fromMode(0o700));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var name_buf: [69]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}.json", .{hex});
    const bytes = try std.json.Stringify.valueAlloc(gpa, Row{ .path = root }, .{});
    defer gpa.free(bytes);
    if (records.readFileAlloc(io, name, gpa, .limited(8192)) catch null) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, bytes)) return;
    }
    // Concurrent saves of a folder write identical data. Separate temporary
    // files and atomic replacement avoid partial records and shared-list races.
    var random: [16]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    var temporary_buf: [102]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buf, "{s}.{s}", .{ name, suffix });
    defer records.deleteFile(io, temporary) catch {};
    {
        const file = try records.createFile(io, temporary, .{
            .exclusive = true,
            .permissions = if (Io.File.Permissions.has_executable_bit) .fromMode(0o600) else .default_file,
        });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try records.rename(temporary, records, name, io);
}

test "workspace history registers the exact saved folder without promoting its parent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "project/nested");
    const home = try tmp.dir.realPathFileAlloc(io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var folder = try tmp.dir.openDir(io, "project/nested", .{});
    defer folder.close(io);
    try record(io, folder, home);
    try record(io, folder, home);
    var index = try tmp.dir.openDir(io, "home/" ++ directory, .{ .iterate = true });
    defer index.close(io);
    var it = index.iterate();
    const entry = (try it.next(io)).?;
    const bytes = try index.readFileAlloc(io, entry.name, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Row, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const expected = try folder.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, parsed.value.path);
    try std.testing.expect((try it.next(io)) == null);
}

test "only successful session writes populate workspace discovery" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const writer = @import("session_writer.zig");
    writer.resetForTest();
    defer writer.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home");
    const home = try tmp.dir.realPathFileAlloc(io, "home", alloc);
    defer alloc.free(home);
    try tmp.dir.createDirPath(io, ".graff/sessions/blocked.session.json");
    const failed = writer.submitInHome(alloc, io, tmp.dir, try alloc.dupe(u8, ".graff/sessions/blocked.session.json"), try alloc.dupe(u8, "{}"), 1, home);
    writer.drain();
    try std.testing.expect(writer.errorFor(failed) != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "home/" ++ directory, .{}));
    const saved = writer.submitInHome(alloc, io, tmp.dir, try alloc.dupe(u8, ".graff/sessions/saved.session.json"), try alloc.dupe(u8, "{}"), 2, home);
    writer.drain();
    try std.testing.expect(writer.errorFor(saved) == null);
    var index = try tmp.dir.openDir(io, "home/" ++ directory, .{ .iterate = true });
    defer index.close(io);
    var it = index.iterate();
    try std.testing.expect((try it.next(io)) != null);
}

test "unavailable workspace discovery storage does not fail a session save" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const writer = @import("session_writer.zig");
    writer.resetForTest();
    defer writer.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "not-home", .data = "preserve" });
    const home = try tmp.dir.realPathFileAlloc(io, "not-home", alloc);
    defer alloc.free(home);
    const ticket = writer.submitInHome(alloc, io, tmp.dir, try alloc.dupe(u8, ".graff/sessions/saved.session.json"), try alloc.dupe(u8, "saved"), 3, home);
    writer.drain();
    try std.testing.expect(writer.errorFor(ticket) == null);
    const bytes = try tmp.dir.readFileAlloc(io, ".graff/sessions/saved.session.json", alloc, .limited(32));
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("saved", bytes);
}
