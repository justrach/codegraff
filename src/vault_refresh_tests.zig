//! Refresh under lease across two devices against the in-memory edge.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const crypto = @import("vault_crypto.zig");
const client = @import("vault_client.zig");
const sync = @import("vault_sync.zig");
const refresh = @import("vault_refresh.zig");
const MockEdge = @import("vault_mock_edge.zig").MockEdge;

const Dev = struct {
    c: client.Client,
    s: sync.Session,
    home: []const u8,
    file: []const u8,
    versions: refresh.Versions,

    fn init(d: *Dev, arena: std.mem.Allocator, edge: *MockEdge, id: []const u8, home: []const u8) !void {
        d.c = .{ .io = testing.io, .arena = arena, .transport = edge.transport(), .bearer = "user-7", .device_id = id, .keys = crypto.DeviceKeys.generate(testing.io), .now_ms = 1 };
        d.s = try sync.Session.open(testing.io, arena, &d.c);
        d.home = home;
        d.file = try std.fmt.allocPrint(arena, "{s}/xai.json", .{home});
        d.versions = try refresh.Versions.at(testing.io, arena, home);
    }

    fn write(d: *Dev, bytes: []const u8) !void {
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = d.file, .data = bytes });
    }

    fn read(d: *Dev, arena: std.mem.Allocator) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, d.file, arena, .limited(4096));
    }
};

fn tmpPath(arena: std.mem.Allocator, tmp: *testing.TmpDir, sub: []const u8) ![]const u8 {
    try tmp.dir.createDirPath(testing.io, sub);
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, sub });
}

test "one refresher at a time: the other device adopts the committed version instead of refreshing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    try a.init(arena, &edge, "dev-a", try tmpPath(arena, &tmp, "a"));
    var b: Dev = undefined;
    try b.init(arena, &edge, "dev-b", try tmpPath(arena, &tmp, "b"));
    _ = try a.s.enable("laptop");
    _ = try b.s.enable("vps");
    try a.s.approve("dev-b");
    try a.write("token-v1");
    const v1 = try a.s.push("graff", "xai", "rotating", "token-v1");
    try a.versions.set("xai", v1);

    // Both devices hit expiry. A plans first and gets the lease.
    const pa = try refresh.plan(&a.s, a.versions, "xai", a.file);
    try testing.expect(pa == .refresh);
    // B has never synced: it adopts v1 rather than refreshing blind…
    const pb = try refresh.plan(&b.s, b.versions, "xai", b.file);
    try testing.expectEqual(refresh.Plan{ .adopted = v1 }, pb);
    // …and once caught up, it must wait while A holds the lease.
    try testing.expect((try refresh.plan(&b.s, b.versions, "xai", b.file)) == .wait);

    // A refreshes and commits the rotated token.
    try a.write("token-v2");
    const v2 = try refresh.commit(&a.s, a.versions, "xai", a.file, pa.refresh);
    try testing.expectEqual(v1 + 1, v2);
    // B's next plan adopts v2 without ever spending the refresh token.
    try testing.expectEqual(refresh.Plan{ .adopted = v2 }, try refresh.plan(&b.s, b.versions, "xai", b.file));
    try testing.expectEqualStrings("token-v2", try b.read(arena));
}

test "a rejected refresh adopts a newer vault login, else marks needs_signin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    try a.init(arena, &edge, "dev-a", try tmpPath(arena, &tmp, "a"));
    var b: Dev = undefined;
    try b.init(arena, &edge, "dev-b", try tmpPath(arena, &tmp, "b"));
    _ = try a.s.enable("laptop");
    _ = try b.s.enable("vps");
    try a.s.approve("dev-b");
    try b.write("stale");
    _ = try a.s.push("graff", "xai", "rotating", "fresh-from-a");
    // B's refresh token was spent by A: invalid_grant → B adopts A's version.
    const r1 = try refresh.rejected(&b.s, b.versions, "xai", b.file);
    try testing.expect(r1 == .adopted);
    try testing.expectEqualStrings("fresh-from-a", try b.read(arena));
    // Nothing newer anywhere: every device should ask the person to sign in.
    try testing.expect((try refresh.rejected(&b.s, b.versions, "xai", b.file)) == .needs_signin);
    try testing.expectEqualStrings("needs_signin", (try a.c.getItem("graff", "xai")).?.status);
}
