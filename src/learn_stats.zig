//! Exact paired-binomial statistics and metric-addition guards for the local
//! learning evaluator. Split out of learn_eval.zig (600-line goal);
//! learn_eval.zig re-exports the shared names so call sites are unchanged.

const std = @import("std");

/// Largest metric value that survives an f64 round trip exactly.
pub const js_exact_max: u64 = 9_007_199_254_740_991;

/// Exact one-sided paired-binomial tail, evaluated stably from the first tail
/// term. A value at or below `alpha / planned_candidates` is significant.
pub fn pairedTail(wins: usize, losses: usize) f64 {
    const n = wins + losses;
    if (n == 0 or wins * 2 <= n) return 1.0;
    const nf: f64 = @floatFromInt(n);
    const wf: f64 = @floatFromInt(wins);
    const lf: f64 = @floatFromInt(n - wins);
    const log_term = std.math.lgamma(f64, nf + 1.0) - std.math.lgamma(f64, wf + 1.0) - std.math.lgamma(f64, lf + 1.0) - nf * @log(2.0);
    var term = @exp(log_term);
    var total = term;
    var k = wins;
    while (k < n) : (k += 1) {
        term *= @as(f64, @floatFromInt(n - k)) / @as(f64, @floatFromInt(k + 1));
        total += term;
    }
    return @min(1.0, total);
}

pub fn toPpb(p: f64) u64 {
    if (p >= 1.0) return 1_000_000_000;
    if (p <= 0.0) return 0;
    return @intFromFloat(@ceil(p * 1_000_000_000.0));
}

pub fn checkedMetricAdd(a: u64, b: u64) !u64 {
    const sum = std.math.add(u64, a, b) catch return error.InvalidMetric;
    if (sum > js_exact_max) return error.InvalidMetric;
    return sum;
}
