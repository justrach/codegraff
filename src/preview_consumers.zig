//! Browser-tab counts for managed preview ports (#941).
//! Absent or unreadable file = unknown, never "no consumers".
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Kind = enum { unknown, none, some };
pub const grace_ms: i64 = 30 * std.time.ms_per_s;
pub const rel_path = ".codegraff/preview-consumers.json";

pub fn path(arena: Allocator, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, rel_path }) catch null;
}

pub fn kindOf(counts: std.json.ObjectMap, port: u16) Kind {
    var buf: [8]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{port}) catch return .unknown;
    const value = counts.get(key) orelse return .unknown;
    const n: i64 = switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return .unknown,
    };
    if (n < 0) return .unknown;
    return if (n == 0) .none else .some;
}

pub fn load(io: Io, arena: Allocator, file: []const u8) ?std.json.ObjectMap {
    const text = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 * 1024)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always }) catch return null;
    return if (parsed == .object) parsed.object else null;
}

pub fn firstPort(text: []const u8) ?u16 {
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        const colon = std.mem.lastIndexOfScalar(u8, item, ':') orelse continue;
        const n = std.fmt.parseInt(u16, item[colon + 1 ..], 10) catch continue;
        if (n != 0) return n;
    }
    return null;
}

test "unknown unless the port is explicitly zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), "{\"5173\":0,\"3000\":2}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Kind.none, kindOf(parsed.value.object, 5173));
    try std.testing.expectEqual(Kind.some, kindOf(parsed.value.object, 3000));
    try std.testing.expectEqual(Kind.unknown, kindOf(parsed.value.object, 8080));
}

test "firstPort reads lsof-style listen lists" {
    try std.testing.expectEqual(@as(?u16, 3002), firstPort("127.0.0.1:3002, *:3003"));
    try std.testing.expectEqual(@as(?u16, null), firstPort(""));
}

// The app's writer runs the same file (justrach/nanoharness
// apps/nano/src/preview_consumers_vectors.json); keep the copies identical.
test "preview consumer vectors drive the listening-job stop only on an explicit zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = @import("job_browser_guard.zig");
    const io = std.testing.io;
    const vectors = try std.json.parseFromSliceLeaky(std.json.Value, arena, @embedFile("preview_consumers_vectors.json"), .{});
    try std.testing.expectEqualStrings(rel_path, vectors.object.get("semantics").?.object.get("file").?.string["$HOME/".len..]);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/.codegraff", .{home}));
    const file = path(arena, home).?;
    var checked: usize = 0;
    for (vectors.object.get("reader").?.array.items) |case| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = case.object.get("file").?.string });
        const kind = kindOf(load(io, arena, file).?, @intCast(case.object.get("port").?.integer));
        try std.testing.expectEqualStrings(case.object.get("kind").?.string, @tagName(kind));
        try std.testing.expectEqual(case.object.get("stop").?.bool, guard.mayStopWith(.listening, false, 1, 1, true, kind));
        checked += 1;
    }
    // Every writer step's counts, as the app writes them: ports, then its
    // own records under a key graff never looks up.
    for (vectors.object.get("writer").?.array.items) |case| for (case.object.get("steps").?.array.items) |step| {
        const stop = step.object.get("stop") orelse continue;
        var text: std.ArrayList(u8) = .empty;
        try text.append(arena, '{');
        var it = step.object.get("counts").?.object.iterator();
        while (it.next()) |e| try text.print(arena, "\"{s}\":{d},", .{ e.key_ptr.*, e.value_ptr.integer });
        try text.appendSlice(arena, "\"harness\":{\"v\":1,\"writers\":[],\"zeros\":{}}}\n");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text.items });
        const counts = load(io, arena, file).?;
        var ports = stop.object.iterator();
        while (ports.next()) |e| {
            const kind = kindOf(counts, try std.fmt.parseInt(u16, e.key_ptr.*, 10));
            try std.testing.expectEqual(e.value_ptr.bool, guard.mayStopWith(.listening, false, 1, 1, true, kind));
            // Pinned, active or unverifiable jobs never stop, whatever the file says.
            try std.testing.expect(!guard.mayStopWith(.listening, true, 1, 1, true, kind));
            try std.testing.expect(!guard.mayStopWith(.listening, false, 1, 2, true, kind));
            try std.testing.expect(!guard.mayStopWith(.unknown, false, 1, 1, true, kind));
            checked += 1;
        }
    };
    try std.testing.expect(checked >= 20);
}
