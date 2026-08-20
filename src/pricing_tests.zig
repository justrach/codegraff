//! Tests carved out of pricing.zig, which sits against the 600-line cap.

const std = @import("std");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");

test "CostTally token and call counters saturate" {
    var tally: pricing.CostTally = .{
        .in_tokens = std.math.maxInt(u64) - 1,
        .cache_tokens = std.math.maxInt(u64),
        .cache_write_tokens = std.math.maxInt(u64),
        .out_tokens = std.math.maxInt(u64) - 2,
        .api_calls = std.math.maxInt(u64),
        .sub_calls = std.math.maxInt(u64),
    };
    tally.add(std.testing.io, .sub, "gpt-5.5", 10, 10, 10, 10);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.in_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.cache_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.cache_write_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.out_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.api_calls);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.sub_calls);
}

test "modelInTable: known models present, unknown absent" {
    try std.testing.expect(pricing.modelInTable("gpt-5.5"));
    try std.testing.expect(pricing.modelInTable("claude-opus-4-8"));
    try std.testing.expect(!pricing.modelInTable("not-a-real-model"));
}

test "priceFor: known model priced, unknown is null" {
    try std.testing.expect(pricing.priceFor("gpt-5.5") != null);
    try std.testing.expect(pricing.priceFor("claude-opus-4-8") != null);
    try std.testing.expect(pricing.priceFor("no-such-model") == null);
}

test "resolveModelName exact aliases and miss" {
    const keys = provider_mod.Keys{ .values = @splat(null) };
    try std.testing.expect(pricing.resolveModelName(keys, "gpt-5.5") != null); // exact name
    try std.testing.expectEqualStrings("glm-5.2", pricing.resolveModelName(keys, "glm5.2").?); // natural alias
    try std.testing.expectEqualStrings("glm-5.3", pricing.resolveModelName(keys, "glm5.3").?);
    try std.testing.expect(pricing.resolveModelName(keys, "totally-unknown-zzz") == null);
}

test "resolveModelName (#377): family-prefixed spelling resolves to the provider's native row" {
    const keys = provider_mod.Keys{ .values = @splat(null) };
    // Works from the COMPILED table alone — no gateway catalog cache needed,
    // so a fresh machine with only a kimi login can type `--model kimi-k3`.
    try std.testing.expectEqualStrings("k3", pricing.resolveModelName(keys, "kimi-k3").?);
    try std.testing.expect(pricing.familyAliasEquals("kimi", "k3", "kimi-k3"));
    try std.testing.expect(pricing.familyAliasEquals("kimi", "k3", "kimi_k3"));
    try std.testing.expect(!pricing.familyAliasEquals("kimi", "k3", "kimi-k30"));
    try std.testing.expect(!pricing.familyAliasEquals("codex", "k3", "kimi-k3"));
}

test "usdFor: per-million math, cache writes, and negative clamping" {
    const p = pricing.priceFor("gpt-5.5").?; // $5 in / $30 out / $0.5 cache per 1M
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), pricing.usdFor(p, 1_000_000, 0, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pricing.usdFor(p, 0, 1_000_000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), pricing.usdFor(p, 0, 0, 100_000), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pricing.usdFor(p, -42, -1, 0), 1e-9); // clamped
    const p56 = pricing.priceFor("gpt-5.6").?;
    try std.testing.expectApproxEqAbs(@as(f64, 6.25), pricing.usdForUsage(p56, "gpt-5.6", 0, 0, 1_000_000, 0), 1e-9);
}

test "grok-4.6 window is 500k and compact-at is 80%" {
    const window = pricing.contextFor("xai", "grok-4.6");
    try std.testing.expectEqual(@as(u64, 500_000), window);
    try std.testing.expectEqual(@as(u64, 1_000_000), pricing.contextFor("xai", "grok-4.3")); // other xAI rows unchanged
    try std.testing.expectEqual(@as(u64, pricing.default_context), pricing.contextFor("nope", "unknown-xyz"));
    const p = provider_mod.Provider{
        .id = "xai",
        .kind = .responses,
        .auth = .bearer,
        .url = "",
        .api_key = "k",
        .model = "grok-4.6",
        .context = window,
    };
    try std.testing.expectEqual(@as(u64, 400_000), p.compactAt()); // 80% of 500k
}

test "grok-4.6 prices: low band under 200k, high band for the whole request at ≥200k" {
    const p = pricing.priceFor("grok-4.6") orelse return error.MissingGrok46Price;
    try std.testing.expectEqual(@as(u64, 200_000), p.high_at);
    // 10k uncached + 2k cached + 500 out @ $2 / $0.50 / $6
    try std.testing.expectApproxEqAbs(@as(f64, 0.024), pricing.usdFor(p, 10_000, 2_000, 500), 1e-12);
    // 199_999 stays on the low band
    try std.testing.expectApproxEqAbs(@as(f64, 0.399998), pricing.usdFor(p, 199_999, 0, 0), 1e-12);
    // 200k uncached + 1k out uses $4 / $12 for every token
    try std.testing.expectApproxEqAbs(@as(f64, 0.812), pricing.usdFor(p, 200_000, 0, 1_000), 1e-12);
    // 190k uncached + 20k cached = 210k prompt → high band on all tokens @ $4 / $1 (cached) / $12 out unused here
    try std.testing.expectApproxEqAbs(@as(f64, 0.78), pricing.usdFor(p, 190_000, 20_000, 0), 1e-12);
    // grok-4.3 stays flat even above 200k
    const old = pricing.priceFor("grok-4.3").?;
    try std.testing.expectEqual(@as(u64, 0), old.high_at);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), pricing.usdFor(old, 200_000, 0, 0), 1e-12);
}

test "xAI default model is grok-4.6 and is catalogued" {
    const spec = provider_mod.specFor("xai") orelse return error.MissingXaiSpec;
    try std.testing.expectEqualStrings("grok-4.6", spec.default_model);
    try std.testing.expect(pricing.providerModelInTable("xai", "grok-4.6"));
}

test "contextFor known model and default fallback" {
    try std.testing.expectEqual(@as(u64, 1_048_576), pricing.contextFor("kimi", "k3"));
    try std.testing.expectEqual(@as(u64, pricing.default_context), pricing.contextFor("nope", "unknown-xyz"));
}

test "Kimi discovery preserves Codex and chooses the newest pure generation" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "kimi", .name = "kimi-for-coding", .context = 262_144 },
        .{ .provider = "kimi", .name = "k2p7", .context = 262_144 },
        .{ .provider = "kimi", .name = "k3", .context = 1_048_576, .protocol = .anthropic, .supports_reasoning = true, .support_efforts = &.{"max"}, .default_effort = "max" },
    };
    try std.testing.expect(pricing.activateKimiModels(arena_state.allocator(), &discovered));
    try std.testing.expectEqualStrings("k3", pricing.providerDefaultModel("kimi", "fallback"));
    try std.testing.expectEqual(pricing.ModelProtocol.anthropic, pricing.kimiProtocol("k3"));
    try std.testing.expect(pricing.kimiSupportsThinking("k3"));
    try std.testing.expectEqualStrings("max", pricing.kimiThinkingEffort("k3", "medium").?);
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.6-sol"));
    try std.testing.expect(!pricing.providerModelInTable("kimi", "kimi-for-coding-highspeed"));
    const codex = [_]pricing.ModelInfo{.{ .provider = "codex", .name = "future-sol", .context = 270_000 }};
    try std.testing.expect(pricing.activateCodexModels(arena_state.allocator(), &codex));
    try std.testing.expect(pricing.providerModelInTable("kimi", "k3"));
}

test "Codex discovery replaces only the baked Codex fallback" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "codex", .name = "future-sol", .context = 372_000 },
        .{ .provider = "codex", .name = "future-luna", .context = 128_000 },
    };
    try std.testing.expect(pricing.activateCodexModels(arena_state.allocator(), &discovered));
    try std.testing.expect(pricing.providerModelInTable("codex", "future-sol"));
    try std.testing.expect(pricing.providerModelInTable("codex", "future-luna"));
    try std.testing.expect(!pricing.providerModelInTable("codex", "gpt-5.5"));
    try std.testing.expectEqual(pricing.codex_context_window, pricing.contextFor("codex", "future-sol"));
    try std.testing.expectEqualStrings("future-sol", pricing.providerDefaultModel("codex", "fallback"));
    try std.testing.expect(pricing.providerModelInTable("openai", "gpt-5.6"));
}

test "baked Codex catalog is an offline fallback, not rollout data" {
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.6-sol"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.6-terra"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.6-luna"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.5"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.4"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.3-codex-spark"));
    try std.testing.expectEqual(pricing.codex_context_window, pricing.contextFor("codex", "gpt-5.6-sol"));
    try std.testing.expectEqualStrings("gpt-5.6-sol", pricing.providerDefaultModel("codex", "fallback"));
    try std.testing.expect(!pricing.providerModelInTable("codex", "gpt-5.5-codex"));
    try std.testing.expect(!pricing.providerModelInTable("codex", "gpt-5-codex"));
    try std.testing.expect(pricing.providerModelInTable("openai", "gpt-5-codex"));
    try std.testing.expect(pricing.providerModelInTable("openai", "gpt-5.6"));
}

test "every built-in provider default_model is catalog-present for that provider" {
    for (provider_mod.provider_specs) |spec|
        try std.testing.expect(pricing.providerModelInTable(spec.id, spec.default_model));
}

test "refresh overlay augments price/context lookups (codex cap still applies)" {
    const saved_p = pricing.price_overlay;
    const saved_c = pricing.context_overlay;
    defer pricing.price_overlay = saved_p;
    defer pricing.context_overlay = saved_c;
    const po = [_]pricing.ModelPrice{.{ .name = "future-model-x", .in = 9, .out = 9, .cache = 1 }};
    const co = [_]pricing.ModelInfo{.{ .provider = "", .name = "future-model-x", .context = 999_000 }};
    pricing.price_overlay = &po;
    pricing.context_overlay = &co;
    try std.testing.expect(pricing.priceFor("future-model-x") != null);
    try std.testing.expectEqual(@as(u64, 999_000), pricing.contextFor("openai", "future-model-x"));
    try std.testing.expectEqual(pricing.codex_context_window, pricing.contextFor("codex", "future-model-x"));
}

test "Z.AI default is GLM-5.3 with official prices and a 1M window" {
    const spec = provider_mod.specFor("zai") orelse return error.MissingZaiSpec;
    try std.testing.expectEqualStrings("glm-5.3", spec.default_model);
    try std.testing.expect(spec.takes_effort);
    try std.testing.expectEqual(provider_mod.ProviderSpec.CatalogKind.openai, spec.catalog);
    try std.testing.expectEqualStrings("https://api.z.ai/api/paas/v4/models", spec.models_url);
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-5.3"));
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-5-turbo"));
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-5v-turbo"));
    try std.testing.expectEqual(@as(u64, 1_000_000), pricing.contextFor("zai", "glm-5.3"));
    const p = pricing.priceFor("glm-5.3") orelse return error.MissingGlm53Price;
    try std.testing.expectEqual(@as(f64, 1.4), p.in);
    try std.testing.expectEqual(@as(f64, 4.4), p.out);
    try std.testing.expectEqual(@as(f64, 0.26), p.cache);
}
