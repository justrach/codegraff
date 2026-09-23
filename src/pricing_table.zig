//! Offline direct-provider prices; gateway rates live separately.
const ModelPrice = @import("pricing.zig").ModelPrice;
pub const rows = [_]ModelPrice{
    .{ .name = "gpt-6-astra", .in = 10, .out = 50, .cache = 1, .high_at = 272_000, .high_in = 20, .high_out = 75, .high_cache = 2 },
    .{ .name = "gpt-6-sol", .in = 2, .out = 10, .cache = 0.2, .high_at = 272_000, .high_in = 4, .high_out = 15, .high_cache = 0.4 },
    .{ .name = "gpt-6-luna", .in = 0.1, .out = 0.5, .cache = 0.01, .high_at = 272_000, .high_in = 0.2, .high_out = 0.75, .high_cache = 0.02 },
    .{ .name = "deepseek-v4-pro", .in = 1.1, .out = 2.2, .cache = 0.11 },
    .{ .name = "deepseek-v4-flash", .in = 0.14, .out = 0.28, .cache = 0.028 },
    // GPT-5.6 family (developers.openai.com model pages, read 2026-09-21).
    // `gpt-5.6` is the API alias for `gpt-5.6-sol`; graff catalogs the direct
    // sol slug only under codex (flat-rate, see provider.zig #294), so it has
    // no row here on purpose — tier/pin logic relies on that. Sol's $4/$20 is
    // promotional (at least through 2026-11-21; list was $5/$30). Requests
    // above 272K input tokens bill 2× input and 1.5× output for the whole
    // request — the `high_*` tier, as for grok-4.6.
    .{ .name = "gpt-5.6", .in = 4, .out = 20, .cache = 0.4, .high_at = 272_000, .high_in = 8, .high_out = 30, .high_cache = 0.8 },
    .{ .name = "gpt-5.6-terra", .in = 2, .out = 12, .cache = 0.2, .high_at = 272_000, .high_in = 4, .high_out = 18, .high_cache = 0.4 },
    .{ .name = "gpt-5.6-luna", .in = 0.2, .out = 1.2, .cache = 0.02, .high_at = 272_000, .high_in = 0.4, .high_out = 1.8, .high_cache = 0.04 },
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
    .{ .name = "mimo-v2.6-pro", .in = 0.435, .out = 0.87, .cache = 0.0036 },
    .{ .name = "mimo-v2.6-flash", .in = 0.14, .out = 0.28, .cache = 0.0028 },
    .{ .name = "mimo-v2.6-pro-ultraspeed", .in = 4.35, .out = 8.7, .cache = 0.036 },
    .{ .name = "mimo-v2.5-pro", .in = 0.435, .out = 0.87, .cache = 0.0036 },
    .{ .name = "mimo-v2.5", .in = 0.14, .out = 0.28, .cache = 0.0028 },
    .{ .name = "kimi-k2.7", .in = 0.95, .out = 4, .cache = 0.1 },
    .{ .name = "kimi-k2.6", .in = 0.95, .out = 4, .cache = 0.1 },
    .{ .name = "kimi-k2-thinking", .in = 0.6, .out = 2.5, .cache = 0.06 },
    .{ .name = "kimi-k2.5", .in = 0.6, .out = 3, .cache = 0.06 },
    .{ .name = "grok-4.7", .in = 2, .out = 6, .cache = 0.5, .high_at = 200_000, .high_in = 4, .high_out = 12, .high_cache = 1 },
    .{ .name = "grok-4.6", .in = 2, .out = 6, .cache = 0.5, .high_at = 200_000, .high_in = 4, .high_out = 12, .high_cache = 1 },
    .{ .name = "muse-spark-1.2", .in = 1.25, .out = 4.25, .cache = 0.125 },
    .{ .name = "muse-spark-1.2-contributor", .in = 0.1, .out = 0.2, .cache = 0.01 },
    .{ .name = "grok-4.3", .in = 1.25, .out = 2.5, .cache = 0.3 },
    .{ .name = "grok-build", .in = 1, .out = 2, .cache = 0.1 },
    .{ .name = "glm-5.3", .in = 1.4, .out = 4.4, .cache = 0.26 },
    .{ .name = "glm-5.2", .in = 1.4, .out = 4.4, .cache = 0.26 },
    .{ .name = "glm-5", .in = 1, .out = 3.2, .cache = 0.2 },
    .{ .name = "glm-5-turbo", .in = 1.2, .out = 4.0, .cache = 0.24 },
    .{ .name = "glm-5v-turbo", .in = 1.2, .out = 4.0, .cache = 0.24 },
    .{ .name = "glm-4.7", .in = 0.6, .out = 2.2, .cache = 0.11 },
    .{ .name = "glm-4.5", .in = 0.6, .out = 2.2, .cache = 0.11 },
    .{ .name = "alibaba/qwen3.8-27b", .in = 0.55, .out = 3.3, .cache = 0.11 },
};
