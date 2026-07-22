//! One-use reservations for hidden learning suites.
//!
//! The marker is created before evaluator invocation. A crash after exposure
//! therefore leaves the suite consumed, which is safer than silently reusing a
//! holdout until it passes.

const std = @import("std");
const builtin = @import("builtin");
const store = @import("learn_store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);

fn markerName(suite_sha256: []const u8, buffer: *[69]u8) ![]const u8 {
    if (!store.validId(suite_sha256)) return error.InvalidId;
    return std.fmt.bufPrint(buffer, "{s}.used", .{suite_sha256});
}

fn openReservations(io: Io, root: Io.Dir) !Io.Dir {
    root.createDir(io, "holdouts", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const dir = try root.openDir(io, "holdouts", .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    if (builtin.os.tag != .windows) {
        const stat = try dir.stat(io);
        if ((stat.permissions.toMode() & 0o077) != 0) return error.InsecurePermissions;
    }
    return dir;
}

pub fn reserve(io: Io, root: Io.Dir, suite_sha256: []const u8, trial_id: []const u8) !void {
    if (!store.validId(trial_id)) return error.InvalidId;
    var name_buffer: [69]u8 = undefined;
    const name = try markerName(suite_sha256, &name_buffer);
    const reservations = try openReservations(io, root);
    defer reservations.close(io);
    const file = reservations.createFile(io, name, .{
        .exclusive = true,
        .permissions = file_permissions,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.HoldoutConsumed,
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, trial_id);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    try store.syncDirectory(io, reservations);
    try store.syncDirectory(io, root);
}

pub fn verify(io: Io, root: Io.Dir, allocator: Allocator, suite_sha256: []const u8, trial_id: []const u8) !void {
    if (!store.validId(trial_id)) return error.InvalidId;
    var name_buffer: [69]u8 = undefined;
    const name = try markerName(suite_sha256, &name_buffer);
    const reservations = try openReservations(io, root);
    defer reservations.close(io);
    const bytes = try store.readFileNoFollow(io, reservations, name, allocator, 65);
    defer allocator.free(bytes);
    if (bytes.len != 65 or bytes[64] != '\n' or !std.mem.eql(u8, bytes[0..64], trial_id))
        return error.HoldoutReservationMismatch;
}

test "hidden suite reservations are durable and one-use" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const suite = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const trial = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try reserve(io, tmp.dir, suite, trial);
    try verify(io, tmp.dir, std.testing.allocator, suite, trial);
    try std.testing.expectError(error.HoldoutConsumed, reserve(io, tmp.dir, suite, trial));
    try std.testing.expectError(error.HoldoutReservationMismatch, verify(io, tmp.dir, std.testing.allocator, suite, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"));
}
