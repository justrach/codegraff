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
    // OpenAI-format direct providers (matched to graff's provider.json).
    .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "https://api.kimi.com/coding/v1/chat/completions", .env_key = "KIMI_API_KEY", .default_model = "kimi-k2.7" },
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

    /// Auto-compact past 80% of the model's context window.
    pub fn compactAt(p: Provider) u64 {
        return p.context / 10 * 8;
    }

    /// #193 follow-up: the largest a SINGLE tool output may be, in serialized
    /// bytes, before it is truncated at send time (capOversizedToolOutputs).
    /// Window-proportional — ~50% of the window in estimated tokens (~4 bytes /
    /// token) — so large-context models keep full tool results untouched and only
    /// a result big enough to threaten the window on its own is bounded. This
    /// guarantees no single output can alone overflow past what the in-turn
    /// emergency-trim recovery can reclaim (it keeps the most-recent outputs
    /// verbatim). 0 (unknown window) disables the cap.
    pub fn perOutputCap(p: Provider) usize {
        if (p.context == 0) return 0;
        return @intCast(p.context * 2);
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
        return .{
            .id = spec.id,
            .kind = spec.kind,
            .auth = spec.auth,
            .url = if (is_codex) g_codex_url_override orelse spec.url else spec.url,
            .api_key = key,
            .model = model,
            .context = contextFor(spec.id, model),
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
