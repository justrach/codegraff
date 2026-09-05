//! Tests split off provider.zig so the spec table can grow under 600 LOC.

const std = @import("std");
const provider_mod = @import("provider.zig");
const pricing = @import("pricing.zig");

const Keys = provider_mod.Keys;
const Provider = provider_mod.Provider;
const provider_specs = provider_mod.provider_specs;

test "Keys.build: g_codex_url_override rewires only the codex endpoint" {
    const all = Keys{ .values = @splat("k") };
    provider_mod.g_codex_url_override = "http://127.0.0.1:8765/responses";
    defer provider_mod.g_codex_url_override = null;
    const codex = try all.providerById("codex", "gpt-5.6-sol");
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/responses", codex.url);
    const anthropic = try all.providerById("anthropic", "claude-opus-4-8");
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic.url);
}

test "Keys.build: Kimi follows the live model protocol and auth style" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = [_]pricing.ModelInfo{
        .{ .provider = "kimi", .name = "native", .context = 1, .protocol = .kimi },
        .{ .provider = "kimi", .name = "messages", .context = 1, .protocol = .anthropic },
    };
    try std.testing.expect(pricing.activateKimiModels(arena_state.allocator(), &rows));
    var keys = Keys{ .values = @splat(null) };
    for (provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "kimi")) keys.values[i] = "token";
    }
    const native = try keys.providerById("kimi", "native");
    try std.testing.expectEqual(Provider.Kind.openai, native.kind);
    try std.testing.expectEqual(Provider.Auth.bearer, native.auth);
    try std.testing.expectEqualStrings(provider_mod.kimi_native_url, native.url);
    const messages = try keys.providerById("kimi", "messages");
    try std.testing.expectEqual(Provider.Kind.anthropic, messages.kind);
    try std.testing.expectEqual(Provider.Auth.x_api_key, messages.auth);
    try std.testing.expectEqualStrings(provider_mod.kimi_anthropic_url, messages.url);
}

test "perOutputCap (#201): window-proportional with an absolute ceiling, keep_recent-safe" {
    var p: Provider = undefined;
    p.context = 270_000;
    try std.testing.expectEqual(@as(usize, 40 * 1024), p.perOutputCap());
    try std.testing.expect(4 * (p.perOutputCap() / 4) < p.context);
    p.context = 4_000_000;
    try std.testing.expectEqual(@as(usize, 40 * 1024), p.perOutputCap());
    p.context = 0;
    try std.testing.expectEqual(@as(usize, 0), p.perOutputCap());
}

test "compactAt (#204): GRAFF_COMPACT_PCT overrides the 80% default, both directions" {
    var p: Provider = undefined;
    p.context = 100_000;
    try std.testing.expectEqual(@as(u64, 80_000), p.compactAt());
    provider_mod.g_compact_pct_override = 70;
    defer provider_mod.g_compact_pct_override = null;
    try std.testing.expectEqual(@as(u64, 70_000), p.compactAt());
    provider_mod.g_compact_pct_override = 95;
    try std.testing.expectEqual(@as(u64, 95_000), p.compactAt());
}

test "gemini routes to google, not the gateway, and carries the real 1M window" {
    const all = Keys{ .values = @splat("k") };
    // Before the google row existed, gemini-* was uncatalogued: providerFor fell
    // through to the codegraff gateway and contextFor returned default_context,
    // so a 1,048,576-token model auto-compacted at 160k instead of 838k.
    const gemini = try all.providerFor("gemini-3.8-flash");
    try std.testing.expectEqualStrings("google", gemini.id);
    try std.testing.expectEqual(@as(u64, 1_048_576), gemini.context);
    try std.testing.expect(gemini.compactAt() > 800_000);
    // Gemini talks Google's first-party Interactions wire, not the OpenAI
    // compatibility shim, and authenticates with x-goog-api-key.
    try std.testing.expectEqual(Provider.Kind.interactions, gemini.kind);
    try std.testing.expectEqual(Provider.Auth.goog_api_key, gemini.auth);

    // With no GEMINI_API_KEY the model is catalogued but unkeyed, which #294
    // says must fail loudly rather than silently bill the gateway.
    var keyless = Keys{ .values = @splat(null) };
    for (provider_specs, 0..) |spec, i| {
        if (!std.mem.eql(u8, spec.id, "google")) keyless.values[i] = "k";
    }
    try std.testing.expectError(error.MissingKey, keyless.providerFor("gemini-3.8-flash"));
}

test "Keys.build: GRAFF_VERCEL_URL rewires only the Vercel endpoint" {
    const all = Keys{ .values = @splat("k") };
    provider_mod.g_vercel_url_override = provider_mod.vercel_v1_url;
    defer provider_mod.g_vercel_url_override = null;
    const vercel = try all.providerById("vercel", "alibaba/qwen3.8-27b");
    try std.testing.expectEqualStrings(provider_mod.vercel_v1_url, vercel.url);
    const zai = try all.providerById("zai", "glm-5.3");
    try std.testing.expectEqualStrings("https://api.z.ai/api/paas/v4/chat/completions", zai.url);
}
