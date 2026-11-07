//! Cache-aware token pricing kept separate from the model catalog and tally.

const std = @import("std");

/// The 5-minute cache write's price as a multiple of input (Anthropic, GPT-5.6).
const five_minute_write: f64 = 1.25;
/// Anthropic's 1-hour cache write (ADR 0220).
const one_hour_write: f64 = 2.0;
/// OpenAI GPT-5.6+ Responses 12-hour cache write (ADR 0312).
const twelve_hour_write: f64 = 2.5;

/// USD for one request (negative token counts clamp to zero). Cache writes are
/// separate from ordinary input: GPT-5.6 and Anthropic ephemeral caches bill
/// writes at 1.25× the ordinary input rate.
pub fn usdForUsage(p: anytype, model: []const u8, ordinary_in: i64, cache_in: i64, cache_write_in: i64, out: i64) f64 {
    const ui = @max(ordinary_in, 0);
    const ci = @max(cache_in, 0);
    const wi = @max(cache_write_in, 0);
    const prompt: u64 = @as(u64, @intCast(ui)) +| @as(u64, @intCast(ci)) +| @as(u64, @intCast(wi));
    const high = p.high_at > 0 and prompt >= p.high_at;
    const input_rate = if (high) p.high_in else p.in;
    const write_multiplier: f64 = p.cache_write_multiplier orelse if (std.mem.startsWith(u8, model, "gpt-5.6") or std.mem.startsWith(u8, model, "gpt-6-") or std.mem.startsWith(u8, model, "claude-")) five_minute_write else 1.0;
    const fi: f64 = @floatFromInt(ui);
    const fc: f64 = @floatFromInt(ci);
    const fw: f64 = @floatFromInt(wi);
    const fo: f64 = @floatFromInt(@max(out, 0));
    return (fi * input_rate + fc * (if (high) p.high_cache else p.cache) + fw * input_rate * write_multiplier + fo * (if (high) p.high_out else p.out)) / 1_000_000.0;
}

/// What usdForUsage leaves out of a Claude request that wrote to the 1-hour
/// cache: those tokens cost 2x input, not the 1.25x it charges every write.
/// A row that states its own write price is billed as it says.
pub fn hourWriteExtraUsd(p: anytype, model: []const u8, prompt_tokens: u64, hour_tokens: i64) f64 {
    if (hour_tokens <= 0 or p.cache_write_multiplier != null or !std.mem.startsWith(u8, model, "claude-")) return 0;
    const high = p.high_at > 0 and prompt_tokens >= p.high_at;
    const input_rate = if (high) p.high_in else p.in;
    return @as(f64, @floatFromInt(hour_tokens)) * input_rate * (one_hour_write - five_minute_write) / 1_000_000.0;
}

/// usdForUsage prices every GPT-5.6+ write at 1.25x. The 12-hour lifetime
/// bills 2.5x; add the difference for tokens named `ttl_12h_tokens`.
pub fn twelveHourWriteExtraUsd(p: anytype, model: []const u8, twelve_tokens: i64) f64 {
    if (twelve_tokens <= 0) return 0;
    if (!(std.mem.startsWith(u8, model, "gpt-5.6") or std.mem.startsWith(u8, model, "gpt-6-") or std.mem.startsWith(u8, model, "gpt-6."))) return 0;
    // A row that prices writes at 1x (hosted gateway) is billed as it says.
    if (p.cache_write_multiplier) |m| if (m <= 1.0) return 0;
    const input_rate = p.in;
    return @as(f64, @floatFromInt(twelve_tokens)) * input_rate * (twelve_hour_write - five_minute_write) / 1_000_000.0;
}

test "ADR 0220: a 1-hour cache write costs 2x input on Claude" {
    const opus = @import("pricing.zig").priceFor("claude-opus-5-5").?;
    // 100k tokens written: 1.25x of $4/MTok in usdForUsage, 0.75x more at 1 hour.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), usdForUsage(opus, "claude-opus-5-5", 0, 0, 100_000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), hourWriteExtraUsd(opus, "claude-opus-5-5", 100_000, 100_000), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), hourWriteExtraUsd(opus, "claude-opus-5-5", 100_000, 0));
    // A row with its own write price (the hosted gateway's flat 1x) is not repriced.
    const flat = @import("pricing_gateway.zig").rows[0];
    try std.testing.expectEqual(@as(f64, 0), hourWriteExtraUsd(flat, flat.name, 100_000, 100_000));
}

test "ADR 0312: a 12-hour OpenAI cache write costs 2.5x input" {
    const sol = @import("pricing.zig").priceFor("gpt-6.1-sol").?;
    // 100k tokens: usdForUsage already charged 1.25x of $2/MTok = $0.25; +1.25x more at 12h.
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), usdForUsage(sol, "gpt-6.1-sol", 0, 0, 100_000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), twelveHourWriteExtraUsd(sol, "gpt-6.1-sol", 100_000), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), twelveHourWriteExtraUsd(sol, "gpt-6.1-sol", 0));
    try std.testing.expectEqual(@as(f64, 0), twelveHourWriteExtraUsd(sol, "gpt-4o", 100_000));
}
