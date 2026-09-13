//! A stable lock inode and atomic replacement for small workspace ledgers.
//! Unsupported locks, contention, malformed data and I/O failures fail closed.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;
pub const Transaction = struct {
    file: Io.File,
    path: []const u8,
    io: Io,
    arena: A,

    pub fn begin(io: Io, arena: A, path: []const u8) !Transaction {
        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{path});
        var attempts: usize = 0;
        const lock = while (true) : (attempts += 1) {
            const file = Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| {
                if (err != error.WouldBlock or attempts >= 20) return err;
                try io.sleep(.fromMilliseconds(10), .awake);
                continue;
            };
            break file;
        };
        return .{ .file = lock, .path = path, .io = io, .arena = arena };
    }
    pub fn end(self: Transaction) void {
        self.file.close(self.io);
    }
    pub fn read(self: Transaction) !?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, self.path, self.arena, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
    pub fn write(self: Transaction, data: []const u8) !void {
        var nonce: [8]u8 = undefined;
        self.io.random(&nonce);
        const tmp = try std.fmt.allocPrint(self.arena, "{s}.{s}.tmp", .{ self.path, std.fmt.bytesToHex(nonce, .lower) });
        defer Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
        {
            const file = try Io.Dir.cwd().createFile(self.io, tmp, .{ .exclusive = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, data, 0);
            try file.sync(self.io);
        }
        try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), self.path, self.io);
    }
};

test "ledger transaction excludes another writer and atomically replaces its content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const path = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/ledger.json", .{tmp.sub_path});
    const first = try Transaction.begin(std.testing.io, arena.allocator(), path);
    defer first.end();
    try std.testing.expectError(error.WouldBlock, Transaction.begin(std.testing.io, arena.allocator(), path));
    try std.testing.expect(try first.read() == null);
    try first.write("one");
    try std.testing.expectEqualStrings("one", (try first.read()).?);
    try first.write("two");
    try std.testing.expectEqualStrings("two", (try first.read()).?);
}
