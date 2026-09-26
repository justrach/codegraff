//! vault_sync against the in-memory edge: enrollment, round trips, CAS,
//! leases, signature enforcement, and rotation on removal.

const std = @import("std");
const testing = std.testing;
const crypto = @import("vault_crypto.zig");
const client = @import("vault_client.zig");
const sync = @import("vault_sync.zig");
const MockEdge = @import("vault_mock_edge.zig").MockEdge;

const Dev = struct {
    c: client.Client,
    s: sync.Session,

    fn init(d: *Dev, arena: std.mem.Allocator, edge: *MockEdge, id: []const u8) void {
        d.c = .{ .io = testing.io, .arena = arena, .transport = edge.transport(), .bearer = "user-7", .device_id = id, .keys = crypto.DeviceKeys.generate(testing.io), .now_ms = 1_700_000_000_000 };
        d.s = sync.Session.open(testing.io, arena, &d.c) catch unreachable;
    }
};

test "first device bootstraps, pushes, and pulls its own bytes back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    try testing.expectEqual(sync.Session.Enrolled.enrolled, try a.s.enable("laptop"));
    try testing.expectEqual(@as(u64, 1), try a.s.push("graff", "codex", "rotating", "{\"t\":1}"));
    const got = (try a.s.pull("graff", "codex")).?;
    try testing.expectEqualStrings("{\"t\":1}", got.bytes);
    try testing.expectEqual(@as(u64, 1), got.version);
    try testing.expectEqual(@as(usize, 0), edge.bad_signatures);
}

test "a second device waits for approval, then reads what the first wrote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    var b: Dev = undefined;
    b.init(arena, &edge, "dev-b");
    _ = try a.s.enable("laptop");
    _ = try a.s.push("graff", "xai", "rotating", "secret-xai");
    try testing.expectEqual(sync.Session.Enrolled.pending, try b.s.enable("vps"));
    try testing.expectError(error.NotEnrolled, b.s.pull("graff", "xai"));
    const v = try a.c.getVault();
    const pending = sync.Session.findDevice(v, "dev-b").?;
    try testing.expectEqualSlices(u8, &crypto.fingerprint(b.c.keys.box.public_key), &(try a.s.deviceFingerprint(pending)));
    try a.s.approve("dev-b");
    try testing.expectEqualStrings("secret-xai", (try b.s.pull("graff", "xai")).?.bytes);
}

test "compare-and-swap: a stale If-Match gets 412, and a lease blocks other writers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    var b: Dev = undefined;
    b.init(arena, &edge, "dev-b");
    _ = try a.s.enable("laptop");
    _ = try b.s.enable("vps");
    try a.s.approve("dev-b");
    _ = try a.s.push("graff", "kimi", "rotating", "v1");
    // b refreshes from a stale version: the edge refuses and names the current one.
    switch (try b.s.putAt("graff", "kimi", "rotating", 0, "b-local")) {
        .conflict => |cur| try testing.expectEqual(@as(u64, 1), cur),
        else => return error.ExpectedConflict,
    }
    try testing.expect((try a.c.lease("graff", "kimi", 60)) != null);
    try testing.expect((try b.c.lease("graff", "kimi", 60)) == null);
    try testing.expect((try b.s.putAt("graff", "kimi", "rotating", 1, "b-refresh")) == .lease_held);
    try testing.expect((try a.s.putAt("graff", "kimi", "rotating", 1, "a-refresh")) == .ok);
    try a.c.release("graff", "kimi");
    try testing.expectEqualStrings("a-refresh", (try b.s.pull("graff", "kimi")).?.bytes);
}

test "unsigned or forged mutations are rejected by the edge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    _ = try a.s.enable("laptop");
    // Same device id, different signing key: an attacker holding only the bearer.
    var forged = a.c;
    forged.keys = crypto.DeviceKeys.generate(testing.io);
    try testing.expectError(error.Unauthorized, forged.lease("graff", "codex", 60));
    try testing.expectEqual(@as(usize, 1), edge.bad_signatures);
}

test "removing a device rotates the key; the survivor still reads, the removed one cannot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    var b: Dev = undefined;
    b.init(arena, &edge, "dev-b");
    _ = try a.s.enable("laptop");
    _ = try b.s.enable("old-vps");
    try a.s.approve("dev-b");
    _ = try a.s.push("graff", "codex", "rotating", "codex-login");
    _ = try a.s.push("graff", "zai", "static", "zai-key");
    const before = try a.s.vaultKey();
    try a.s.remove("dev-b");
    const after = try a.s.vaultKey();
    try testing.expectEqual(before.epoch + 1, after.epoch);
    try testing.expect(!std.mem.eql(u8, &before.key, &after.key));
    try testing.expectEqualStrings("codex-login", (try a.s.pull("graff", "codex")).?.bytes);
    try testing.expectEqualStrings("zai-key", (try a.s.pull("graff", "zai")).?.bytes);
    // The removed device has no wrapped key any more and its signatures fail.
    try testing.expectError(error.NotEnrolled, b.s.pull("graff", "codex"));
    // Leases taken for the rotation were released.
    try testing.expect((try a.c.lease("graff", "codex", 60)) != null);
}

test "a crash between rotating the key and re-encrypting strands nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    a.s.prev_key_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/prev.key", .{tmp.sub_path});
    var b: Dev = undefined;
    b.init(arena, &edge, "dev-b");
    _ = try a.s.enable("laptop");
    _ = try b.s.enable("old-vps");
    try a.s.approve("dev-b");
    _ = try a.s.push("graff", "codex", "rotating", "codex-login");
    try a.s.rotateKey("dev-b"); // …and the process dies here.
    // Items are still at the old epoch; the cached key still opens them.
    try testing.expectEqualStrings("codex-login", (try a.s.pull("graff", "codex")).?.bytes);
    try a.s.migrate();
    const now = try a.c.getVault();
    for (now.items) |h| try testing.expectEqual(now.keyEpoch, h.keyEpoch);
    try testing.expectEqualStrings("codex-login", (try a.s.pull("graff", "codex")).?.bytes);
    // The previous key is gone once nothing needs it.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, a.s.prev_key_path.?, .{}));
}

test "a rotation that cannot take every lease releases the ones it took" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var edge = MockEdge.init(testing.allocator);
    defer edge.deinit();
    var a: Dev = undefined;
    a.init(arena, &edge, "dev-a");
    var b: Dev = undefined;
    b.init(arena, &edge, "dev-b");
    var c: Dev = undefined;
    c.init(arena, &edge, "dev-c");
    _ = try a.s.enable("laptop");
    _ = try b.s.enable("vps");
    _ = try c.s.enable("old");
    try a.s.approve("dev-b");
    try a.s.approve("dev-c");
    _ = try a.s.push("graff", "codex", "rotating", "c");
    _ = try a.s.push("graff", "xai", "rotating", "x");
    // B is mid-refresh on one rotating login.
    const busy = if (std.mem.eql(u8, (try a.c.getVault()).items[0].slot, "codex")) "xai" else "codex";
    try testing.expect((try b.c.lease("graff", busy, 60)) != null);
    try testing.expectError(error.LeaseHeld, a.s.remove("dev-c"));
    // Whatever A leased before stopping is free again for B.
    const other = if (std.mem.eql(u8, busy, "codex")) "xai" else "codex";
    try testing.expect((try b.c.lease("graff", other, 60)) != null);
}
