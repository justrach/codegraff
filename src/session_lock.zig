//! The session file's write path: parent directories, an exclusive advisory
//! lock, and the write itself. Two graff instances in one workspace share
//! `.graff/sessions/<name>.session.json`, and an unlocked whole-file write let
//! the second one silently clobber the first (#289, item 4). Split out of
//! session.zig, which is at the 600-line cap.
//!
//! The lock is ADVISORY and best effort: a filesystem that cannot lock (some
//! network mounts) degrades to the old unlocked write rather than refusing to
//! save. Only real contention — another live graff holding this very session —
//! is reported, as `error.SessionOpenInAnotherGraff`; /save and the one-shot
//! saver already print the error name, so the user sees which failure it was.

const std = @import("std");
const Io = std.Io;

/// Write `data` to `path` under `dir` while holding an exclusive advisory lock
/// on the session file, creating the parent directory chain first.
///
/// std.Io takes the lock with `flock(LOCK_EX|LOCK_NB)` on POSIX and
/// `NtLockFile` on Windows, so the platform difference (Windows has no flock)
/// is handled there instead of by a raw syscall here.
///
/// The open must NOT truncate: on Linux and Windows the lock is taken *after*
/// the open, so `O_TRUNC` would already have emptied the other graff's session
/// file by the time we discovered the contention. We open at the existing
/// length, and only once the lock is ours overwrite from byte 0 and cut the
/// file back to the new length.
pub fn writeSession(io: Io, dir: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| dir.createDirPath(io, parent) catch {};
    const file = dir.createFile(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        // Another graff is live on this session: report, never clobber.
        error.WouldBlock => return error.SessionOpenInAnotherGraff,
        // #289: locking is advisory. A filesystem with no working locks (some
        // network mounts report either of these) must still save the session —
        // degrade to the pre-#289 unlocked write instead of losing the file.
        error.FileLocksUnsupported, error.SystemResources => {
            return dir.writeFile(io, .{ .sub_path = path, .data = data });
        },
        else => return err,
    };
    defer file.close(io);
    try file.writePositionalAll(io, data, 0);
    try file.setLength(io, data.len);
}

test "a second graff reports contention instead of clobbering the session (#289)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = ".graff/sessions/wf.session.json";
    const first = "{\"title\":\"first graff\",\"messages\":[1,2,3]}";

    // Creates .graff/sessions/ on the way, like the old inline createDir pair.
    try writeSession(io, tmp.dir, path, first);

    // A second graff holding the same session file, exactly as writeSession
    // holds it. flock/NtLockFile are per open file description, so this
    // conflicts even though it is the same process.
    const held = try tmp.dir.createFile(io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    const second = "{\"t\":2}"; // shorter: a clobbering write would leave a tail
    try std.testing.expectError(error.SessionOpenInAnotherGraff, writeSession(io, tmp.dir, path, second));
    held.close(io); // the other graff exits and the lock goes with it

    // Read only after the lock is gone: Windows byte-range locks are mandatory.
    const kept = try tmp.dir.readFileAlloc(io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings(first, kept);

    // With the lock free the write goes through, and truncates to the new
    // length rather than leaving the longer previous session's tail behind.
    try writeSession(io, tmp.dir, path, second);
    const now = try tmp.dir.readFileAlloc(io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(now);
    try std.testing.expectEqualStrings(second, now);
}
