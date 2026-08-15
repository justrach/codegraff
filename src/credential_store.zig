//! Atomic, owner-only writes for credential and cache files.
//!
//! Truncate-in-place (createFile + write) leaves a half-written file behind
//! when the process dies, the disk fills, or a second graff writes the same
//! path. For an OAuth credential that is fatal: the file holds the only copy of
//! the refresh token, so a truncated write reads back as "not logged in" — a
//! silent logout with nothing left to recover from. Write a per-writer-unique
//! temp file in the target's own directory, fsync it, then rename over the
//! target, so a reader sees either the whole old file or the whole new one.
//!
//! The guarantee is against a crashed process, not against power loss: the temp
//! file is fsynced but the containing directory is not, so some filesystems can
//! still lose the rename across a hard power cut. Same shape — and same limit —
//! as learn_store.writeAtomicReplace / eval_memory.writeNotes.

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
///
/// `permissions` is the mode for a file that does not exist yet. Pass
/// `private_file` for anything holding a secret; pass `.default_file` to keep
/// the ordinary umask-governed behaviour of a plain `createFile`.
pub fn replaceFile(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8, permissions: Io.File.Permissions) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = if (dir.readLink(io, sub_path, &path_buf)) |n| path_buf[0..n] else |_| sub_path;
    var atomic = try dir.createFileAtomic(io, dest, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);
    if (Io.File.Permissions.has_executable_bit) {
        if (permissions != .default_file) {
            // An explicit mode is a requirement, not a hint: the create mode is
            // masked by umask and chmod is not, so re-apply it and an unusual
            // umask cannot widen the file out from under a caller asking for
            // 0600. NEVER do this for .default_file — that constant is 0o666,
            // and chmodding to it publishes a world-writable credential file.
            atomic.file.setPermissions(io, permissions) catch {};
        } else if (dir.statFile(io, sub_path, .{})) |existing| {
            // Rename-into-place discards the old inode, so without this a mode
            // the user set by hand (`chmod 600 ~/.codex/auth.json`) would be
            // silently re-widened on every save. Nothing to carry for a new
            // file, and then umask governs exactly as createFile did.
            atomic.file.setPermissions(io, Io.File.Permissions.fromMode(existing.permissions.toMode() & 0o7777)) catch {};
        } else |_| {}
    }
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// #477: the process $HOME, pinned once at startup (startup.zig, beside
/// #402's initCodexHome). Throwaway side agents — the pre-compaction note,
/// the title generator, playbook reflect — carry the Agent default home="",
/// and a caller-threaded home then resolves to "/.kimi/...", which disabled
/// BOTH refresh arms (proactive and post-401) for those agents: the first
/// side call after token expiry ate a 401 the root call a beat later simply
/// refreshed around. One resolver, one file, catalog or not.
pub var g_home: []const u8 = "";

pub fn initHome(home: []const u8) void {
    if (home.len > 0) g_home = home;
}

/// The caller's home when it has one, else the startup-pinned process home.
fn resolveHome(home: []const u8) []const u8 {
    return if (home.len > 0) home else g_home;
}

/// `<home>/<provider_dir>/credentials/graff-oauth.json` — where the kimi and
/// xai device-code logins keep their access/refresh pair.
pub fn oauthPath(arena: Allocator, home: []const u8, provider_dir: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/credentials/graff-oauth.json", .{ resolveHome(home), provider_dir }) catch "";
}

/// Store an access/refresh/expiry triple at `oauthPath`, 0600 inside 0700 dirs.
pub fn writeOAuth(io: Io, arena: Allocator, home: []const u8, provider_dir: []const u8, access: []const u8, refresh: []const u8, expires_at: i64) !void {
    // createDir is one level, so make <home>/<provider_dir> then its credentials/.
    const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ resolveHome(home), provider_dir });
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

// The #477 g_home fallback test lives in startup_tests.zig (with the other
// credential-scope regressions): exactly ONE test in the suite may mutate
// g_home, because the parallel test runner makes two mutators a coin flip.

test "replaceFile: .default_file keeps umask in charge and never widens an existing mode" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A NEW file must land on exactly the mode the plain `createFile` these call
    // sites used to do produces: 0o666 masked by the process umask. Chmodding to
    // the requested `.default_file` instead would publish 0o666 — world-WRITABLE
    // ~/.codex/auth.json and ~/.simple-harness-codegraff.json.
    (try tmp.dir.createFile(io, "reference", .{})).close(io);
    const reference_mode = (try tmp.dir.statFile(io, "reference", .{})).permissions.toMode() & 0o777;
    try replaceFile(io, tmp.dir, "settings.json", "{}", .default_file);
    // (Comparing against a live reference rather than a hard 0o644 keeps this
    // umask-agnostic; the umask-independent guard is the second half below.)
    try std.testing.expectEqual(reference_mode, (try tmp.dir.statFile(io, "settings.json", .{})).permissions.toMode() & 0o777);

    // An EXISTING file's mode survives the rewrite. Rename-into-place discards
    // the old inode, so a user's manual `chmod 600` has to be carried forward by
    // hand or every save silently re-widens the file.
    try tmp.dir.setFilePermissions(io, "settings.json", private_file, .{});
    try replaceFile(io, tmp.dir, "settings.json", "{\"fallback_providers\":[]}", .default_file);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try tmp.dir.statFile(io, "settings.json", .{})).permissions.toMode() & 0o777);
}

test "writeOAuth: the credential file is 0600 inside 0700 directories" {
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

test "#405: replaceFile writes through a symlink instead of replacing it" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const target = try std.fmt.allocPrint(std.testing.allocator, "{s}/real.json", .{base});
    defer std.testing.allocator.free(target);
    const link = try std.fmt.allocPrint(std.testing.allocator, "{s}/settings.json", .{base});
    defer std.testing.allocator.free(link);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "old\n" });
    try Io.Dir.cwd().symLink(io, target, link, .{});
    try replaceFile(io, Io.Dir.cwd(), link, "new\n", .default_file);
    const through = try Io.Dir.cwd().readFileAlloc(io, target, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(through);
    try std.testing.expectEqualStrings("new\n", through);
}
