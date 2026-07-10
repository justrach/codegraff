//! Model pricing, catalog, and the session cost tally — the first module
//! split out of main.zig (#123). Pure tables + functions over std only:
//! provider wiring (Provider/Keys) lives in provider.zig, so the one
//! routine that needs key state (resolveModelName) takes it as `anytype`
//! (its own co-located test back-imports main for Keys/provider_specs).

const std = @import("std");
const Io = std.Io;

/// Per-model token pricing in USD per 1M tokens (from models.dev, snapshot
/// 2026-06-10). Keyed by model name, provider-agnostic. Login providers
/// (codex, claude) bill via subscription, not per token — recordCost treats
/// them as $0 ("sub") regardless of this table. Models absent here have no
/// known price and contribute 0 to the running cost (shown as ~).
pub const ModelPrice = struct { name: []const u8, in: f64, out: f64, cache: f64 };
pub const price_table = [_]ModelPrice{
    .{ .name = "deepseek-v4-pro", .in = 1.1, .out = 2.2, .cache = 0.11 },
    .{ .name = "deepseek-v4-flash", .in = 0.14, .out = 0.28, .cache = 0.028 },
    .{ .name = "gpt-5.6", .in = 5, .out = 30, .cache = 0.5 }, // Sol / flagship (models.dev 2026-07-09)
    .{ .name = "gpt-5.6-terra", .in = 2.5, .out = 15, .cache = 0.25 },
    .{ .name = "gpt-5.6-luna", .in = 1, .out = 6, .cache = 0.1 },
    .{ .name = "gpt-5.5", .in = 5, .out = 30, .cache = 0.5 },
    .{ .name = "gpt-5.5-codex", .in = 1.25, .out = 10, .cache = 0.125 },
    .{ .name = "gpt-5.4", .in = 2.5, .out = 15, .cache = 0.25 },
    .{ .name = "gpt-5.4-mini", .in = 0.75, .out = 4.5, .cache = 0.075 },
    .{ .name = "gpt-5.3-codex", .in = 1.75, .out = 14, .cache = 0.175 },
    .{ .name = "gpt-5.2", .in = 1.75, .out = 14, .cache = 0.175 },
    .{ .name = "gpt-5-codex", .in = 1.25, .out = 10, .cache = 0.125 },
    .{ .name = "claude-opus-4-8", .in = 15, .out = 75, .cache = 1.5 },
    .{ .name = "claude-opus-4.8", .in = 15, .out = 75, .cache = 1.5 },
    .{ .name = "claude-sonnet-4-6", .in = 3, .out = 15, .cache = 0.3 },
    .{ .name = "claude-sonnet-4.6", .in = 3, .out = 15, .cache = 0.3 },
    .{ .name = "claude-haiku-4-5", .in = 1, .out = 5, .cache = 0.1 },
    .{ .name = "MiniMax-M3", .in = 0.3, .out = 1.2, .cache = 0.06 },
    .{ .name = "minimax-m3", .in = 0.3, .out = 1.2, .cache = 0.06 },
    .{ .name = "mimo-v2.5-pro", .in = 0.435, .out = 0.87, .cache = 0.0036 },
    .{ .name = "mimo-v2.5", .in = 0.14, .out = 0.28, .cache = 0.0028 },
    .{ .name = "kimi-k2.7", .in = 0.95, .out = 4, .cache = 0.1 },
    .{ .name = "kimi-k2.6", .in = 0.95, .out = 4, .cache = 0.1 },
    .{ .name = "kimi-k2-thinking", .in = 0.6, .out = 2.5, .cache = 0.06 },
    .{ .name = "kimi-k2.5", .in = 0.6, .out = 3, .cache = 0.06 },
    .{ .name = "grok-4.3", .in = 1.25, .out = 2.5, .cache = 0.3 },
    .{ .name = "grok-build", .in = 1, .out = 2, .cache = 0.1 },
    .{ .name = "glm-5.2", .in = 1, .out = 3.2, .cache = 0.1 },
    .{ .name = "glm-5", .in = 1, .out = 3.2, .cache = 0.1 },
    .{ .name = "glm-4.7", .in = 0.6, .out = 2.2, .cache = 0.06 },
    .{ .name = "glm-4.5", .in = 0.6, .out = 2.2, .cache = 0.06 },
};

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

/// Billing class of one API call: the codex subscription login bills
/// flat-rate, price_table rows bill per token, anything else is unpriced.
pub const Billing = enum { sub, priced, unpriced };

pub fn billingFor(provider_id: []const u8, model: []const u8) Billing {
    if (std.mem.eql(u8, provider_id, "codex")) return .sub;
    return if (priceFor(model) != null) .priced else .unpriced;
}

/// USD for one request at price `p` (negative token counts clamp to 0).
pub fn usdFor(p: ModelPrice, uncached_in: i64, cache_in: i64, out: i64) f64 {
    const fi: f64 = @floatFromInt(@max(uncached_in, 0));
    const fc: f64 = @floatFromInt(@max(cache_in, 0));
    const fo: f64 = @floatFromInt(@max(out, 0));
    return (fi * p.in + fc * p.cache + fo * p.out) / 1_000_000.0;
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
    in_tokens: u64 = 0, // uncached input
    cache_tokens: u64 = 0, // cache-read input
    out_tokens: u64 = 0,
    api_calls: u64 = 0,
    sub_calls: u64 = 0, // subscription-billed (flat-rate; contribute $0)
    unpriced_calls: u64 = 0, // no price_table row

    pub fn add(self: *CostTally, io: Io, provider_id: []const u8, model: []const u8, uncached_in: i64, cache_in: i64, out: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.api_calls += 1;
        self.in_tokens += @intCast(@max(uncached_in, 0));
        self.cache_tokens += @intCast(@max(cache_in, 0));
        self.out_tokens += @intCast(@max(out, 0));
        switch (billingFor(provider_id, model)) {
            .sub => self.sub_calls += 1,
            .unpriced => self.unpriced_calls += 1,
            .priced => self.usd += usdFor(priceFor(model).?, uncached_in, cache_in, out),
        }
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
        try w.print("{d} api call(s) · {d} in ({d} cached) + {d} out tokens · ${d:.4}", .{
            c.api_calls, c.in_tokens + c.cache_tokens, c.cache_tokens, c.out_tokens, c.usd,
        });
        if (c.sub_calls > 0) try w.print(" · {d} subscription call(s), flat-rate (not in $)", .{c.sub_calls});
        if (c.unpriced_calls > 0) try w.print(" · {d} call(s) on unpriced models", .{c.unpriced_calls});
    }
};

pub var g_cost: CostTally = .{};

// Known models per provider: context window in tokens. Direct-provider
// numbers from models.dev/api.json, codegraff numbers from the gateway's
// /v1/models endpoint (both snapshot 2026-06-10). The same model name can
// appear under several providers with different limits — routing picks the
// first row whose provider has an API key. Compaction triggers at 80% of
// the context; unknown models fall back to a conservative 200k.
pub const ModelInfo = struct {
    provider: []const u8,
    name: []const u8,
    context: u64,
};

// Codex/ChatGPT backend: gpt-5.x window is 272k (codex-rs models.json); budget
// 270k so compaction (80% -> 216k) fires just under the hard cap and absorbs our
// token under-count (a turn displaying 270k still 400'd). Not the API's 1.05M.
pub const codex_context_window: u64 = 270_000;

pub const model_table = [_]ModelInfo{
    // Local Apple-Silicon model served by mlx-lm (mlx_lm.server, OpenAI-compatible).
    .{ .provider = "mlx", .name = "mlx-community/Qwen3.6-27B-OptiQ-4bit", .context = 262_144 },
    // LM Studio serves whatever model is loaded; "lmstudio" is a routing alias —
    // swap for your loaded model id if LM Studio requires an exact match (GET :1234/v1/models).
    .{ .provider = "lmstudio", .name = "lmstudio", .context = 200_000 },
    .{ .provider = "anthropic", .name = "claude-fable-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-8", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-7", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-6", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-4-6", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-haiku-4-5", .context = 200_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-5", .context = 200_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-4-5", .context = 200_000 },
    .{ .provider = "deepseek", .name = "deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-v4-flash", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-chat", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-reasoner", .context = 1_000_000 },
    .{ .provider = "openai", .name = "gpt-5.6", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.6-terra", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.6-luna", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.5", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.4", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.4-pro", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-5.4-mini", .context = 400_000 },
    .{ .provider = "openai", .name = "gpt-5.2", .context = 400_000 },
    .{ .provider = "openai", .name = "gpt-5-codex", .context = 400_000 },
    .{ .provider = "minimax", .name = "MiniMax-M3", .context = 512_000 },
    .{ .provider = "minimax", .name = "MiniMax-M2.7", .context = 204_800 },
    .{ .provider = "minimax", .name = "MiniMax-M2.5", .context = 204_800 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5-pro", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5-pro-ultraspeed", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2-flash", .context = 262_144 },
    // Codex/ChatGPT backend lineup (codex-rs models.json): the slugs the
    // chatgpt.com/backend-api/codex/responses endpoint accepts. Default is
    // gpt-5.5 (available to every Codex account); gpt-5.6 is the newest but
    // ENTITLEMENT-GATED — OpenAI rolls it out to Codex accounts gradually, and
    // one without it 400s ("model not supported when using Codex with a ChatGPT
    // account"), so it is a selectable opt-in here, NOT the default. Verified
    // live 2026-07-10. The -codex-suffixed API-only names (gpt-5.5-codex,
    // gpt-5-codex) are NOT codex-backend slugs and stay openai-only. All share
    // the ~272k backend window (codex_context_window), not the API's 1.05M.
    .{ .provider = "codex", .name = "gpt-5.5", .context = codex_context_window },
    .{ .provider = "codex", .name = "gpt-5.6", .context = codex_context_window }, // newest; entitlement-gated opt-in
    .{ .provider = "codex", .name = "gpt-5.4", .context = codex_context_window },
    .{ .provider = "codex", .name = "gpt-5.4-mini", .context = codex_context_window },
    .{ .provider = "codex", .name = "gpt-5.3-codex", .context = codex_context_window },
    .{ .provider = "codex", .name = "gpt-5.2", .context = codex_context_window },
    // Sakana AI — Fugu (OpenAI-compatible chat/completions). `fugu` is the fast
    // mini model, `fugu-ultra` the multi-agent reasoning conductor. Sakana does
    // not publish a context window; use the harness's conservative 200k default
    // (auto-compaction + #88 overflow recovery cover an underestimate safely).
    .{ .provider = "fugu", .name = "fugu", .context = 200_000 },
    .{ .provider = "fugu", .name = "fugu-ultra", .context = 200_000 },
    .{ .provider = "fugu", .name = "fugu-ultra-20260615", .context = 200_000 },
    // Fireworks AI (OpenAI-compatible, api.fireworks.ai/inference/v1). Full
    // account-path model ids; context windows from models.dev (snapshot
    // 2026-06-23). Not yet live-tested here (no key on hand), but the wire shape
    // is the same OpenAI one fugu/deepseek use. Set FIREWORKS_API_KEY or
    // `graff key set fireworks <key>`; verify the live list at .../v1/models.
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/deepseek-v4-flash", .context = 1_000_000 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/kimi-k2p7-code", .context = 262_000 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/kimi-k2p6", .context = 262_000 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/glm-5p2", .context = 1_048_576 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/minimax-m3", .context = 512_000 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/qwen3p7-plus", .context = 262_144 },
    .{ .provider = "fireworks", .name = "accounts/fireworks/models/gpt-oss-120b", .context = 131_072 },
    // codegraff gateway (its claude aliases use dots, so they don't collide
    // with the anthropic rows above)
    .{ .provider = "codegraff", .name = "claude-opus-4.8", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "claude-sonnet-4.6", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "minimax-m3", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "gpt-5.5", .context = 400_000 },
    .{ .provider = "codegraff", .name = "kimi-k2.6", .context = 262_144 },
    .{ .provider = "codegraff", .name = "grok-build", .context = 256_000 },
    .{ .provider = "codegraff", .name = "glm-5.2", .context = 204_800 },
    .{ .provider = "codegraff", .name = "mimo-v2.5", .context = 128_000 },
    .{ .provider = "codegraff", .name = "mimo-v2.5-pro", .context = 128_000 },
    // kimi: the Kimi for Coding plan endpoint accepts versioned ids (and the
    // `kimi-for-coding` alias), all routed to the latest coding model. We expose
    // `kimi-k2.7` — its current release. Verified via /coding/v1 2026-06-16.
    .{ .provider = "kimi", .name = "kimi-k2.7", .context = 262_144 },
    .{ .provider = "moonshot", .name = "kimi-latest", .context = 131_072 },
    .{ .provider = "xai", .name = "grok-4.3", .context = 1_000_000 },
    .{ .provider = "xai", .name = "grok-build", .context = 256_000 },
    .{ .provider = "zai", .name = "glm-5.2", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-5", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.7", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.5", .context = 131_072 },
};

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
    const is_codex = std.mem.eql(u8, provider_id, "codex");
    // Provider-specific baked row is authoritative (gateway gpt-5.5 = 400k, not
    // the API's 1.05M), so it wins over the fresh name-only overlay below.
    for (model_table) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model)) return m.context;
    }
    // Fresh overlay (models.dev refresh), then the baked name-only fallback. A
    // name-only window may exceed what the Codex backend honors — cap codex.
    for (context_overlay) |m| {
        if (std.mem.eql(u8, m.name, model)) return if (is_codex) @min(m.context, codex_context_window) else m.context;
    }
    for (model_table) |m| {
        if (std.mem.eql(u8, m.name, model)) return if (is_codex) @min(m.context, codex_context_window) else m.context;
    }
    return default_context;
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

/// `keys` is main.zig's Keys (anytype to keep provider wiring out of this
/// module) — anything with `get(provider_id) ?[]const u8`.
pub fn resolveModelName(keys: anytype, query: []const u8) ?[]const u8 {
    for (model_table) |m| if (std.mem.eql(u8, m.name, query)) return m.name;
    for (model_table) |m| if (modelAliasEquals(m.name, query)) return m.name;
    var qbuf: [128]u8 = undefined;
    const qnorm = normalizeModelAlias(&qbuf, query);
    var fallback: ?[]const u8 = null;
    for (model_table) |m| {
        var nbuf: [128]u8 = undefined;
        const nnorm = normalizeModelAlias(&nbuf, m.name);
        if (std.ascii.indexOfIgnoreCase(m.name, query) == null and std.mem.indexOf(u8, nnorm, qnorm) == null) continue;
        if (keys.get(m.provider) != null) return m.name;
        if (fallback == null) fallback = m.name;
    }
    return fallback;
}

/// Exact membership test against the comptime model table — used to ignore a
/// remembered startup model that no provider actually serves.
pub fn modelInTable(name: []const u8) bool {
    for (model_table) |m| if (std.mem.eql(u8, m.name, name)) return true;
    return false;
}

pub fn providerModelInTable(provider_id: []const u8, model: []const u8) bool {
    for (model_table) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model)) return true;
    }
    return false;
}

test "contextFor known model and default fallback" {
    try std.testing.expectEqual(@as(u64, 262_144), contextFor("kimi", "kimi-k2.7"));
    try std.testing.expectEqual(@as(u64, default_context), contextFor("nope", "unknown-xyz"));
}

test "codex catalog matches the codex backend lineup" {
    // The codex ChatGPT backend serves the codex-rs models.json slugs; the
    // -codex-suffixed API-only names (gpt-5.5-codex, gpt-5-codex) are NOT
    // backend slugs, so they stay openai-served and out of the codex catalog.
    try std.testing.expect(providerModelInTable("codex", "gpt-5.6")); // newest, entitlement-gated opt-in
    try std.testing.expect(providerModelInTable("codex", "gpt-5.5"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.4"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.3-codex"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.2"));
    try std.testing.expect(!providerModelInTable("codex", "gpt-5.5-codex"));
    try std.testing.expect(!providerModelInTable("codex", "gpt-5-codex"));
    try std.testing.expect(providerModelInTable("openai", "gpt-5-codex"));
    try std.testing.expect(providerModelInTable("openai", "gpt-5.6"));
}

test "every provider default_model is catalog-present for that provider" {
    // Guards the codex/openai gpt-5.6 default flip (and any future one): a
    // provider whose default_model isn't in model_table would boot on a model
    // contextFor()/routing can't resolve.
    const specs = @import("provider.zig").provider_specs;
    for (specs) |spec|
        try std.testing.expect(providerModelInTable(spec.id, spec.default_model));
}

test "refresh overlay augments price/context lookups (codex cap still applies)" {
    const saved_p = price_overlay;
    const saved_c = context_overlay;
    defer price_overlay = saved_p;
    defer context_overlay = saved_c;
    const po = [_]ModelPrice{.{ .name = "future-model-x", .in = 9, .out = 9, .cache = 1 }};
    const co = [_]ModelInfo{.{ .provider = "", .name = "future-model-x", .context = 999_000 }};
    price_overlay = &po;
    context_overlay = &co;
    try std.testing.expect(priceFor("future-model-x") != null);
    try std.testing.expectEqual(@as(u64, 999_000), contextFor("openai", "future-model-x"));
    try std.testing.expectEqual(codex_context_window, contextFor("codex", "future-model-x"));
}

test "billingFor: subscription, priced, unpriced classification" {
    try std.testing.expectEqual(Billing.sub, billingFor("codex", "gpt-5.5")); // priced model, but flat-rate login
    try std.testing.expectEqual(Billing.priced, billingFor("openai", "gpt-5.5"));
    try std.testing.expectEqual(Billing.priced, billingFor("anthropic", "claude-sonnet-4-6"));
    try std.testing.expectEqual(Billing.unpriced, billingFor("openai", "mystery-model"));
}

test "usdFor: per-million math and negative clamping" {
    const p = priceFor("gpt-5.5").?; // $5 in / $30 out / $0.5 cache per 1M
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), usdFor(p, 1_000_000, 0, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), usdFor(p, 0, 1_000_000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), usdFor(p, 0, 0, 100_000), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), usdFor(p, -42, -1, 0), 1e-9); // clamped
}

test "modelInTable: known models present, unknown absent" {
    try std.testing.expect(modelInTable("gpt-5.5"));
    try std.testing.expect(modelInTable("claude-opus-4-8"));
    try std.testing.expect(!modelInTable("not-a-real-model"));
}

test "priceFor: known model priced, unknown is null" {
    try std.testing.expect(priceFor("gpt-5.5") != null);
    try std.testing.expect(priceFor("claude-opus-4-8") != null);
    try std.testing.expect(priceFor("no-such-model") == null);
}

test "resolveModelName exact aliases and miss" {
    const provider_mod = @import("provider.zig");
    const Keys = provider_mod.Keys;
    const provider_specs = provider_mod.provider_specs;
    const keys = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expect(resolveModelName(keys, "gpt-5.5") != null); // exact name
    try std.testing.expectEqualStrings("glm-5.2", resolveModelName(keys, "glm5.2").?); // natural alias
    try std.testing.expect(resolveModelName(keys, "totally-unknown-zzz") == null);
}
