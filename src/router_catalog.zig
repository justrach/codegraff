//! Model discovery for Codegraff, Anthropic, and the optional workspace router.
//!
//! The workspace router is declared by `.graff/.config.router`; its catalog
//! cache stays beside that config. Catalog failures never prevent startup.
//! Anthropic's `/v1/models` (catalog kind `.anthropic`) rides the same
//! machinery so new Claude releases appear without a rebuild. It differs in
//! auth (x-api-key + anthropic-version, like Messages) and in pagination:
//! the Models API pages with after_id/has_more/last_id rather than the
//! page/next_page scheme, so fetch follows has_more until the list is
//! complete. Discovery replaces the provider's slice, keeping graff's list
//! 1:1 with the official one; the baked pricing.zig rows remain purely the
//! no-key/offline fallback.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const root = @import("main.zig");
const catalog_selection = @import("catalog_selection.zig");
const credential_store = @import("credential_store.zig");
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
    // Models-API cursor pagination (after_id/has_more/last_id). Absent on
    // OpenAI-shaped routers and on this module's cache shape → one page.
    has_more: bool = false,
    last_id: ?[]const u8 = null,
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

/// Whether this module demand-loads the spec's live model list over HTTP.
/// Codex and Kimi have their own bespoke loaders (models_cache/kimi_catalog).
pub fn dynamic(spec: provider.ProviderSpec) bool {
    return spec.catalog == .openai or spec.catalog == .anthropic;
}

pub fn modelsUrl(spec: provider.ProviderSpec) []const u8 {
    return if (dynamic(spec)) spec.models_url else "";
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

/// Context window from the baked offline table for a live-discovered row
/// whose catalog omits windows (Anthropic's /v1/models has no context field).
/// Exact provider+name first, then the longest baked name that prefixes a
/// dated id at a '-' boundary (claude-opus-4-8-20260115 → claude-opus-4-8).
fn bakedContext(provider_id: []const u8, name: []const u8) ?u64 {
    var best: ?u64 = null;
    var best_len: usize = 0;
    for (pricing.model_table) |m| {
        if (!std.mem.eql(u8, m.provider, provider_id)) continue;
        if (std.mem.eql(u8, m.name, name)) return m.context;
        if (m.name.len > best_len and m.name.len < name.len and
            std.mem.startsWith(u8, name, m.name) and name[m.name.len] == '-')
        {
            best = m.context;
            best_len = m.name.len;
        }
    }
    return best;
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
        // Anthropic declares the input window as max_input_tokens. Its sibling
        // max_tokens is the OUTPUT cap (128k on Opus 5) — never read it as a
        // window, or a 1M-context model would compact at ~102k.
        if (context == 0) context = positiveInt(item.object, "max_input_tokens");
        if (context == 0) context = bakedContext(provider_id, id) orelse pricing.default_context;
        rows.append(arena, .{
            .provider = provider_id,
            .name = arena.dupe(u8, id) catch continue,
            .context = context,
            .supports_reasoning = listsReasoning(item.object) or boolField(item.object, "supports_reasoning"),
        }) catch continue;
    }
    const owned = rows.toOwnedSlice(arena) catch return null;
    if (owned.len == 0) return null;
    const has_more = value.object.get("has_more") orelse Value{ .null = {} };
    return .{
        .models = owned,
        .fetched_at_ms = switch (value.object.get("fetched_at_ms") orelse Value{ .null = {} }) {
            .integer => |i| i,
            else => 0,
        },
        .has_more = has_more == .bool and has_more.bool,
        .last_id = util.strFieldObj(value.object, "last_id"),
    };
}

/// Catalog GET auth mirrors the provider's chat auth: OpenAI-style routers
/// take a bearer token; Anthropic's /v1/models wants the same x-api-key +
/// anthropic-version pair as the Messages endpoint itself.
fn catalogHeaders(arena: Allocator, spec: provider.ProviderSpec, key: []const u8, buf: *[3]std.http.Header) ?[]const std.http.Header {
    buf[0] = .{ .name = "Accept", .value = "application/json" };
    if (spec.auth == .x_api_key) {
        buf[1] = .{ .name = "x-api-key", .value = key };
        buf[2] = .{ .name = "anthropic-version", .value = root.anthropic_version };
        return buf[0..3];
    }
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{key}) catch return null;
    buf[1] = .{ .name = "Authorization", .value = bearer };
    return buf[0..2];
}

/// Next page of a Models-API cursor walk: `after_id` rides alongside the
/// base URL's own query (limit=1000).
fn pageUrl(arena: Allocator, base: []const u8, after_id: ?[]const u8) ?[]const u8 {
    const id = after_id orelse return base;
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) '&' else '?';
    return std.fmt.allocPrint(arena, "{s}{c}after_id={s}", .{ base, sep, id }) catch null;
}

fn containsName(rows: []const pricing.ModelInfo, name: []const u8) bool {
    for (rows) |row| if (std.mem.eql(u8, row.name, name)) return true;
    return false;
}

fn fetchPage(io: Io, gpa: Allocator, arena: Allocator, spec: provider.ProviderSpec, key: []const u8, url: []const u8) ?Snapshot {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var headers_buf: [3]std.http.Header = undefined;
    const headers = catalogHeaders(arena, spec, key, &headers_buf) orelse return null;
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = headers,
    }) catch return null;
    if (@intFromEnum(res.status) != 200) return null;
    return parseModels(arena, spec.id, aw.writer.buffered());
}

/// Fetch the COMPLETE model list. The Models API pages with after_id +
/// has_more/last_id (not page/next_page), so one GET is not the whole
/// catalog; OpenAI-shaped routers never set has_more and stay one page.
/// A failed later page keeps the rows already gathered rather than
/// discarding a valid prefix; the page cap only guards against a server
/// that always answers has_more.
fn fetch(io: Io, gpa: Allocator, arena: Allocator, spec: provider.ProviderSpec, key: []const u8) ?Snapshot {
    const base = modelsUrl(spec);
    if (base.len == 0) return null;
    var rows: std.ArrayList(pricing.ModelInfo) = .empty;
    var after_id: ?[]const u8 = null;
    var pages: usize = 0;
    while (pages < 16) : (pages += 1) {
        const url = pageUrl(arena, base, after_id) orelse break;
        const page = fetchPage(io, gpa, arena, spec, key, url) orelse break;
        for (page.models) |m| {
            if (containsName(rows.items, m.name)) continue;
            rows.append(arena, m) catch return null;
        }
        if (!page.has_more) break;
        after_id = page.last_id orelse break;
    }
    if (rows.items.len == 0) return null;
    return .{ .models = rows.toOwnedSlice(arena) catch return null };
}

fn cacheDocument(io: Io, arena: Allocator, spec: provider.ProviderSpec, models: []const pricing.ModelInfo) ?[]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("{\"source\":") catch return null;
    var source_stringify: std.json.Stringify = .{ .writer = &aw.writer };
    source_stringify.write(spec.models_url) catch return null;
    aw.writer.print(",\"fetched_at_ms\":{d},\"models\":[", .{util.unixMs(io)}) catch return null;
    for (models, 0..) |model, i| {
        if (i > 0) aw.writer.writeByte(',') catch return null;
        aw.writer.writeAll("{\"name\":") catch return null;
        var name_stringify: std.json.Stringify = .{ .writer = &aw.writer };
        name_stringify.write(model.name) catch return null;
        aw.writer.print(",\"context\":{d},\"supports_reasoning\":{}}}", .{ model.context, model.supports_reasoning }) catch return null;
    }
    aw.writer.writeAll("]}\n") catch return null;
    return aw.writer.buffered();
}

fn writeCache(io: Io, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, models: []const pricing.ModelInfo) void {
    const document = cacheDocument(io, arena, spec, models) orelse return;
    for ([_][]const u8{ dirPath(arena, home, spec), flatPath(arena, home, spec) }) |path| {
        if (path.len == 0) continue;
        credential_store.replaceFile(io, Io.Dir.cwd(), path, document, .default_file) catch continue;
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
/// Swap the provider's slice for the discovered rows — the active list stays
/// 1:1 with the provider's own catalog; baked rows return only when no live
/// or cached snapshot exists (no key, offline first run).
fn activate(arena: Allocator, spec: provider.ProviderSpec, discovered: []const pricing.ModelInfo) bool {
    return pricing.activateProviderModels(arena, spec.id, discovered);
}

fn loadSpec(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, force_refresh: bool) bool {
    if (!dynamic(spec) or key.len == 0) return false;
    const cached = cachedSnapshot(io, arena, home, spec);
    if (!force_refresh) if (cached) |snapshot| {
        const age = util.unixMs(io) - snapshot.fetched_at_ms;
        if (age >= 0 and age <= cache_ttl_ms and activate(arena, spec, snapshot.models)) return true;
    };
    if (fetch(io, gpa, arena, spec, key)) |snapshot| {
        if (activate(arena, spec, snapshot.models)) {
            if (home.len != 0 or isAdditional(spec)) writeCache(io, arena, home, spec, snapshot.models);
            return true;
        }
    }
    if (cached) |snapshot| return activate(arena, spec, snapshot.models);
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
        if (!dynamic(spec) or !catalog_selection.startupMayUse(keys, spec.id, model_flag, saved)) continue;
        ensureAt(io, gpa, arena, home, index, keys.get(spec.id) orelse "");
    }
    if (provider.additional_router) |spec|
        if (catalog_selection.startupMayUse(keys, spec.id, model_flag, saved))
            ensureAdditional(io, gpa, arena, home, keys);
}

pub fn ensureForQuery(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, query: []const u8) void {
    for (provider.provider_specs, 0..) |spec, index| {
        if (!dynamic(spec) or !catalog_selection.queryMayUse(spec.id, query)) continue;
        ensureAt(io, gpa, arena, home, index, keys.get(spec.id) orelse "");
    }
    if (provider.additional_router) |spec|
        if (catalog_selection.queryMayUse(spec.id, query))
            ensureAdditional(io, gpa, arena, home, keys);
}

pub fn loadAll(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, force_refresh: bool) void {
    for (provider.provider_specs, 0..) |spec, index| {
        if (!dynamic(spec)) continue;
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
        if (!dynamic(spec)) continue;
        const snapshot = cachedSnapshot(io, arena, home, spec) orelse continue;
        _ = activate(arena, spec, snapshot.models);
    }
    if (provider.additional_router) |spec| {
        const snapshot = cachedSnapshot(io, arena, home, spec) orelse return;
        _ = activate(arena, spec, snapshot.models);
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

test "cache document serializes every model name as valid JSON" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const spec = provider.specFor("codegraff") orelse return error.TestUnexpectedResult;
    const models = [_]pricing.ModelInfo{
        .{ .provider = spec.id, .name = "first", .context = 128_000 },
        .{ .provider = spec.id, .name = "quote\"model", .context = 256_000, .supports_reasoning = true },
    };
    const document = cacheDocument(std.testing.io, arena, spec, &models) orelse
        return error.TestUnexpectedResult;
    const value = try std.json.parseFromSliceLeaky(Value, arena, document, .{});
    const cached_models = value.object.get("models") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), cached_models.array.items.len);
    const second = cached_models.array.items[1].object;
    try std.testing.expectEqualStrings("quote\"model", second.get("name").?.string);
    try std.testing.expect(second.get("supports_reasoning").?.bool);
}

test "Anthropic catalog is live and authenticates like Messages" {
    const spec = provider.specFor("anthropic") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(provider.ProviderSpec.CatalogKind.anthropic, spec.catalog);
    try std.testing.expect(dynamic(spec));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/models?limit=1000", modelsUrl(spec));
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [3]std.http.Header = undefined;
    const headers = catalogHeaders(state.allocator(), spec, "sk-test", &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("x-api-key", headers[1].name);
    try std.testing.expectEqualStrings("sk-test", headers[1].value);
    try std.testing.expectEqualStrings("anthropic-version", headers[2].name);
    // Bearer routers are unchanged by the x-api-key branch.
    const router = provider.specFor("codegraff") orelse return error.TestUnexpectedResult;
    const bearer = catalogHeaders(state.allocator(), router, "key", &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), bearer.len);
    try std.testing.expectEqualStrings("Authorization", bearer[1].name);
}

test "Anthropic /v1/models rows inherit baked context windows" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    // A row declaring max_input_tokens uses it as the window — and never its
    // sibling max_tokens, which is the OUTPUT cap (128k on Opus 5). A row
    // without limits takes its alias family's baked window; an unknown family
    // falls back to the conservative default.
    const snapshot = parseModels(state.allocator(), "anthropic",
        \\{"data":[
        \\ {"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5",
        \\  "max_input_tokens":1000000,"max_tokens":128000},
        \\ {"type":"model","id":"claude-opus-4-8-20260115","display_name":"Claude Opus 4.8"},
        \\ {"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"},
        \\ {"type":"model","id":"claude-nova-9","display_name":"Claude Nova 9"}
        \\],"has_more":false}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), snapshot.models.len);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[1].context);
    try std.testing.expectEqual(@as(u64, 200_000), snapshot.models[2].context);
    try std.testing.expectEqual(pricing.default_context, snapshot.models[3].context);
}

test "Anthropic discovery keeps the active slice 1:1 with the live list" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const spec = provider.specFor("anthropic") orelse return error.TestUnexpectedResult;
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "anthropic", .name = "claude-opus-5", .context = 1_000_000 },
        .{ .provider = "anthropic", .name = "claude-opus-4-8", .context = 1_000_000 },
    };
    try std.testing.expect(activate(state.allocator(), spec, &discovered));
    // Exactly the live rows — a baked row the API no longer lists is gone,
    // so the picker shows the official catalog and nothing else.
    var count: usize = 0;
    for (pricing.models()) |m| {
        if (std.mem.eql(u8, m.provider, "anthropic")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(pricing.providerModelInTable("anthropic", "claude-opus-5"));
    try std.testing.expect(!pricing.providerModelInTable("anthropic", "claude-sonnet-4-5"));
    try std.testing.expectEqual(@as(u64, 1_000_000), pricing.contextFor("anthropic", "claude-opus-5"));
    // Other providers' slices are untouched.
    try std.testing.expect(pricing.providerModelInTable("codegraff", "claude-opus-4.8"));
}

test "Models-API cursor pagination is followed 1:1 with the docs" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    // parseModels surfaces the after_id/has_more/last_id scheme (the Models
    // API does NOT use page/next_page — see "API overview → Pagination").
    const page = parseModels(arena, "anthropic",
        \\{"data":[{"type":"model","id":"claude-opus-5","max_input_tokens":1000000,"max_tokens":128000}],
        \\ "has_more":true,"first_id":"claude-opus-5","last_id":"claude-opus-5"}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualStrings("claude-opus-5", page.last_id orelse return error.TestUnexpectedResult);
    // A final page reports has_more:false; the cache shape carries neither.
    const last = parseModels(arena, "anthropic",
        \\{"data":[{"id":"claude-haiku-4-5"}],"has_more":false,"last_id":"claude-haiku-4-5"}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!last.has_more);
    const cache = parseModels(arena, "anthropic",
        \\{"fetched_at_ms":1,"models":[{"name":"claude-opus-5","context":1000000}]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!cache.has_more);
    try std.testing.expect(cache.last_id == null);
    // after_id joins the base URL's existing query string.
    try std.testing.expectEqualStrings(
        "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5",
        pageUrl(arena, "https://api.anthropic.com/v1/models?limit=1000", "claude-opus-5") orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/models?after_id=m1",
        pageUrl(arena, "https://example.com/models", "m1") orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings("base", pageUrl(arena, "base", null) orelse return error.TestUnexpectedResult);
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
