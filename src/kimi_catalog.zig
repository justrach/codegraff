//! Authenticated Kimi Code model discovery. Kimi's coding endpoint publishes
//! account-visible ids at /coding/v1/models; keep routing current without
//! baking each K2/K3 rollout into the OAuth client.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const pricing = @import("pricing.zig");
const util = @import("util.zig");
const identity = @import("kimi_identity.zig");

pub const models_url = "https://api.kimi.com/coding/v1/models";
pub const user_agent = identity.user_agent;
pub const platform = identity.platform;
pub const version = identity.version;
pub const identityHeaders = identity.identityHeaders;
pub var catalog_source: []const u8 = "baked offline fallback";
var catalog_attempted = false;

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    return true;
}

fn positiveInt(obj: std.json.ObjectMap, name: []const u8) u64 {
    const value = obj.get(name) orelse return 0;
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) bool {
    const value = obj.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn thinkingSupport(obj: std.json.ObjectMap) pricing.ThinkingSupport {
    const raw = util.strFieldObj(obj, "supports_thinking_type") orelse return .unknown;
    if (std.mem.eql(u8, raw, "no")) return .no;
    if (std.mem.eql(u8, raw, "both")) return .both;
    if (std.mem.eql(u8, raw, "only")) return .only;
    return .unknown;
}

fn parseEfforts(arena: Allocator, obj: std.json.ObjectMap) struct { values: []const []const u8, default: ?[]const u8 } {
    const raw = obj.get("think_efforts") orelse return .{ .values = &.{}, .default = null };
    if (raw != .object or !boolField(raw.object, "support")) return .{ .values = &.{}, .default = null };
    var values: std.ArrayList([]const u8) = .empty;
    if (raw.object.get("valid_efforts")) |list| if (list == .array) {
        for (list.array.items) |value| {
            if (value != .string or value.string.len == 0 or value.string.len > 32) continue;
            values.append(arena, arena.dupe(u8, value.string) catch continue) catch continue;
        }
    };
    return .{
        .values = values.toOwnedSlice(arena) catch &.{},
        .default = if (util.strFieldObj(raw.object, "default_effort")) |value| arena.dupe(u8, value) catch null else null,
    };
}

/// Parse the OpenAI-style model list Kimi exposes. Preserve server ordering for
/// the picker, while pricing.providerDefaultModel independently selects the
/// newest pure `kN` generation rather than the first compatibility alias.
pub fn parseModels(arena: Allocator, data: []const u8) ?[]const pricing.ModelInfo {
    const value = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    const items = value.object.get("data") orelse return null;
    if (items != .array) return null;
    var rows: std.ArrayList(pricing.ModelInfo) = .empty;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const id = util.strFieldObj(item.object, "id") orelse continue;
        if (!validModelId(id)) continue;
        var duplicate = false;
        for (rows.items) |row| if (std.mem.eql(u8, row.name, id)) {
            duplicate = true;
        };
        if (duplicate) continue;
        var context = positiveInt(item.object, "context_length");
        if (context == 0) context = positiveInt(item.object, "context_window");
        if (context == 0) context = pricing.default_context;
        const effort = parseEfforts(arena, item.object);
        const protocol: pricing.ModelProtocol = if (util.strFieldObj(item.object, "protocol")) |protocol_name|
            (if (std.mem.eql(u8, protocol_name, "anthropic")) .anthropic else .kimi)
        else
            .kimi;
        rows.append(arena, .{
            .provider = "kimi",
            .name = arena.dupe(u8, id) catch continue,
            .context = context,
            .protocol = protocol,
            .supports_reasoning = boolField(item.object, "supports_reasoning"),
            .thinking_support = thinkingSupport(item.object),
            .support_efforts = effort.values,
            .default_effort = effort.default,
        }) catch continue;
    }
    const owned = rows.toOwnedSlice(arena) catch return null;
    return if (owned.len > 0) owned else null;
}

/// Network half of `load`, no table mutation. Startup fans this out beside
/// the other live catalogs, then `commit`s on the joining thread so
/// `pricing.active_model_table` stays single-writer.
pub const Fetch = struct {
    rows: []const pricing.ModelInfo = &.{},
    source: []const u8 = "baked fallback — live refresh unavailable",
};

pub fn fetch(io: Io, gpa: Allocator, arena: Allocator, access: []const u8) Fetch {
    if (access.len == 0) return .{ .source = "baked fallback — no Kimi login" };
    const body = fetchBody(io, gpa, arena, access) orelse return .{};
    const rows = parseModels(arena, body) orelse
        return .{ .source = "baked fallback — invalid live catalog" };
    return .{ .rows = rows, .source = "live account catalog" };
}

fn fetchBody(io: Io, gpa: Allocator, arena: Allocator, access: []const u8) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{access}) catch return null;
    var extra: [8]std.http.Header = undefined;
    extra[0] = .{ .name = "Authorization", .value = bearer };
    extra[1] = .{ .name = "Accept", .value = "application/json" };
    const sent = 2 + identityHeaders(extra[2..]).len;
    const response = client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = extra[0..sent],
    }) catch return null;
    if (@backingInt(response.status) != 200) return null;
    return aw.writer.buffered();
}

/// The account catalog as last fetched, so boot activates it instead of
/// waiting on the network; `catalog_bounded` rewrites it in the background.
pub const cache_ttl_ms: i64 = 6 * 60 * 60 * 1000;

fn cachePaths(arena: Allocator, home: []const u8) [2][]const u8 {
    if (home.len == 0) return .{ "", "" };
    return .{
        std.fmt.allocPrint(arena, "{s}/.codegraff/kimi-models.json", .{home}) catch "",
        std.fmt.allocPrint(arena, "{s}/.codegraff-kimi-models.json", .{home}) catch "",
    };
}

/// Fetch the catalog and store the raw body; true when a valid catalog was
/// written. Runs on a `catalog_bounded` worker with its own Io and allocator.
pub fn fetchToCache(io: Io, gpa: Allocator, home: []const u8, access: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body = fetchBody(io, gpa, a, access) orelse return false;
    if (parseModels(a, body) == null) return false;
    for (cachePaths(a, home)) |path| {
        if (path.len == 0) continue;
        @import("credential_store.zig").replaceFile(io, Io.Dir.cwd(), path, body, .default_file) catch continue;
        return true;
    }
    return false;
}

pub const Cached = struct { rows: []const pricing.ModelInfo, fresh: bool };

pub fn cached(io: Io, arena: Allocator, home: []const u8) ?Cached {
    for (cachePaths(arena, home)) |path| {
        if (path.len == 0) continue;
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch continue;
        const rows = parseModels(arena, data) orelse continue;
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .rows = rows, .fresh = false };
        const age = util.unixMs(io) - @as(i64, @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)));
        return .{ .rows = rows, .fresh = age >= 0 and age <= cache_ttl_ms };
    }
    return null;
}

fn retain(arena: Allocator, rows: []const pricing.ModelInfo) ?[]const pricing.ModelInfo {
    const out = arena.alloc(pricing.ModelInfo, rows.len) catch return null;
    for (rows, out) |src, *dst| {
        dst.* = src;
        dst.provider = arena.dupe(u8, src.provider) catch return null;
        dst.name = arena.dupe(u8, src.name) catch return null;
        if (src.support_efforts.len != 0) {
            const efforts = arena.alloc([]const u8, src.support_efforts.len) catch return null;
            for (src.support_efforts, efforts) |effort, *slot|
                slot.* = arena.dupe(u8, effort) catch return null;
            dst.support_efforts = efforts;
        }
        if (src.default_effort) |effort| dst.default_effort = arena.dupe(u8, effort) catch return null;
    }
    return out;
}

/// Install a `fetch` result into the session table. `rows`/`source` may live
/// in a task arena; strings are copied before activate.
pub fn commit(arena: Allocator, rows: []const pricing.ModelInfo, source: []const u8) void {
    if (rows.len == 0) {
        catalog_source = source;
        return;
    }
    const kept = retain(arena, rows) orelse {
        catalog_source = source;
        return;
    };
    catalog_source = if (pricing.activateKimiModels(arena, kept)) source else "baked fallback — catalog rows rejected";
}

/// Claim the once-per-process fetch. Startup's fan-out calls this before
/// spawning so a later `/model` `ensure` cannot start a second GET.
pub fn claimAttempt() bool {
    if (catalog_attempted) return false;
    catalog_attempted = true;
    return true;
}

/// Fetch and activate the authenticated catalog. Any failure leaves the baked
/// K3 rows intact, so offline runs and temporary Kimi outages still start.
pub fn load(io: Io, gpa: Allocator, arena: Allocator, access: []const u8) bool {
    if (access.len == 0) {
        catalog_source = "baked fallback — no Kimi login";
        return false;
    }
    catalog_attempted = true;
    const got = fetch(io, gpa, arena, access);
    if (got.rows.len == 0) {
        catalog_source = got.source;
        return false;
    }
    if (!pricing.activateKimiModels(arena, got.rows)) return false;
    catalog_source = "live account catalog";
    return true;
}

/// Demand-load the account catalog at most once per process. Startup fans
/// the GET out via `claimAttempt` + `fetch`; `/model` and `/models` call
/// this when their catalog surfaces become visible.
pub fn ensure(io: Io, gpa: Allocator, arena: Allocator, access: []const u8) void {
    if (catalog_attempted) return;
    _ = load(io, gpa, arena, access);
}

test "parseModels accepts Kimi aliases and K3 context windows" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const rows = parseModels(state.allocator(),
        \\{"object":"list","data":[
        \\ {"id":"kimi-for-coding","context_length":262144,"supports_reasoning":true},
        \\ {"id":"k3","context_length":1048576,"protocol":"anthropic","supports_reasoning":true,"supports_thinking_type":"only","think_efforts":{"support":true,"valid_efforts":["max"],"default_effort":"max"}},
        \\ {"id":"k3","context_length":1},
        \\ {"id":"bad id","context_length":42}]}
    ).?;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("kimi-for-coding", rows[0].name);
    try std.testing.expectEqualStrings("k3", rows[1].name);
    try std.testing.expectEqual(@as(u64, 1_048_576), rows[1].context);
    try std.testing.expectEqual(pricing.ModelProtocol.anthropic, rows[1].protocol);
    try std.testing.expectEqual(pricing.ThinkingSupport.only, rows[1].thinking_support);
    try std.testing.expectEqualStrings("max", rows[1].support_efforts[0]);
    try std.testing.expectEqualStrings("max", rows[1].default_effort.?);
}

test "commit installs fetched Kimi rows into the active table" {
    const saved_table = pricing.active_model_table;
    const saved_source = catalog_source;
    defer {
        pricing.active_model_table = saved_table;
        catalog_source = saved_source;
    }
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const rows = [_]pricing.ModelInfo{
        .{ .provider = "kimi", .name = "k9-fanout", .context = 99_000, .protocol = .anthropic },
    };
    commit(state.allocator(), &rows, "live account catalog");
    try std.testing.expectEqualStrings("live account catalog", catalog_source);
    try std.testing.expect(pricing.providerModelInTable("kimi", "k9-fanout"));
    try std.testing.expect(pricing.providerModelInTable("anthropic", "claude-opus-4-8"));
}

test "the cached account catalog activates at boot and reports its age" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    try std.testing.expect(cached(io, a, home) == null);
    try tmp.dir.createDir(io, ".codegraff", .default_dir);
    const path = try std.fmt.allocPrint(a, "{s}/.codegraff/kimi-models.json", .{home});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\{"object":"list","data":[{"id":"k9-cached","context_length":262144}]}
    });
    const hit = cached(io, a, home) orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit.fresh);
    try std.testing.expectEqualStrings("k9-cached", hit.rows[0].name);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not json" });
    try std.testing.expect(cached(io, a, home) == null);
}
