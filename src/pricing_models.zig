//! The baked model catalog: provider, model name and context window, plus the
//! per-model protocol and effort facts some providers need. Live catalogs
//! (Codex, Anthropic, gateways) replace their provider's slice at startup;
//! these rows are the offline floor. Split out of pricing.zig for the
//! 600-line cap, like pricing_table.zig's prices.
const ModelInfo = @import("pricing.zig").ModelInfo;

pub const rows = [_]ModelInfo{
    // Local Apple-Silicon model served by mlx-lm (mlx_lm.server, OpenAI-compatible).
    .{ .provider = "mlx", .name = "mlx-community/Qwen3.6-27B-OptiQ-4bit", .context = 262_144 },
    // Recursive Flint INT4 through `rec serve --port 8080`, which serves it as "flint".
    .{ .provider = "mlx", .name = "flint", .context = 262_144 },
    // LM Studio serves whatever model is loaded; "lmstudio" is a routing alias —
    // swap for your loaded model id if LM Studio requires an exact match (GET :1234/v1/models).
    .{ .provider = "lmstudio", .name = "lmstudio", .context = 200_000 },
    // oMLX needs an exact id. Its live /v1/models list replaces this offline alias
    // and its first row becomes the default (pricing.providerDefaultModel).
    .{ .provider = "omlx", .name = "omlx", .context = 200_000 },
    // Anthropic: no-key/offline FALLBACK ONLY; with a key, router_catalog swaps
    // in the live /v1/models list. Rows exist so boot, --schema and routing
    // (the default, ladder and vision picks) resolve before that fetch.
    .{ .provider = "anthropic", .name = "claude-opus-5-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-5-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-fable-5-1", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-fable-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-8", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-7", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-6", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-4-6", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-haiku-5-5", .context = 1_000_000 },
    .{ .provider = "anthropic", .name = "claude-opus-4-5", .context = 200_000 },
    .{ .provider = "anthropic", .name = "claude-sonnet-4-5", .context = 200_000 },
    // Claude Agent (ADR 0309): the models Claude Code's opus/fable/sonnet/
    // haiku aliases resolve to, under their real names, so the plan reads like
    // any other. `claude-agent/<id>` passes any id Claude Code accepts. Claude
    // Code runs each of these at 1M natively (its result reports contextWindow
    // 1000000 with or without a `[1m]` suffix), so the window matches Anthropic's.
    .{ .provider = "claude-agent", .name = "claude-opus-5-5", .context = 1_000_000 },
    .{ .provider = "claude-agent", .name = "claude-fable-5-1", .context = 1_000_000 },
    .{ .provider = "claude-agent", .name = "claude-sonnet-5-5", .context = 1_000_000 },
    .{ .provider = "claude-agent", .name = "claude-haiku-5-5", .context = 1_000_000 },
    // The previous generation Claude Code still offers by name.
    .{ .provider = "claude-agent", .name = "claude-opus-5", .context = 1_000_000 },
    .{ .provider = "claude-agent", .name = "claude-fable-5", .context = 1_000_000 },
    .{ .provider = "claude-agent", .name = "claude-sonnet-5", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-v4-flash", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-chat", .context = 1_000_000 },
    .{ .provider = "deepseek", .name = "deepseek-reasoner", .context = 1_000_000 },
    .{ .provider = "openai", .name = "gpt-6-astra", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-6-sol", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-6.1-sol", .context = 1_050_000 },
    .{ .provider = "openai", .name = "gpt-6-luna", .context = 1_050_000 },
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
    .{ .provider = "xiaomi", .name = "mimo-v2.6-pro", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.6-flash", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.6-pro-ultraspeed", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5-pro", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2.5-pro-ultraspeed", .context = 1_048_576 },
    .{ .provider = "xiaomi", .name = "mimo-v2-flash", .context = 262_144 },
    // Offline snapshot only: at startup models_cache.zig replaces the whole
    // Codex slice from the account-scoped /models response (5-minute cache).
    // These rows keep Codex usable when auth or discovery is unavailable.
    .{ .provider = "codex", .name = "gpt-6-astra", .context = 272_000, .default_effort = "medium", .default_verbosity = "low" },
    .{ .provider = "codex", .name = "gpt-6-sol", .context = 272_000, .default_effort = "medium", .default_verbosity = "low" },
    .{ .provider = "codex", .name = "gpt-6.1-sol", .context = 500_000, .default_effort = "low", .default_verbosity = "low" },
    .{ .provider = "codex", .name = "gpt-6-luna", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.6-sol", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.6-terra", .context = 272_000 },
    .{ .provider = "codegraff", .name = "muse-spark-1.2", .context = 262_144 },
    .{ .provider = "codegraff", .name = "muse-spark-1.2-contributor", .context = 262_144 },
    .{ .provider = "meta", .name = "muse-spark-1.2", .context = 1_048_576 },
    .{ .provider = "meta", .name = "muse-spark-1.2-contributor", .context = 1_048_576 },
    .{ .provider = "codex", .name = "gpt-5.6-luna", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.5", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.4", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.4-mini", .context = 272_000 },
    .{ .provider = "codex", .name = "gpt-5.3-codex-spark", .context = 128_000 },
    // The ChatGPT plan through the new sign-in (ADR 0221): subscription
    // defaults, with GPT-6.1 Sol at 500k (ADR 0292). Offline fallback rows.
    .{ .provider = "chatgpt-new", .name = "gpt-6.1-sol", .context = 500_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-6-astra", .context = 272_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-6-sol", .context = 272_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-6-luna", .context = 272_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-5.6-sol", .context = 272_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-5.6-terra", .context = 272_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-5.6-luna", .context = 272_000 },
    .{ .provider = "chatgpt-new", .name = "gpt-5.5", .context = 272_000 },
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
    // PR #395 providers (groq/mistral/kilo): context rows so boot and routing
    // work before any live /models fetch. gpt-oss-120b matches the fireworks
    // row for the same weights; kilo-auto routes dynamically, so its row
    // carries the conservative small-model window.
    .{ .provider = "groq", .name = "openai/gpt-oss-120b", .context = 131_072 },
    // Cerebras Inference (api.cerebras.ai OpenAI chat) — not the WSE CSL SDK.
    .{ .provider = "cerebras", .name = "gpt-oss-120b", .context = 131_072 },
    .{ .provider = "cerebras", .name = "gemma-4-31b", .context = 131_072 },
    .{ .provider = "mistral", .name = "mistral-medium-latest", .context = 131_072 },
    .{ .provider = "kilo", .name = "kilo-auto/small", .context = 131_072 },
    // codegraff gateway (its claude aliases use dots, so they don't collide
    // with the anthropic rows above)
    .{ .provider = "codegraff", .name = "claude-opus-4.8", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "claude-sonnet-4.6", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "deepseek-v4-pro", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "deepseek-v4-flash", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "minimax-m3", .context = 1_000_000 },
    .{ .provider = "codegraff", .name = "gpt-6-astra", .context = 1_050_000 },
    .{ .provider = "codegraff", .name = "gpt-6-sol", .context = 1_050_000 },
    .{ .provider = "codegraff", .name = "gpt-6.1-sol", .context = 1_050_000 },
    .{ .provider = "codegraff", .name = "gpt-6-luna", .context = 1_050_000 },
    .{ .provider = "codegraff", .name = "kimi-k2.6", .context = 262_144 },
    .{ .provider = "codegraff", .name = "grok-4.7", .context = 500_000 },
    .{ .provider = "codegraff", .name = "grok-4.6", .context = 500_000 },
    .{ .provider = "codegraff", .name = "grok-build", .context = 256_000 },
    .{ .provider = "codegraff", .name = "glm-5.2", .context = 204_800 },
    .{ .provider = "codegraff", .name = "glm-5.3-flash", .context = 202_752 },
    .{ .provider = "codegraff", .name = "mimo-v2.6-pro", .context = 1_048_576 },
    .{ .provider = "codegraff", .name = "mimo-v2.6-flash", .context = 1_048_576 },
    .{ .provider = "codegraff", .name = "mimo-v2.5", .context = 128_000 },
    .{ .provider = "codegraff", .name = "mimo-v2.5-pro", .context = 128_000 },
    // Kimi Code offline fallback. Authenticated startup replaces this slice
    // from /coding/v1/models; K3 is the current explicit generation while the
    // two compatibility aliases keep their smaller advertised window.
    .{ .provider = "kimi", .name = "k3", .context = 1_048_576, .protocol = .kimi, .supports_reasoning = true, .support_efforts = &.{ "low", "high", "max" }, .default_effort = "high" },
    .{ .provider = "kimi", .name = "kimi-for-coding", .context = 262_144, .protocol = .kimi, .supports_reasoning = true },
    .{ .provider = "kimi", .name = "kimi-for-coding-highspeed", .context = 262_144, .protocol = .kimi, .supports_reasoning = true },
    .{ .provider = "moonshot", .name = "kimi-latest", .context = 131_072 },

    .{ .provider = "moonshot", .name = "kimi-k2.7-code", .context = 262_144, .supports_reasoning = true },
    .{ .provider = "moonshot", .name = "kimi-k2.6", .context = 262_144, .supports_reasoning = true },
    // Moonshot platform K3 (api.moonshot.ai, model id `kimi-k3`). Distinct from
    // Kimi Code's native `k3` row: `--model kimi-k3` with only MOONSHOT_API_KEY
    // must not rewrite onto the coding-plan login.
    .{ .provider = "moonshot", .name = "kimi-k3", .context = 1_048_576, .supports_reasoning = true, .support_efforts = &.{ "low", "high", "max" }, .default_effort = "max" },
    .{ .provider = "xai", .name = "grok-4.7", .context = 500_000, .supports_reasoning = true },
    .{ .provider = "xai", .name = "grok-4.6", .context = 500_000, .supports_reasoning = true },
    .{ .provider = "xai", .name = "grok-4.3", .context = 1_000_000 },
    .{ .provider = "xai", .name = "grok-build", .context = 256_000 },
    .{ .provider = "zai", .name = "glm-5.3", .context = 1_000_000, .supports_reasoning = true },
    .{ .provider = "zai", .name = "glm-5.2", .context = 1_000_000, .supports_reasoning = true },
    .{ .provider = "zai", .name = "glm-5-turbo", .context = 204_800, .supports_reasoning = true },
    .{ .provider = "zai", .name = "glm-5v-turbo", .context = 204_800, .supports_reasoning = true },
    .{ .provider = "zai", .name = "glm-5", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.7", .context = 204_800 },
    .{ .provider = "zai", .name = "glm-4.5", .context = 131_072 },
    // Google AI Studio. Every gemini-3.x row is the live inputTokenLimit
    // (1,048,576) read from generativelanguage /v1beta/models — its
    // OpenAI-compat /models omits the window entirely, so without these rows
    // contextFor falls to default_context and a 1M model compacts at 160k.
    // Efforts mirror the compat layer's own rejection message: "Valid values
    // are: high, low, medium, minimal, none".
    .{ .provider = "google", .name = "gemini-4-argon", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both, .support_efforts = &.{ "low", "medium", "high" }, .default_effort = "medium" },
    .{ .provider = "google", .name = "gemini-3.8-flash", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both, .support_efforts = &.{ "minimal", "low", "medium", "high" }, .default_effort = "medium" },
    .{ .provider = "google", .name = "gemini-3.7-flash", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both, .support_efforts = &.{ "minimal", "low", "medium", "high" }, .default_effort = "medium" },
    .{ .provider = "google", .name = "gemini-3.6-flash", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both },
    .{ .provider = "google", .name = "gemini-3.5-flash", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both },
    .{ .provider = "google", .name = "gemini-3.5-flash-lite", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both },
    .{ .provider = "google", .name = "gemini-3.1-pro-preview", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both },
    .{ .provider = "google", .name = "gemini-3.1-flash-lite", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both },
    .{ .provider = "google", .name = "gemini-3-flash-preview", .context = 1_048_576, .supports_reasoning = true, .thinking_support = .both },
    .{ .provider = "google", .name = "gemma-4-31b-it", .context = 262_144 },
    .{ .provider = "google", .name = "gemma-4-26b-a4b-it", .context = 262_144 },
    .{ .provider = "vercel", .name = "alibaba/qwen3.8-27b", .context = 1_000_000, .supports_reasoning = true },
    .{ .provider = "openrouter", .name = "anthropic/claude-sonnet-4.6", .context = 1_000_000, .supports_reasoning = true },
};
