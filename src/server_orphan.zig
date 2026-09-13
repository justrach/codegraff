//! Explicit stop authority for a user-selected legacy listener snapshot.
//! Discovery alone never authorizes a signal or creates an ownership record.
const std = @import("std");
const builtin = @import("builtin");
const identity = @import("proc_identity.zig");
const stop_tree = @import("job_registry_stop.zig");
const Io = std.Io;
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

pub const Snapshot = struct {
    pid: i32,
    start: u64,
    executable: u64,
    pub fn token(self: Snapshot, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{x}-{x}", .{ self.start, self.executable });
    }
};

pub fn capture(io: Io, pid: i32) ?Snapshot {
    if (pid <= 1) return null;
    const before = switch (identity.probe(io, pid)) {
        .id => |v| v,
        else => return null,
    };
    if (before == 0) return null;
    var buf: [4096]u8 = undefined;
    const exe: []const u8 = if (builtin.os.tag == .macos) blk: {
        const n = proc_pidpath(pid, &buf, buf.len);
        if (n <= 0 or n >= buf.len) return null;
        break :blk std.mem.sliceTo(buf[0..@intCast(n)], 0);
    } else if (builtin.os.tag == .linux) blk: {
        var pbuf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/exe", .{pid}) catch return null;
        const n = Io.Dir.cwd().readLink(io, path, &buf) catch return null;
        break :blk buf[0..n];
    } else return null;
    const stat = Io.Dir.cwd().statFile(io, exe, .{}) catch return null;
    var hash = std.hash.Wyhash.init(0);
    hash.update(exe);
    hash.update(std.mem.asBytes(&stat.inode));
    hash.update(std.mem.asBytes(&stat.size));
    const modified: i128 = stat.mtime.nanoseconds;
    hash.update(std.mem.asBytes(&modified));
    const native = stop_tree.Native{ .io = io };
    if (native.group(pid) != pid or native.ownGroup() == pid) return null;
    if (identity.ownerState(before, identity.probe(io, pid)) != .held) return null;
    // Unknown is not a matching identity, even though it conservatively holds
    // ownership records. Stop authorization requires a positive second read.
    switch (identity.probe(io, pid)) {
        .id => |v| if (v != before) return null,
        else => return null,
    }
    return .{ .pid = pid, .start = before, .executable = hash.final() };
}

pub fn matches(expected: Snapshot, current: ?Snapshot) bool {
    const got = current orelse return false;
    return expected.pid == got.pid and expected.start == got.start and expected.executable == got.executable;
}

const Checked = struct {
    native: stop_tree.Native,
    expected: Snapshot,
    pub fn probe(self: Checked, pid: i32) identity.Probe {
        const current = self.native.probe(pid);
        if (current == .gone) return .gone;
        if (!matches(self.expected, capture(self.native.io, pid))) return .unknown;
        return current;
    }
    pub fn ownGroup(self: Checked) ?i32 {
        return self.native.ownGroup();
    }
    pub fn group(self: Checked, pid: i32) ?i32 {
        return self.native.group(pid);
    }
    pub fn signal(self: Checked, pid: i32, sig: stop_tree.Signal) !void {
        if (!matches(self.expected, capture(self.native.io, pid))) return error.IdentityChanged;
        try self.native.signal(pid, sig);
    }
    pub fn groupGone(self: Checked, pid: i32) ?bool {
        return self.native.groupGone(pid);
    }
    pub fn sleep(self: Checked) !void {
        try self.native.sleep();
    }
};

/// Caller must have re-discovered this exact candidate and received the
/// explicit token displayed to the user; never used by automatic cleanup.
pub fn stop(io: Io, expected: Snapshot, token: []const u8) stop_tree.Result {
    var buf: [80]u8 = undefined;
    const want = expected.token(&buf) catch return .unverifiable;
    if (!std.mem.eql(u8, want, token)) return .unverifiable;
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        return stop_tree.stop(expected.pid, expected.start, Checked{ .native = .{ .io = io }, .expected = expected });
    } else return .unsupported;
}

test "#817 legacy stop snapshot rejects PID reuse, executable changes and unavailable identity" {
    const expected = Snapshot{ .pid = 200, .start = 10, .executable = 30 };
    try std.testing.expect(matches(expected, expected));
    try std.testing.expect(!matches(expected, .{ .pid = 200, .start = 11, .executable = 30 }));
    try std.testing.expect(!matches(expected, .{ .pid = 200, .start = 10, .executable = 31 }));
    try std.testing.expect(!matches(expected, null));
    try std.testing.expectEqual(stop_tree.Result.unverifiable, stop(std.testing.io, expected, "stale-token"));
}
