//! Durable shell handles. The numeric wire stays exact in JavaScript; the new
//! namespace cannot overlap any legacy u32 handle retained in saved history.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
pub const Id = u64;
pub const first: Id = 1 << 32;
pub const last: Id = (1 << 53) - 1;
const marker = "shell-ids-v1\n";
const private_file = @import("credential_store.zig").private_file;
var test_mutex: Io.Mutex = .init;
var test_home: ?[]const u8 = null;

/// Existing job tests still exercise this allocator, in a private test-only
/// directory rather than the user's HOME. Dedicated tests call reserve directly.
pub fn forJob(io: Io) !Id {
    if (builtin.is_test) {
        test_mutex.lockUncancelable(io);
        defer test_mutex.unlock(io);
        if (test_home == null) {
            var tmp = std.testing.tmpDir(.{});
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try tmp.dir.realPath(io, &buf);
            test_home = try std.heap.page_allocator.dupe(u8, buf[0..n]);
            tmp.dir.close(io);
            tmp.parent_dir.close(io);
        }
        return reserve(io, test_home.?);
    }
    return reserve(io, @import("job_registry.zig").home) catch |err| switch (err) {
        error.ShellIdentityHomeRequired, error.ShellIdentityStoreInvalid, error.ShellIdentityExhausted => return err,
        else => return error.ShellIdentityUnavailable,
    };
}

fn readCounter(io: Io, dir: Io.Dir, name: []const u8) !Id {
    var buf: [64]u8 = undefined;
    const data = dir.readFile(io, name, &buf) catch return error.ShellIdentityStoreInvalid;
    if (data.len < 2 or data[data.len - 1] != '\n') return error.ShellIdentityStoreInvalid;
    const n = std.fmt.parseInt(Id, data[0 .. data.len - 1], 10) catch return error.ShellIdentityStoreInvalid;
    if (n < first - 1 or n > last) return error.ShellIdentityStoreInvalid;
    return n;
}

fn writeCounter(io: Io, dir: Io.Dir, name: []const u8, n: Id) !void {
    var buf: [32]u8 = undefined;
    const data = try std.fmt.bufPrint(&buf, "{d}\n", .{n});
    try @import("credential_store.zig").replaceFile(io, dir, name, data, private_file);
}

pub fn reserve(io: Io, home: []const u8) !Id {
    for (0..50) |_| {
        return reserveLocked(io, home) catch |err| {
            if (err != error.ShellIdentityInitializing) return err;
            // Release the advisory lock before the creator can initialize it.
            try io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
    }
    return error.ShellIdentityStoreInvalid;
}

fn reserveLocked(io: Io, home: []const u8) !Id {
    if (home.len == 0) return error.ShellIdentityHomeRequired;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/.codegraff", .{home});
    Io.Dir.cwd().createDir(io, path, @import("credential_store.zig").private_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var fresh = true;
    const lock = dir.createFile(io, "shell-id.lock", .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = .exclusive,
        .permissions = private_file,
    }) catch |err| blk: {
        if (err != error.PathAlreadyExists) return err;
        fresh = false;
        break :blk try dir.openFile(io, "shell-id.lock", .{ .mode = .read_write, .lock = .exclusive });
    };
    defer lock.close(io);
    if (fresh) {
        if (builtin.os.tag != .windows) {
            // The first reserver may not be the process that created the
            // directory. Sync its parent before initializing durable state.
            const parent = try Io.Dir.cwd().openFile(io, home, .{ .allow_directory = true });
            defer parent.close(io);
            try parent.sync(io);
        }
        // Existing counters without their initialization marker are not a new
        // store. Do not reset them after deletion/replacement of the lock file.
        if (dir.statFile(io, "shell-id.counter", .{})) |_| return error.ShellIdentityStoreInvalid else |e| if (e != error.FileNotFound) return e;
        try lock.writePositionalAll(io, marker, 0);
        try lock.sync(io);
        try writeCounter(io, dir, "shell-id.counter", first - 1);
    } else {
        var content: [32]u8 = undefined;
        const n = try lock.readPositionalAll(io, &content, 0);
        if (n == 0) return error.ShellIdentityInitializing;
        if (!std.mem.eql(u8, content[0..n], marker)) return error.ShellIdentityStoreInvalid;
    }
    const current = try readCounter(io, dir, "shell-id.counter");
    if (current == last) return error.ShellIdentityExhausted;
    const next = current + 1;
    // Atomic replacement yields the old or new valid counter after a crash.
    // Spawn happens only after the new counter and directory entry are synced.
    try writeCounter(io, dir, "shell-id.counter", next);
    return next;
}

test "shell identity reservations survive a fresh allocator and remain JS exact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    try std.testing.expectEqual(first, try reserve(std.testing.io, buf[0..n]));
    try std.testing.expectEqual(first + 1, try reserve(std.testing.io, buf[0..n]));
    try std.testing.expect(last <= 9007199254740991);
    try std.testing.expectError(error.ShellIdentityHomeRequired, reserve(std.testing.io, ""));
}

test "shell identity fails closed on missing corrupt or exhausted storage" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = buf[0..n];
    _ = try reserve(io, home);
    var dir = try tmp.dir.openDir(io, ".codegraff", .{});
    defer dir.close(io);
    try dir.deleteFile(io, "shell-id.counter");
    try std.testing.expectError(error.ShellIdentityStoreInvalid, reserve(io, home));
    // An initializer killed after syncing its marker must never reset IDs.
    try std.testing.expectError(error.ShellIdentityStoreInvalid, reserve(io, home));
    try dir.writeFile(io, .{ .sub_path = "shell-id.lock", .data = "" });
    try std.testing.expectError(error.ShellIdentityStoreInvalid, reserve(io, home));
    try dir.writeFile(io, .{ .sub_path = "shell-id.lock", .data = marker });
    try dir.writeFile(io, .{ .sub_path = "shell-id.counter", .data = "bad" });
    try std.testing.expectError(error.ShellIdentityStoreInvalid, reserve(io, home));
    try writeCounter(io, dir, "shell-id.counter", last);
    try std.testing.expectError(error.ShellIdentityExhausted, reserve(io, home));
    try dir.deleteFile(io, "shell-id.lock");
    try std.testing.expectError(error.ShellIdentityStoreInvalid, reserve(io, home));
}
