//! `graff models` — the model-catalog CLI and the models.dev refresh cache.
//!
//! graff's catalog (pricing.model_table / price_table) is a hand-maintained
//! snapshot: instant to read, works offline, and the source of truth for
//! ROUTING (which provider serves a name). But snapshots drift as OpenAI/etc.
//! ship models. This module keeps the METADATA (context window + per-token
//! price) fresh without a rebuild and without slowing startup:
//!
//!   * `graff models`          — print the effective catalog (baked + overlay)
//!   * `graff models refresh`  — GET https://models.dev/api.json, extract the
//!                               window/price for every model graff already
//!                               knows by name, and cache it to disk
//!
//! At startup resolveKeys() calls loadOverlay(), which reads that small cache
//! (NOT the 3 MB models.dev doc — startup stays instant) into two runtime
//! overlays in pricing.zig that priceFor()/contextFor() consult before the
//! baked table. No cache / offline / fresh install → the baked table is the
//! sole source, so nothing here can break a run. Routing is untouched: the
//! overlay only refreshes numbers for names the baked table already routes.
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

/// models.dev provider ids to trust FIRST when a model id appears under
/// several providers — a vendor's own listing beats a reseller's markup
/// (models.dev keys resellers like requesty/openrouter/vercel alongside the
/// canonical labs). Names not found here fall back to an any-provider scan.
const canonical_providers = [_][]const u8{
    "openai",       "anthropic", "deepseek", "xai",   "zai",
    "z-ai",         "zhipuai",   "google",   "minimax", "moonshotai",
    "moonshot",     "mistral",   "meta",     "xiaomi", "fireworks-ai",
    "fireworks",    "alibaba",
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

/// `graff models refresh`: pull models.dev, cache window+price for every model
/// graff knows by name, apply it live, and report what changed / what's new.
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
    for (pricing.model_table, 0..) |mi, i| {
        var dup = false; // dedupe: the same name can appear under several providers
        for (pricing.model_table[0..i]) |prev| {
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
    try out.print("model catalog — {d} entries{s}\n", .{ pricing.model_table.len, if (fresh) " (refreshed from models.dev)" else "" });
    var last: []const u8 = "";
    for (pricing.model_table) |m| {
        if (!std.mem.eql(u8, m.provider, last)) {
            try out.print("\n{s}:\n", .{m.provider});
            last = m.provider;
        }
        const ctx = pricing.contextFor(m.provider, m.name);
        if (pricing.priceFor(m.name)) |p| {
            try out.print("  {s:<34}{d:>10} ctx   ${d}/{d} per 1M\n", .{ m.name, ctx, p.in, p.out });
        } else {
            try out.print("  {s:<34}{d:>10} ctx   (unpriced)\n", .{ m.name, ctx });
        }
    }
    try out.writeAll("\nrefresh window/price from models.dev:  graff models refresh\n");
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
