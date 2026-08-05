//! Atomic, owner-only writes for credential and cache files.
//!
//! Truncate-in-place (createFile + write) leaves a half-written file behind
//! when the process dies, the disk fills, or a second graff writes the same
//! path. For an OAuth credential that is fatal: the file holds the only copy of
//! the refresh token, so a truncated write reads back as "not logged in" — a
//! silent logout with nothing left to recover from. Write a per-writer-unique
//! temp file in the target's own directory, fsync it, then rename over the
//! target, so a reader sees either the whole old file or the whole new one.
//! Same shape as learn_store.writeAtomicReplace / eval_memory.writeNotes.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// 0600 / 0700 on platforms that have permission bits at all.
pub const private_file: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) @enumFromInt(0o600) else .default_file;
pub const private_dir: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) @enumFromInt(0o700) else .default_dir;

/// Replace `dir`/`sub_path` with `bytes` atomically. `sub_path` may carry
/// directory components; createFileAtomic keeps the temp file in the target's
/// own directory, so the rename never crosses a filesystem.
pub fn replaceFile(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8, permissions: Io.File.Permissions) !void {
    var atomic = try dir.createFileAtomic(io, sub_path, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);
    // The create mode is masked by umask; chmod is not, so an unusual umask
    // cannot narrow the file out from under the caller that asked for 0600.
    if (builtin.os.tag != .windows) atomic.file.setPermissions(io, permissions) catch {};
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// `<home>/<provider_dir>/credentials/graff-oauth.json` — where the kimi and
/// xai device-code logins keep their access/refresh pair.
pub fn oauthPath(arena: Allocator, home: []const u8, provider_dir: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/credentials/graff-oauth.json", .{ home, provider_dir }) catch "";
}

/// Store an access/refresh/expiry triple at `oauthPath`, 0600 inside 0700 dirs.
pub fn writeOAuth(io: Io, arena: Allocator, home: []const u8, provider_dir: []const u8, access: []const u8, refresh: []const u8, expires_at: i64) !void {
    // createDir is one level, so make <home>/<provider_dir> then its credentials/.
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, provider_dir });
    const credentials = try std.fmt.allocPrint(arena, "{s}/credentials", .{base});
    for ([_][]const u8{ base, credentials }) |path| {
        Io.Dir.cwd().createDir(io, path, private_dir) catch {};
        // iterate=true: see kimi_catalog.secureDir — a default openDir can be
        // O_PATH on Linux, where fchmod panics EBADF instead of erroring.
        const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        dir.setPermissions(io, private_dir) catch {};
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "access_token", .{ .string = access });
    try obj.put(arena, "refresh_token", .{ .string = refresh });
    try obj.put(arena, "expires_at", .{ .integer = expires_at });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = obj });
    try replaceFile(io, Io.Dir.cwd(), oauthPath(arena, home, provider_dir), aw.writer.buffered(), private_file);
}

fn entryCount(io: Io, dir: Io.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "replaceFile: renames a whole new file into place, never truncating the target" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "cred.json", .data = "{\"refresh_token\":\"old\"}" });

    // Hold the ORIGINAL inode open: a truncate-in-place writer changes what this
    // handle sees, a temp-file+rename writer cannot touch it. That is exactly
    // the property that keeps a crashed write from eating the refresh token.
    const original = try tmp.dir.openFile(io, "cred.json", .{});
    defer original.close(io);

    try replaceFile(io, tmp.dir, "cred.json", "{\"refresh_token\":\"new\"}", private_file);

    var read_buffer: [64]u8 = undefined;
    var reader = original.reader(io, &read_buffer);
    const before = try reader.interface.allocRemaining(gpa, .limited(1024));
    defer gpa.free(before);
    try std.testing.expectEqualStrings("{\"refresh_token\":\"old\"}", before);

    const after = try tmp.dir.readFileAlloc(io, "cred.json", gpa, .limited(1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("{\"refresh_token\":\"new\"}", after);

    // The temp file was consumed by the rename, not left in the directory.
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, tmp.dir));
}

test "writeOAuth: the credential file is 0600 inside 0700 directories (#xai parity)" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    try writeOAuth(io, arena, home, ".xai", "access-1", "refresh-1", 1234);

    const base = try tmp.dir.openDir(io, ".xai", .{});
    defer base.close(io);
    const credentials = try base.openDir(io, "credentials", .{});
    defer credentials.close(io);
    try std.testing.expectEqual(@as(u32, 0o700), (try base.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o700), (try credentials.stat(io)).permissions.toMode() & 0o777);
    const file = try credentials.openFile(io, "graff-oauth.json", .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);

    // The loader reads back what the writer stored, at the path it advertises.
    const data = try Io.Dir.cwd().readFileAlloc(io, oauthPath(arena, home, ".xai"), arena, .limited(4096));
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always });
    try std.testing.expectEqualStrings("access-1", parsed.object.get("access_token").?.string);
    try std.testing.expectEqualStrings("refresh-1", parsed.object.get("refresh_token").?.string);
    try std.testing.expectEqual(@as(i64, 1234), parsed.object.get("expires_at").?.integer);
}
