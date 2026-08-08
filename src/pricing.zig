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
    .{ .name = "claude-fable-5", .in = 10, .out = 50, .cache = 1 }, // pricier than opus-5; unpriced it read as a cheap rung
    .{ .name = "claude-opus-5", .in = 5, .out = 25, .cache = 0.5 },
    .{ .name = "claude-sonnet-5", .in = 2, .out = 10, .cache = 0.2 }, // introductory, $3/$15 from 2026-09-01
    .{ .name = "claude-opus-4-8", .in = 5, .out = 25, .cache = 0.5 },
    .{ .name = "claude-opus-4.8", .in = 5, .out = 25, .cache = 0.5 },
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

/// Billing class of one API call: a flat-rate subscription login bills nothing
/// per token, price_table rows bill per token, anything else is unpriced.
/// Classifying a SEAT is billing.zig's job — it needs the provider spec and the
/// credential source, neither of which belongs in a price sheet.
pub const Billing = enum { sub, priced, unpriced };

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

    /// `billing` is the caller's already-classified seat (billing.forSeat): a
    /// flat-rate login and a metered env key on the SAME provider+model are
    /// different classes, so the tally cannot derive it itself (#471).
    pub fn add(self: *CostTally, io: Io, billing: Billing, model: []const u8, uncached_in: i64, cache_in: i64, out: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.api_calls +|= 1;
        self.in_tokens +|= @intCast(@max(uncached_in, 0));
        self.cache_tokens +|= @intCast(@max(cache_in, 0));
        self.out_tokens +|= @intCast(@max(out, 0));
        switch (billing) {
            .sub => self.sub_calls +|= 1,
            .unpriced => self.unpriced_calls +|= 1,
            // No `.?`: the class comes from the caller; a dropped row falls back.
            .priced => {
                if (priceFor(model)) |p| self.usd += usdFor(p, uncached_in, cache_in, out) else self.unpriced_calls +|= 1;
            },
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
            c.api_calls, c.in_tokens +| c.cache_tokens, c.cache_tokens, c.out_tokens, c.usd,
        });
        if (c.sub_calls > 0) try w.print(" · {d} subscription call(s), flat-rate (not in $)", .{c.sub_calls});
        if (c.unpriced_calls > 0) try w.print(" · {d} call(s) on unpriced models", .{c.unpriced_calls});
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
    // Kimi Code's authenticated /models catalog may choose the wire protocol
    // per model. Missing/`kimi` uses its native OpenAI-shaped transport;
    // `anthropic` switches only that model to beta Messages.
    protocol: ModelProtocol = .provider_default,
    supports_reasoning: bool = false,
    thinking_support: ThinkingSupport = .unknown,
    support_efforts: []const []const u8 = &.{},
    default_effort: ?[]const u8 = null,
};

pub const ModelProtocol = enum { provider_default, kimi, anthropic };
pub const ThinkingSupport = enum { unknown, no, both, only };

// Hard cap on the usable input for ANY codex (ChatGPT-account) model. The
// backend enforces ~272k input for every gpt-5.x regardless of what the /models
// catalog advertises (e.g. 372k for sol/terra/luna, which is NOT honored for
// input). contextFor() clamps every codex resolution path to this so
// auto-compaction (80%) fires before the backend's "input exceeds the context
// window" rejection. 270k -> compaction at 216k, ~56k below the ~272k wall.
pub const codex_context_window: u64 = 270_000;

pub const model_table = [_]ModelInfo{
    // Local Apple-Silicon model served by mlx-lm (mlx_lm.server, OpenAI-compatible).
    .{ .provider = "mlx", .name = "mlx-community/Qwen3.6-27B-OptiQ-4bit", .context = 262_144 },
    // LM Studio serves whatever model is loaded; "lmstudio" is a routing alias —
    // swap for your loaded model id if LM Studio requires an exact match (GET :1234/v1/models).
    .{ .provider = "lmstudio", .name = "lmstudio", .context = 200_000 },
    // Anthropic: no-key/offline FALLBACK ONLY. With a key, router_catalog
    // fetches /v1/models and replaces this slice 1:1 with the live list
    // (windows from max_input_tokens) — do not grow or "fix" these rows to
    // track releases; they exist so boot, --schema, and routing work before
    // the first authenticated fetch.
    .{ .provider = "anthropic", .name = "claude-opus-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-5", .context = 1_000_000 },
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
    // Offline snapshot only. At startup models_cache.zig replaces the entire
    // Codex slice from the account-scoped /models response (5-minute cache).
    // Keep this usable when auth/discovery is unavailable: these are the
    // visible rows and advertised windows from the 2026-07-10 Codex catalog.
    .{ .provider = "codex", .name = "gpt-5.6-sol", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.6-terra", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.6-luna", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.5", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.4", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.4-mini", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.3-codex-spark", .context = 128_000 },
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
    // Kimi Code offline fallback. Authenticated startup replaces this slice
    // from /coding/v1/models; K3 is the current explicit generation while the
    // two compatibility aliases keep their smaller advertised window.
    .{ .provider = "kimi", .name = "k3", .context = 1_048_576, .protocol = .kimi, .supports_reasoning = true, .support_efforts = &.{"max"}, .default_effort = "max" },
    .{ .provider = "kimi", .name = "kimi-for-coding", .context = 262_144, .protocol = .kimi, .supports_reasoning = true },
    .{ .provider = "kimi", .name = "kimi-for-coding-highspeed", .context = 262_144, .protocol = .kimi, .supports_reasoning = true },
    .{ .provider = "moonshot", .name = "kimi-latest", .context = 131_072 },
    .{ .provider = "xai", .name = "grok-4.3", .context = 1_000_000 },
    .{ .provider = "xai", .name = "grok-build", .context = 256_000 },
    .{ .provider = "zai", .name = "glm-5.2", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-5", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.7", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.5", .context = 131_072 },
};

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

/// Codex's first visible account model is its dynamic default. Kimi prefers
/// the newest explicit pure generation (`k3`, then future `k4`, etc.) over
/// compatibility aliases and K2 point-release ids.
pub fn providerDefaultModel(provider_id: []const u8, fallback: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_id, "codex")) {
        for (models()) |model| if (std.mem.eql(u8, model.provider, "codex")) return model.name;
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
    const is_codex = std.mem.eql(u8, provider_id, "codex");
    // Provider-specific baked row is authoritative (gateway gpt-5.5 = 400k, not
    // the API's 1.05M), so it wins over the fresh name-only overlay below.
    for (models()) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model))
            return if (is_codex) @min(m.context, codex_context_window) else m.context;
    }
    // Fresh overlay (models.dev refresh), then the baked name-only fallback. A
    // name-only window may exceed what the Codex backend honors — cap codex.
    for (context_overlay) |m| {
        if (std.mem.eql(u8, m.name, model)) return if (is_codex) @min(m.context, codex_context_window) else m.context;
    }
    for (models()) |m| {
        if (std.mem.eql(u8, m.name, model)) return if (is_codex) @min(m.context, codex_context_window) else m.context;
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
    for (models()) |m| if (std.mem.eql(u8, m.name, query)) return m.name;
    for (models()) |m| if (modelAliasEquals(m.name, query)) return m.name;
    // #377: family-prefixed spelling of a provider's own row (`kimi-k3` → kimi's
    // `k3`) — resolves even when no gateway catalog supplies the prefixed name.
    for (models()) |m| if (familyAliasEquals(m.provider, m.name, query)) return m.name;
    var qbuf: [128]u8 = undefined;
    const qnorm = normalizeModelAlias(&qbuf, query);
    var fallback: ?[]const u8 = null;
    for (models()) |m| {
        var nbuf: [128]u8 = undefined;
        const nnorm = normalizeModelAlias(&nbuf, m.name);
        if (util.indexOfIgnoreCase(m.name, query) == null and std.mem.indexOf(u8, nnorm, qnorm) == null) continue;
        if (keys.get(m.provider) != null) return m.name;
        if (fallback == null) fallback = m.name;
    }
    return fallback;
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

test "contextFor known model and default fallback" {
    try std.testing.expectEqual(@as(u64, 1_048_576), contextFor("kimi", "k3"));
    try std.testing.expectEqual(@as(u64, default_context), contextFor("nope", "unknown-xyz"));
}

test "Kimi discovery preserves Codex and chooses the newest pure generation" {
    const saved = active_model_table;
    defer active_model_table = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const discovered = [_]ModelInfo{
        .{ .provider = "kimi", .name = "kimi-for-coding", .context = 262_144 },
        .{ .provider = "kimi", .name = "k2p7", .context = 262_144 },
        .{ .provider = "kimi", .name = "k3", .context = 1_048_576, .protocol = .anthropic, .supports_reasoning = true, .support_efforts = &.{"max"}, .default_effort = "max" },
    };
    try std.testing.expect(activateKimiModels(arena_state.allocator(), &discovered));
    try std.testing.expectEqualStrings("k3", providerDefaultModel("kimi", "fallback"));
    try std.testing.expectEqual(ModelProtocol.anthropic, kimiProtocol("k3"));
    try std.testing.expect(kimiSupportsThinking("k3"));
    try std.testing.expectEqualStrings("max", kimiThinkingEffort("k3", "medium").?);
    try std.testing.expect(providerModelInTable("codex", "gpt-5.6-sol"));
    try std.testing.expect(!providerModelInTable("kimi", "kimi-for-coding-highspeed"));
    const codex = [_]ModelInfo{.{ .provider = "codex", .name = "future-sol", .context = 270_000 }};
    try std.testing.expect(activateCodexModels(arena_state.allocator(), &codex));
    try std.testing.expect(providerModelInTable("kimi", "k3"));
}

test "Codex discovery replaces only the baked Codex fallback" {
    const saved = active_model_table;
    defer active_model_table = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const discovered = [_]ModelInfo{
        .{ .provider = "codex", .name = "future-sol", .context = 372_000 },
        .{ .provider = "codex", .name = "future-luna", .context = 128_000 },
    };
    try std.testing.expect(activateCodexModels(arena_state.allocator(), &discovered));
    try std.testing.expect(providerModelInTable("codex", "future-sol"));
    try std.testing.expect(providerModelInTable("codex", "future-luna"));
    try std.testing.expect(!providerModelInTable("codex", "gpt-5.5"));
    try std.testing.expectEqual(codex_context_window, contextFor("codex", "future-sol")); // live 372k row clamps to the codex cap
    try std.testing.expectEqualStrings("future-sol", providerDefaultModel("codex", "fallback"));
    try std.testing.expect(providerModelInTable("openai", "gpt-5.6"));
}

test "baked Codex catalog is an offline fallback, not rollout data" {
    try std.testing.expect(providerModelInTable("codex", "gpt-5.6-sol"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.6-terra"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.6-luna"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.5"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.4"));
    try std.testing.expect(providerModelInTable("codex", "gpt-5.3-codex-spark"));
    try std.testing.expectEqual(codex_context_window, contextFor("codex", "gpt-5.6-sol")); // baked 272k row clamps to the codex cap
    try std.testing.expectEqualStrings("gpt-5.6-sol", providerDefaultModel("codex", "fallback"));
    try std.testing.expect(!providerModelInTable("codex", "gpt-5.5-codex"));
    try std.testing.expect(!providerModelInTable("codex", "gpt-5-codex"));
    try std.testing.expect(providerModelInTable("openai", "gpt-5-codex"));
    try std.testing.expect(providerModelInTable("openai", "gpt-5.6"));
}

test "every built-in provider default_model is catalog-present for that provider" {
    // Workspace routers are runtime configuration and are tested separately.
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

// Seat classification moved to billing.zig with #471 — it needs the provider
// spec and the credential source, not the price sheet. Its tests live there.

test "usdFor: per-million math and negative clamping" {
    const p = priceFor("gpt-5.5").?; // $5 in / $30 out / $0.5 cache per 1M
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), usdFor(p, 1_000_000, 0, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), usdFor(p, 0, 1_000_000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), usdFor(p, 0, 0, 100_000), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), usdFor(p, -42, -1, 0), 1e-9); // clamped
}

// CostTally/modelInTable/priceFor/resolveModelName tests live in
// pricing_tests.zig (this file sits against the 600-line cap).
