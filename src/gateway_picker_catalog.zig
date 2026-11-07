//! A bounded gateway-only refresh for explicit model surfaces (#1155).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const catalog_bounded = @import("catalog_bounded.zig");
const router = @import("router_catalog.zig");
const provider = @import("provider.zig");
const util = @import("util.zig");

var last_attempt: ?i64 = null;

/// Setting confirmations need current local state, not provider discovery.
pub fn requested(params: ?std.json.Value) bool {
    const value = params orelse return true;
    if (value != .object) return true;
    const flag = value.object.get("refresh") orelse return true;
    return flag != .bool or flag.bool;
}

test "gateway refresh is skipped only by explicit false" {
    const a = std.testing.allocator;
    try std.testing.expect(requested(null));
    for ([_][]const u8{ "{}", "null", "{\"refresh\":true}", "{\"refresh\":\"false\"}" }) |input| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
        defer parsed.deinit();
        try std.testing.expect(requested(parsed.value));
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"refresh\":false}", .{});
    defer parsed.deinit();
    try std.testing.expect(!requested(parsed.value));
}

pub fn refresh(io: Io, arena: Allocator, home: []const u8, keys: provider.Keys) void {
    const key = keys.get("codegraff") orelse return;
    const now = util.unixMs(io);
    if (last_attempt) |previous| if (now >= previous and now - previous < 30_000) return;
    last_attempt = now;
    const spec = provider.specFor("codegraff") orelse return;
    _ = refreshAt(io, arena, home, spec, key, keys.source("codegraff"), .fromMilliseconds(500));
}

/// Fetch into the disk cache on a detached worker and activate it only if it
/// lands within `deadline`. Cancelling an HTTP worker joins it, and one parked
/// in DNS or TLS held `graff/models` for seconds past this deadline; a late
/// worker is abandoned instead and leaves the cache for the next caller.
pub fn refreshAt(io: Io, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource, deadline: Io.Duration) bool {
    var batch: catalog_bounded.Batch = .{};
    const slot = batch.spawn(.{ .router = .{ .spec = spec, .source = source } }, home, key);
    batch.wait(io, deadline);
    if (!batch.fetched(slot)) return false;
    return router.activateCached(io, arena, home, spec);
}

/// The 50ms call's worker is abandoned and reads its spec until the test releases it.
var test_url_buf: [64]u8 = undefined;

test "gateway picker refresh uses live aliases and preserves its snapshot on timeout" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(home);
    const io = std.testing.io;
    const pricing = @import("pricing.zig");
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, answer, .{ io, &server });
    var spec = provider.specFor("codegraff").?;
    spec.models_url = try std.fmt.bufPrint(&test_url_buf, "http://127.0.0.1:{d}/v1/models", .{server.socket.address.getPort()});
    try std.testing.expect(refreshAt(io, arena.allocator(), home, spec, "test-key", .environment, .fromSeconds(1)));
    try std.testing.expect(pricing.providerModelInTable("codegraff", "new-gateway-alias"));
    const before = pricing.active_model_table;
    for (0..2) |_| {
        try std.testing.expect(!refreshAt(io, arena.allocator(), home, spec, "test-key", .environment, .fromSeconds(1)));
        try std.testing.expectEqual(before.ptr, pricing.active_model_table.ptr);
    }
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    try std.testing.expect(!refreshAt(io, arena.allocator(), home, spec, "test-key", .environment, .fromMilliseconds(50)));
    try std.testing.expect(Io.Timestamp.now(io, .awake).nanoseconds - started < 2 * std.time.ns_per_s);
    try std.testing.expectEqual(before.ptr, pricing.active_model_table.ptr);
    // Close the stalled connection and let the abandoned worker finish inside this test.
    group.cancel(io);
    try std.testing.expect(catalog_bounded.waitIdle(io, .fromSeconds(10)));
}

fn answer(io: Io, server: *Io.net.Server) void {
    const bodies = [_][]const u8{ "{\"data\":[{\"id\":\"new-gateway-alias\"}]}", "invalid-json", "{\"data\":[]}" };
    for (bodies) |body| {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &read_buffer);
        const request = reader.interface.takeDelimiter('\n') catch return;
        if (!std.mem.eql(u8, request orelse return, "GET /v1/models HTTP/1.1\r")) return;
        var authenticated = false;
        while (reader.interface.takeDelimiter('\n') catch null) |line| {
            if (std.ascii.eqlIgnoreCase(line, "Authorization: Bearer test-key\r")) authenticated = true;
            if (std.mem.eql(u8, line, "\r") or line.len == 0) break;
        }
        if (!authenticated) return;
        var write_buffer: [4096]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
        writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
        writer.interface.flush() catch return;
    }
    const stalled = server.accept(io) catch return;
    defer stalled.close(io);
    io.sleep(.fromSeconds(5), .awake) catch {};
}
