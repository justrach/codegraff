//! Non-blocking stale-while-revalidate refresh and bounded force-refresh
//! across all authenticated dynamic providers (including Codex and Kimi).
//!
//! Keeps startup and ordinary `graff/models` calls free of network stalls
//! (ADR 0340 / ADR 0350) while letting explicit refreshes (`graff/models` with
//! `{"force": true}`, `/refresh`) update every signed-in catalog immediately.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const catalog_bounded = @import("catalog_bounded.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const landing = @import("catalog_landing.zig");
const models_cache = @import("models_cache.zig");
const pricing = @import("pricing.zig");
const provider = @import("provider.zig");
const rc = @import("router_catalog.zig");
const util = @import("util.zig");

/// Throttle per-session background revalidation triggered by repeated `graff/models` calls.
var last_bg_sweep_ms: ?i64 = null;
const bg_sweep_cooldown_ms: i64 = 30_000;

/// True when `params` carries `{"force": true}` (explicit user catalog refresh).
pub fn forceRequested(params: ?std.json.Value) bool {
    const value = params orelse return false;
    if (value != .object) return false;
    const flag = value.object.get("force") orelse return false;
    return flag == .bool and flag.bool;
}

/// True when the on-disk Codex cache is absent, older than 5 minutes, or below
/// Graff's supported client_version floor (or native Codex cache version).
pub fn codexNeedsRefresh(io: Io, arena: Allocator, home: []const u8, codex_home: []const u8) bool {
    if (provider.g_codex_url_override != null) return false;
    if (home.len == 0) return false;
    const native_data = models_cache.readSmall(io, arena, models_cache.nativeCodexPath(arena, codex_home));
    const native = if (native_data) |d| models_cache.parseCodexSnapshot(arena, d) else null;
    const want_ver = models_cache.effectiveCodexVersion(null, native);
    const cached_data = models_cache.readSmall(io, arena, models_cache.codexDirPath(arena, home)) orelse
        models_cache.readSmall(io, arena, models_cache.codexFlatPath(arena, home)) orelse return true;
    const cached = models_cache.parseCodexSnapshot(arena, cached_data) orelse return true;
    if (!models_cache.snapshotMatchesVersion(cached, want_ver)) return true;
    const age = util.unixMs(io) - cached.fetched_at_ms;
    return age < 0 or age > models_cache.codex_cache_ttl_ms;
}

/// Worker-side fetch of the authenticated Codex account catalog to disk cache.
/// Never touches the shared model table; main thread activates via `activateCachedCodex`.
pub fn fetchCodexToCache(io: Io, gpa: Allocator, home: []const u8, codex_home: []const u8, token: []const u8, account: []const u8) bool {
    if (provider.g_codex_url_override != null) return false;
    if (home.len == 0 or token.len == 0 or account.len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const native_data = models_cache.readSmall(io, a, models_cache.nativeCodexPath(a, codex_home));
    const native = if (native_data) |d| models_cache.parseCodexSnapshot(a, d) else null;
    const version = models_cache.effectiveCodexVersion(models_cache.installedCodexVersion(io, a), native);
    const snapshot = models_cache.fetchCodexSnapshot(io, gpa, a, token, account, version) orelse return false;
    return models_cache.writeCodexCache(io, a, home, version, snapshot.models);
}

/// Main-thread activation of a landed Codex disk cache.
pub fn activateCachedCodex(io: Io, arena: Allocator, home: []const u8) bool {
    if (provider.g_codex_url_override != null or home.len == 0) return false;
    const data = models_cache.readSmall(io, arena, models_cache.codexDirPath(arena, home)) orelse
        models_cache.readSmall(io, arena, models_cache.codexFlatPath(arena, home)) orelse return false;
    const snapshot = models_cache.parseCodexSnapshot(arena, data) orelse return false;
    if (!pricing.activateCodexModels(arena, snapshot.models)) return false;
    models_cache.codex_catalog_source = "live account catalog";
    return true;
}

/// Zero-delay background refresh for Codex when its cache is missing, stale, or
/// below the current client_version floor.
pub fn detachCodexIfStale(io: Io, arena: Allocator, home: []const u8, codex_home: []const u8, token: []const u8, account: []const u8) void {
    if (token.len == 0 or account.len == 0 or home.len == 0) return;
    if (landing.waiting(landing.codex_slot)) return;
    if (!codexNeedsRefresh(io, arena, home, codex_home)) return;
    const job: catalog_bounded.Job = .{ .codex = .{ .account = account, .codex_home = codex_home } };
    landing.expect(job);
    catalog_bounded.detach(job, home, token);
}

/// Non-blocking stale-while-revalidate sweep for ordinary `graff/models` calls:
/// detaches background fetches for any authenticated provider whose cache is
/// absent or older than 5 minutes, adding zero latency to the caller.
pub fn detachStaleAll(io: Io, arena: Allocator, home: []const u8, codex_home: []const u8, keys: provider.Keys) void {
    if (home.len == 0) return;
    const now = util.unixMs(io);
    if (last_bg_sweep_ms) |prev| if (now >= prev and now - prev < bg_sweep_cooldown_ms) return;
    last_bg_sweep_ms = now;

    for (provider.provider_specs, 0..) |spec, index| {
        if (!rc.dynamic(spec)) continue;
        if (landing.waiting(index)) continue;
        const key = keys.get(spec.id) orelse continue;
        if (key.len == 0) continue;
        if (!rc.cacheNeedsRevalidate(io, arena, home, spec)) continue;
        const job: catalog_bounded.Job = .{ .router = .{ .spec = spec, .source = keys.source(spec.id) } };
        landing.expect(job);
        catalog_bounded.detach(job, home, key);
    }
    if (provider.additional_router) |spec| {
        if (!landing.waiting(landing.additional_slot)) {
            if (keys.get(spec.id)) |key| if (key.len != 0 and rc.cacheNeedsRevalidate(io, arena, home, spec)) {
                const job: catalog_bounded.Job = .{ .router = .{ .spec = spec, .source = keys.source(spec.id) } };
                landing.expect(job);
                catalog_bounded.detach(job, ".", key);
            };
        }
    }
    if (!landing.waiting(landing.kimi_slot)) {
        if (keys.get("kimi")) |key| if (key.len != 0) {
            const stale = if (kimi_catalog.cached(io, arena, home)) |c| !c.fresh else true;
            if (stale) {
                landing.expect(.kimi);
                catalog_bounded.detach(.kimi, home, key);
            }
        };
    }
    detachCodexIfStale(io, arena, home, codex_home, keys.get("codex") orelse "", keys.codex_account);
}

/// Bounded concurrent live refresh across every authenticated dynamic provider
/// (router providers, Kimi, and Codex). Used by `graff/models {"force": true}`
/// so an explicit user refresh lands fresh models immediately while a single
/// unresponsive host cannot hang ACP past `budget`.
pub fn refreshAllBounded(io: Io, arena: Allocator, home: []const u8, codex_home: []const u8, keys: provider.Keys, budget: Io.Duration) usize {
    if (home.len == 0) return 0;
    var batch: catalog_bounded.Batch = .{};
    var router_slots: [provider.provider_specs.len + 1]?usize = @splat(null);
    var spawned: usize = 0;

    for (provider.provider_specs, 0..) |spec, index| {
        if (!rc.dynamic(spec)) continue;
        const key = keys.get(spec.id) orelse continue;
        if (key.len == 0) continue;
        rc.attempted[index] = true;
        const job: catalog_bounded.Job = .{ .router = .{ .spec = spec, .source = keys.source(spec.id) } };
        landing.expect(job);
        router_slots[index] = batch.spawn(job, home, key);
        if (router_slots[index] != null) spawned += 1;
    }
    if (provider.additional_router) |spec| {
        if (keys.get(spec.id)) |key| if (key.len != 0) {
            rc.additional_attempted = true;
            const job: catalog_bounded.Job = .{ .router = .{ .spec = spec, .source = keys.source(spec.id) } };
            landing.expect(job);
            router_slots[provider.provider_specs.len] = batch.spawn(job, ".", key);
            if (router_slots[provider.provider_specs.len] != null) spawned += 1;
        };
    }
    var kimi_slot: ?usize = null;
    if (keys.get("kimi")) |key| if (key.len != 0) {
        landing.expect(.kimi);
        kimi_slot = batch.spawn(.kimi, home, key);
        if (kimi_slot != null) spawned += 1;
    };
    var codex_slot: ?usize = null;
    if (provider.g_codex_url_override == null) {
        const tok = keys.get("codex") orelse "";
        if (tok.len != 0 and keys.codex_account.len != 0) {
            const job: catalog_bounded.Job = .{ .codex = .{ .account = keys.codex_account, .codex_home = codex_home } };
            landing.expect(job);
            codex_slot = batch.spawn(job, home, tok);
            if (codex_slot != null) spawned += 1;
        }
    }
    if (batch.len == 0) return 0;
    batch.wait(io, budget);

    var activated: usize = 0;
    for (provider.provider_specs, 0..) |spec, index| {
        if (batch.fetched(router_slots[index])) {
            _ = landing.take(index);
            if (rc.activateCached(io, arena, home, spec)) activated += 1;
        }
    }
    if (provider.additional_router) |spec| {
        if (batch.fetched(router_slots[provider.provider_specs.len])) {
            _ = landing.take(landing.additional_slot);
            if (rc.activateCached(io, arena, home, spec)) activated += 1;
        }
    }
    if (batch.fetched(kimi_slot)) {
        _ = landing.take(landing.kimi_slot);
        if (kimi_catalog.cached(io, arena, home)) |fresh| {
            kimi_catalog.commit(arena, fresh.rows, "live account catalog");
            activated += 1;
        }
    }
    if (batch.fetched(codex_slot)) {
        _ = landing.take(landing.codex_slot);
        if (activateCachedCodex(io, arena, home)) activated += 1;
    }
    return activated;
}

test "forceRequested is true only for explicit boolean force:true" {
    const a = std.testing.allocator;
    try std.testing.expect(!forceRequested(null));
    for ([_][]const u8{ "{}", "null", "{\"force\":false}", "{\"force\":\"true\"}", "{\"refresh\":true}" }) |input| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
        defer parsed.deinit();
        try std.testing.expect(!forceRequested(parsed.value));
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"force\":true}", .{});
    defer parsed.deinit();
    try std.testing.expect(forceRequested(parsed.value));
}

test "codexNeedsRefresh flags stale or older-client-version caches and skips fresh ones" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const saved_override = provider.g_codex_url_override;
    defer provider.g_codex_url_override = saved_override;
    provider.g_codex_url_override = null;

    try std.testing.expect(codexNeedsRefresh(io, a, home, ""));
    try tmp.dir.createDirPath(io, ".codegraff");
    const path = try std.fmt.allocPrint(a, "{s}/.codegraff/codex-models.json", .{home});

    // Older client_version than floor triggers refresh even if timestamp is now.
    const old_ver = try std.fmt.allocPrint(a, "{{\"fetched_at_ms\":{d},\"client_version\":\"0.169.0\",\"models\":[{{\"name\":\"gpt-6-astra\",\"context\":272000}}]}}\n", .{util.unixMs(io)});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = old_ver });
    try std.testing.expect(codexNeedsRefresh(io, a, home, ""));

    // Fresh cache matching floor needs no refresh.
    const fresh = try std.fmt.allocPrint(a, "{{\"fetched_at_ms\":{d},\"client_version\":\"{s}\",\"models\":[{{\"name\":\"gpt-6.2-sol\",\"context\":500000}}]}}\n", .{ util.unixMs(io), models_cache.codex_client_version_floor });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = fresh });
    try std.testing.expect(!codexNeedsRefresh(io, a, home, ""));

    // Stale (>5m) cache matching floor needs refresh.
    const stale = try std.fmt.allocPrint(a, "{{\"fetched_at_ms\":{d},\"client_version\":\"{s}\",\"models\":[{{\"name\":\"gpt-6.2-sol\",\"context\":500000}}]}}\n", .{ util.unixMs(io) - models_cache.codex_cache_ttl_ms - 1000, models_cache.codex_client_version_floor });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = stale });
    try std.testing.expect(codexNeedsRefresh(io, a, home, ""));
}

test "refreshAllBounded updates dynamic provider catalog immediately within budget" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    const Handler = struct {
        fn serve(srv_io: Io, srv: *Io.net.Server) void {
            const stream = srv.accept(srv_io) catch return;
            defer stream.close(srv_io);
            var rbuf: [2048]u8 = undefined;
            var r = Io.net.Stream.Reader.init(stream, srv_io, &rbuf);
            while (r.interface.takeDelimiter('\n') catch null) |line|
                if (std.mem.eql(u8, line, "\r") or line.len == 0) break;
            const body = "{\"models\":[{\"slug\":\"gpt-6.2-sol\",\"visibility\":\"list\",\"context_window\":500000},{\"slug\":\"gpt-6.2-astra\",\"visibility\":\"list\",\"context_window\":272000}]}";
            var wbuf: [2048]u8 = undefined;
            var w = Io.net.Stream.Writer.init(stream, srv_io, &wbuf);
            w.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            w.interface.flush() catch return;
        }
    };
    try group.concurrent(io, Handler.serve, .{ io, &server });

    const saved_override = provider.g_chatgpt_url_override;
    defer provider.g_chatgpt_url_override = saved_override;
    const saved_table = pricing.active_model_table;
    defer pricing.active_model_table = saved_table;
    const saved_attempted = rc.attempted;
    defer rc.attempted = saved_attempted;
    landing.reset();
    defer landing.reset();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/responses", .{server.socket.address.getPort()});
    provider.g_chatgpt_url_override = url;
    var keys: provider.Keys = .{ .values = @splat(null) };
    _ = keys.set("chatgpt-new", "test-token", .login);

    const refreshed = refreshAllBounded(io, a, home, "", keys, .fromSeconds(2));
    try std.testing.expect(catalog_bounded.waitIdle(io, .fromSeconds(5)));
    try std.testing.expectEqual(@as(usize, 1), refreshed);
    try std.testing.expect(pricing.providerModelInTable("chatgpt-new", "gpt-6.2-sol"));
    try std.testing.expect(pricing.providerModelInTable("chatgpt-new", "gpt-6.2-astra"));
    try std.testing.expectEqual(@as(u64, 500_000), pricing.contextFor("chatgpt-new", "gpt-6.2-sol"));
}
