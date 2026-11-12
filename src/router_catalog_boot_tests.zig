//! ADR 0340: a cold catalog cache never holds boot, and still lands.
//!
//! These drive the real `ensureForStartup` against a loopback `/v1/models`
//! (Z.AI's endpoint override keeps discovery on the test's origin, #1795) and
//! a scratch HOME. The worker is the real detached `catalog_bounded` worker;
//! each test waits for it to drain before returning (see `waitIdle`).

const std = @import("std");
const Io = std.Io;

const boot = @import("router_catalog_boot.zig");
const catalog_bounded = @import("catalog_bounded.zig");
const failures = @import("catalog_failures.zig");
const landing = @import("catalog_landing.zig");
const pricing = @import("pricing.zig");
const pricing_db = @import("pricing_db.zig");
const provider = @import("provider.zig");
const rc = @import("router_catalog.zig");

const Reply = struct { delay_ms: i64 = 0, status: []const u8 = "200 OK", body: []const u8 };

/// Answer every `GET /v1/models` with `reply` after `delay_ms`; count them.
fn serveModels(io: Io, server: *Io.net.Server, reply: Reply, gets: *std.atomic.Value(usize)) void {
    while (true) {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &read_buffer);
        const line = (reader.interface.takeDelimiter('\n') catch continue) orelse continue;
        // #1303: another local process can probe a fresh loopback listener.
        if (!std.mem.startsWith(u8, line, "GET /v1/models")) continue;
        while (reader.interface.takeDelimiter('\n') catch null) |header|
            if (std.mem.eql(u8, header, "\r") or header.len == 0) break;
        _ = gets.fetchAdd(1, .acq_rel);
        if (reply.delay_ms > 0) io.sleep(.fromMilliseconds(reply.delay_ms), .awake) catch return;
        var write_buffer: [4096]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
        writer.interface.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ reply.status, reply.body.len, reply.body }) catch continue;
        writer.interface.flush() catch continue;
    }
}

/// A scratch boot: Z.AI keyed and pointed at a loopback catalog, nothing
/// else keyed, every latch this boot sets put back afterwards.
const Fixture = struct {
    server: Io.net.Server,
    group: Io.Group = .init,
    gets: std.atomic.Value(usize) = .init(0),
    tmp: std.testing.TmpDir,
    home: [:0]u8,
    url: []u8,
    keys: provider.Keys,
    saved_table: []const pricing.ModelInfo,
    saved_override: ?[]const u8,
    index: usize,

    fn init(f: *Fixture, reply: Reply) !void {
        const io = std.testing.io;
        var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        f.server = try Io.net.IpAddress.listen(&address, io, .{});
        f.group = .init;
        f.gets = .init(0);
        f.tmp = std.testing.tmpDir(.{});
        f.home = try f.tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        f.url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/api/paas/v4/chat/completions", .{f.server.socket.address.getPort()});
        f.keys = .{ .values = @splat(null) };
        for (provider.provider_specs, &f.keys.values, 0..) |spec, *value, i| if (std.mem.eql(u8, spec.id, "zai")) {
            value.* = "test-key";
            f.index = i;
        };
        f.saved_table = pricing.active_model_table;
        f.saved_override = provider.g_zai_url_override;
        provider.g_zai_url_override = f.url;
        rc.attempted[f.index] = false;
        landing.reset();
        try f.group.concurrent(io, serveModels, .{ io, &f.server, reply, &f.gets });
    }

    fn deinit(f: *Fixture) void {
        const io = std.testing.io;
        // No worker may outlive the test that started it (catalog_bounded.live).
        _ = catalog_bounded.waitIdle(io, .fromSeconds(10));
        f.group.cancel(io);
        f.server.deinit(io);
        provider.g_zai_url_override = f.saved_override;
        pricing.active_model_table = f.saved_table;
        rc.attempted[f.index] = false;
        landing.reset();
        failures.clear("zai");
        std.testing.allocator.free(f.url);
        std.testing.allocator.free(f.home);
        f.tmp.cleanup();
    }

    fn cachePath(f: *Fixture, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/.codegraff/zai-models.json", .{f.home});
    }

    /// Whichever of the cache's two homes the worker could write (no
    /// `.codegraff` directory in a fresh HOME means the flat one).
    fn cacheWritten(f: *Fixture) bool {
        const io = std.testing.io;
        var buf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&buf, "{s}/.codegraff/zai-models.json", .{f.home}) catch return false;
        if (Io.Dir.cwd().statFile(io, dir, .{})) |_| return true else |_| {}
        const flat = std.fmt.bufPrint(&buf, "{s}/.codegraff-zai-models.json", .{f.home}) catch return false;
        if (Io.Dir.cwd().statFile(io, flat, .{})) |_| return true else |_| {}
        return false;
    }
};

fn msSince(io: Io, start: i96) i96 {
    return @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - start, std.time.ns_per_ms);
}

const landed_body = "{\"data\":[{\"id\":\"glm-landed-test\",\"context_length\":131072}]}";

test "a cold catalog cache does not hold boot, and the list activates when the fetch lands" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var f: Fixture = undefined;
    // The catalog answers well after the old startup budget would have expired.
    const slow = catalog_bounded.startup_budget.toMilliseconds() + 700;
    try f.init(.{ .delay_ms = slow, .body = landed_body });
    defer f.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const start = Io.Timestamp.now(io, .awake).nanoseconds;
    rc.ensureForStartup(io, std.testing.allocator, arena, f.home, f.keys, "zai", null, null);
    const waited = msSince(io, start);
    // Before ADR 0340 this paid the whole budget (800 ms) on a cold cache.
    try std.testing.expect(waited < @divTrunc(catalog_bounded.startup_budget.toMilliseconds(), 4));
    try std.testing.expect(!pricing.providerModelInTable("zai", "glm-landed-test"));
    try std.testing.expect(landing.waiting(f.index));
    // Nothing has landed yet: a model surface beat changes nothing.
    boot.activateLanded(io, arena, f.home);
    try std.testing.expect(!pricing.providerModelInTable("zai", "glm-landed-test"));

    try std.testing.expect(catalog_bounded.waitIdle(io, .fromSeconds(10)));
    try std.testing.expectEqual(@as(usize, 1), f.gets.load(.acquire));
    try std.testing.expect(f.cacheWritten());
    // The next model-surface beat (`ensureForQuery`, as `/model` runs it)
    // activates the landed list on the main thread, once.
    pricing_db.invalidate();
    defer pricing_db.invalidate();
    rc.ensureForQuery(io, std.testing.allocator, arena, f.home, f.keys, "zai");
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-landed-test"));
    try std.testing.expect(!landing.waiting(f.index));
    try std.testing.expect(!landing.take(f.index));
    try std.testing.expectEqual(@as(usize, 1), f.gets.load(.acquire));
}

test "a stale catalog cache still activates now and refreshes behind for the next process" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var f: Fixture = undefined;
    try f.init(.{ .body = landed_body });
    defer f.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const spec = provider.specFor("zai").?;
    var buf: [512]u8 = undefined;
    const path = try f.cachePath(&buf);
    try f.tmp.dir.createDirPath(io, ".codegraff");
    const stale = try std.fmt.allocPrint(arena, "{{\"source\":\"{s}\",\"fetched_at_ms\":1,\"models\":[{{\"name\":\"glm-cached-test\"}}]}}\n", .{spec.models_url});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = stale });

    rc.ensureForStartup(io, std.testing.allocator, arena, f.home, f.keys, "zai", null, null);
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-cached-test"));
    // Unchanged by ADR 0340: a stale refresh is not marked for activation.
    try std.testing.expect(!landing.waiting(f.index));
    try std.testing.expect(catalog_bounded.waitIdle(io, .fromSeconds(10)));
    try std.testing.expectEqual(@as(usize, 1), f.gets.load(.acquire));
    boot.activateLanded(io, arena, f.home);
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-cached-test"));
    try std.testing.expect(!pricing.providerModelInTable("zai", "glm-landed-test"));
    // ...and the refreshed list is on disk for the next process.
    const written = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, written, "glm-landed-test") != null);
}

test "a rejected cold catalog fetch stays quiet, activates nothing and is not retried" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var f: Fixture = undefined;
    try f.init(.{ .status = "401 Unauthorized", .body = "{\"error\":\"invalid key\"}" });
    defer f.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const before = pricing.active_model_table;

    rc.ensureForStartup(io, std.testing.allocator, arena, f.home, f.keys, "zai", null, null);
    try std.testing.expect(catalog_bounded.waitIdle(io, .fromSeconds(10)));
    try std.testing.expectEqual(@as(usize, 1), f.gets.load(.acquire));
    // The mark is cleared: no landing to activate, the baked rows stay.
    try std.testing.expect(!landing.waiting(f.index));
    boot.activateLanded(io, arena, f.home);
    try std.testing.expectEqual(before.ptr, pricing.active_model_table.ptr);
    try std.testing.expect(!f.cacheWritten());
    // The rejection is recorded for the listing commands, never printed at boot.
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try failures.report(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "zai: live model list not refreshed") != null);
    // One attempt per process: neither another boot pass nor a model
    // surface starts a second GET.
    rc.ensureForStartup(io, std.testing.allocator, arena, f.home, f.keys, "zai", null, null);
    pricing_db.invalidate();
    defer pricing_db.invalidate();
    rc.ensureForQuery(io, std.testing.allocator, arena, f.home, f.keys, "zai");
    try std.testing.expect(catalog_bounded.waitIdle(io, .fromSeconds(10)));
    try std.testing.expectEqual(@as(usize, 1), f.gets.load(.acquire));
}

test "only a --model the baked rows cannot resolve needs the live rows at boot" {
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-5.3"));
    try std.testing.expect(!boot.needsLiveRows("zai", null));
    try std.testing.expect(!boot.needsLiveRows("zai", ""));
    try std.testing.expect(!boot.needsLiveRows("zai", "zai"));
    try std.testing.expect(!boot.needsLiveRows("zai", "zai/glm-5.3"));
    try std.testing.expect(!boot.needsLiveRows("zai", "glm-5.3"));
    try std.testing.expect(!boot.needsLiveRows("zai", "anthropic/glm-not-baked"));
    try std.testing.expect(boot.needsLiveRows("zai", "zai/glm-not-baked"));
    try std.testing.expect(boot.needsLiveRows("zai", "glm-not-baked"));
}
