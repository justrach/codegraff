//! Browser-tab counts for managed preview ports (#941).
//! Missing, invalid or stale data leaves browser visibility unknown.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Kind = enum { unknown, none, some };
pub const grace_ms: u64 = 30 * std.time.ms_per_s;
pub const max_age_ms: i64 = 10 * std.time.ms_per_s;
pub const poll_ms: i64 = 2 * std.time.ms_per_s;
pub const rel_path = ".codegraff/preview-consumers.json";
pub var grace: u64 = grace_ms;

pub const Snapshot = struct {
    counts: std.json.ObjectMap,
    modified_ms: i64,

    pub fn kindOf(s: Snapshot, port: u16) Kind {
        var buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{port}) catch return .unknown;
        const value = s.counts.get(key) orelse return .unknown;
        const n = switch (value) {
            .integer => |i| i,
            // Counts have always represented whole numbers. Also accept zero
            // written as 0.0, without unsafe float-to-integer casts.
            .float => |f| return if (f == 0) .none else if (f > 0 and std.math.isFinite(f) and @trunc(f) == f) .some else .unknown,
            else => return .unknown,
        };
        if (n < 0) return .unknown;
        return if (n == 0) .none else .some;
    }

    pub fn allListenersEmpty(s: Snapshot, listeners: []const u8) bool {
        var it = std.mem.splitSequence(u8, listeners, ", ");
        while (it.next()) |addr| {
            const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return false;
            const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return false;
            if (port == 0 or s.kindOf(port) != .none) return false;
        }
        return true;
    }

    pub fn isFresh(s: Snapshot, started_ms: i64, now_ms: i64) bool {
        return s.modified_ms > 0 and s.modified_ms >= started_ms and
            s.modified_ms <= now_ms and now_ms - s.modified_ms <= max_age_ms;
    }

    pub fn hasExplicitZero(s: Snapshot) bool {
        var i = s.counts.iterator();
        while (i.next()) |entry| {
            const port = std.fmt.parseInt(u16, entry.key_ptr.*, 10) catch continue;
            if (port != 0 and s.kindOf(port) == .none) return true;
        }
        return false;
    }
};

pub fn read(io: Io, arena: Allocator, home: []const u8) ?Snapshot {
    if (home.len == 0) return null;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, rel_path }) catch return null;
    const dir = Io.Dir.cwd();
    const candidate = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return null;
    if (candidate.kind != .file) return null;
    const file = dir.openFile(io, path, .{ .follow_symlinks = false }) catch return null;
    defer file.close(io);
    const before = file.stat(io) catch return null;
    if (before.kind != .file) return null;
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const data = reader.interface.allocRemaining(arena, .limited(64 * 1024)) catch return null;
    const after = file.stat(io) catch return null;
    if (before.mtime.nanoseconds != after.mtime.nanoseconds or before.size != after.size) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return null;
    return if (parsed == .object) .{
        .counts = parsed.object,
        .modified_ms = std.math.cast(i64, @divTrunc(after.mtime.nanoseconds, std.time.ns_per_ms)) orelse return null,
    } else null;
}

pub const Empty = struct { timestamp: i64, listeners: u64 };

pub const Grace = struct {
    first_empty_ms: i64 = 0,
    last_empty_ms: i64 = 0,
    listeners: u64 = 0,

    pub fn observe(g: *Grace, empty: ?Empty, grace_period: u64) bool {
        const current = empty orelse {
            g.* = .{};
            return false;
        };
        const timestamp = current.timestamp;
        if (g.last_empty_ms == 0 or g.listeners != current.listeners or timestamp < g.last_empty_ms or timestamp - g.last_empty_ms > max_age_ms)
            g.first_empty_ms = timestamp;
        g.last_empty_ms = timestamp;
        g.listeners = current.listeners;
        return grace_period != 0 and @as(u64, @intCast(timestamp - g.first_empty_ms)) >= grace_period;
    }
};

test "preview consumer inventory requires all listener ports" {
    var mem: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer mem.deinit();
    const raw = try std.json.parseFromSliceLeaky(std.json.Value, mem.allocator(), "{\"5173\":0,\"8080\":2,\"9000\":0.5,\"9001\":1e90}", .{});
    const counts: Snapshot = .{ .counts = raw.object, .modified_ms = 20_000 };
    try std.testing.expect(counts.allListenersEmpty("[::1]:5173, 127.0.0.1:5173"));
    try std.testing.expect(!counts.allListenersEmpty("127.0.0.1:5173, *:8080"));
    try std.testing.expect(!counts.allListenersEmpty("127.0.0.1:5173, *:8081"));
    try std.testing.expectEqual(Kind.unknown, counts.kindOf(9000));
    try std.testing.expectEqual(Kind.some, counts.kindOf(9001));
    try std.testing.expect(!counts.isFresh(20_001, 21_000));
    try std.testing.expect(!counts.isFresh(19_000, 21_000 + max_age_ms));
}

test "preview grace requires continuous fresh zero snapshots after navigation or reconnect" {
    var state: Grace = .{};
    try std.testing.expect(!state.observe(.{ .timestamp = 10_000, .listeners = 1 }, 9000));
    try std.testing.expect(!state.observe(.{ .timestamp = 10_000, .listeners = 1 }, 9000)); // polling the same file cannot advance its time
    try std.testing.expect(!state.observe(.{ .timestamp = 18_000, .listeners = 1 }, 9000));
    try std.testing.expect(!state.observe(null, 9000)); // reconnect, stale/missing file, or unknown visibility
    try std.testing.expect(!state.observe(.{ .timestamp = 20_000, .listeners = 1 }, 9000));
    try std.testing.expect(!state.observe(.{ .timestamp = 20_000 + max_age_ms + 1, .listeners = 1 }, 9000)); // reporter paused
    try std.testing.expect(state.observe(.{ .timestamp = 40_000, .listeners = 1 }, 9000));
}

test "preview grace starts over when the listener set changes" {
    var state: Grace = .{};
    try std.testing.expect(!state.observe(.{ .timestamp = 10_000, .listeners = 1 }, 1000));
    try std.testing.expect(!state.observe(.{ .timestamp = 12_000, .listeners = 2 }, 1000));
    try std.testing.expect(state.observe(.{ .timestamp = 13_000, .listeners = 2 }, 1000));
}

test "#941 preview grace matches the Lean trace across listener changes and unknown inventory" {
    const snapshots = [_]?Empty{
        .{ .timestamp = 10_000, .listeners = 1 },
        .{ .timestamp = 13_000, .listeners = 1 },
        .{ .timestamp = 15_000, .listeners = 2 },
        .{ .timestamp = 17_000, .listeners = 2 },
        null,
        .{ .timestamp = 21_000, .listeners = 2 },
        .{ .timestamp = 26_000, .listeners = 2 },
    };
    const expected = @embedFile("test_fixtures/preview_grace.txt");
    try std.testing.expectEqual(snapshots.len + 1, expected.len);
    var state: Grace = .{};
    for (snapshots, expected[0..snapshots.len]) |snapshot, decision| {
        try std.testing.expectEqual(decision == 'T', state.observe(snapshot, 4000));
    }
}
