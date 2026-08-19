//! Cache-aware token pricing kept separate from the model catalog and tally.

const std = @import("std");

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
    const write_multiplier: f64 = if (std.mem.startsWith(u8, model, "gpt-5.6") or std.mem.startsWith(u8, model, "claude-")) 1.25 else 1.0;
    const fi: f64 = @floatFromInt(ui);
    const fc: f64 = @floatFromInt(ci);
    const fw: f64 = @floatFromInt(wi);
    const fo: f64 = @floatFromInt(@max(out, 0));
    return (fi * input_rate + fc * (if (high) p.high_cache else p.cache) + fw * input_rate * write_multiplier + fo * (if (high) p.high_out else p.out)) / 1_000_000.0;
}
