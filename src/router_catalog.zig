//! Model discovery for Codegraff and the optional workspace router.
//!
//! The workspace router is declared by `.graff/.config.router`; its catalog
//! cache stays beside that config. Catalog failures never prevent startup.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const catalog_selection = @import("catalog_selection.zig");
const pricing = @import("pricing.zig");
const provider = @import("provider.zig");
const serde = @import("serde.zig");
const util = @import("util.zig");

/// Router catalogs change on the order of weeks; favour instant startup.
const cache_ttl_ms: i64 = 6 * 60 * 60 * 1000;
var attempted: [provider.provider_specs.len]bool = @splat(false);
var additional_attempted = false;

const Snapshot = struct {
    models: []const pricing.ModelInfo,
    fetched_at_ms: i64 = 0,
};

fn isAdditional(spec: provider.ProviderSpec) bool {
    return if (provider.additional_router) |configured|
        std.mem.eql(u8, configured.id, spec.id)
    else
        false;
}

fn dirPath(arena: Allocator, home: []const u8, spec: provider.ProviderSpec) []const u8 {
    if (isAdditional(spec)) return ".graff/.models.router";
    if (home.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/.codegraff/{s}-models.json", .{ home, spec.id }) catch "";
}

fn flatPath(arena: Allocator, home: []const u8, spec: provider.ProviderSpec) []const u8 {
    if (isAdditional(spec) or home.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/.codegraff-{s}-models.json", .{ home, spec.id }) catch "";
}

fn readSmall(io: Io, arena: Allocator, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch null;
}

pub fn modelsUrl(spec: provider.ProviderSpec) []const u8 {
    return if (spec.catalog == .openai) spec.models_url else "";
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./:@+", c) != null)) return false;
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

fn listsReasoning(obj: std.json.ObjectMap) bool {
    const params = obj.get("supported_parameters") orelse return false;
    if (params != .array) return false;
    for (params.array.items) |param| {
        if (param == .string and std.mem.eql(u8, param.string, "reasoning")) return true;
    }
    return false;
}

/// Accept the common OpenAI `/models` shape and this module's compact cache
/// shape. `provider_id` is data, so the parser is reusable by every router.
pub fn parseModels(arena: Allocator, provider_id: []const u8, data: []const u8) ?Snapshot {
    const value = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    const items = value.object.get("data") orelse value.object.get("models") orelse return null;
    if (items != .array) return null;
    var rows: std.ArrayList(pricing.ModelInfo) = .empty;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const id = util.strFieldObj(item.object, "id") orelse util.strFieldObj(item.object, "name") orelse continue;
        if (!validModelId(id)) continue;
        var duplicate = false;
        for (rows.items) |row| if (std.mem.eql(u8, row.name, id)) {
            duplicate = true;
        };
        if (duplicate) continue;
        var context = positiveInt(item.object, "context_length");
        if (context == 0) context = positiveInt(item.object, "context");
        if (context == 0) context = pricing.default_context;
        rows.append(arena, .{
            .provider = provider_id,
            .name = arena.dupe(u8, id) catch continue,
            .context = context,
            .supports_reasoning = listsReasoning(item.object) or boolField(item.object, "supports_reasoning"),
        }) catch continue;
    }
    const owned = rows.toOwnedSlice(arena) catch return null;
    if (owned.len == 0) return null;
    return .{
        .models = owned,
        .fetched_at_ms = switch (value.object.get("fetched_at_ms") orelse Value{ .null = {} }) {
            .integer => |i| i,
            else => 0,
        },
    };
}

fn fetch(io: Io, gpa: Allocator, arena: Allocator, spec: provider.ProviderSpec, key: []const u8) ?Snapshot {
    const url = modelsUrl(spec);
    if (url.len == 0) return null;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{key}) catch return null;
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = bearer },
    };
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &headers,
    }) catch return null;
    if (@intFromEnum(res.status) != 200) return null;
    return parseModels(arena, spec.id, aw.writer.buffered());
}

fn writeCache(io: Io, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, models: []const pricing.ModelInfo) void {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("{\"source\":") catch return;
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    stringify.write(spec.models_url) catch return;
    aw.writer.print(",\"fetched_at_ms\":{d},\"models\":[", .{util.unixMs(io)}) catch return;
    for (models, 0..) |model, i| {
        if (i > 0) aw.writer.writeByte(',') catch return;
        aw.writer.writeAll("{\"name\":") catch return;
        stringify.write(model.name) catch return;
        aw.writer.print(",\"context\":{d},\"supports_reasoning\":{}}}", .{ model.context, model.supports_reasoning }) catch return;
    }
    aw.writer.writeAll("]}\n") catch return;
    for ([_][]const u8{ dirPath(arena, home, spec), flatPath(arena, home, spec) }) |path| {
        if (path.len == 0) continue;
        const file = Io.Dir.cwd().createFile(io, path, .{}) catch continue;
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        writer.interface.writeAll(aw.writer.buffered()) catch continue;
        writer.interface.flush() catch continue;
        return;
    }
}

fn cachedSnapshot(io: Io, arena: Allocator, home: []const u8, spec: provider.ProviderSpec) ?Snapshot {
    const data = readSmall(io, arena, dirPath(arena, home, spec)) orelse
        readSmall(io, arena, flatPath(arena, home, spec)) orelse return null;
    const value = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    if (util.strFieldObj(value.object, "source")) |source|
        if (!std.mem.eql(u8, source, spec.models_url)) return null;
    return parseModels(arena, spec.id, data);
}

/// Activate one router's catalog. Fresh cache short-circuits the network; stale
/// cache remains an offline fallback. No failure is fatal.
fn loadSpec(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, force_refresh: bool) bool {
    if (spec.catalog != .openai or key.len == 0) return false;
    const cached = cachedSnapshot(io, arena, home, spec);
    if (!force_refresh) if (cached) |snapshot| {
        const age = util.unixMs(io) - snapshot.fetched_at_ms;
        if (age >= 0 and age <= cache_ttl_ms and pricing.activateProviderModels(arena, spec.id, snapshot.models)) return true;
    };
    if (fetch(io, gpa, arena, spec, key)) |snapshot| {
        if (pricing.activateProviderModels(arena, spec.id, snapshot.models)) {
            if (home.len != 0 or isAdditional(spec)) writeCache(io, arena, home, spec, snapshot.models);
            return true;
        }
    }
    if (cached) |snapshot| return pricing.activateProviderModels(arena, spec.id, snapshot.models);
    return false;
}

fn ensureAt(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, index: usize, key: []const u8) void {
    if (attempted[index] or key.len == 0) return;
    attempted[index] = true;
    _ = loadSpec(io, gpa, arena, home, provider.provider_specs[index], key, false);
}

fn ensureAdditional(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys) void {
    if (additional_attempted) return;
    const spec = provider.additional_router orelse return;
    const key = keys.get(spec.id) orelse return;
    additional_attempted = true;
    _ = loadSpec(io, gpa, arena, home, spec, key, false);
}

pub fn ensureForStartup(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, model_flag: ?[]const u8, saved: ?serde.SavedModel) void {
    for (provider.provider_specs, 0..) |spec, index| {
        if (spec.catalog != .openai or !catalog_selection.startupMayUse(keys, spec.id, model_flag, saved)) continue;
        ensureAt(io, gpa, arena, home, index, keys.get(spec.id) orelse "");
    }
    if (provider.additional_router) |spec|
        if (catalog_selection.startupMayUse(keys, spec.id, model_flag, saved))
            ensureAdditional(io, gpa, arena, home, keys);
}

pub fn ensureForQuery(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, query: []const u8) void {
    for (provider.provider_specs, 0..) |spec, index| {
        if (spec.catalog != .openai or !catalog_selection.queryMayUse(spec.id, query)) continue;
        ensureAt(io, gpa, arena, home, index, keys.get(spec.id) orelse "");
    }
    if (provider.additional_router) |spec|
        if (catalog_selection.queryMayUse(spec.id, query))
            ensureAdditional(io, gpa, arena, home, keys);
}

pub fn loadAll(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, force_refresh: bool) void {
    for (provider.provider_specs, 0..) |spec, index| {
        if (spec.catalog != .openai) continue;
        attempted[index] = true;
        _ = loadSpec(io, gpa, arena, home, spec, keys.get(spec.id) orelse "", force_refresh);
    }
    if (provider.additional_router) |spec| {
        additional_attempted = true;
        _ = loadSpec(io, gpa, arena, home, spec, keys.get(spec.id) orelse "", force_refresh);
    }
}

/// Activate previous-run caches without credentials or network. `--schema`
/// uses this so GUI model metadata follows router rollouts.
pub fn loadCachedAll(io: Io, arena: Allocator, home: []const u8) void {
    for (provider.provider_specs) |spec| {
        if (spec.catalog != .openai) continue;
        const snapshot = cachedSnapshot(io, arena, home, spec) orelse continue;
        _ = pricing.activateProviderModels(arena, spec.id, snapshot.models);
    }
    if (provider.additional_router) |spec| {
        const snapshot = cachedSnapshot(io, arena, home, spec) orelse return;
        _ = pricing.activateProviderModels(arena, spec.id, snapshot.models);
    }
}

test "OpenAI catalog configuration carries its models endpoint" {
    const spec = provider.specFor("codegraff") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(provider.ProviderSpec.CatalogKind.openai, spec.catalog);
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/models", modelsUrl(spec));
    for (provider.provider_specs) |candidate| {
        if (candidate.catalog != .openai) continue;
        try std.testing.expect(candidate.kind == .openai);
        try std.testing.expect(candidate.models_url.len != 0);
    }
}

test "parseModels is reusable for a newly configured router" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "new-router",
        \\{"object":"list","data":[
        \\ {"id":"glm-5.2","context_length":1000000,"supported_parameters":["reasoning","tools"]},
        \\ {"id":"openai/gpt-oss:free","context_length":131072},
        \\ {"id":"no-window"},
        \\ {"id":"glm-5.2","context_length":128000},
        \\ {"id":"bad id!","context_length":999}
        \\]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), snapshot.models.len);
    try std.testing.expectEqualStrings("new-router", snapshot.models[0].provider);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expect(snapshot.models[0].supports_reasoning);
    try std.testing.expectEqualStrings("openai/gpt-oss:free", snapshot.models[1].name);
    try std.testing.expectEqual(pricing.default_context, snapshot.models[2].context);
}

test "parseModels round-trips the generic cache shape" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "router",
        \\{"fetched_at_ms":1700000000000,
        \\ "models":[{"name":"minimax-m3","context":1000000,"supports_reasoning":true}]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), snapshot.fetched_at_ms);
    try std.testing.expectEqualStrings("router", snapshot.models[0].provider);
    try std.testing.expect(snapshot.models[0].supports_reasoning);
}

test "router discovery replaces only its provider slice" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "codegraff", .name = "kimi-k3", .context = 1_048_576 },
    };
    try std.testing.expect(pricing.activateProviderModels(state.allocator(), "codegraff", &discovered));
    try std.testing.expect(pricing.providerModelInTable("codegraff", "kimi-k3"));
    try std.testing.expect(!pricing.providerModelInTable("codegraff", "claude-opus-4.8"));
    try std.testing.expect(pricing.providerModelInTable("anthropic", "claude-opus-4-8"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.6-sol"));
}
