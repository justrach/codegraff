//! The tests for router_catalog.zig, split into a sibling under the 600-line
//! ceiling (the same `*_tests.zig` shape engine_sink/providers already use).
//! They drive the real parser, cache document, and auth headers — nothing
//! here is a mock of the thing under test.

const std = @import("std");
const Value = std.json.Value;

const provider = @import("provider.zig");
const pricing = @import("pricing.zig");
const rc = @import("router_catalog.zig");

const parseModels = rc.parseModels;
const modelsUrl = rc.modelsUrl;
const dynamic = rc.dynamic;
const alwaysLive = rc.alwaysLive;
const catalogHeaders = rc.catalogHeaders;
const cacheDocument = rc.cacheDocument;
const pageUrl = rc.pageUrl;
const activate = rc.activate;

test "OpenAI catalog configuration carries its models endpoint" {
    const spec = provider.specFor("codegraff") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(provider.ProviderSpec.CatalogKind.openai, spec.catalog);
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/models", modelsUrl(spec));
    for (provider.provider_specs) |candidate| {
        if (candidate.catalog != .openai) continue;
        try std.testing.expect(candidate.kind == .openai);
        try std.testing.expect(candidate.models_url.len != 0);
    }
}

test "parseModels reads Vercel context_window and skips non-language types" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "vercel",
        \\{"object":"list","data":[
        \\ {"id":"alibaba/qwen3.8-27b","context_window":1000000,"type":"language","supported_parameters":["reasoning","tools"]},
        \\ {"id":"alibaba/wan-video","context_window":0,"type":"video"},
        \\ {"id":"openai/text-embedding-3-large","type":"embedding"},
        \\ {"id":"no-window","type":"language"}
        \\]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqualStrings("alibaba/qwen3.8-27b", snapshot.models[0].name);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expect(snapshot.models[0].supports_reasoning);
    try std.testing.expectEqualStrings("no-window", snapshot.models[1].name);
    try std.testing.expectEqual(pricing.default_context, snapshot.models[1].context);
}

test "parseModels reads OpenRouter context_length and include_reasoning" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "openrouter",
        \\{"data":[
        \\ {"id":"anthropic/claude-sonnet-4.6","context_length":1000000,"supported_parameters":["tools","include_reasoning"]},
        \\ {"id":"openai/gpt-oss:free","context_length":131072}
        \\]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4.6", snapshot.models[0].name);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expect(snapshot.models[0].supports_reasoning);
    try std.testing.expectEqualStrings("openai/gpt-oss:free", snapshot.models[1].name);
    try std.testing.expect(!snapshot.models[1].supports_reasoning);
}

test "parseModels is reusable for a newly configured router" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "new-router",
        \\{"object":"list","data":[
        \\ {"id":"glm-5.2","context_length":1000000,"supported_parameters":["reasoning","tools"]},
        \\ {"id":"openai/gpt-oss:free","context_length":131072},
        \\ {"id":"no-window"},
        \\ {"id":"glm-5.2","context_length":128000},
        \\ {"id":"bad id!","context_length":999}
        \\]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), snapshot.models.len);
    try std.testing.expectEqualStrings("new-router", snapshot.models[0].provider);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expect(snapshot.models[0].supports_reasoning);
    try std.testing.expectEqualStrings("openai/gpt-oss:free", snapshot.models[1].name);
    try std.testing.expectEqual(pricing.default_context, snapshot.models[2].context);
}

test "fireworks catalog is live and parses the AIP gateway shape" {
    const spec = provider.specFor("fireworks") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(provider.ProviderSpec.CatalogKind.openai, spec.catalog);
    try std.testing.expect(std.mem.indexOf(u8, modelsUrl(spec), "accounts/fireworks/models") != null);

    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "fireworks",
        \\{"models":[
        \\ {"name":"accounts/fireworks/models/glm-5p2","displayName":"GLM 5.2","contextLength":1048576},
        \\ {"name":"accounts/fireworks/models/no-window"},
        \\ {"name":"accounts/fireworks/models/glm-5p2","contextLength":128000}
        \\],"nextPageToken":"tok-page-2","totalSize":3}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len); // the duplicate id drops
    try std.testing.expectEqualStrings("accounts/fireworks/models/glm-5p2", snapshot.models[0].name);
    try std.testing.expectEqual(@as(u64, 1_048_576), snapshot.models[0].context); // camelCase contextLength read
    try std.testing.expectEqual(pricing.default_context, snapshot.models[1].context); // omitted + no baked match → default
    try std.testing.expect(snapshot.has_more);
    try std.testing.expectEqualStrings("tok-page-2", snapshot.page_token.?);

    // The walk spells the cursor the gateway's way, not Anthropic's.
    const url = pageUrl(state.allocator(), modelsUrl(spec), .{ .page_token = "tok-page-2" }).?;
    try std.testing.expect(std.mem.indexOf(u8, url, "&pageToken=tok-page-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "after_id") == null);
}

test "parseModels round-trips the generic cache shape" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const snapshot = parseModels(state.allocator(), "router",
        \\{"fetched_at_ms":1700000000000,
        \\ "models":[{"name":"minimax-m3","context":1000000,"supports_reasoning":true}]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), snapshot.fetched_at_ms);
    try std.testing.expectEqualStrings("router", snapshot.models[0].provider);
    try std.testing.expect(snapshot.models[0].supports_reasoning);
}

test "cache document serializes every model name as valid JSON" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const spec = provider.specFor("codegraff") orelse return error.TestUnexpectedResult;
    const models = [_]pricing.ModelInfo{
        .{ .provider = spec.id, .name = "first", .context = 128_000 },
        .{ .provider = spec.id, .name = "quote\"model", .context = 256_000, .supports_reasoning = true },
    };
    const document = cacheDocument(std.testing.io, arena, spec, &models) orelse
        return error.TestUnexpectedResult;
    const value = try std.json.parseFromSliceLeaky(Value, arena, document, .{});
    const cached_models = value.object.get("models") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), cached_models.array.items.len);
    const second = cached_models.array.items[1].object;
    try std.testing.expectEqualStrings("quote\"model", second.get("name").?.string);
    try std.testing.expect(second.get("supports_reasoning").?.bool);
}

test "Anthropic catalog is live and authenticates like Messages" {
    const spec = provider.specFor("anthropic") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(provider.ProviderSpec.CatalogKind.anthropic, spec.catalog);
    try std.testing.expect(dynamic(spec));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/models?limit=1000", modelsUrl(spec));
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [4]std.http.Header = undefined;
    const headers = catalogHeaders(state.allocator(), spec, "sk-test", .none, &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("x-api-key", headers[1].name);
    try std.testing.expectEqualStrings("sk-test", headers[1].value);
    try std.testing.expectEqualStrings("anthropic-version", headers[2].name);
    // Bearer routers are unchanged by the x-api-key branch.
    const router = provider.specFor("codegraff") orelse return error.TestUnexpectedResult;
    const bearer = catalogHeaders(state.allocator(), router, "key", .none, &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), bearer.len);
    try std.testing.expectEqualStrings("Authorization", bearer[1].name);
}

test "xAI catalog is live (grok-build parity: fetch /v1/models, never a baked-only list)" {
    const spec = provider.specFor("xai") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(provider.ProviderSpec.CatalogKind.openai, spec.catalog);
    try std.testing.expect(dynamic(spec));
    try std.testing.expect(alwaysLive(spec));
    try std.testing.expectEqualStrings("https://api.x.ai/v1/models", modelsUrl(spec));
    // API-key catalog GET: plain bearer. OAuth login: + X-XAI-Token-Auth.
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [4]std.http.Header = undefined;
    const headers = catalogHeaders(state.allocator(), spec, "xai-test", .environment, &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Authorization", headers[1].name);
    try std.testing.expectEqualStrings("Bearer xai-test", headers[1].value);
    const login_headers = catalogHeaders(state.allocator(), spec, "oauth-tok", .login, &buf) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), login_headers.len);
    try std.testing.expectEqualStrings("X-XAI-Token-Auth", login_headers[2].name);
    try std.testing.expectEqualStrings("xai-grok-cli", login_headers[2].value);
}

test "alwaysLive is xAI-only so other OpenAI routers keep the disk TTL" {
    try std.testing.expect(alwaysLive(provider.specFor("xai").?));
    try std.testing.expect(!alwaysLive(provider.specFor("codegraff").?));
    try std.testing.expect(!alwaysLive(provider.specFor("anthropic").?));
    try std.testing.expect(!alwaysLive(provider.specFor("fireworks").?));
    try std.testing.expectEqual(@as(i64, 500), rc.live_budget_ms);
}

test "xAI /v1/models rows inherit baked context windows" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    // xAI's list is the plain OpenAI shape (id only): a known id keeps its
    // baked window, a suffixed rollout of a known family inherits at the '-'
    // boundary, and an unknown family takes the conservative default.
    const snapshot = parseModels(state.allocator(), "xai",
        \\{"object":"list","data":[
        \\ {"id":"grok-4.3","object":"model","created":1,"owned_by":"xai"},
        \\ {"id":"grok-4.3-fast","object":"model","created":1,"owned_by":"xai"},
        \\ {"id":"grok-nova-9","object":"model","created":1,"owned_by":"xai"}
        \\]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), snapshot.models.len);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[1].context);
    try std.testing.expectEqual(pricing.default_context, snapshot.models[2].context);
}

test "Anthropic /v1/models rows inherit baked context windows" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    // A row declaring max_input_tokens uses it as the window — and never its
    // sibling max_tokens, which is the OUTPUT cap (128k on Opus 5). A row
    // without limits takes its alias family's baked window; an unknown family
    // falls back to the conservative default.
    const snapshot = parseModels(state.allocator(), "anthropic",
        \\{"data":[
        \\ {"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5",
        \\  "max_input_tokens":1000000,"max_tokens":128000},
        \\ {"type":"model","id":"claude-opus-4-8-20260115","display_name":"Claude Opus 4.8"},
        \\ {"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"},
        \\ {"type":"model","id":"claude-nova-9","display_name":"Claude Nova 9"}
        \\],"has_more":false}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), snapshot.models.len);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[0].context);
    try std.testing.expectEqual(@as(u64, 1_000_000), snapshot.models[1].context);
    try std.testing.expectEqual(@as(u64, 200_000), snapshot.models[2].context);
    try std.testing.expectEqual(pricing.default_context, snapshot.models[3].context);
}

test "Anthropic discovery keeps the active slice 1:1 with the live list" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const spec = provider.specFor("anthropic") orelse return error.TestUnexpectedResult;
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "anthropic", .name = "claude-opus-5", .context = 1_000_000 },
        .{ .provider = "anthropic", .name = "claude-opus-4-8", .context = 1_000_000 },
    };
    try std.testing.expect(activate(state.allocator(), spec, &discovered));
    // Exactly the live rows — a baked row the API no longer lists is gone,
    // so the picker shows the official catalog and nothing else.
    var count: usize = 0;
    for (pricing.models()) |m| {
        if (std.mem.eql(u8, m.provider, "anthropic")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(pricing.providerModelInTable("anthropic", "claude-opus-5"));
    try std.testing.expect(!pricing.providerModelInTable("anthropic", "claude-sonnet-4-5"));
    try std.testing.expectEqual(@as(u64, 1_000_000), pricing.contextFor("anthropic", "claude-opus-5"));
    // Other providers' slices are untouched.
    try std.testing.expect(pricing.providerModelInTable("codegraff", "claude-opus-4.8"));
}

test "Models-API cursor pagination is followed 1:1 with the docs" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    // parseModels surfaces the after_id/has_more/last_id scheme (the Models
    // API does NOT use page/next_page — see "API overview → Pagination").
    const page = parseModels(arena, "anthropic",
        \\{"data":[{"type":"model","id":"claude-opus-5","max_input_tokens":1000000,"max_tokens":128000}],
        \\ "has_more":true,"first_id":"claude-opus-5","last_id":"claude-opus-5"}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(page.has_more);
    try std.testing.expectEqualStrings("claude-opus-5", page.last_id orelse return error.TestUnexpectedResult);
    // A final page reports has_more:false; the cache shape carries neither.
    const last = parseModels(arena, "anthropic",
        \\{"data":[{"id":"claude-haiku-4-5"}],"has_more":false,"last_id":"claude-haiku-4-5"}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!last.has_more);
    const cache = parseModels(arena, "anthropic",
        \\{"fetched_at_ms":1,"models":[{"name":"claude-opus-5","context":1000000}]}
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!cache.has_more);
    try std.testing.expect(cache.last_id == null);
    // after_id joins the base URL's existing query string.
    try std.testing.expectEqualStrings(
        "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5",
        pageUrl(arena, "https://api.anthropic.com/v1/models?limit=1000", .{ .after_id = "claude-opus-5" }) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/models?after_id=m1",
        pageUrl(arena, "https://example.com/models", .{ .after_id = "m1" }) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings("base", pageUrl(arena, "base", null) orelse return error.TestUnexpectedResult);
}

test "router discovery replaces only its provider slice" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const discovered = [_]pricing.ModelInfo{
        .{ .provider = "codegraff", .name = "kimi-k3", .context = 1_048_576 },
    };
    try std.testing.expect(pricing.activateProviderModels(state.allocator(), "codegraff", &discovered));
    try std.testing.expect(pricing.providerModelInTable("codegraff", "kimi-k3"));
    try std.testing.expect(!pricing.providerModelInTable("codegraff", "claude-opus-4.8"));
    try std.testing.expect(pricing.providerModelInTable("anthropic", "claude-opus-4-8"));
    try std.testing.expect(pricing.providerModelInTable("codex", "gpt-5.6-sol"));
}

test "startup catalog loads fan out concurrently with Kimi" {
    const src = @embedFile("router_catalog.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "io.concurrent(fetchSpecTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "io.concurrent(kimiFetchTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn spawnKimi") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "startBackgroundRefresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "live_budget_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (alwaysLive(spec)) return false") == null);
}

// ── provider.zig routing tests parked here under its 600-line ceiling ──────

test "providerFor (#377): family-prefixed spelling routes to the direct provider, not the gateway" {
    // kimi's catalog row is `k3`; gateways catalog the same model as `kimi-k3`.
    // The prefixed spelling must seat the keyed direct provider on its NATIVE
    // name — before this fix it fell through to the codegraff gateway and a
    // flat-rate subscription silently became metered/licensed usage.
    const Keys = provider.Keys;
    const all = Keys{ .values = @splat("k") };
    try std.testing.expectEqualStrings("moonshot", (try all.providerFor("kimi-k3")).id);
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    pricing.active_model_table = &.{
        .{ .provider = "kimi", .name = "k3", .context = 1_048_576 },
        .{ .provider = "codex", .name = "gpt-5.6-sol", .context = 272_000 },
    };
    const p = try all.providerFor("kimi-k3");
    try std.testing.expectEqualStrings("kimi", p.id);
    try std.testing.expectEqualStrings("k3", p.model);
    // Exact catalog names keep absolute priority over the family alias.
    try std.testing.expectEqualStrings("gpt-5.6-sol", (try all.providerFor("gpt-5.6-sol")).model);
    // Without the kimi credential the prefixed spelling behaves exactly as
    // before: uncatalogued in this fixture, so the gateway fallback.
    var values: [provider.provider_specs.len]?[]const u8 = @splat("k");
    for (provider.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "kimi")) values[i] = null;
    }
    const no_kimi = Keys{ .values = values };
    try std.testing.expectEqualStrings("codegraff", (try no_kimi.providerFor("kimi-k3")).id);
}

test "xAI defaults to the Responses wire; GRAFF_XAI_WIRE=chat opts out (#502)" {
    const Keys = provider.Keys;
    const Provider = provider.Provider;
    const all = Keys{ .values = @splat("k") };
    const saved = provider.g_xai_responses;
    defer provider.g_xai_responses = saved;
    // The compiled-in default IS the responses wire — a regression here means
    // grok silently loses server compaction, WS turns, and structured outputs.
    try std.testing.expect(provider.g_xai_responses);
    // GRAFF_XAI_WIRE=chat (any non-"responses" value) restores chat completions.
    provider.g_xai_responses = false;
    const chat = try all.providerById("xai", "grok-4.3");
    try std.testing.expectEqual(Provider.Kind.openai, chat.kind);
    try std.testing.expect(chat.serverCompactUrl() == null); // chat wire: no blob replay path
    provider.g_xai_responses = true;
    const resp = try all.providerById("xai", "grok-4.3");
    try std.testing.expectEqual(Provider.Kind.responses, resp.kind);
    try std.testing.expectEqualStrings(provider.xai_responses_url, resp.url);
    try std.testing.expectEqualStrings(provider.xai_compact_url, resp.serverCompactUrl().?);
    // withModel keeps the wire choice.
    const moved = resp.withModel("grok-4.6");
    try std.testing.expectEqual(Provider.Kind.responses, moved.kind);
    try std.testing.expectEqualStrings(provider.xai_responses_url, moved.url);
    // codex keeps in-stream compaction — never the explicit endpoint.
    const codex = try all.providerById("codex", "gpt-5.6-sol");
    try std.testing.expect(codex.serverCompactUrl() == null);
    // every other provider is untouched by the knob: openai keeps its native
    // Responses wire (default since v0.0.250) and its own endpoint.
    const oai = try all.providerById("openai", "gpt-5.6");
    try std.testing.expectEqual(Provider.Kind.responses, oai.kind);
    try std.testing.expect(std.mem.indexOf(u8, oai.url, "api.openai.com") != null);
}
