//! Model pricing, catalog, and the session cost tally — the first module
//! split out of main.zig (#123). Pure tables + functions over std only:
//! provider wiring (Provider/Keys) lives in provider.zig, so the one
//! routine that needs key state (resolveModelName) takes it as `anytype`
//! (its own co-located test back-imports main for Keys/provider_specs).

const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

/// Per-model token pricing in USD per 1M tokens (from models.dev, snapshot
/// 2026-06-10). Keyed by model name, provider-agnostic. Login providers
/// (codex, claude) bill via subscription, not per token — recordCost treats
/// them as $0 ("sub") regardless of this table. Models absent here have no
/// known price and contribute 0 to the running cost (shown as ~).
pub const ModelPrice = struct { name: []const u8, in: f64, out: f64, cache: f64, high_at: u64 = 0, high_in: f64 = 0, high_out: f64 = 0, high_cache: f64 = 0, cache_write_multiplier: ?f64 = null };
pub const price_table = @import("pricing_table.zig").rows;

/// Runtime price overlay populated by `graff models refresh` (models.dev
/// cache, see models_cache.zig): consulted before the baked-in table so a
/// refresh keeps prices current without a rebuild. Empty by default → the
/// baked table is the sole source offline and on a fresh install.
pub var price_overlay: []const ModelPrice = &.{};

pub fn priceFor(model: []const u8) ?ModelPrice {
    for (price_overlay) |p| if (std.mem.eql(u8, p.name, model)) return p;
    for (price_table) |p| if (std.mem.eql(u8, p.name, model)) return p;
    return null;
}

/// Gateway aliases have their own prices; vendor overlays must not replace them.
/// The gateway's live catalog wins over the baked snapshot, so a model or price
/// it adds bills correctly without a graff release.
pub fn priceForProvider(provider: []const u8, model: []const u8) ?ModelPrice {
    // Vercel AI Gateway publishes its own per-route price in /models too.
    if (std.mem.eql(u8, provider, "vercel")) {
        if (modelInfoFor(provider, model)) |info| if (info.price) |p| return @import("catalog_price.zig").asModelPrice(info.name, p);
        return priceFor(model);
    }
    if (std.mem.eql(u8, provider, "codegraff")) {
        if (modelInfoFor(provider, model)) |info| if (info.price) |p| return @import("catalog_price.zig").asModelPrice(info.name, p);
        return @import("pricing_gateway.zig").find(model);
    }
    return priceFor(model);
}

/// Billing class of one API call: a flat-rate subscription login bills nothing
/// per token, a server on this machine bills nothing at all, price_table rows
/// bill per token, anything without a reliable settled charge is unpriced for
/// the session tally.
/// Classifying a SEAT is billing.zig's job — it needs the provider spec and the
/// credential source, neither of which belongs in a price sheet.
pub const Billing = enum { sub, local, priced, unpriced };

pub const usdForUsage = @import("pricing_cache.zig").usdForUsage;

pub fn usdFor(p: ModelPrice, uncached_in: i64, cache_in: i64, out: i64) f64 {
    return usdForUsage(p, "", uncached_in, cache_in, 0, out);
}

/// Session-wide usage/cost tally. Every API response lands here — the root
/// agent AND subagents/workflow tasks (which run on pool threads, hence the
/// mutex; their per-agent numbers used to vanish with their arenas). Always
/// on: /cost reads it, one-shot mode prints it to stderr, the --cost prompt
/// suffix and --json turn events render the running USD, and the telemetry
/// session summary ships it.
pub const CostTally = struct {
    mutex: Io.Mutex = .init,
    usd: f64 = 0,
    in_tokens: u64 = 0, // ordinary + cache-write input
    cache_tokens: u64 = 0, // cache-read input
    cache_write_tokens: u64 = 0,
    out_tokens: u64 = 0,
    api_calls: u64 = 0,
    sub_calls: u64 = 0, // subscription-billed (flat-rate; contribute $0)
    unreported_failed_attempts: u64 = 0, // not successful calls; billing is unknown
    missing_usage_calls: u64 = 0, // completed responses whose usage was absent
    unpriced_calls: u64 = 0, // no reliable settled charge (or no price_table row)

    /// `billing` is the caller's already-classified seat (billing.forSeat): a
    /// flat-rate login and a metered env key on the SAME provider+model are
    /// different classes, so the tally cannot derive it itself (#471).
    pub fn add(self: *CostTally, io: Io, billing: Billing, model: []const u8, ordinary_in: i64, cache_in: i64, cache_write_in: i64, out: i64) void {
        self.addForProvider(io, billing, "", model, ordinary_in, cache_in, cache_write_in, out);
    }
    pub fn addForProvider(self: *CostTally, io: Io, billing: Billing, provider: []const u8, model: []const u8, ordinary_in: i64, cache_in: i64, cache_write_in: i64, out: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.api_calls +|= 1;
        self.in_tokens +|= @intCast(@max(ordinary_in, 0) +| @max(cache_write_in, 0));
        self.cache_tokens +|= @intCast(@max(cache_in, 0));
        self.cache_write_tokens +|= @intCast(@max(cache_write_in, 0));
        self.out_tokens +|= @intCast(@max(out, 0));
        switch (billing) {
            .sub => self.sub_calls +|= 1,
            .local => {}, // a known $0, so the total stays complete
            .unpriced => self.unpriced_calls +|= 1,
            // No `.?`: the class comes from the caller; a dropped row falls back.
            .priced => {
                if (priceForProvider(provider, model)) |p| self.usd += usdForUsage(p, model, ordinary_in, cache_in, cache_write_in, out) else self.unpriced_calls +|= 1;
            },
        }
    }

    pub fn addSettled(self: *CostTally, io: Io, input: i64, output: i64, charge_micro_usd: u64) void {
        @import("pricing_settled.zig").add(self, io, input, output, charge_micro_usd);
    }

    pub fn missingUsage(self: *CostTally, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.api_calls +|= 1;
        self.missing_usage_calls +|= 1;
    }

    pub fn failedWithoutUsage(self: *CostTally, io: Io, count: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.unreported_failed_attempts +|= count;
    }

    /// Consistent copy for rendering (taken under the lock).
    pub fn snap(self: *CostTally, io: Io) CostTally {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var c = self.*;
        c.mutex = .init;
        return c;
    }

    /// One-line summary shared by /cost and the one-shot stderr report.
    pub fn render(c: CostTally, w: *Io.Writer) !void {
        if (c.missing_usage_calls > 0 or c.unreported_failed_attempts > 0 or c.unpriced_calls > 0) try w.writeAll("known subtotal: ");
        try w.print("{d} api call(s) · {d} in ({d} cached, {d} cache writes) + {d} out tokens · ${d:.8}", .{
            c.api_calls, c.in_tokens +| c.cache_tokens, c.cache_tokens, c.cache_write_tokens, c.out_tokens, c.usd,
        });
        if (c.missing_usage_calls > 0) try w.print(" · totals incomplete: {d} call(s) missing usage (tokens and cost unknown)", .{c.missing_usage_calls});
        if (c.unreported_failed_attempts > 0) try w.print(" · totals incomplete: {d} failed request attempt(s) without usage (tokens and cost unknown)", .{c.unreported_failed_attempts});
        if (c.sub_calls > 0) try w.print(" · {d} subscription call(s), flat-rate (not in $)", .{c.sub_calls});
        if (c.unpriced_calls > 0) try w.print(" · {d} call(s) with unknown cost", .{c.unpriced_calls});
    }
};

pub var g_cost: CostTally = .{};

/// The one-shot `[usage]` stderr footer. Shared by the success path and the
/// fatal paths (#387/#389): the expensive runs — budget exhaustion, a late
/// gateway refusal — must not exit without cost accounting.
pub fn printUsageFooter(io: Io) void {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    if (CostTally.render(g_cost.snap(io), &w)) {
        std.debug.print("[usage] {s}\n", .{w.buffered()});
    } else |_| {}
}

// Known models per provider: context window in tokens. Direct-provider numbers
// from models.dev/api.json, codegraff numbers from the gateway's /v1/models
// (both snapshot 2026-06-10). One name can appear under several providers with
// different limits; routing picks the first row whose provider has an API key.
// Compaction triggers at 80% of the context; unknown models fall back to 200k.
pub const ModelInfo = struct {
    provider: []const u8,
    name: []const u8,
    context: u64,
    // Kimi Code's authenticated /models catalog may choose the wire protocol
    // per model. Missing/`kimi` uses its native OpenAI-shaped transport;
    // `anthropic` switches only that model to beta Messages.
    protocol: ModelProtocol = .provider_default,
    supports_reasoning: bool = false,
    thinking_support: ThinkingSupport = .unknown,
    support_efforts: []const []const u8 = &.{},
    default_effort: ?[]const u8 = null,
    /// Codex catalog `default_verbosity` (ADR 0226): the `text.verbosity` the
    /// route's own client sends for this model.
    default_verbosity: ?[]const u8 = null,
    /// What the route charges, when its own catalog publishes it (catalog_price.zig).
    price: ?CatalogPrice = null,
};

/// USD per 1M tokens, with the optional whole-request long-context tier.
pub const CatalogPrice = struct { in: f64, out: f64, cache: f64, high_at: u64 = 0, high_in: f64 = 0, high_out: f64 = 0, high_cache: f64 = 0 };

pub const ModelProtocol = enum { provider_default, kimi, anthropic };
pub const ThinkingSupport = enum { unknown, no, both, only };

// Conservative subscription input cap for older/unverified models: their
// advertised total window may exceed what the backend accepts as input.
pub const codex_context_window: u64 = 270_000;
// Use GPT-6.1 Sol's announced subscription default, not the API's larger
// maximum (ADR 0292).
pub const sol_subscription_context_window: u64 = 500_000;

pub const model_table = @import("pricing_models.zig").rows;

/// Active catalog for routing, pickers, completion, and runtime listings.
/// It starts with the offline table above; authenticated Codex discovery swaps
/// only the Codex rows while keeping every other provider unchanged.
pub var active_model_table: []const ModelInfo = model_table[0..];

pub fn models() []const ModelInfo {
    return active_model_table;
}

pub fn modelInfoFor(provider_id: []const u8, model: []const u8) ?ModelInfo {
    for (models()) |info| {
        if (std.mem.eql(u8, info.provider, provider_id) and std.mem.eql(u8, info.name, model)) return info;
    }
    return null;
}

/// The official Kimi Code client treats an absent protocol exactly like
/// `kimi`; only a server-declared `anthropic` row uses Messages beta.
pub fn kimiProtocol(model: []const u8) ModelProtocol {
    const info = modelInfoFor("kimi", model) orelse return .kimi;
    return if (info.protocol == .anthropic) .anthropic else .kimi;
}

pub fn kimiSupportsThinking(model: []const u8) bool {
    const info = modelInfoFor("kimi", model) orelse return false;
    return switch (info.thinking_support) {
        .no => false,
        .both, .only => true,
        .unknown => info.supports_reasoning,
    };
}

/// Normalize a requested Graff effort to the server's live allow-list. Kimi
/// Code uses the declared default (or the middle entry) when the requested
/// value is unavailable; an empty list means boolean thinking with no effort.
pub fn kimiThinkingEffort(model: []const u8, requested: []const u8) ?[]const u8 {
    const info = modelInfoFor("kimi", model) orelse return null;
    if (!kimiSupportsThinking(model) or info.support_efforts.len == 0) return null;
    const normalized = if (std.mem.eql(u8, requested, "ultra")) "max" else requested;
    for (info.support_efforts) |effort| if (std.mem.eql(u8, effort, normalized)) return effort;
    if (info.default_effort) |fallback| {
        for (info.support_efforts) |effort| if (std.mem.eql(u8, effort, fallback)) return effort;
    }
    return info.support_efforts[info.support_efforts.len / 2];
}

fn pureKimiGeneration(name: []const u8) ?u32 {
    if (name.len < 2 or name[0] != 'k') return null;
    for (name[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, name[1..], 10) catch null;
}

/// Codex's first visible account model is its dynamic default, and so is the
/// first model oMLX lists. Kimi prefers the newest explicit pure generation
/// (`k3`, then future `k4`, etc.) over compatibility aliases and K2 point-release ids.
pub fn providerDefaultModel(provider_id: []const u8, fallback: []const u8) []const u8 {
    for (models()) |model| if (std.mem.eql(u8, model.provider, provider_id) and
        std.mem.eql(u8, model.name, "mimo-v2.6-pro")) return model.name;
    if (std.mem.eql(u8, provider_id, "codex") or std.mem.eql(u8, provider_id, "omlx")) {
        for (models()) |model| if (std.mem.eql(u8, model.provider, provider_id)) return model.name;
        return fallback;
    }
    if (!std.mem.eql(u8, provider_id, "kimi")) return fallback;
    var best: ?[]const u8 = null;
    var best_generation: u32 = 0;
    var alias: ?[]const u8 = null;
    for (models()) |model| {
        if (!std.mem.eql(u8, model.provider, "kimi")) continue;
        if (std.mem.eql(u8, model.name, "kimi-for-coding")) alias = model.name;
        const generation = pureKimiGeneration(model.name) orelse continue;
        if (best == null or generation > best_generation) {
            best = model.name;
            best_generation = generation;
        }
    }
    if (best) |model| return model;
    if (alias) |model| return model;
    return fallback;
}

pub fn activateProviderModels(arena: std.mem.Allocator, provider_id: []const u8, discovered: []const ModelInfo) bool {
    if (discovered.len == 0) return false;
    var retained: usize = 0;
    for (active_model_table) |m| if (!std.mem.eql(u8, m.provider, provider_id)) {
        retained += 1;
    };
    const combined = arena.alloc(ModelInfo, retained + discovered.len) catch return false;
    var n: usize = 0;
    for (active_model_table) |m| {
        if (std.mem.eql(u8, m.provider, provider_id)) continue;
        combined[n] = m;
        n += 1;
    }
    @memcpy(combined[n..], discovered);
    active_model_table = combined;
    return true;
}

pub fn activateCodexModels(arena: std.mem.Allocator, discovered: []const ModelInfo) bool {
    return activateProviderModels(arena, "codex", discovered);
}

pub fn activateKimiModels(arena: std.mem.Allocator, discovered: []const ModelInfo) bool {
    return activateProviderModels(arena, "kimi", discovered);
}

pub const default_context = 200_000;

/// Runtime context-window overlay from `graff models refresh` (name-keyed;
/// models.dev has no per-graff-provider rows). Consulted after the baked-in
/// provider-specific row (so gateway/codex windows stay authoritative) but
/// before the baked name-only fallback, so a refresh can widen a model graff
/// only knows by name. Empty by default.
pub var context_overlay: []const ModelInfo = &.{};

/// Context window for a model as served by a specific provider; falls back
/// to any provider's row for the name, then to the conservative default.
pub fn contextFor(provider_id: []const u8, model: []const u8) u64 {
    // `<id>[1m]` is Claude Code's spelling of an id's 1M window (claude-agent passes it through).
    if (std.mem.endsWith(u8, model, "[1m]")) return @max(1_000_000, contextFor(provider_id, model[0 .. model.len - "[1m]".len]));
    // The ChatGPT plan route caps input like the Codex backend it shares.
    const is_codex = std.mem.eql(u8, provider_id, "codex") or std.mem.eql(u8, provider_id, "chatgpt-new");
    const subscription_cap = if (std.mem.eql(u8, model, "gpt-6.1-sol")) sol_subscription_context_window else codex_context_window;
    // Provider-specific baked row is authoritative (gateway gpt-5.5 = 400k, not
    // the API's 1.05M), so it wins over the fresh name-only overlay below.
    for (models()) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model))
            return if (is_codex) @min(m.context, subscription_cap) else m.context;
    }
    // Fresh overlay (models.dev refresh), then the baked name-only fallback. A
    // name-only window may exceed what the Codex backend honors — cap codex.
    for (context_overlay) |m| {
        if (std.mem.eql(u8, m.name, model)) return if (is_codex) @min(m.context, subscription_cap) else m.context;
    }
    for (models()) |m| {
        if (std.mem.eql(u8, m.name, model)) return if (is_codex) @min(m.context, subscription_cap) else m.context;
    }
    return default_context;
}

/// Whether a model has a catalogued context window (baked row or fresh overlay),
/// as opposed to falling through to default_context. Mirrors contextFor's lookup so
/// a caller can tell an unknown/local model from a known 200k one (#203) — needed
/// because contextFor returns default_context for both.
pub fn isKnownModel(provider_id: []const u8, model: []const u8) bool {
    for (models()) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model)) return true;
    }
    for (context_overlay) |m| {
        if (std.mem.eql(u8, m.name, model)) return true;
    }
    for (models()) |m| {
        if (std.mem.eql(u8, m.name, model)) return true;
    }
    return false;
}

/// Fuzzy model selection for `/model <query>` (graff-style). Exact name wins;
/// otherwise case-insensitive substring, preferring a model whose provider has
/// a key/login available so `/model sonnet` lands on a usable provider. Returns
/// null when nothing matches (caller falls back to the query verbatim so the
/// providerFor claude*/gateway fallback still applies).
pub fn normalizeModelAlias(dst: *[128]u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '-' or c == '_' or c == ' ') continue;
        if (n >= dst.len) break;
        dst[n] = std.ascii.toLower(c);
        n += 1;
    }
    return dst[0..n];
}

pub fn modelAliasEquals(name: []const u8, query: []const u8) bool {
    var nb: [128]u8 = undefined;
    var qb: [128]u8 = undefined;
    return std.mem.eql(u8, normalizeModelAlias(&nb, name), normalizeModelAlias(&qb, query));
}

/// #377: `<provider><sep><name>` is the same model as the provider's own
/// `<name>` row under a family-prefixed spelling (gateway catalogs do this).
/// Alias-normalized so `kimi-k3` == kimi + `k3` regardless of separators.
pub fn familyAliasEquals(provider_id: []const u8, name: []const u8, query: []const u8) bool {
    var qb: [128]u8 = undefined;
    var pb: [128]u8 = undefined;
    var nb: [128]u8 = undefined;
    const q = normalizeModelAlias(&qb, query);
    const p = normalizeModelAlias(&pb, provider_id);
    const n = normalizeModelAlias(&nb, name);
    return q.len == p.len + n.len and std.mem.startsWith(u8, q, p) and std.mem.endsWith(u8, q, n);
}

/// `keys` is main.zig's Keys (anytype to keep provider wiring out of this
/// module) — anything with `get(provider_id) ?[]const u8`.
pub fn resolveModelName(keys: anytype, query: []const u8) ?[]const u8 {
    // `<provider>/<model>` pins the provider (startup's explicitProvider splits
    // on '/'), so resolve the remainder against that provider's own rows first.
    // openrouter-style slugs keep working: "openrouter/anthropic/claude-x"
    // strips only the leading provider id.
    if (std.mem.indexOfScalar(u8, query, '/')) |slash| {
        const rest = query[slash + 1 ..];
        if (rest.len > 0 and providerModelInTable(query[0..slash], rest)) return rest;
    }
    // #377: `kimi-k3` is Kimi Code's family spelling of `k3`. Moonshot's
    // platform id is also `kimi-k3`. A keyed kimi login keeps the rewrite; a
    // moonshot-only key keeps the Moonshot row (exact match below).
    const kimi_keyed = keys.get("kimi") != null;
    const moonshot_keyed = keys.get("moonshot") != null;
    if (kimi_keyed or !moonshot_keyed) {
        if (familyAliasEquals("kimi", "k3", query)) return "k3";
    }
    for (models()) |m| if (std.mem.eql(u8, m.name, query)) return m.name;
    for (models()) |m| if (modelAliasEquals(m.name, query)) return m.name;
    for (models()) |m| if (familyAliasEquals(m.provider, m.name, query)) return m.name;
    var qbuf: [128]u8 = undefined;
    const qnorm = normalizeModelAlias(&qbuf, query);
    var best_name: ?[]const u8 = null;
    var best_score: i32 = std.math.minInt(i32);
    for (models()) |m| {
        var nbuf: [128]u8 = undefined;
        const nnorm = normalizeModelAlias(&nbuf, m.name);
        if (util.indexOfIgnoreCase(m.name, query) == null and std.mem.indexOf(u8, nnorm, qnorm) == null) continue;
        const keyed = keys.get(m.provider) != null;
        var s: i32 = if (keyed) 1_000_000 else 0;
        // A ChatGPT/Codex login beats a metered or gateway slug for the same
        // needle ("5.6 sol" → gpt-5.6-sol on codex, not openai/gpt-5.6-sol).
        if (keyed and std.mem.eql(u8, m.provider, "codex")) s += 400_000;
        if (std.mem.eql(u8, nnorm, qnorm)) s += 300_000 else if (std.mem.endsWith(u8, nnorm, qnorm)) s += 200_000 else s += 100_000;
        s -= @intCast(@min(m.name.len, 200));
        if (s > best_score) {
            best_score = s;
            best_name = m.name;
        }
    }
    return best_name;
}

/// Exact membership test against the active model table — used to ignore a
/// remembered startup model that no provider actually serves.
pub fn modelInTable(name: []const u8) bool {
    for (models()) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}

pub fn providerModelInTable(provider_id: []const u8, model: []const u8) bool {
    for (models()) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model)) return true;
    }
    return false;
}

// Seat classification lives in billing.zig. Discovery / price-overlay / default
// catalog tests live in pricing_tests.zig (600-line cap).
test "completed response without usage marks totals incomplete without inventing tokens or cost" {
    var tally: CostTally = .{};
    tally.missingUsage(std.testing.io);
    const snapshot = tally.snap(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), snapshot.api_calls);
    try std.testing.expectEqual(@as(u64, 1), snapshot.missing_usage_calls);
    try std.testing.expectEqual(@as(u64, 0), snapshot.in_tokens);
    try std.testing.expectEqual(@as(f64, 0), snapshot.usd);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try snapshot.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "totals incomplete: 1 call(s) missing usage (tokens and cost unknown)") != null);
}
