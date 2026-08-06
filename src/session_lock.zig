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
//!
//! On that degraded path there is no lock to hold, so since #413 the writers
//! coordinate through a sidecar owner record instead — `<session>.owner`,
//! carrying `{pid, start_id}`. It is stamped for the duration of ONE write and
//! removed after, so an idle graff never blocks anybody; a graff that crashes
//! mid-write leaves it behind, and the start identity is what lets the next
//! writer PROVE the holder is gone instead of guessing with a timeout — a
//! recycled pid would otherwise look like a live owner forever.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const proc_identity = @import("proc_identity.zig");

/// Suffix of the sidecar that stands in for the advisory lock on a filesystem
/// that has none. Only the degraded path touches it, so the ordinary flock
/// path pays nothing for it.
pub const owner_suffix = ".owner";

/// Longest session path we will stamp a sidecar for; a longer one simply
/// writes as it did before #413 rather than failing the save.
const owner_path_max = 512;

fn ownerPath(buf: *[owner_path_max]u8, path: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ path, owner_suffix }) catch null;
}

/// Take the sidecar for one unlocked write, or report the live foreign writer.
/// A path too long to name simply skips the sidecar: it is a best-effort
/// stand-in for a lock the filesystem could not give us, and must never become
/// the reason a session is lost.
fn claimOwner(io: Io, dir: Io.Dir, path: []const u8) error{SessionOpenInAnotherGraff}!void {
    var name_buf: [owner_path_max]u8 = undefined;
    const owner = ownerPath(&name_buf, path) orelse return;
    proc_identity.claimOwnerFile(io, dir, owner) catch return error.SessionOpenInAnotherGraff;
}

fn releaseOwner(io: Io, dir: Io.Dir, path: []const u8) void {
    var name_buf: [owner_path_max]u8 = undefined;
    const owner = ownerPath(&name_buf, path) orelse return;
    proc_identity.releaseOwnerFile(io, dir, owner);
}

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
        // #413: with no lock to hold, the sidecar owner record is the only
        // thing keeping two writers apart, so it brackets the write.
        error.FileLocksUnsupported, error.SystemResources => {
            try claimOwner(io, dir, path);
            defer releaseOwner(io, dir, path);
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

test "the unlocked fallback waits for a live writer and reclaims a crashed one (#413)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no pid 1
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "wf.session.json";
    const owner = path ++ owner_suffix;
    var buf: [proc_identity.record_max]u8 = undefined;

    // pid 1 (init/launchd) is alive on every unix and is never us. A record
    // with NO start identity is what a graff older than #413 wrote: it must
    // still block, or the upgrade would brick an in-flight lock.
    try tmp.dir.writeFile(io, .{ .sub_path = owner, .data = "graff-owner 1 pid=1\n" });
    try std.testing.expectError(error.SessionOpenInAnotherGraff, claimOwner(io, tmp.dir, path));

    switch (proc_identity.probe(io, 1)) {
        .id => |live| {
            // Same pid, provably a different process: a recycled pid may never
            // keep the lock, so the crashed writer's record is reclaimed…
            const stale = proc_identity.formatRecord(&buf, .{ .pid = 1, .start_id = live +% 1 });
            try tmp.dir.writeFile(io, .{ .sub_path = owner, .data = stale });
            try claimOwner(io, tmp.dir, path);
            // …and the sidecar now names us.
            var back: [proc_identity.record_max]u8 = undefined;
            const rec = proc_identity.parseRecord(try tmp.dir.readFile(io, owner, &back)) orelse return error.ExpectedRecord;
            try std.testing.expectEqual(proc_identity.selfPid(), rec.pid);

            // Same pid AND the same identity: a genuinely live holder is never
            // stolen from.
            const held = proc_identity.formatRecord(&buf, .{ .pid = 1, .start_id = live });
            try tmp.dir.writeFile(io, .{ .sub_path = owner, .data = held });
            try std.testing.expectError(error.SessionOpenInAnotherGraff, claimOwner(io, tmp.dir, path));
        },
        // pid 1 is opaque to an unprivileged user on macOS. Unreadable is
        // held, never stolen — which the legacy assertion above already
        // proved on this platform.
        .unknown => {},
        .gone => return error.InitProcessReportedGone,
    }

    // A record nobody owns any more: the write goes through and the sidecar is
    // released rather than left behind for the next writer to trip over.
    try tmp.dir.deleteFile(io, owner);
    try writeSession(io, tmp.dir, path, "{}");
    try claimOwner(io, tmp.dir, path);
    releaseOwner(io, tmp.dir, path);
    var gone: [proc_identity.record_max]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, owner, &gone));
}
