//! Pending clipboard exports carry a locked recovery record until release/send.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const private_dir: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) .fromMode(0o700) else .default_dir;
const private_file: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) .fromMode(0o600) else .default_file;

const Record = struct {
    version: u8 = 1,
    path: []const u8,
    inode: u128,
    size: u64,
    mtime: i96,
    ctime: i96,
};

pub const Lease = struct {
    file: Io.File,
    name: [40]u8,
};

pub const Store = struct {
    dir: Io.Dir,
    cursor: Io.Dir.Iterator,
    io: Io,
    alloc: Allocator,

    pub fn init(io: Io, alloc: Allocator, root: []const u8) !Store {
        try Io.Dir.cwd().createDirPath(io, root);
        const dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        try dir.setPermissions(io, private_dir);
        return .{ .dir = dir, .cursor = dir.iterate(), .io = io, .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close(self.io);
    }

    pub fn record(self: *Store, file_path: []const u8, stat: Io.File.Stat) !Lease {
        if (!std.fs.path.isAbsolute(file_path) or stat.kind != .file) return error.InvalidExport;
        var raw: [16]u8 = undefined;
        self.io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        var name: [40]u8 = undefined;
        @memcpy(name[0..32], &hex);
        @memcpy(name[32..], ".pending");
        const file = try self.dir.createFile(self.io, &name, .{
            .read = true,
            .exclusive = true,
            .permissions = private_file,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer file.close(self.io);
        errdefer self.dir.deleteFile(self.io, &name) catch {};
        const bytes = try std.json.Stringify.valueAlloc(self.alloc, Record{
            .path = file_path,
            .inode = stat.inode,
            .size = stat.size,
            .mtime = stat.mtime.nanoseconds,
            .ctime = stat.ctime.nanoseconds,
        }, .{});
        defer self.alloc.free(bytes);
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
        return .{ .file = file, .name = name };
    }

    /// Remove recovery authority before a submitted image can reach a worker.
    /// Failure must prevent the handoff; closing a still-pending lease is unsafe.
    pub fn retain(self: *Store, lease: *?Lease) !void {
        const held = lease.* orelse return;
        try self.dir.deleteFile(self.io, &held.name);
        held.file.close(self.io);
        lease.* = null;
    }

    pub fn release(self: *Store, lease: *?Lease) void {
        const held = lease.* orelse return;
        self.dir.deleteFile(self.io, &held.name) catch {};
        held.file.close(self.io);
        lease.* = null;
    }

    /// A rolling cursor bounds directory work too, including invalid records.
    pub fn sweep(self: *Store, limit: usize) usize {
        var removed: usize = 0;
        for (0..limit) |_| {
            const entry = (self.cursor.next(self.io) catch return removed) orelse {
                self.cursor = self.dir.iterate();
                break;
            };
            if (entry.kind != .file or entry.name.len != 40 or !std.mem.endsWith(u8, entry.name, ".pending")) continue;
            const file = self.dir.openFile(self.io, entry.name, .{
                .mode = .read_write,
                .follow_symlinks = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch continue;
            defer file.close(self.io);
            var buffer: [8192]u8 = undefined;
            const n = file.readPositionalAll(self.io, &buffer, 0) catch continue;
            if (n == buffer.len) continue;
            const parsed = std.json.parseFromSlice(Record, self.alloc, buffer[0..n], .{}) catch continue;
            defer parsed.deinit();
            const r = parsed.value;
            if (r.version != 1 or !std.fs.path.isAbsolute(r.path)) continue;
            const stat = Io.Dir.cwd().statFile(self.io, r.path, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.FileNotFound) self.dir.deleteFile(self.io, entry.name) catch {};
                continue;
            };
            if (stat.kind != .file or stat.inode != r.inode or stat.size != r.size or
                stat.mtime.nanoseconds != r.mtime or stat.ctime.nanoseconds != r.ctime) continue;
            Io.Dir.cwd().deleteFile(self.io, r.path) catch continue;
            self.dir.deleteFile(self.io, entry.name) catch {};
            removed += 1;
        }
        return removed;
    }
};
