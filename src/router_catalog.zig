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

pub const Snapshot = struct {
    models: []const pricing.ModelInfo,
    fetched_at_ms: i64 = 0,
    // Models-API cursor pagination (after_id/has_more/last_id). Absent on
    // OpenAI-shaped routers and on this module's cache shape → one page.
    has_more: bool = false,
    last_id: ?[]const u8 = null,
    // Fireworks' AIP-style pagination (nextPageToken/pageToken) — a different
    // cursor spelled differently, so it gets its own slot rather than
    // masquerading as an after_id.
    page_token: ?[]const u8 = null,
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
        // Fireworks declares the window in camelCase (AIP gateway shape).
        if (context == 0) context = positiveInt(item.object, "contextLength");
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
    const page_token = util.strFieldObj(value.object, "nextPageToken");
    return .{
        .models = owned,
        .fetched_at_ms = switch (value.object.get("fetched_at_ms") orelse Value{ .null = {} }) {
            .integer => |i| i,
            else => 0,
        },
        .has_more = (has_more == .bool and has_more.bool) or (page_token != null and page_token.?.len > 0),
        .last_id = util.strFieldObj(value.object, "last_id"),
        .page_token = page_token,
    };
}

/// Catalog GET auth mirrors the provider's chat auth: OpenAI-style routers
/// take a bearer token; Anthropic's /v1/models wants the same x-api-key +
/// anthropic-version pair as the Messages endpoint itself.
pub fn catalogHeaders(arena: Allocator, spec: provider.ProviderSpec, key: []const u8, buf: *[3]std.http.Header) ?[]const std.http.Header {
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

/// The two cursor spellings the catalog walk speaks: Anthropic's Models API
/// pages with `after_id`, Fireworks' AIP gateway with `pageToken`.
pub const Cursor = union(enum) { after_id: []const u8, page_token: []const u8 };

/// Next page of a catalog walk: the cursor rides alongside the base URL's own
/// query (limit=1000, or filter/pageSize for the AIP gateway).
pub fn pageUrl(arena: Allocator, base: []const u8, cursor: ?Cursor) ?[]const u8 {
    const c = cursor orelse return base;
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '?') != null) '&' else '?';
    return switch (c) {
        .after_id => |id| std.fmt.allocPrint(arena, "{s}{c}after_id={s}", .{ base, sep, id }) catch null,
        .page_token => |tok| std.fmt.allocPrint(arena, "{s}{c}pageToken={s}", .{ base, sep, tok }) catch null,
    };
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
    var cursor: ?Cursor = null;
    var pages: usize = 0;
    while (pages < 16) : (pages += 1) {
        const url = pageUrl(arena, base, cursor) orelse break;
        const page = fetchPage(io, gpa, arena, spec, key, url) orelse break;
        for (page.models) |m| {
            if (containsName(rows.items, m.name)) continue;
            rows.append(arena, m) catch return null;
        }
        if (!page.has_more) break;
        cursor = if (page.page_token != null and page.page_token.?.len > 0)
            .{ .page_token = page.page_token.? }
        else
            .{ .after_id = page.last_id orelse break };
    }
    if (rows.items.len == 0) return null;
    return .{ .models = rows.toOwnedSlice(arena) catch return null };
}

pub fn cacheDocument(io: Io, arena: Allocator, spec: provider.ProviderSpec, models: []const pricing.ModelInfo) ?[]const u8 {
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
pub fn activate(arena: Allocator, spec: provider.ProviderSpec, discovered: []const pricing.ModelInfo) bool {
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

test {
    _ = @import("router_catalog_tests.zig");
}
