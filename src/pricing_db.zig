//! #557 — hydrate graff's price/context overlay from the community LiteLLM
//! price database (`model_prices_and_context_window.json`).
//!
//! Layering, outermost first. Every layer is best-effort; a missing or broken
//! one simply falls through to the next, so the baked table in pricing.zig is
//! always a working floor:
//!
//!   1. `graff models refresh` (models.dev) — models_cache.loadOverlay installs
//!      its rows FIRST, and priceFor/contextFor return the first match, so an
//!      explicit refresh keeps winning over this automatic layer.
//!   2. this database — appended AFTER those rows, covering every catalog model
//!      models.dev did not.
//!   3. pricing.price_table / pricing.model_table — the baked offline fallback.
//!
//! Inside one model the layering is per FIELD: a value the database omits keeps
//! whatever answered before (`pricing.priceFor`), never 0. Dropping a rate to
//! zero would silently make cached input free, and dropping grok-4.6's ≥200k
//! band would under-bill every long request — a stale number beats a wrong one.
//!
//! Cached tokens: `CostTally` counts cache READS only, so only
//! `cache_read_input_token_cost` is plumbed. Anthropic's cache-WRITE premium
//! (`cache_creation_input_token_cost`) is deliberately ignored: there is no
//! cache-write counter to bill it against, and folding it into the read rate
//! would over-bill every provider that has no write premium at all.
//!
//! Context: `max_input_tokens` ONLY. LiteLLM's `max_tokens` mirrors
//! `max_output_tokens` for chat rows (2402 of 3040 rows at time of writing), so
//! using it as a fallback would report a 64k window for a 200k model and fire
//! auto-compaction against a phantom wall.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const pricing = @import("pricing.zig");
const util = @import("util.zig");
const credential_store = @import("credential_store.zig");

pub const db_url = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

/// A price sheet a day old is fine; the upstream file moves on release cadence.
pub const ttl_ms: i64 = 24 * 60 * 60 * 1000;
/// Upstream is ~1.8 MB. Anything past this is not the price database.
pub const max_bytes: usize = 8 * 1024 * 1024;

/// `GRAFF_PRICES_PATH` — pinned at startup, since the modules that trigger
/// hydration sit several calls below the one that holds the environment.
pub var path_override: []const u8 = "";

/// One dim line for the `/models` footer; empty until something hydrates.
pub var source: []const u8 = "";

var cache_loaded = false;
var live_loaded = false;
var layered = false;
var base_prices: []const pricing.ModelPrice = &.{};
var base_contexts: []const pricing.ModelInfo = &.{};

pub fn initOverride(path: ?[]const u8) void {
    const p = path orelse return;
    if (p.len != 0) path_override = p;
}

/// Forget the per-process latch and the captured overlay base. Tests use it;
/// so would a future in-session "re-read my price sheet" surface.
pub fn invalidate() void {
    cache_loaded = false;
    live_loaded = false;
    layered = false;
    base_prices = &.{};
    base_contexts = &.{};
    source = "";
}

// ── the upstream row ────────────────────────────────────────────────────────

/// Sentinel for "the database did not say", kept distinct from a real 0 so a
/// genuinely free model is not confused with a missing field.
const absent: f64 = -1;

/// The seven numbers we read out of one upstream model object. Costs are USD
/// per TOKEN here (upstream units); conversion to graff's per-1M happens in
/// `priceOf`, once, so the on-disk cache stays comparable with upstream.
const Fields = struct {
    in: f64 = absent,
    out: f64 = absent,
    cache: f64 = absent,
    high_in: f64 = absent,
    high_out: f64 = absent,
    high_cache: f64 = absent,
    context: f64 = absent,

    fn slot(self: *Fields, key: []const u8) ?*f64 {
        const eq = std.mem.eql;
        if (eq(u8, key, "input_cost_per_token")) return &self.in;
        if (eq(u8, key, "output_cost_per_token")) return &self.out;
        if (eq(u8, key, "cache_read_input_token_cost")) return &self.cache;
        if (eq(u8, key, "input_cost_per_token_above_200k_tokens")) return &self.high_in;
        if (eq(u8, key, "output_cost_per_token_above_200k_tokens")) return &self.high_out;
        if (eq(u8, key, "cache_read_input_token_cost_above_200k_tokens")) return &self.high_cache;
        if (eq(u8, key, "max_input_tokens")) return &self.context;
        return null;
    }

    fn usable(self: Fields) bool {
        return self.in >= 0 or self.out >= 0 or self.context > 0;
    }
};

pub const Row = struct { name: []const u8, fields: Fields };

/// Upstream publishes a `sample_spec` row whose values are prose ("max input
/// tokens, if the provider specifies it"). Reading numbers only — and requiring
/// at least one — drops it without a name-based special case.
fn readFields(scanner: *std.json.Scanner, sa: Allocator) !Fields {
    if (try scanner.next() != .object_begin) return error.NotAnObject;
    var f: Fields = .{};
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .object_end => {
                _ = try scanner.next();
                return f;
            },
            .string => {},
            else => return error.NotAnObject,
        }
        const key = switch (try scanner.nextAlloc(sa, .alloc_if_needed)) {
            .string, .allocated_string => |s| s,
            else => return error.NotAnObject,
        };
        const slot = f.slot(key) orelse {
            try scanner.skipValue();
            continue;
        };
        if (try scanner.peekNextTokenType() != .number) {
            try scanner.skipValue();
            continue;
        }
        const text = switch (try scanner.nextAlloc(sa, .alloc_if_needed)) {
            .number, .allocated_number => |s| s,
            else => continue,
        };
        const value = std.fmt.parseFloat(f64, text) catch continue;
        // `absent` is -1, and a cost cannot be negative or infinite: anything
        // else would read back as "the database did not say" or bill nonsense.
        if (std.math.isFinite(value) and value >= 0) slot.* = value;
    }
}

// ── matching upstream keys to graff's catalog ───────────────────────────────

/// LiteLLM keys are `[<billing vendor>/]<model id>`, and the LEADING segment is
/// who bills you: `openrouter/anthropic/claude-sonnet-4.6` is OpenRouter's
/// markup of an Anthropic model, not Anthropic's own row. These are the vendors
/// graff itself routes to, in LiteLLM's spellings — same intent as
/// models_cache's `canonical_providers`, read off the key so a row never has to
/// be parsed before it can be ranked.
const canonical_vendors = [_][]const u8{
    "openai",    "anthropic",    "deepseek",     "xai",      "zai",
    "z-ai",      "zhipuai",      "minimax",      "moonshot", "moonshotai",
    "mistral",   "xiaomi",       "groq",         "google",   "gemini",
    "fireworks", "fireworks_ai", "fireworks-ai",
};

/// A reseller quotes the same weights at its own margin. Trusting it for a
/// CONTEXT window is safe — the window is a property of the model. Trusting it
/// for a PRICE is not: it would replace graff's hand-pinned direct-seat rate
/// with a middleman's markup (upstream today has only `openrouter/xiaomi/
/// mimo-v2.5-pro`, at 2.3x Xiaomi's own price). Below this rank a row
/// contributes its window and nothing else.
const trusted_price_rank: u8 = 2;

/// A graff catalog name plus its alias-normalized form, computed once instead
/// of once per (key, name) pair — upstream ships ~3000 keys against ~65 names.
const Target = struct { name: []const u8, norm: []const u8 };

const KeyForm = struct {
    raw: []const u8,
    norm: []const u8,
    tail_norm: []const u8,
    namespaced: bool,
    canonical: bool,
};

fn keyForm(key: []const u8, norm_buf: *[128]u8, tail_buf: *[128]u8) KeyForm {
    const first = std.mem.indexOfScalar(u8, key, '/') orelse return .{
        .raw = key,
        .norm = pricing.normalizeModelAlias(norm_buf, key),
        .tail_norm = "",
        .namespaced = false,
        .canonical = false,
    };
    var canonical = false;
    for (canonical_vendors) |v| if (std.ascii.eqlIgnoreCase(v, key[0..first])) {
        canonical = true;
    };
    const last = std.mem.lastIndexOfScalar(u8, key, '/').?;
    return .{
        .raw = key,
        .norm = pricing.normalizeModelAlias(norm_buf, key),
        .tail_norm = pricing.normalizeModelAlias(tail_buf, key[last + 1 ..]),
        .namespaced = true,
        .canonical = canonical,
    };
}

/// How well an upstream key names a graff model; higher wins, 0 is no match.
/// A bare key is the vendor's own row and outranks every namespaced spelling of
/// the same id, which is what keeps `xai/grok-4.3` ahead of `azure_ai/grok-4.3`
/// and `zai/glm-5` ahead of `baseten/zai-org/GLM-5`.
fn rankFor(k: KeyForm, name: []const u8, name_norm: []const u8) u8 {
    if (std.mem.eql(u8, k.raw, name)) return 6;
    if (!k.namespaced) return if (std.mem.eql(u8, k.norm, name_norm)) 4 else 0;
    if (std.mem.eql(u8, k.norm, name_norm)) return if (k.canonical) 3 else 1;
    if (k.tail_norm.len != 0 and std.mem.eql(u8, k.tail_norm, name_norm)) return if (k.canonical) 2 else 1;
    return 0;
}

const Hit = struct { index: usize, rank: u8 };

fn bestMatch(k: KeyForm, targets: []const Target, ranks: []const u8) ?Hit {
    var best: ?Hit = null;
    for (targets, 0..) |t, i| {
        const rank = rankFor(k, t.name, t.norm);
        if (rank == 0 or rank <= ranks[i]) continue;
        if (best) |b| if (rank <= b.rank) continue;
        best = .{ .index = i, .rank = rank };
    }
    return best;
}

/// Deduped graff catalog names, newest activation included (the codex/kimi/
/// router slices are already swapped in by the time hydration runs).
fn targetsOf(sa: Allocator) ![]const Target {
    var out: std.ArrayList(Target) = .empty;
    for (pricing.models()) |m| {
        var dup = false;
        for (out.items) |t| if (std.mem.eql(u8, t.name, m.name)) {
            dup = true;
        };
        if (dup) continue;
        const buf = try sa.create([128]u8);
        try out.append(sa, .{ .name = m.name, .norm = pricing.normalizeModelAlias(buf, m.name) });
    }
    return out.toOwnedSlice(sa);
}

/// One streaming pass over the database: every value whose key cannot beat the
/// current match for some graff model is skipped without being materialized, so
/// peak memory is the ~40 rows we keep, not the ~3000 rows upstream ships.
pub fn scan(gpa: Allocator, arena: Allocator, data: []const u8) ?[]const Row {
    if (data.len == 0 or data.len > max_bytes) return null;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const targets = targetsOf(sa) catch return null;
    const ranks = sa.alloc(u8, targets.len) catch return null;
    const found = sa.alloc(Fields, targets.len) catch return null;
    @memset(ranks, 0);

    var scanner: std.json.Scanner = .initCompleteInput(sa, data);
    defer scanner.deinit();
    if ((scanner.next() catch return null) != .object_begin) return null;
    var norm_buf: [128]u8 = undefined;
    var tail_buf: [128]u8 = undefined;
    while (true) {
        switch (scanner.peekNextTokenType() catch return null) {
            .object_end => break,
            .string => {},
            else => return null,
        }
        const key = switch (scanner.nextAlloc(sa, .alloc_if_needed) catch return null) {
            .string, .allocated_string => |s| s,
            else => return null,
        };
        const hit = bestMatch(keyForm(key, &norm_buf, &tail_buf), targets, ranks) orelse {
            scanner.skipValue() catch return null;
            continue;
        };
        // A matched key whose value is not an object is upstream's problem, not
        // a reason to throw away 3000 good rows — skip it and keep scanning.
        if ((scanner.peekNextTokenType() catch return null) != .object_begin) {
            scanner.skipValue() catch return null;
            continue;
        }
        const fields = readFields(&scanner, sa) catch return null;
        if (!fields.usable()) continue;
        ranks[hit.index] = hit.rank;
        found[hit.index] = fields;
    }

    var rows: std.ArrayList(Row) = .empty;
    for (targets, 0..) |t, i| {
        if (ranks[i] == 0) continue;
        var fields = found[i];
        // Strip an untrusted price HERE, not at apply time, so the trimmed
        // cache we write never carries a markup that would reload as a
        // vendor-grade row (its keys are graff names, i.e. exact matches).
        if (ranks[i] < trusted_price_rank) fields = .{ .context = fields.context };
        if (!fields.usable()) continue;
        const owned = arena.dupe(u8, t.name) catch continue;
        rows.append(arena, .{ .name = owned, .fields = fields }) catch continue;
    }
    if (rows.items.len == 0) return null;
    return rows.toOwnedSlice(arena) catch null;
}

// ── overlay assembly ────────────────────────────────────────────────────────

/// Per-token USD to graff's per-1M USD. Rounded to nano-dollars because the
/// multiply is not exact in binary: zai's 3.2e-6 comes back as
/// 3.1999999999999997, which `graff models` would print verbatim.
fn perMillion(v: f64, fallback: f64) f64 {
    if (v < 0) return fallback;
    return @round(v * 1_000_000.0 * 1e9) / 1e9;
}

/// Per-field layering (see the module header): upstream when it says, the
/// currently effective price when it doesn't, 0 only when nothing knows.
fn priceOf(row: Row) pricing.ModelPrice {
    const prev = pricing.priceFor(row.name) orelse pricing.ModelPrice{ .name = row.name, .in = 0, .out = 0, .cache = 0 };
    const f = row.fields;
    const in = perMillion(f.in, prev.in);
    const out = perMillion(f.out, prev.out);
    const cache = perMillion(f.cache, prev.cache);
    // A ≥200k band needs BOTH of its dominant rates. Half a tier is no tier:
    // taking `cache_read_..._above_200k_tokens` alone would switch usdFor into
    // a band whose input rate is whatever the flat baked row had — often 0, i.e.
    // free input on exactly the largest requests. Keep the baked band instead.
    if (!(f.high_in >= 0 and f.high_out >= 0)) return .{
        .name = row.name,
        .in = in,
        .out = out,
        .cache = cache,
        .high_at = prev.high_at,
        .high_in = prev.high_in,
        .high_out = prev.high_out,
        .high_cache = prev.high_cache,
    };
    return .{
        .name = row.name,
        .in = in,
        .out = out,
        .cache = cache,
        .high_at = 200_000,
        .high_in = perMillion(f.high_in, 0),
        .high_out = perMillion(f.high_out, 0),
        // Upstream tiers input/output far more often than cache reads; the base
        // cache rate is the honest floor for the band, never 0.
        .high_cache = perMillion(f.high_cache, if (prev.high_cache > 0) prev.high_cache else cache),
    };
}

/// Append our rows to whatever the models.dev refresh already installed. The
/// context rows carry `provider = ""` on purpose: contextFor consults a baked
/// provider-specific row first (so the gateway's narrower gpt-5.5 window still
/// wins) and clamps EVERY codex resolution to codex_context_window, so a wide
/// upstream number can never lift the codex cap.
pub fn apply(arena: Allocator, rows: []const Row) void {
    if (!layered) {
        base_prices = pricing.price_overlay;
        base_contexts = pricing.context_overlay;
        layered = true;
    }
    var prices: std.ArrayList(pricing.ModelPrice) = .empty;
    var contexts: std.ArrayList(pricing.ModelInfo) = .empty;
    prices.appendSlice(arena, base_prices) catch return;
    contexts.appendSlice(arena, base_contexts) catch return;
    for (rows) |row| {
        if (row.fields.in >= 0 or row.fields.out >= 0) prices.append(arena, priceOf(row)) catch {};
        // Range-checked before the cast: @intFromFloat past u64 is undefined
        // behaviour, and a hand-edited prices.json is an untrusted input.
        if (row.fields.context >= 1 and row.fields.context < 1e15)
            contexts.append(arena, .{ .provider = "", .name = row.name, .context = @intFromFloat(row.fields.context) }) catch {};
    }
    pricing.price_overlay = prices.toOwnedSlice(arena) catch pricing.price_overlay;
    pricing.context_overlay = contexts.toOwnedSlice(arena) catch pricing.context_overlay;
}

// ── on-disk cache ───────────────────────────────────────────────────────────

/// Re-emit the matched rows in the SAME shape as upstream, so one parser reads
/// both and `GRAFF_PRICES_PATH` accepts either a vendored copy of the database
/// or one of these. Keyed by graff's model name, which reloads as an exact
/// match. `{e}` round-trips an f64 through parseFloat; `{d}` would not.
pub fn serialize(arena: Allocator, rows: []const Row) ?[]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeByte('{') catch return null;
    for (rows, 0..) |row, i| {
        if (i > 0) aw.writer.writeByte(',') catch return null;
        var name: std.json.Stringify = .{ .writer = &aw.writer };
        name.write(row.name) catch return null;
        aw.writer.writeAll(":{") catch return null;
        var wrote: usize = 0;
        inline for (.{
            .{ "input_cost_per_token", "in" },
            .{ "output_cost_per_token", "out" },
            .{ "cache_read_input_token_cost", "cache" },
            .{ "input_cost_per_token_above_200k_tokens", "high_in" },
            .{ "output_cost_per_token_above_200k_tokens", "high_out" },
            .{ "cache_read_input_token_cost_above_200k_tokens", "high_cache" },
            .{ "max_input_tokens", "context" },
        }) |pair| {
            const value = @field(row.fields, pair[1]);
            if (value >= 0) {
                if (wrote > 0) aw.writer.writeByte(',') catch return null;
                aw.writer.print("\"{s}\":{e}", .{ pair[0], value }) catch return null;
                wrote += 1;
            }
        }
        aw.writer.writeByte('}') catch return null;
    }
    aw.writer.writeAll("}\n") catch return null;
    return aw.writer.buffered();
}

/// Age of `path` from its mtime, or null when it is not there. Path-based on
/// purpose: `stat` on a WRITE-ONLY handle is ACCESS_DENIED on Windows (#462),
/// and this runs on every platform graff ships to.
fn ageMs(io: Io, dir: Io.Dir, path: []const u8) ?i64 {
    if (path.len == 0) return null;
    const st = dir.statFile(io, path, .{}) catch return null;
    return util.unixMs(io) - @as(i64, @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms)));
}

fn readCapped(io: Io, arena: Allocator, dir: Io.Dir, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    return dir.readFileAlloc(io, path, arena, .limited(max_bytes)) catch null;
}

fn fetch(io: Io, gpa: Allocator, arena: Allocator) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const extra = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "graff-prices/1.0" },
    };
    const res = client.fetch(.{
        .location = .{ .url = db_url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &extra,
    }) catch return null;
    if (@intFromEnum(res.status) != 200) return null;
    const body = aw.writer.buffered();
    return if (body.len == 0 or body.len > max_bytes) null else body;
}

// ── hydration ───────────────────────────────────────────────────────────────

pub const Paths = struct { override: []const u8 = "", cache: []const u8 = "", flat: []const u8 = "" };

fn cachePaths(arena: Allocator, home: []const u8) Paths {
    if (home.len == 0) return .{ .override = path_override };
    return .{
        .override = path_override,
        .cache = std.fmt.allocPrint(arena, "{s}/.codegraff/prices.json", .{home}) catch "",
        .flat = std.fmt.allocPrint(arena, "{s}/.codegraff-prices.json", .{home}) catch "",
    };
}

fn note(arena: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "litellm";
}

/// The whole policy, in one place and testable against a `tmpDir`:
/// `GRAFF_PRICES_PATH` beats everything, then a cache younger than the TTL,
/// then the network, then a stale cache (offline beats nothing). Every arm is
/// silent — a failure just leaves the baked table authoritative.
pub fn hydrateAt(io: Io, gpa: Allocator, arena: Allocator, dir: Io.Dir, paths: Paths, allow_network: bool) void {
    if (readCapped(io, arena, dir, paths.override)) |data| {
        if (scan(gpa, arena, data)) |rows| {
            apply(arena, rows);
            source = note(arena, "GRAFF_PRICES_PATH · {d} model(s)", .{rows.len});
        }
        return; // an explicit override is the answer, fresh or not
    }
    var path: []const u8 = "";
    var age: i64 = std.math.maxInt(i64);
    for ([_][]const u8{ paths.cache, paths.flat }) |candidate| {
        if (ageMs(io, dir, candidate)) |a| {
            path = candidate;
            age = a;
            break;
        }
    }
    if (path.len != 0 and age >= 0 and age < ttl_ms) {
        if (readCapped(io, arena, dir, path)) |data| if (scan(gpa, arena, data)) |rows| {
            apply(arena, rows);
            source = note(arena, "litellm cache · {d}h old · {d} model(s)", .{ @divTrunc(age, 60 * 60 * 1000), rows.len });
            return;
        };
    }
    if (allow_network) {
        if (fetch(io, gpa, arena)) |body| if (scan(gpa, arena, body)) |rows| {
            apply(arena, rows);
            source = note(arena, "litellm live · {d} model(s)", .{rows.len});
            if (serialize(arena, rows)) |bytes| for ([_][]const u8{ paths.cache, paths.flat }) |p| {
                if (p.len == 0) continue;
                credential_store.replaceFile(io, dir, p, bytes, .default_file) catch continue;
                break;
            };
            return;
        };
    }
    // Offline with only a stale sheet: yesterday's prices beat last release's.
    if (path.len != 0) if (readCapped(io, arena, dir, path)) |data| if (scan(gpa, arena, data)) |rows| {
        apply(arena, rows);
        source = note(arena, "litellm cache (stale) · {d} model(s)", .{rows.len});
    };
}

/// Hydrate at most once per process per mode. `allow_network = false` is the
/// catalog-ensure path (cache/override only, so boot never waits on a 2 MB
/// GET); `allow_network = true` is the explicit `/models` freshness moment.
pub fn ensure(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, allow_network: bool) void {
    if (if (allow_network) live_loaded else cache_loaded) return;
    cache_loaded = true;
    if (allow_network) live_loaded = true;
    hydrateAt(io, gpa, arena, Io.Dir.cwd(), cachePaths(arena, home), allow_network);
}

test {
    _ = @import("pricing_db_tests.zig");
}
