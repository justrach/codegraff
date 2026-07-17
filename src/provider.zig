//! The provider/keys core: wire format + auth style + endpoint per provider
//! (ProviderSpec/provider_specs), the resolved Provider a request is sent
//! with (model, context window, api key), and Keys — one optional API key
//! per provider_specs entry, read from the environment, with the routing
//! logic (providerFor/providerById/defaultProvider) that picks a Provider
//! for a model name. Split out of main.zig (600-line goal). Re-exported
//! (`pub const Provider = provider.Provider;` etc.) so the ~everywhere
//! `main_mod.Provider`/`main_mod.Keys`/`main_mod.provider_specs`
//! back-imports across the other split files keep resolving unchanged.
//! Only needs pricing.zig (contextFor/models) for Keys.build/providerFor.

const std = @import("std");

const pricing = @import("pricing.zig");
const contextFor = pricing.contextFor;

/// #203: declare the context window (tokens) for an unknown/local model whose real
/// window graff cannot look up, replacing the conservative default. Applied only
/// when contextFor falls back to default_context (see contextWindowFor) so it can
/// never shrink a known/catalogued window. Set from GRAFF_CONTEXT / GRAFF_CONTEXT_WINDOW.
pub var g_context_override: ?u64 = null;

/// #204: override the auto-compaction threshold as a percent of the window
/// (default 80). null → 80. Unlike codex we allow lowering AND raising (1..100).
pub var g_compact_pct_override: ?u8 = null;

/// The context window for a provider+model, honoring g_context_override for an
/// unknown/local model — i.e. only when contextFor returns the conservative default,
/// never overriding a known window (#203).
fn contextWindowFor(provider_id: []const u8, model: []const u8) u64 {
    // Only an unknown/local model (no catalogued window) takes the override, so a
    // global GRAFF_CONTEXT can never shrink a known model that happens to be 200k.
    if (g_context_override) |ov| if (!pricing.isKnownModel(provider_id, model)) return ov;
    return contextFor(provider_id, model);
}

/// Wire format + auth style + endpoint per provider. Base URLs and env-var
/// names from models.dev/api.json (snapshot 2026-06-10); the anthropic and
/// openai bases are the canonical ones (models.dev lists them as null).
/// minimax serves the Anthropic Messages format with bearer auth. Order is
/// the default-provider priority at startup, and the tiebreak when one model
/// name is served by several providers.
const ProviderSpec = struct {
    id: []const u8,
    kind: Provider.Kind, // wire format
    auth: Provider.Auth, // header style
    url: []const u8,
    env_key: []const u8,
    default_model: []const u8,
};

pub const provider_specs = [_]ProviderSpec{
    .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "https://api.anthropic.com/v1/messages", .env_key = "ANTHROPIC_API_KEY", .default_model = "claude-opus-4-8" },
    .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "https://gateway.codegraff.com/v1/chat/completions", .env_key = "CODEGRAFF_API_KEY", .default_model = "deepseek-v4-pro" },
    .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "https://api.deepseek.com/chat/completions", .env_key = "DEEPSEEK_API_KEY", .default_model = "deepseek-v4-pro" },
    .{ .id = "openai", .kind = .openai, .auth = .bearer, .url = "https://api.openai.com/v1/chat/completions", .env_key = "OPENAI_API_KEY", .default_model = "gpt-5.6" },
    .{ .id = "minimax", .kind = .anthropic, .auth = .bearer, .url = "https://api.minimax.io/anthropic/v1/messages", .env_key = "MINIMAX_API_KEY", .default_model = "MiniMax-M3" },
    .{ .id = "xiaomi", .kind = .openai, .auth = .bearer, .url = "https://api.xiaomimimo.com/v1/chat/completions", .env_key = "XIAOMI_API_KEY", .default_model = "mimo-v2.5-pro" },
    // Kimi Code publishes the protocol per model. Missing/`kimi` is the native
    // chat-completions wire; a live `protocol: anthropic` row is switched in
    // Keys.build to the beta Messages endpoint + x-api-key, matching kimi-code.
    .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = kimi_native_url, .env_key = "KIMI_API_KEY", .default_model = "k3" },
    // moonshot: the regular Kimi Open Platform (pay-as-you-go API key, not the
    // Coding plan). OpenAI-compatible; .cn host for China. kimi-latest tracks
    // the newest Kimi. Same /v1/models discovery applies if wired later.
    .{ .id = "moonshot", .kind = .openai, .auth = .bearer, .url = "https://api.moonshot.ai/v1/chat/completions", .env_key = "MOONSHOT_API_KEY", .default_model = "kimi-latest" },
    .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "https://api.x.ai/v1/chat/completions", .env_key = "XAI_API_KEY", .default_model = "grok-4.3" },
    .{ .id = "zai", .kind = .openai, .auth = .bearer, .url = "https://api.z.ai/api/paas/v4/chat/completions", .env_key = "ZAI_API_KEY", .default_model = "glm-5.2" },
    .{ .id = "fugu", .kind = .openai, .auth = .bearer, .url = "https://api.sakana.ai/v1/chat/completions", .env_key = "FUGU_API_KEY", .default_model = "fugu-ultra" },
    .{ .id = "fireworks", .kind = .openai, .auth = .bearer, .url = "https://api.fireworks.ai/inference/v1/chat/completions", .env_key = "FIREWORKS_API_KEY", .default_model = "accounts/fireworks/models/deepseek-v4-pro" },
    // mlx: a local model served by mlx-lm (`mlx_lm.server`) on Apple Silicon —
    // OpenAI-compatible, no real key (MLX_API_KEY=local just clears graff's boot gate).
    .{ .id = "mlx", .kind = .openai, .auth = .bearer, .url = "http://127.0.0.1:8080/v1/chat/completions", .env_key = "MLX_API_KEY", .default_model = "mlx-community/Qwen3.6-27B-OptiQ-4bit" },
    // lm-studio: the LM Studio app's local OpenAI-compatible server (default :1234).
    // Load a model in LM Studio, then `LMSTUDIO_API_KEY=local graff --model lmstudio`.
    .{ .id = "lmstudio", .kind = .openai, .auth = .bearer, .url = "http://127.0.0.1:1234/v1/chat/completions", .env_key = "LMSTUDIO_API_KEY", .default_model = "lmstudio" },
    // codex: ChatGPT login via the Responses API. Its "key" isn't an env var
    // — it's the OAuth access token read from CODEX_HOME/auth.json at startup
    // (see loadCodexAuth), the same on-disk-credential trick used for the
    // codegraff gateway key in ~/forge/.credentials.json.
    .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://chatgpt.com/backend-api/codex/responses", .env_key = "CODEX_DISABLED", .default_model = "gpt-5.6-sol" },
};

pub const kimi_native_url = "https://api.kimi.com/coding/v1/chat/completions";
pub const kimi_anthropic_url = "https://api.kimi.com/coding/v1/messages?beta=true";

/// Codex responses-endpoint override (GRAFF_CODEX_URL, parsed in main.zig at
/// startup — localhost mocks / integration tests). Lives here because every
/// provider (re)build path (startup, /model switches, session restore) goes
/// through Keys.build; both the WS and SSE transports read provider.url.
pub var g_codex_url_override: ?[]const u8 = null;

pub const Provider = struct {
    id: []const u8,
    kind: Kind,
    auth: Auth,
    url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context: u64,
    account: []const u8 = "", // ChatGPT account id, codex/responses only
    source: Keys.CredentialSource = .none, // #148: how api_key was obtained — only .login tokens auto-refresh

    // Wire format. `responses` is the OpenAI Responses API as served by the
    // ChatGPT backend (Codex login) — input items, not chat messages.
    pub const Kind = enum { anthropic, openai, responses };
    pub const Auth = enum { x_api_key, bearer };

    /// Auto-compact past a percentage (default 80%) of the model's context window.
    /// GRAFF_COMPACT_PCT overrides the percentage, clamped to 1..100 (#204). Unlike
    /// codex's one-directional clamp, the override may lower OR raise the threshold.
    pub fn compactAt(p: Provider) u64 {
        const pct: u64 = if (g_compact_pct_override) |o| @min(o, 100) else 80;
        return p.context / 100 * pct;
    }

    /// Whether a failed compaction may safely fall back to destructive trimming.
    /// Keep this stricter than compactAt(): at 80-95% a transient summary failure
    /// should leave history intact and retry later. Subtraction avoids overflow for
    /// provider-controlled token counts near u64.max.
    pub fn nearContextLimit(p: Provider, tokens: u64) bool {
        if (p.context == 0) return false;
        return tokens >= p.context - (p.context / 20); // 95%
    }

    /// #201: absolute ceiling for a single tool output regardless of window size,
    /// so a huge-context model still bounds one pathological result.
    const abs_output_cap_bytes: usize = 256 * 1024;

    /// #193 follow-up / #201: the largest a SINGLE tool output may be, in serialized
    /// bytes, before it is truncated at send time (capOversizedToolOutputs). It must
    /// stay small enough that `keep_recent` (=4) such outputs — which
    /// trimOldestToolOutputs keeps VERBATIM during in-turn recovery — still leave
    /// room for the trimmed remainder + system prompt to fit on retry. At the old
    /// `context * 2` (~50% of the window each) four recent outputs pinned ~2x the
    /// window, past what recovery could reclaim → wedge (#201). Now window-proportional
    /// at ~1/8 of the window in estimated tokens (context/2 bytes at ~4 bytes/token),
    /// so 4 recent outputs occupy ~50% of the window, plus an absolute ceiling for
    /// very large windows. Large-context models still keep normal tool results
    /// untouched; only a result big enough to threaten the window is bounded.
    /// 0 (unknown window) disables the cap.
    pub fn perOutputCap(p: Provider) usize {
        if (p.context == 0) return 0;
        const proportional: usize = @intCast(p.context / 2);
        return @min(proportional, abs_output_cap_bytes);
    }
};

/// One optional API key per provider_specs entry, read from the environment.
pub const Keys = struct {
    pub const CredentialSource = enum {
        none,
        environment,
        login,
        stored,
        session,

        pub fn label(self: CredentialSource) []const u8 {
            return switch (self) {
                .none => "missing",
                .environment => "environment",
                .login => "OAuth/login",
                .stored => "secure store",
                .session => "this session",
            };
        }
    };

    values: [provider_specs.len]?[]const u8,
    sources: [provider_specs.len]CredentialSource = [_]CredentialSource{.none} ** provider_specs.len,
    codex_account: []const u8 = "", // ChatGPT account id for the codex provider

    pub fn get(keys: Keys, provider_id: []const u8) ?[]const u8 {
        for (provider_specs, keys.values) |spec, value| {
            if (std.mem.eql(u8, spec.id, provider_id)) return value;
        }
        return null;
    }

    pub fn source(keys: Keys, provider_id: []const u8) CredentialSource {
        for (provider_specs, keys.sources) |spec, source_value| {
            if (std.mem.eql(u8, spec.id, provider_id)) return source_value;
        }
        return .none;
    }

    pub fn build(keys: Keys, spec: ProviderSpec, key: []const u8, model: []const u8) Provider {
        const is_codex = std.mem.eql(u8, spec.id, "codex");
        const is_kimi_anthropic = std.mem.eql(u8, spec.id, "kimi") and pricing.kimiProtocol(model) == .anthropic;
        return .{
            .id = spec.id,
            .kind = if (is_kimi_anthropic) .anthropic else spec.kind,
            .auth = if (is_kimi_anthropic) .x_api_key else spec.auth,
            .url = if (is_kimi_anthropic) kimi_anthropic_url else if (is_codex) g_codex_url_override orelse spec.url else spec.url,
            .api_key = key,
            .model = model,
            .context = contextWindowFor(spec.id, model),
            .account = if (is_codex) keys.codex_account else "",
            .source = keys.source(spec.id),
        };
    }

    /// Route a model to a provider: first active catalog row whose provider has
    /// a key wins (spec order breaks ties). Unknown claude* models go to
    /// Anthropic; any other unknown model goes to the codegraff gateway.
    pub fn providerFor(keys: Keys, model: []const u8) error{MissingKey}!Provider {
        // Prefer a direct provider the user keyed over the codegraff gateway: the
        // gateway proxies almost every model, so a low gateway balance would
        // otherwise block models the user can serve with their own key. Pass 1
        // skips the gateway (direct keys win); pass 2 lets it back in as fallback.
        for ([_]bool{ false, true }) |allow_gateway| {
            for (provider_specs, keys.values) |spec, value| {
                const key = value orelse continue;
                if (std.mem.eql(u8, spec.id, "codegraff") != allow_gateway) continue;
                for (pricing.models()) |m| {
                    if (std.mem.eql(u8, m.provider, spec.id) and std.mem.eql(u8, m.name, model))
                        return keys.build(spec, key, model);
                }
            }
        }
        const fallback_id: []const u8 = if (std.mem.startsWith(u8, model, "claude")) "anthropic" else "codegraff";
        for (provider_specs, keys.values) |spec, value| {
            if (!std.mem.eql(u8, spec.id, fallback_id)) continue;
            const key = value orelse break;
            return keys.build(spec, key, model);
        }
        return error.MissingKey;
    }

    /// The startup default: the first provider (in spec order) with a key,
    /// on its default model.
    pub fn defaultProvider(keys: Keys) error{MissingKey}!Provider {
        for (provider_specs, keys.values) |spec, value| {
            const key = value orelse continue;
            return keys.build(spec, key, pricing.providerDefaultModel(spec.id, spec.default_model));
        }
        return error.MissingKey;
    }

    /// Rebuild a provider from a saved session's (id, model). Falls back to
    /// model-based routing if the id is unknown.
    pub fn providerById(keys: Keys, id: []const u8, model: []const u8) error{MissingKey}!Provider {
        for (provider_specs, keys.values) |spec, value| {
            if (!std.mem.eql(u8, spec.id, id)) continue;
            const key = value orelse return error.MissingKey;
            return keys.build(spec, key, model);
        }
        return keys.providerFor(model);
    }
};

test "Provider.compactAt: auto-compacts at 80% of the context window (long-horizon trigger)" {
    const big = Provider{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 1_000_000 };
    try std.testing.expectEqual(@as(u64, 800_000), big.compactAt());
    const small = Provider{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 200_000 };
    try std.testing.expectEqual(@as(u64, 160_000), small.compactAt());
    const zero = Provider{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "m", .context = 0 };
    try std.testing.expectEqual(@as(u64, 0), zero.compactAt());
}

test "Provider.nearContextLimit: destructive recovery starts at 95% without overflow math" {
    const p: Provider = .{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "x", .context = 100_000 };
    try std.testing.expect(!p.nearContextLimit(94_999));
    try std.testing.expect(p.nearContextLimit(95_000));
    try std.testing.expect(p.nearContextLimit(std.math.maxInt(u64)));
    var unknown = p;
    unknown.context = 0;
    try std.testing.expect(!unknown.nearContextLimit(std.math.maxInt(u64)));
}

test "Keys.providerFor: known model, claude/gateway fallbacks, missing key" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const none = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expectEqualStrings("anthropic", (try all.providerFor("claude-does-not-exist")).id);
    try std.testing.expectEqualStrings("codegraff", (try all.providerFor("totally-made-up-model")).id);
    try std.testing.expectEqualStrings("gpt-5.5", (try all.providerFor("gpt-5.5")).model);
    try std.testing.expectError(error.MissingKey, none.providerFor("claude-opus-4-8"));
}

test "Keys.providerById: exact id wins, unknown id falls back to model routing" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const p = try all.providerById("anthropic", "claude-opus-4-8");
    try std.testing.expectEqualStrings("anthropic", p.id);
    try std.testing.expectEqualStrings("claude-opus-4-8", p.model);
    const fb = try all.providerById("no-such-provider", "gpt-5.5");
    try std.testing.expectEqualStrings("gpt-5.5", fb.model);
}

test "Keys.defaultProvider: first keyed provider on its default model" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const p = try all.defaultProvider();
    try std.testing.expectEqualStrings("anthropic", p.id); // anthropic leads provider_specs
    try std.testing.expectEqualStrings("claude-opus-4-8", p.model);
    const none = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    try std.testing.expectError(error.MissingKey, none.defaultProvider());
}

test "Keys.build: g_codex_url_override rewires only the codex endpoint" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    g_codex_url_override = "http://127.0.0.1:8765/responses";
    defer g_codex_url_override = null;
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
    var keys = Keys{ .values = [_]?[]const u8{null} ** provider_specs.len };
    for (provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "kimi")) keys.values[i] = "token";
    }
    const native = try keys.providerById("kimi", "native");
    try std.testing.expectEqual(Provider.Kind.openai, native.kind);
    try std.testing.expectEqual(Provider.Auth.bearer, native.auth);
    try std.testing.expectEqualStrings(kimi_native_url, native.url);
    const messages = try keys.providerById("kimi", "messages");
    try std.testing.expectEqual(Provider.Kind.anthropic, messages.kind);
    try std.testing.expectEqual(Provider.Auth.x_api_key, messages.auth);
    try std.testing.expectEqualStrings(kimi_anthropic_url, messages.url);
}

test "perOutputCap (#201): window-proportional with an absolute ceiling, keep_recent-safe" {
    var p: Provider = undefined;
    // ~1/8 of the window in tokens (context/2 bytes at ~4 bytes/token)
    p.context = 270_000;
    try std.testing.expectEqual(@as(usize, 135_000), p.perOutputCap());
    // #201 invariant: keep_recent (=4) verbatim outputs must stay reclaimable —
    // 4 * cap (in estimated tokens) < the window.
    try std.testing.expect(4 * (p.perOutputCap() / 4) < p.context);
    // absolute ceiling bounds a huge window so one result can't dominate
    p.context = 4_000_000;
    try std.testing.expectEqual(@as(usize, 256 * 1024), p.perOutputCap());
    // unknown window disables the cap
    p.context = 0;
    try std.testing.expectEqual(@as(usize, 0), p.perOutputCap());
}

test "contextWindowFor (#203): GRAFF_CONTEXT overrides only an unknown/local model" {
    g_context_override = 8192;
    defer g_context_override = null;
    // unknown/local model (no catalogued window) → the override applies
    try std.testing.expectEqual(@as(u64, 8192), contextWindowFor("lmstudio", "some-local-gguf"));
    // a known, catalogued model keeps its real window even with the override set
    try std.testing.expect(pricing.isKnownModel("anthropic", "claude-opus-4-8"));
    try std.testing.expect(contextWindowFor("anthropic", "claude-opus-4-8") != 8192);
}

test "compactAt (#204): GRAFF_COMPACT_PCT overrides the 80% default, both directions" {
    var p: Provider = undefined;
    p.context = 100_000;
    try std.testing.expectEqual(@as(u64, 80_000), p.compactAt()); // default 80%
    g_compact_pct_override = 70;
    defer g_compact_pct_override = null;
    try std.testing.expectEqual(@as(u64, 70_000), p.compactAt()); // lowered
    g_compact_pct_override = 95;
    try std.testing.expectEqual(@as(u64, 95_000), p.compactAt()); // raised — no codex-style clamp to 90
}
