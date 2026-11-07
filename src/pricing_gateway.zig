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
    .{ .name = "gemini-4-argon", .in = 2.2, .out = 11.0, .cache = 0.11, .cache_write_multiplier = 1 },
    .{ .name = "glm-5.2", .in = 1.68, .out = 5.28, .cache = 0.312, .cache_write_multiplier = 1 },
    .{ .name = "glm-5.3", .in = 1.68, .out = 5.28, .cache = 0.312, .cache_write_multiplier = 1 },
    .{ .name = "glm-5.3-flash", .in = 0.075, .out = 0.25, .cache = 0.015, .cache_write_multiplier = 1 },
    .{ .name = "gpt-6-astra", .in = 11.0, .out = 55.0, .cache = 1.1, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 22.0, .high_out = 82.5, .high_cache = 2.2 },
    .{ .name = "gpt-6-luna", .in = 0.11, .out = 0.55, .cache = 0.011, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 0.22, .high_out = 0.825, .high_cache = 0.022 },
    .{ .name = "gpt-6-sol", .in = 2.2, .out = 11.0, .cache = 0.22, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 4.4, .high_out = 16.5, .high_cache = 0.44 },
    .{ .name = "gpt-6.1-sol", .in = 2.0, .out = 10.0, .cache = 0.1, .cache_write_multiplier = 1, .high_at = 272_000, .high_in = 4.0, .high_out = 15.0, .high_cache = 0.2 },
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

/// A gateway endpoint's settled charge receipt, or null when it is missing,
/// unsettled, or malformed: a published list rate never stands in for one.
pub fn settledCharge(body: std.json.Value) ?u64 {
    if (body != .object) return null;
    const receipt = body.object.get("codegraff_billing") orelse return null;
    if (receipt != .object) return null;
    const settled = receipt.object.get("settled") orelse return null;
    const currency = receipt.object.get("currency") orelse return null;
    const charge = receipt.object.get("charge_micro_usd") orelse return null;
    if (settled != .bool or !settled.bool or currency != .string or
        !std.mem.eql(u8, currency.string, "USD") or charge != .integer or
        charge.integer < 0 or charge.integer > 9_007_199_254_740_991) return null;
    return @intCast(charge.integer);
}
