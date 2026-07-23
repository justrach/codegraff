//! Aggregate paired correctness, economy, and latency evidence.

const std = @import("std");
const store = @import("learn_store.zig");
const protocol = @import("learn_eval_types.zig");
const stats = @import("learn_stats.zig");

fn reductionPpm(parent: u64, child: u64) i64 {
    if (parent == 0) return if (child == 0) 0 else -1_000_000;
    const delta = @as(i128, parent) - @as(i128, child);
    const raw = @divTrunc(delta * 1_000_000, @as(i128, parent));
    // Economy promotion only distinguishes reductions from non-reductions.
    // Bound regressions at -100% so hostile-but-valid aggregate counters can
    // neither overflow i64 nor escape the signed receipt's fixed range.
    return @intCast(@max(-1_000_000, raw));
}

test "tool-call reduction is bounded for extreme regressions" {
    try std.testing.expectEqual(@as(i64, -1_000_000), reductionPpm(1, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(i64, 0), reductionPpm(0, 0));
    try std.testing.expectEqual(@as(i64, 500_000), reductionPpm(10, 5));
}

pub fn computeComparison(
    config: store.Config,
    suite_sha256: []const u8,
    request_id: []const u8,
    response_id: []const u8,
    requested: []const protocol.PairRequest,
    response: protocol.EvaluationResponse,
    planned_candidates: usize,
) !protocol.ComparisonRecord {
    if (response.pairs.len != requested.len) return error.MissingPair;
    var parent_passes: usize = 0;
    var child_passes: usize = 0;
    var statistical_units: usize = 0;
    var wins: usize = 0;
    var losses: usize = 0;
    var tool_wins: usize = 0;
    var tool_losses: usize = 0;
    var child_critical_failures: usize = 0;
    var critical_regressions: usize = 0;
    var correctness_regressions: usize = 0;
    var score_delta: i128 = 0;
    var parent_cost: u64 = 0;
    var child_cost: u64 = 0;
    var parent_tool_calls: u64 = 0;
    var child_tool_calls: u64 = 0;
    var parent_latency: u64 = 0;
    var child_latency: u64 = 0;
    var tool_calls_measured = true;
    var latency_measured = true;
    for (response.pairs, requested) |result, pair| {
        if (!std.mem.eql(u8, result.case_id, pair.case_id) or !std.mem.eql(u8, result.seed, pair.seed)) return error.PairMismatch;
        if (result.parent_score_ppm > 1_000_000 or result.child_score_ppm > 1_000_000) return error.InvalidScore;
        if (result.parent_cost_micros > stats.js_exact_max or result.child_cost_micros > stats.js_exact_max or result.parent_latency_ms > stats.js_exact_max or result.child_latency_ms > stats.js_exact_max or result.parent_tool_calls > stats.js_exact_max or result.child_tool_calls > stats.js_exact_max) return error.InvalidMetric;
        if (result.parent_pass) parent_passes += 1;
        if (result.child_pass) child_passes += 1;
        if (!result.child_pass and pair.critical) child_critical_failures += 1;
        if (result.parent_pass and !result.child_pass) {
            correctness_regressions += 1;
            if (pair.critical) critical_regressions += 1;
        }
        score_delta += @as(i128, result.child_score_ppm) - @as(i128, result.parent_score_ppm);
        parent_cost = try stats.checkedMetricAdd(parent_cost, result.parent_cost_micros);
        child_cost = try stats.checkedMetricAdd(child_cost, result.child_cost_micros);
        parent_tool_calls = try stats.checkedMetricAdd(parent_tool_calls, result.parent_tool_calls);
        child_tool_calls = try stats.checkedMetricAdd(child_tool_calls, result.child_tool_calls);
        parent_latency = try stats.checkedMetricAdd(parent_latency, result.parent_latency_ms);
        child_latency = try stats.checkedMetricAdd(child_latency, result.child_latency_ms);
        tool_calls_measured = tool_calls_measured and result.tool_calls_measured;
        latency_measured = latency_measured and result.latency_measured;
    }

    // Repetitions and explicitly related clone IDs are one statistical unit.
    // Aggregate correctness and calls within that unit before directions.
    for (requested, 0..) |pair, index| {
        const unit_id = protocol.statisticalUnitId(pair);
        var seen = false;
        for (requested[0..index]) |prior| if (std.mem.eql(u8, protocol.statisticalUnitId(prior), unit_id)) {
            seen = true;
            break;
        };
        if (seen) continue;
        statistical_units += 1;
        var parent_case_passes: usize = 0;
        var child_case_passes: usize = 0;
        var parent_case_calls: u64 = 0;
        var child_case_calls: u64 = 0;
        for (response.pairs, requested) |result, grouped_pair| {
            if (!std.mem.eql(u8, protocol.statisticalUnitId(grouped_pair), unit_id)) continue;
            if (result.parent_pass) parent_case_passes += 1;
            if (result.child_pass) child_case_passes += 1;
            parent_case_calls = try stats.checkedMetricAdd(parent_case_calls, result.parent_tool_calls);
            child_case_calls = try stats.checkedMetricAdd(child_case_calls, result.child_tool_calls);
        }
        if (child_case_passes > parent_case_passes) wins += 1;
        if (parent_case_passes > child_case_passes) losses += 1;
        if (tool_calls_measured and child_case_calls < parent_case_calls) tool_wins += 1;
        if (tool_calls_measured and parent_case_calls < child_case_calls) tool_losses += 1;
    }

    const pair_count = requested.len;
    const pass_delta: i128 = @as(i128, @intCast(child_passes)) - @as(i128, @intCast(parent_passes));
    const delta_ppm: i64 = @intCast(@divTrunc(pass_delta * 1_000_000, @as(i128, @intCast(pair_count))));
    const mean_score_delta: i64 = @intCast(@divTrunc(score_delta, @as(i128, @intCast(pair_count))));
    const correctness_p = stats.pairedTail(wins, losses);
    const tool_p = stats.pairedTail(tool_wins, tool_losses);
    const alpha: f64 = @as(f64, @floatFromInt(config.gate.alpha_ppm)) / 1_000_000.0;
    const correction: f64 = @floatFromInt(planned_candidates);
    const correctness_significant = correctness_p * correction <= alpha;
    const tool_significant = tool_p * correction <= alpha;
    const tool_delta = reductionPpm(parent_tool_calls, child_tool_calls);
    const tool_discordant = tool_wins + tool_losses;
    const economy_eligible = config.gate.economy_gate_enabled and
        child_critical_failures == 0 and statistical_units >= config.gate.minimum_pairs and
        correctness_regressions == 0 and child_passes >= parent_passes and
        losses == 0 and mean_score_delta >= 0 and
        tool_calls_measured and
        tool_discordant >= config.gate.minimum_economy_pairs and
        tool_delta >= config.gate.minimum_tool_reduction_ppm and tool_significant;

    var eligible = true;
    var reason: []const u8 = "eligible";
    if (child_critical_failures > 0) {
        eligible = false;
        reason = if (critical_regressions > 0) "critical_regression" else "critical_failure";
    } else if (statistical_units < config.gate.minimum_pairs) {
        eligible = false;
        reason = "minimum_pairs";
    } else if (config.gate.promotion_mode == .correctness and delta_ppm >= config.gate.minimum_delta_ppm and correctness_significant) {
        // Pre-registered correctness-improvement path.
    } else if (config.gate.promotion_mode == .economy and economy_eligible) {
        reason = "economy_eligible";
    } else {
        eligible = false;
        reason = if (config.gate.promotion_mode == .economy and (correctness_regressions > 0 or child_passes < parent_passes or losses > 0 or mean_score_delta < 0))
            "correctness_regression"
        else if (config.gate.promotion_mode == .economy and !tool_calls_measured)
            "tool_calls_unmeasured"
        else if (config.gate.promotion_mode == .economy and tool_discordant < config.gate.minimum_economy_pairs)
            "minimum_economy_pairs"
        else if (config.gate.promotion_mode == .economy and tool_delta < config.gate.minimum_tool_reduction_ppm)
            "minimum_tool_reduction"
        else if (config.gate.promotion_mode == .economy and !tool_significant)
            "economy_not_significant"
        else if (delta_ppm < config.gate.minimum_delta_ppm)
            "minimum_delta"
        else
            "not_significant";
    }
    return .{
        .suite_sha256 = suite_sha256,
        .request_evidence_id = request_id,
        .response_evidence_id = response_id,
        .pairs = pair_count,
        .statistical_units = statistical_units,
        .parent_passes = parent_passes,
        .child_passes = child_passes,
        .wins = wins,
        .losses = losses,
        .ties = statistical_units - wins - losses,
        .child_critical_failures = child_critical_failures,
        .critical_regressions = critical_regressions,
        .correctness_regressions = correctness_regressions,
        .delta_ppm = delta_ppm,
        .mean_score_delta_ppm = mean_score_delta,
        .p_value_ppb = stats.toPpb(correctness_p),
        .parent_cost_micros = parent_cost,
        .child_cost_micros = child_cost,
        .tool_calls_measured = tool_calls_measured,
        .parent_tool_calls = parent_tool_calls,
        .child_tool_calls = child_tool_calls,
        .tool_wins = tool_wins,
        .tool_losses = tool_losses,
        .tool_ties = if (tool_calls_measured) statistical_units - tool_wins - tool_losses else 0,
        .tool_delta_ppm = tool_delta,
        .tool_p_value_ppb = stats.toPpb(tool_p),
        .latency_measured = latency_measured,
        .parent_latency_ms = parent_latency,
        .child_latency_ms = child_latency,
        .economy_eligible = economy_eligible,
        .eligible = eligible,
        .reason = reason,
    };
}
