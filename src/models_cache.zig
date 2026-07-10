//! `graff models` — the model-catalog CLI and the models.dev refresh cache.
//!
//! Non-Codex routing starts from pricing.model_table. Codex model names and
//! windows are account-scoped and discovered from the same authenticated
//! `/models?client_version=…` endpoint and 5-minute cache design as openai/codex;
//! the baked Codex rows are only an offline fallback. Separately, models.dev
//! keeps context/price METADATA fresh for the non-Codex catalog:
//!
//!   * `graff models`          — print the effective catalog (baked + overlay)
//!   * `graff models refresh`  — force the Codex account catalog refresh, then
//!                               refresh known window/price rows from models.dev
//!
//! At startup resolveKeys() first calls loadCodexCatalog(), then loadOverlay().
//! Codex discovery swaps only the Codex rows in pricing.active_model_table.
//! loadOverlay() reads the small models.dev cache
//! (NOT the 3 MB models.dev doc — startup stays instant) into two runtime
//! overlays in pricing.zig that priceFor()/contextFor() consult before the
//! baked table. No cache / offline / fresh install → the baked table is the
//! sole source, so nothing here can break a run. The models.dev overlay only
//! refreshes numbers for names the active table already routes.
//!
//! Cache path: ~/.codegraff/models.json, falling back to the flat dotfile
//! ~/.codegraff-models.json when that directory doesn't exist (zig 0.16's
//! Io.Dir has no mkdir, and the flat form matches ~/.simple-harness-*.json).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const pricing = @import("pricing.zig");
const util = @import("util.zig");
const strFieldObj = util.strFieldObj;

const models_dev_url = "https://models.dev/api.json";
const codex_models_url = "https://chatgpt.com/backend-api/codex/models";
const codex_cache_ttl_ms: i64 = 5 * 60 * 1000;
pub var codex_catalog_source: []const u8 = "baked offline fallback";

/// models.dev provider ids to trust FIRST when a model id appears under
/// several providers — a vendor's own listing beats a reseller's markup
/// (models.dev keys resellers like requesty/openrouter/vercel alongside the
/// canonical labs). Names not found here fall back to an any-provider scan.
const canonical_providers = [_][]const u8{
    "openai",    "anthropic", "deepseek", "xai",     "zai",
    "z-ai",      "zhipuai",   "google",   "minimax", "moonshotai",
    "moonshot",  "mistral",   "meta",     "xiaomi",  "fireworks-ai",
    "fireworks", "alibaba",
};

/// One refreshed metadata row — the subset of a models.dev model we cache.
const Meta = struct { name: []const u8, context: u64, in: f64, out: f64, cache: f64 };

/// Read a JSON number field as f64 (models.dev costs are floats, windows ints).
fn numField(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Non-negative integer field as u64 (0 when absent / negative / wrong type).
fn u64Field(obj: std.json.ObjectMap, name: []const u8) u64 {
    const v = obj.get(name) orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn dirPath(arena: Allocator, home: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/.codegraff/models.json", .{home}) catch "";
}
fn flatPath(arena: Allocator, home: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/.codegraff-models.json", .{home}) catch "";
}

fn codexDirPath(arena: Allocator, home: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/.codegraff/codex-models.json", .{home}) catch "";
}
fn codexFlatPath(arena: Allocator, home: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/.codegraff-codex-models.json", .{home}) catch "";
}
fn nativeCodexPath(arena: Allocator, codex_home: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/models_cache.json", .{codex_home}) catch "";
}

const CodexSnapshot = struct {
    models: []const pricing.ModelInfo,
    client_version: []const u8 = "",
    fetched_at_ms: i64 = 0,
};

fn validModelSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 256) return false;
    for (slug) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    return true;
}

/// Accepts both Codex's native cache/remote shape (`slug`, `context_window`)
/// and graff's compact cache shape (`name`, `context`). Hidden models stay out
/// of user-facing routing and pickers, matching Codex's ModelPreset behavior.
fn parseCodexSnapshot(arena: Allocator, data: []const u8) ?CodexSnapshot {
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const arr = v.object.get("models") orelse return null;
    if (arr != .array) return null;
    var rows: std.ArrayList(pricing.ModelInfo) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        if (strFieldObj(item.object, "visibility")) |visibility|
            if (!std.mem.eql(u8, visibility, "list")) continue;
        const slug = strFieldObj(item.object, "name") orelse strFieldObj(item.object, "slug") orelse continue;
        if (!validModelSlug(slug)) continue;
        var duplicate = false;
        for (rows.items) |row| if (std.mem.eql(u8, row.name, slug)) {
            duplicate = true;
        };
        if (duplicate) continue;
        var context = u64Field(item.object, "context");
        if (context == 0) context = u64Field(item.object, "context_window");
        if (context == 0) context = pricing.codex_context_window;
        rows.append(arena, .{
            .provider = "codex",
            .name = arena.dupe(u8, slug) catch continue,
            .context = context,
        }) catch continue;
    }
    const models = rows.toOwnedSlice(arena) catch return null;
    if (models.len == 0) return null;
    return .{
        .models = models,
        .client_version = strFieldObj(v.object, "client_version") orelse "",
        .fetched_at_ms = util.intFieldObj(v.object, "fetched_at_ms", 0),
    };
}

fn readSmall(io: Io, arena: Allocator, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch null;
}

fn installedCodexVersion(io: Io, arena: Allocator) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "codex", "--version" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer _ = child.wait(io) catch {};
    const f = child.stdout orelse return null;
    var rbuf: [1024]u8 = undefined;
    var fr = f.readerStreaming(io, &rbuf);
    const output = fr.interface.allocRemaining(arena, .limited(8 * 1024)) catch return null;
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    const at = std.mem.lastIndexOfAny(u8, trimmed, " \t") orelse return null;
    const version = std.mem.trim(u8, trimmed[at + 1 ..], " \t");
    if (version.len == 0 or !std.ascii.isDigit(version[0]) or std.mem.indexOfScalar(u8, version, '.') == null) return null;
    return version;
}

fn fetchCodexSnapshot(io: Io, gpa: Allocator, arena: Allocator, token: []const u8, account: []const u8, version: []const u8) ?CodexSnapshot {
    if (token.len == 0 or account.len == 0 or version.len == 0) return null;
    const url = std.fmt.allocPrint(arena, "{s}?client_version={s}", .{ codex_models_url, version }) catch return null;
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return null;
    const user_agent = std.fmt.allocPrint(arena, "codex_cli_rs/{s} (graff)", .{version}) catch return null;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = bearer },
        .{ .name = "chatgpt-account-id", .value = account },
        .{ .name = "originator", .value = "codex_cli_rs" },
        .{ .name = "User-Agent", .value = user_agent },
    };
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &headers,
    }) catch return null;
    if (@intFromEnum(res.status) != 200) return null;
    return parseCodexSnapshot(arena, aw.writer.buffered());
}

fn writeCodexCache(io: Io, arena: Allocator, home: []const u8, version: []const u8, models: []const pricing.ModelInfo) void {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("{\"source\":\"chatgpt.com/backend-api/codex/models\",\"fetched_at_ms\":") catch return;
    aw.writer.print("{d},\"client_version\":", .{util.unixMs(io)}) catch return;
    var version_stringify: std.json.Stringify = .{ .writer = &aw.writer };
    version_stringify.write(version) catch return;
    aw.writer.writeAll(",\"models\":[") catch return;
    for (models, 0..) |model, i| {
        if (i > 0) aw.writer.writeByte(',') catch return;
        aw.writer.writeAll("{\"name\":") catch return;
        var name_stringify: std.json.Stringify = .{ .writer = &aw.writer };
        name_stringify.write(model.name) catch return;
        aw.writer.print(",\"context\":{d}}}", .{model.context}) catch return;
    }
    aw.writer.writeAll("]}\n") catch return;
    for ([_][]const u8{ codexDirPath(arena, home), codexFlatPath(arena, home) }) |path| {
        if (path.len == 0) continue;
        const f = Io.Dir.cwd().createFile(io, path, .{}) catch continue;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(aw.writer.buffered()) catch continue;
        fw.interface.flush() catch continue;
        return;
    }
}

/// Activate an account-scoped Codex catalog. Match openai/codex's policy:
/// a client-version-keyed cache is fresh for five minutes, then remote refresh;
/// remote failure falls back to stale graff cache, native Codex cache, and
/// finally pricing.zig's minimal baked rows. Tokens are never persisted.
pub fn loadCodexCatalog(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, codex_home: []const u8, token: []const u8, account: []const u8, force_refresh: bool) void {
    const native_data = readSmall(io, arena, nativeCodexPath(arena, codex_home));
    const native = if (native_data) |data| parseCodexSnapshot(arena, data) else null;
    const version = installedCodexVersion(io, arena) orelse if (native) |snapshot| snapshot.client_version else "";
    const cached_data = readSmall(io, arena, codexDirPath(arena, home)) orelse readSmall(io, arena, codexFlatPath(arena, home));
    const cached = if (cached_data) |data| parseCodexSnapshot(arena, data) else null;
    const now = util.unixMs(io);
    if (!force_refresh) if (cached) |snapshot| {
        const age = now - snapshot.fetched_at_ms;
        if (std.mem.eql(u8, snapshot.client_version, version) and age >= 0 and age <= codex_cache_ttl_ms) {
            if (pricing.activateCodexModels(arena, snapshot.models)) codex_catalog_source = "dynamic cache";
            return;
        }
    };
    if (fetchCodexSnapshot(io, gpa, arena, token, account, version)) |snapshot| {
        if (pricing.activateCodexModels(arena, snapshot.models)) {
            codex_catalog_source = "live account catalog";
            writeCodexCache(io, arena, home, version, snapshot.models);
            return;
        }
    }
    if (cached) |snapshot| if (pricing.activateCodexModels(arena, snapshot.models)) {
        codex_catalog_source = "stale dynamic cache (offline)";
        return;
    };
    if (native) |snapshot| if (pricing.activateCodexModels(arena, snapshot.models)) {
        codex_catalog_source = "Codex native cache (offline)";
        return;
    };
}

/// GET models.dev/api.json (~3 MB) and parse it into the arena, or null on any
/// failure (offline, non-200, malformed) — the caller falls back to baked data.
fn fetchModelsDev(io: Io, gpa: Allocator, arena: Allocator) ?Value {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const extra = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "graff-models/1.0" }, // models.dev 403s a bare UA
    };
    const res = client.fetch(.{
        .location = .{ .url = models_dev_url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &extra,
    }) catch return null;
    if (@intFromEnum(res.status) != 200) return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    return v;
}

/// Extract window + costs from one models.dev model object.
fn metaOf(m: std.json.ObjectMap, name: []const u8) Meta {
    var context: u64 = 0;
    if (m.get("limit")) |lv| if (lv == .object) {
        context = u64Field(lv.object, "context");
    };
    var in: f64 = 0;
    var out: f64 = 0;
    var cache: f64 = 0;
    if (m.get("cost")) |cv| if (cv == .object) {
        in = numField(cv.object, "input") orelse 0;
        out = numField(cv.object, "output") orelse 0;
        cache = numField(cv.object, "cache_read") orelse 0;
    };
    return .{ .name = name, .context = context, .in = in, .out = out, .cache = cache };
}

/// Find `name` in a provider's models map: exact id key first, then the same
/// normalized-alias rule pricing uses (so "gpt5.6" matches "gpt-5.6").
fn matchInModels(models: std.json.ObjectMap, name: []const u8) ?Meta {
    if (models.get(name)) |mv| if (mv == .object) return metaOf(mv.object, name);
    var it = models.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) continue;
        if (pricing.modelAliasEquals(e.key_ptr.*, name)) return metaOf(e.value_ptr.object, name);
    }
    return null;
}

fn modelsOf(doc: std.json.ObjectMap, provider_id: []const u8) ?std.json.ObjectMap {
    const pv = doc.get(provider_id) orelse return null;
    if (pv != .object) return null;
    const mv = pv.object.get("models") orelse return null;
    if (mv != .object) return null;
    return mv.object;
}

/// Look up a graff model name across the whole models.dev doc, preferring the
/// canonical vendor providers before scanning everything else.
fn findModel(doc: std.json.ObjectMap, name: []const u8) ?Meta {
    for (canonical_providers) |pid| {
        if (modelsOf(doc, pid)) |models| if (matchInModels(models, name)) |m| return m;
    }
    var it = doc.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const models = entry.value_ptr.object.get("models") orelse continue;
        if (models != .object) continue;
        if (matchInModels(models.object, name)) |m| return m;
    }
    return null;
}

/// Serialize the refreshed rows and write them to the cache file, returning the
/// path actually written (dir form first, flat dotfile fallback), or null.
fn writeCache(io: Io, arena: Allocator, home: []const u8, metas: []const Meta) ?[]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("{\"source\":\"models.dev/api.json\",\"models\":[") catch return null;
    for (metas, 0..) |m, i| {
        if (i > 0) aw.writer.writeAll(",") catch return null;
        aw.writer.print("{{\"name\":\"{s}\",\"context\":{d},\"in\":{d},\"out\":{d},\"cache\":{d}}}", .{ m.name, m.context, m.in, m.out, m.cache }) catch return null;
    }
    aw.writer.writeAll("]}\n") catch return null;
    const bytes = aw.writer.buffered();
    for ([_][]const u8{ dirPath(arena, home), flatPath(arena, home) }) |path| {
        if (path.len == 0) continue;
        const f = Io.Dir.cwd().createFile(io, path, .{}) catch continue;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(bytes) catch continue;
        fw.interface.flush() catch continue;
        return path;
    }
    return null;
}

/// Read the cache bytes (dir form first, then flat), or null when neither is
/// present — the overlays stay empty and the baked table is the sole source.
fn readCache(io: Io, arena: Allocator, home: []const u8) ?[]const u8 {
    for ([_][]const u8{ dirPath(arena, home), flatPath(arena, home) }) |path| {
        if (path.len == 0) continue;
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024))) |data| return data else |_| {}
    }
    return null;
}

/// Populate pricing.zig's runtime overlays from the on-disk cache. Called once
/// at startup (resolveKeys) and again right after a refresh. No-op when the
/// cache is absent/unreadable/malformed, so it never blocks or fails a run.
pub fn loadOverlay(io: Io, arena: Allocator, home: []const u8) void {
    const data = readCache(io, arena, home) orelse return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const arr = v.object.get("models") orelse return;
    if (arr != .array) return;
    var prices: std.ArrayList(pricing.ModelPrice) = .empty;
    var ctxs: std.ArrayList(pricing.ModelInfo) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const name = strFieldObj(item.object, "name") orelse continue;
        if (name.len == 0) continue;
        const nm = arena.dupe(u8, name) catch continue;
        const in = numField(item.object, "in") orelse 0;
        const out = numField(item.object, "out") orelse 0;
        const cache = numField(item.object, "cache") orelse 0;
        const context = u64Field(item.object, "context");
        if (in > 0 or out > 0) prices.append(arena, .{ .name = nm, .in = in, .out = out, .cache = cache }) catch {};
        if (context > 0) ctxs.append(arena, .{ .provider = "", .name = nm, .context = context }) catch {};
    }
    if (prices.items.len > 0) pricing.price_overlay = prices.toOwnedSlice(arena) catch pricing.price_overlay;
    if (ctxs.items.len > 0) pricing.context_overlay = ctxs.toOwnedSlice(arena) catch pricing.context_overlay;
}

/// FYI after a refresh: upstream gpt-5+/claude models.dev lists that graff's
/// catalog doesn't yet, so the user can spot a new release at a glance.
fn reportNew(doc: std.json.ObjectMap, out: *Io.Writer) void {
    const checks = [_]struct { pid: []const u8, prefix: []const u8 }{
        .{ .pid = "openai", .prefix = "gpt-5" },
        .{ .pid = "openai", .prefix = "gpt-6" },
        .{ .pid = "anthropic", .prefix = "claude" },
    };
    var shown: usize = 0;
    for (checks) |c| {
        const models = modelsOf(doc, c.pid) orelse continue;
        var it = models.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            if (!std.mem.startsWith(u8, id, c.prefix)) continue;
            if (pricing.modelInTable(id)) continue;
            if (shown == 0) out.writeAll("\nupstream models.dev lists that graff's catalog doesn't yet:\n") catch {};
            if (shown < 12) out.print("  · {s} ({s})\n", .{ id, c.pid }) catch {};
            shown += 1;
        }
    }
    if (shown > 12) out.print("  … and {d} more\n", .{shown - 12}) catch {};
}

/// `graff models refresh`: Codex was force-refreshed by startup.runSubcommand;
/// now pull models.dev, cache window+price for every active model name, apply it
/// live, and report what changed / what's new.
pub fn refresh(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, out: *Io.Writer) !void {
    try out.print("fetching {s} …\n", .{models_dev_url});
    try out.flush();
    const doc = fetchModelsDev(io, gpa, arena) orelse {
        try out.writeAll("✗ could not reach models.dev (offline?) — the baked-in catalog stays in effect\n");
        try out.flush();
        return;
    };
    var metas: std.ArrayList(Meta) = .empty;
    defer metas.deinit(gpa);
    const catalog = pricing.models();
    for (catalog, 0..) |mi, i| {
        var dup = false; // dedupe: the same name can appear under several providers
        for (catalog[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, mi.name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (findModel(doc.object, mi.name)) |meta| metas.append(gpa, meta) catch {};
    }
    const path = writeCache(io, arena, home, metas.items) orelse {
        try out.writeAll("✗ refreshed, but could not write the cache file (check ~ permissions)\n");
        try out.flush();
        return;
    };
    try out.print("✓ refreshed {d} models from models.dev → {s}\n", .{ metas.items.len, path });
    reportNew(doc.object, out);
    loadOverlay(io, arena, home); // apply to this process too
    try out.flush();
}

/// `graff models`: print the effective catalog (baked table + any refresh
/// overlay), grouped by provider, with the live window and per-1M price.
pub fn list(out: *Io.Writer) !void {
    const fresh = pricing.price_overlay.len > 0 or pricing.context_overlay.len > 0;
    const catalog = pricing.models();
    try out.print("model catalog — {d} entries{s}\n", .{ catalog.len, if (fresh) " (refreshed from models.dev)" else "" });
    var last: []const u8 = "";
    for (catalog) |m| {
        if (!std.mem.eql(u8, m.provider, last)) {
            if (std.mem.eql(u8, m.provider, "codex"))
                try out.print("\n{s} ({s}):\n", .{ m.provider, codex_catalog_source })
            else
                try out.print("\n{s}:\n", .{m.provider});
            last = m.provider;
        }
        const ctx = pricing.contextFor(m.provider, m.name);
        if (std.mem.eql(u8, m.provider, "codex")) {
            try out.print("  {s:<34}{d:>10} ctx   (subscription)\n", .{ m.name, ctx });
        } else if (pricing.priceFor(m.name)) |p| {
            try out.print("  {s:<34}{d:>10} ctx   ${d}/{d} per 1M\n", .{ m.name, ctx, p.in, p.out });
        } else {
            try out.print("  {s:<34}{d:>10} ctx   (unpriced)\n", .{ m.name, ctx });
        }
    }
    try out.writeAll("\nrefresh Codex catalog + models.dev metadata:  graff models refresh\n");
    try out.flush();
}

/// `graff models [refresh]` entry point (dispatched from startup.runSubcommand).
pub fn command(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, sub_args: []const []const u8) !void {
    var obuf: [8 * 1024]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    if (sub_args.len > 0 and (std.mem.eql(u8, sub_args[0], "refresh") or
        std.mem.eql(u8, sub_args[0], "--refresh") or std.mem.eql(u8, sub_args[0], "update")))
    {
        try refresh(io, gpa, arena, home, out);
        return;
    }
    loadOverlay(io, arena, home); // reflect a prior refresh in the listing
    try list(out);
}

test "numField reads int and float JSON numbers; u64Field clamps" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, a.allocator(),
        \\{"i": 42, "f": 2.5, "neg": -3, "s": "x"}
    , .{ .allocate = .alloc_always });
    try std.testing.expectEqual(@as(f64, 42), numField(v.object, "i").?);
    try std.testing.expectEqual(@as(f64, 2.5), numField(v.object, "f").?);
    try std.testing.expect(numField(v.object, "s") == null);
    try std.testing.expect(numField(v.object, "missing") == null);
    try std.testing.expectEqual(@as(u64, 42), u64Field(v.object, "i"));
    try std.testing.expectEqual(@as(u64, 0), u64Field(v.object, "neg")); // clamped
    try std.testing.expectEqual(@as(u64, 0), u64Field(v.object, "missing"));
}

test "findModel prefers the canonical vendor over a reseller markup" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    // gpt-5.6 listed under a reseller (higher price) AND canonical openai.
    const v = try std.json.parseFromSliceLeaky(Value, a.allocator(),
        \\{"reseller":{"models":{"gpt-5.6":{"limit":{"context":100},"cost":{"input":99,"output":99,"cache_read":9}}}},
        \\ "openai":{"models":{"gpt-5.6":{"limit":{"context":1050000},"cost":{"input":5,"output":30,"cache_read":0.5}}}}}
    , .{ .allocate = .alloc_always });
    const m = findModel(v.object, "gpt-5.6").?;
    try std.testing.expectEqual(@as(f64, 5), m.in); // openai, not the reseller's 99
    try std.testing.expectEqual(@as(u64, 1_050_000), m.context);
    // Alias match: "gpt5.6" normalizes to "gpt-5.6".
    try std.testing.expect(findModel(v.object, "gpt5.6") != null);
    try std.testing.expect(findModel(v.object, "no-such-model") == null);
}

test "Codex snapshot uses visible remote slugs and their advertised contexts" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const snapshot = parseCodexSnapshot(a.allocator(),
        \\{"client_version":"9.9.9","models":[
        \\ {"slug":"future-sol","visibility":"list","context_window":372000},
        \\ {"slug":"future-hidden","visibility":"hide","context_window":999000},
        \\ {"slug":"future-luna","visibility":"list","context_window":128000},
        \\ {"slug":"future-luna","visibility":"list","context_window":1}]}
    ).?;
    try std.testing.expectEqualStrings("9.9.9", snapshot.client_version);
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqualStrings("future-sol", snapshot.models[0].name);
    try std.testing.expectEqual(@as(u64, 372_000), snapshot.models[0].context);
    try std.testing.expectEqualStrings("future-luna", snapshot.models[1].name);
    try std.testing.expectEqual(@as(u64, 128_000), snapshot.models[1].context);
}
