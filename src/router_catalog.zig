//! Model discovery for Codegraff, Anthropic, xAI, and the optional workspace router.
//!
//! The workspace router is declared by `.graff/.config.router`; its catalog
//! cache stays beside that config. xAI is always-live (never TTL-short-circuits).
//! Startup fans live GETs out concurrently (with Kimi) so REPL boot pays
//! max(latency), not the sum. Catalog failures never prevent startup.
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
const kimi_catalog = @import("kimi_catalog.zig");
const pricing = @import("pricing.zig");
const pricing_db = @import("pricing_db.zig"); // #557: LiteLLM price/context overlay, hydrated on the same beats as these catalogs
const provider = @import("provider.zig");
const serde = @import("serde.zig");
const util = @import("util.zig");

/// Router catalogs change on the order of weeks; favour instant startup.
const cache_ttl_ms: i64 = 6 * 60 * 60 * 1000;
var attempted: [provider.provider_specs.len]bool = @splat(false);
var additional_attempted = false;

/// Providers whose live `/models` list must win over a disk cache every load.
/// xAI ships new Grok ids often enough that a 6h snapshot is actively wrong;
/// always hit api.x.ai and only fall back to cache/baked when offline.
pub fn alwaysLive(spec: provider.ProviderSpec) bool {
    return std.mem.eql(u8, spec.id, "xai");
}

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
/// anthropic-version pair as the Messages endpoint itself. xAI OAuth user
/// tokens also need X-XAI-Token-Auth (same as chat — GrokAuthCredentials).
pub fn catalogHeaders(arena: Allocator, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource, buf: *[4]std.http.Header) ?[]const std.http.Header {
    buf[0] = .{ .name = "Accept", .value = "application/json" };
    if (spec.auth == .x_api_key) {
        buf[1] = .{ .name = "x-api-key", .value = key };
        buf[2] = .{ .name = "anthropic-version", .value = root.anthropic_version };
        return buf[0..3];
    }
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{key}) catch return null;
    buf[1] = .{ .name = "Authorization", .value = bearer };
    if (std.mem.eql(u8, spec.id, "xai") and source == .login) {
        buf[2] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
        return buf[0..3];
    }
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

fn fetchPage(io: Io, gpa: Allocator, arena: Allocator, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource, url: []const u8) ?Snapshot {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var headers_buf: [4]std.http.Header = undefined;
    const headers = catalogHeaders(arena, spec, key, source, &headers_buf) orelse return null;
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
fn fetch(io: Io, gpa: Allocator, arena: Allocator, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource) ?Snapshot {
    const base = modelsUrl(spec);
    if (base.len == 0) return null;
    var rows: std.ArrayList(pricing.ModelInfo) = .empty;
    var cursor: ?Cursor = null;
    var pages: usize = 0;
    while (pages < 16) : (pages += 1) {
        const url = pageUrl(arena, base, cursor) orelse break;
        const page = fetchPage(io, gpa, arena, spec, key, source, url) orelse break;
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

fn loadSpec(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource, force_refresh: bool) bool {
    if (!dynamic(spec) or key.len == 0) return false;
    const cached = cachedSnapshot(io, arena, home, spec);
    // alwaysLive providers (xAI) never short-circuit on a fresh disk cache —
    // every load tries the network so new Grok ids appear without waiting for
    // TTL or `graff models refresh`. Cache remains offline fallback only.
    const skip_cache = force_refresh or alwaysLive(spec);
    if (!skip_cache) if (cached) |snapshot| {
        const age = util.unixMs(io) - snapshot.fetched_at_ms;
        if (age >= 0 and age <= cache_ttl_ms and activate(arena, spec, snapshot.models)) return true;
    };
    if (fetch(io, gpa, arena, spec, key, source)) |snapshot| {
        if (activate(arena, spec, snapshot.models)) {
            // Still write for offline/`--schema` fallback, but never treat it as
            // authoritative for alwaysLive providers on the next load.
            if (home.len != 0 or isAdditional(spec)) writeCache(io, arena, home, spec, snapshot.models);
            return true;
        }
    }
    if (cached) |snapshot| return activate(arena, spec, snapshot.models);
    return false;
}

fn ensureAt(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, index: usize) void {
    if (attempted[index]) return;
    const spec = provider.provider_specs[index];
    const key = keys.get(spec.id) orelse return;
    if (key.len == 0) return;
    attempted[index] = true;
    _ = loadSpec(io, gpa, arena, home, spec, key, keys.source(spec.id), false);
}

fn ensureAdditional(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys) void {
    if (additional_attempted) return;
    const spec = provider.additional_router orelse return;
    const key = keys.get(spec.id) orelse return;
    additional_attempted = true;
    _ = loadSpec(io, gpa, arena, home, spec, key, keys.source(spec.id), false);
}

const FetchOutcome = struct {
    spec: provider.ProviderSpec,
    models: []const pricing.ModelInfo = &.{},
    write_cache: bool = false,
    arena_state: ?std.heap.ArenaAllocator = null,
};

fn retainModels(arena: Allocator, rows: []const pricing.ModelInfo) ?[]const pricing.ModelInfo {
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

fn fetchSpecTask(io: Io, gpa: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource) FetchOutcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const a = arena_state.allocator();
    const snapshot = fetch(io, gpa, a, spec, key, source) orelse {
        arena_state.deinit();
        return .{ .spec = spec };
    };
    return .{
        .spec = spec,
        .models = snapshot.models,
        .write_cache = home.len != 0 or isAdditional(spec),
        .arena_state = arena_state,
    };
}

fn spawnFetch(io: Io, gpa: Allocator, home: []const u8, spec: provider.ProviderSpec, key: []const u8, source: provider.Keys.CredentialSource) Io.Future(FetchOutcome) {
    const args = .{ io, gpa, home, spec, key, source };
    return io.concurrent(fetchSpecTask, args) catch io.async(fetchSpecTask, args);
}

fn finishFetch(io: Io, arena: Allocator, home: []const u8, outcome: FetchOutcome) void {
    var task_arena = outcome.arena_state;
    defer if (task_arena) |*ta| ta.deinit();
    if (outcome.models.len > 0) {
        const kept = retainModels(arena, outcome.models) orelse return;
        if (activate(arena, outcome.spec, kept) and outcome.write_cache)
            writeCache(io, arena, home, outcome.spec, kept);
        return;
    }
    if (cachedSnapshot(io, arena, home, outcome.spec)) |snapshot|
        _ = activate(arena, outcome.spec, snapshot.models);
}

fn cacheFresh(io: Io, arena: Allocator, home: []const u8, spec: provider.ProviderSpec) bool {
    if (alwaysLive(spec)) return false;
    const snapshot = cachedSnapshot(io, arena, home, spec) orelse return false;
    const age = util.unixMs(io) - snapshot.fetched_at_ms;
    return age >= 0 and age <= cache_ttl_ms and activate(arena, spec, snapshot.models);
}

const KimiOutcome = struct {
    fetch: kimi_catalog.Fetch = .{},
    arena_state: ?std.heap.ArenaAllocator = null,
};

fn kimiFetchTask(io: Io, gpa: Allocator, home: []const u8, access: []const u8) KimiOutcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    return .{
        .fetch = kimi_catalog.fetch(io, gpa, arena_state.allocator(), home, access),
        .arena_state = arena_state,
    };
}

fn spawnKimi(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, model_flag: ?[]const u8, saved: ?serde.SavedModel) ?Io.Future(KimiOutcome) {
    if (!catalog_selection.startupMayUse(keys, "kimi", model_flag, saved)) return null;
    if (!kimi_catalog.claimAttempt()) return null;
    const access = keys.get("kimi") orelse "";
    if (access.len == 0) {
        kimi_catalog.commit(arena, &.{}, "baked fallback — no Kimi login");
        return null;
    }
    const args = .{ io, gpa, home, access };
    return io.concurrent(kimiFetchTask, args) catch io.async(kimiFetchTask, args);
}

/// Startup catalog load. Fresh disk caches activate inline; every live GET
/// (xAI, stale Anthropic/Codegraff, Kimi, …) runs concurrently so boot pays
/// the slowest host, not the sum. Table mutation stays on this thread.
pub fn ensureForStartup(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, model_flag: ?[]const u8, saved: ?serde.SavedModel) void {
    var kimi_task = spawnKimi(io, gpa, arena, home, keys, model_flag, saved);
    defer if (kimi_task) |*fut| {
        var outcome = fut.await(io);
        defer if (outcome.arena_state) |*ta| ta.deinit();
        kimi_catalog.commit(arena, outcome.fetch.rows, outcome.fetch.source);
    };

    var futures: [provider.provider_specs.len + 1]?Io.Future(FetchOutcome) = @splat(null);
    for (provider.provider_specs, 0..) |spec, index| {
        if (!dynamic(spec) or !catalog_selection.startupMayUse(keys, spec.id, model_flag, saved)) continue;
        if (attempted[index]) continue;
        const key = keys.get(spec.id) orelse continue;
        if (key.len == 0) continue;
        attempted[index] = true;
        if (cacheFresh(io, arena, home, spec)) continue;
        futures[index] = spawnFetch(io, gpa, home, spec, key, keys.source(spec.id));
    }
    if (provider.additional_router) |spec| {
        if (catalog_selection.startupMayUse(keys, spec.id, model_flag, saved) and !additional_attempted) {
            if (keys.get(spec.id)) |key| if (key.len != 0) {
                additional_attempted = true;
                if (!cacheFresh(io, arena, home, spec))
                    futures[provider.provider_specs.len] = spawnFetch(io, gpa, home, spec, key, keys.source(spec.id));
            };
        }
    }
    for (&futures) |*maybe| {
        const outcome = if (maybe.*) |*fut| fut.await(io) else continue;
        finishFetch(io, arena, home, outcome);
    }
}

/// An explicit /models listing is the freshness moment: hit every keyed
/// dynamic provider live, concurrently (startup's own fan-out), bypassing
/// BOTH the once-per-process attempt latch and the 6h TTL — the pair that
/// made /models show a boot-time snapshot until restart. The disk cache
/// remains the offline fallback, and each live list is re-cached for the
/// next boot. Returns how many providers were pinged.
pub fn refreshForListing(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys) usize {
    pricing_db.ensure(io, gpa, arena, home, true); // the same freshness moment covers the price sheet, network and all
    var futures: [provider.provider_specs.len + 1]?Io.Future(FetchOutcome) = @splat(null);
    var pinged: usize = 0;
    for (provider.provider_specs, 0..) |spec, index| {
        if (!dynamic(spec)) continue;
        const key = keys.get(spec.id) orelse continue;
        if (key.len == 0) continue;
        attempted[index] = true;
        futures[index] = spawnFetch(io, gpa, home, spec, key, keys.source(spec.id));
        pinged += 1;
    }
    if (provider.additional_router) |spec| {
        if (keys.get(spec.id)) |key| if (key.len != 0) {
            additional_attempted = true;
            futures[provider.provider_specs.len] = spawnFetch(io, gpa, home, spec, key, keys.source(spec.id));
            pinged += 1;
        };
    }
    for (&futures) |*maybe| {
        const outcome = if (maybe.*) |*fut| fut.await(io) else continue;
        finishFetch(io, arena, home, outcome);
    }
    return pinged;
}

pub fn ensureForQuery(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, query: []const u8) void {
    // Cache/override only: this runs at boot too, and no model surface is worth
    // a 2 MB GET on the hot path. refreshForListing is the online arm.
    pricing_db.ensure(io, gpa, arena, home, false);
    for (provider.provider_specs, 0..) |spec, index| {
        if (!dynamic(spec) or !catalog_selection.queryMayUse(spec.id, query)) continue;
        ensureAt(io, gpa, arena, home, keys, index);
    }
    if (provider.additional_router) |spec|
        if (catalog_selection.queryMayUse(spec.id, query))
            ensureAdditional(io, gpa, arena, home, keys);
}

pub fn loadAll(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: provider.Keys, force_refresh: bool) void {
    for (provider.provider_specs, 0..) |spec, index| {
        if (!dynamic(spec)) continue;
        attempted[index] = true;
        _ = loadSpec(io, gpa, arena, home, spec, keys.get(spec.id) orelse "", keys.source(spec.id), force_refresh);
    }
    if (provider.additional_router) |spec| {
        additional_attempted = true;
        _ = loadSpec(io, gpa, arena, home, spec, keys.get(spec.id) orelse "", keys.source(spec.id), force_refresh);
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
