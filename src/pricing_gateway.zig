//! Gateway price snapshot from codegraff.com/docs/models, 2026-09-23.
//! Provider-specific aliases and markups must not inherit direct vendor prices.
//! Cache writes carry ordinary input rate: no separate gateway write tariff
//! is documented. Unknown models remain explicitly unpriced.
const std = @import("std");
const ModelPrice = @import("pricing.zig").ModelPrice;
pub const rows = [_]ModelPrice{
    .{ .name = "claude-opus-5", .in = 5.0, .out = 25.0, .cache = 0.5, .cache_write_multiplier = 1 },
    .{ .name = "claude-sonnet-5", .in = 2.0, .out = 10.0, .cache = 0.2, .cache_write_multiplier = 1 },
    .{ .name = "deepseek-flash", .in = 0.3, .out = 1.2, .cache = 0.006, .cache_write_multiplier = 1 },
    .{ .name = "deepseek-v4-flash", .in = 0.3, .out = 1.2, .cache = 0.006, .cache_write_multiplier = 1 },
    .{ .name = "deepseek-v4-flash-fast", .in = 0.294, .out = 0.588, .cache = 0.0735, .cache_write_multiplier = 1 },
    .{ .name = "deepseek-v4-pro", .in = 0.435, .out = 0.87, .cache = 0.0036, .cache_write_multiplier = 1 },
    .{ .name = "gemini-3.7-flash", .in = 0.75, .out = 3.75, .cache = 0.075, .cache_write_multiplier = 1 },
    .{ .name = "gemini-3.8-flash", .in = 0.75, .out = 3.75, .cache = 0.075, .cache_write_multiplier = 1 },
    .{ .name = "glm-5.2", .in = 1.68, .out = 5.28, .cache = 0.312, .cache_write_multiplier = 1 },
    .{ .name = "glm-5.3", .in = 1.68, .out = 5.28, .cache = 0.312, .cache_write_multiplier = 1 },
    .{ .name = "glm-5.3-flash", .in = 0.075, .out = 0.25, .cache = 0.015, .cache_write_multiplier = 1 },
    .{ .name = "gpt-5.5", .in = 4.0, .out = 20.0, .cache = 0.4, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 8.0, .high_out = 30.0, .high_cache = 0.8 },
    .{ .name = "gpt-5.6", .in = 4.0, .out = 20.0, .cache = 0.4, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 8.0, .high_out = 30.0, .high_cache = 0.8 },
    .{ .name = "gpt-5.6-luna", .in = 0.2, .out = 1.2, .cache = 0.02, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 0.4, .high_out = 1.7999999999999998, .high_cache = 0.04 },
    .{ .name = "gpt-5.6-sol", .in = 4.0, .out = 20.0, .cache = 0.4, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 8.0, .high_out = 30.0, .high_cache = 0.8 },
    .{ .name = "gpt-5.6-terra", .in = 2.0, .out = 12.0, .cache = 0.2, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 4.0, .high_out = 18.0, .high_cache = 0.4 },
    .{ .name = "gpt-6-astra", .in = 10.0, .out = 50.0, .cache = 1.0, .cache_write_multiplier = 1 },
    .{ .name = "grok-4.6", .in = 2.0, .out = 6.0, .cache = 0.5, .cache_write_multiplier = 1, .high_at = 200_000, .high_in = 4.0, .high_out = 12.0, .high_cache = 1.0 },
    .{ .name = "grok-4.7", .in = 2.0, .out = 6.0, .cache = 0.5, .cache_write_multiplier = 1, .high_at = 200_000, .high_in = 4.0, .high_out = 12.0, .high_cache = 1.0 },
    .{ .name = "grok-build", .in = 1.0, .out = 2.0, .cache = 0.2, .cache_write_multiplier = 1 },
    .{ .name = "hy4-preview", .in = 1.0, .out = 3.0, .cache = 0.0504, .cache_write_multiplier = 1 },
    .{ .name = "kimi-k2.6", .in = 1.14, .out = 4.8, .cache = 0.228, .cache_write_multiplier = 1 },
    .{ .name = "kimi-k2.7-code", .in = 1.14, .out = 4.8, .cache = 0.228, .cache_write_multiplier = 1 },
    .{ .name = "kimi-k2.7-code-highspeed", .in = 2.28, .out = 9.6, .cache = 0.456, .cache_write_multiplier = 1 },
    .{ .name = "kimi-k3", .in = 3.6, .out = 18.0, .cache = 0.36, .cache_write_multiplier = 1 },
    .{ .name = "ling-3.0-flash-fin", .in = 0.0, .out = 0.0, .cache = 0.0, .cache_write_multiplier = 1 },
    .{ .name = "mimo-v2.6-flash", .in = 0.14, .out = 0.28, .cache = 0.0028, .cache_write_multiplier = 1 },
    .{ .name = "mimo-v2.6-pro", .in = 0.435, .out = 0.87, .cache = 0.0036, .cache_write_multiplier = 1 },
    .{ .name = "mimo-v2.6-pro-ultraspeed", .in = 4.35, .out = 8.7, .cache = 0.036, .cache_write_multiplier = 1 },
    .{ .name = "minimax-m3", .in = 0.72, .out = 2.88, .cache = 0.144, .cache_write_multiplier = 1 },
    .{ .name = "muse-spark-1.2", .in = 1.25, .out = 4.25, .cache = 0.15, .cache_write_multiplier = 1 },
    .{ .name = "muse-spark-1.2-contributor", .in = 0.1, .out = 0.2, .cache = 0.002, .cache_write_multiplier = 1 },
    .{ .name = "muse-spark-1.3", .in = 1.25, .out = 4.25, .cache = 0.15, .cache_write_multiplier = 1 },
    .{ .name = "muse-spark-1.3-contributor", .in = 0.1, .out = 0.2, .cache = 0.002, .cache_write_multiplier = 1 },
    .{ .name = "qwen-3.8-27b", .in = 0.99, .out = 1.49, .cache = 0.99, .cache_write_multiplier = 1 },
};
pub fn find(model: []const u8) ?ModelPrice {
    for (rows) |p| if (std.mem.eql(u8, p.name, model)) return p;
    return null;
}
