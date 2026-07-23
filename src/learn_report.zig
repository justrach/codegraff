//! Human/model-facing summaries for local learning runs. These deliberately
//! expose aggregate evidence only: no genome text, suite payloads, or paths.

const std = @import("std");
const Io = std.Io;
const eval = @import("learn_eval.zig");

fn writeComparison(out: *Io.Writer, label: []const u8, comparison: eval.ComparisonRecord) !void {
    try out.print(
        "  {s}: {d} pairs; {d} independent units; pass {d}/{d} -> {d}/{d}; delta {d} ppm; " ++
            "wins/losses/ties {d}/{d}/{d}; regressions {d}; p {d} ppb; ",
        .{
            label,
            comparison.pairs,
            comparison.statistical_units,
            comparison.parent_passes,
            comparison.pairs,
            comparison.child_passes,
            comparison.pairs,
            comparison.delta_ppm,
            comparison.wins,
            comparison.losses,
            comparison.ties,
            comparison.correctness_regressions,
            comparison.p_value_ppb,
        },
    );
    if (comparison.tool_calls_measured)
        try out.print("calls {d} -> {d} ({d} ppm; case W/L/T {d}/{d}/{d}; p {d} ppb); ", .{
            comparison.parent_tool_calls,
            comparison.child_tool_calls,
            comparison.tool_delta_ppm,
            comparison.tool_wins,
            comparison.tool_losses,
            comparison.tool_ties,
            comparison.tool_p_value_ppb,
        })
    else
        try out.writeAll("calls unmeasured; ");
    if (comparison.behavior_measured)
        try out.print("behavior {d} -> {d} ppm; ", .{
            comparison.parent_behavior_score_ppm,
            comparison.child_behavior_score_ppm,
        })
    else
        try out.writeAll("behavior unmeasured; ");
    if (comparison.latency_measured)
        try out.print("latency {d} -> {d} ms; ", .{ comparison.parent_latency_ms, comparison.child_latency_ms })
    else
        try out.writeAll("latency unmeasured; ");
    try out.print("cost {d} -> {d} micros; gate {s}\n", .{
        comparison.parent_cost_micros,
        comparison.child_cost_micros,
        comparison.reason,
    });
}

pub fn writeCandidateSummary(out: *Io.Writer, candidates: []const eval.CandidateRecord) !void {
    for (candidates, 0..) |candidate, index| {
        try out.print("candidate {d} {s}", .{ index + 1, candidate.genome_id });
        if (candidate.mutation.genome_bytes > 0) try out.print(" [{d} bytes]", .{candidate.mutation.genome_bytes});
        try out.writeByte('\n');
        if (candidate.primary) |primary|
            try writeComparison(out, "primary", primary)
        else
            try out.writeAll("  primary: not run\n");
        if (candidate.holdout) |holdout|
            try writeComparison(out, "holdout", holdout)
        else
            try out.writeAll("  holdout: not run\n");
        try out.print("  decision: {s}\n", .{candidate.reason});
    }
}

test "candidate summary reports actionable aggregate evidence without content" {
    const comparison: eval.ComparisonRecord = .{
        .suite_sha256 = "suite",
        .request_evidence_id = "request",
        .response_evidence_id = "response",
        .pairs = 15,
        .statistical_units = 15,
        .parent_passes = 14,
        .child_passes = 15,
        .wins = 1,
        .losses = 0,
        .ties = 14,
        .critical_regressions = 0,
        .correctness_regressions = 1,
        .delta_ppm = 66_666,
        .mean_score_delta_ppm = 66_666,
        .p_value_ppb = 500_000_000,
        .parent_cost_micros = 23,
        .child_cost_micros = 29,
        .tool_calls_measured = true,
        .parent_tool_calls = 23,
        .child_tool_calls = 29,
        .behavior_measured = true,
        .parent_behavior_score_ppm = 1_000_000,
        .child_behavior_score_ppm = 750_000,
        .tool_wins = 2,
        .tool_losses = 1,
        .tool_ties = 12,
        .tool_delta_ppm = -260_869,
        .tool_p_value_ppb = 500_000_000,
        .latency_measured = true,
        .parent_latency_ms = 100,
        .child_latency_ms = 80,
        .eligible = false,
        .reason = "not_significant",
    };
    const candidates = [_]eval.CandidateRecord{.{
        .genome_id = "child-fingerprint",
        .mutation = .{
            .seed = "seed",
            .request_evidence_id = "mutation-request",
            .response_evidence_id = "mutation-response",
            .description = "PRIVATE_MUTATOR_OUTPUT_DO_NOT_RENDER",
        },
        .primary = comparison,
        .holdout = null,
        .eligible = false,
        .reason = "not_significant",
    }};
    var allocating: Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try writeCandidateSummary(&allocating.writer, &candidates);
    const rendered = allocating.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "15 pairs; 15 independent units") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pass 14/15 -> 15/15") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "wins/losses/ties 1/0/14") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "regressions 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "calls 23 -> 29") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "behavior 1000000 -> 750000 ppm") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "latency 100 -> 80 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "decision: not_significant") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "suite") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "PRIVATE_MUTATOR_OUTPUT_DO_NOT_RENDER") == null);
}
