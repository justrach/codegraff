//! Pure tournament policy for primary ranking, one-winner holdout evaluation,
//! and final promotion eligibility.

const std = @import("std");
const eval = @import("learn_eval.zig");

pub const Eligibility = struct {
    eligible: bool,
    reason: []const u8,
};

pub const Finalized = struct {
    /// Best unique, non-parent candidate with primary evidence. Eligibility is
    /// applied separately before deciding whether holdout exposure is useful.
    primary_winner_index: ?usize,
    /// Set only when that one winner passes every configured promotion gate.
    selected_genome_id: ?[]const u8,
};

fn passRateOrder(a: eval.ComparisonRecord, b: eval.ComparisonRecord) std.math.Order {
    if (a.pairs == 0 or b.pairs == 0) {
        if (a.pairs == 0 and b.pairs == 0) return .eq;
        return if (a.pairs == 0) .lt else .gt;
    }
    const a_rate = @as(u128, a.child_passes) * @as(u128, b.pairs);
    const b_rate = @as(u128, b.child_passes) * @as(u128, a.pairs);
    return std.math.order(a_rate, b_rate);
}

/// Safety and the candidate's own observed correctness dominate the
/// tournament. Parent-relative deltas and one-shot latency are deliberately
/// excluded: a stochastic parent or noisy wall clock must not choose a winner.
/// Resource use is considered only after child correctness ties.
pub fn primaryOutranks(a: eval.CandidateRecord, b: eval.CandidateRecord) bool {
    const ac = a.primary.?;
    const bc = b.primary.?;
    if (ac.child_critical_failures != bc.child_critical_failures) return ac.child_critical_failures < bc.child_critical_failures;
    if (ac.critical_regressions != bc.critical_regressions) return ac.critical_regressions < bc.critical_regressions;
    switch (passRateOrder(ac, bc)) {
        .gt => return true,
        .lt => return false,
        .eq => {},
    }
    if (ac.child_passes != bc.child_passes) return ac.child_passes > bc.child_passes;
    // Missing instrumentation is unknown, not zero. Prefer measured economy;
    // only compare exact call counts when both adapters supplied them.
    if (ac.tool_calls_measured != bc.tool_calls_measured) return ac.tool_calls_measured;
    if (ac.tool_calls_measured and ac.child_tool_calls != bc.child_tool_calls) return ac.child_tool_calls < bc.child_tool_calls;
    if (ac.child_cost_micros != bc.child_cost_micros) return ac.child_cost_micros < bc.child_cost_micros;
    if (a.mutation.genome_bytes != 0 and b.mutation.genome_bytes != 0 and a.mutation.genome_bytes != b.mutation.genome_bytes)
        return a.mutation.genome_bytes < b.mutation.genome_bytes;
    return std.mem.order(u8, a.genome_id, b.genome_id) == .lt;
}

fn exclusionReason(parent_genome_id: []const u8, candidates: []const eval.CandidateRecord, index: usize) ?[]const u8 {
    const contender = candidates[index];
    if (std.mem.eql(u8, contender.genome_id, parent_genome_id)) return "identical_parent";
    for (candidates[0..index]) |prior| {
        if (std.mem.eql(u8, contender.genome_id, prior.genome_id)) return "duplicate_candidate";
    }
    return null;
}

/// Chooses the sole candidate that may see the hidden holdout. A primary
/// comparison is required, but primary eligibility is deliberately not: the
/// tournament ranks observed performance before applying promotion gates.
pub fn primaryWinnerIndex(parent_genome_id: []const u8, candidates: []const eval.CandidateRecord) ?usize {
    var winner: ?usize = null;
    for (candidates, 0..) |contender, index| {
        if (contender.primary == null or exclusionReason(parent_genome_id, candidates, index) != null) continue;
        if (winner == null or primaryOutranks(contender, candidates[winner.?])) winner = index;
    }
    return winner;
}

/// Computes promotion eligibility for the primary winner. A primary rejection
/// is final and does not require exposing the configured hidden holdout.
pub fn deriveWinnerEligibility(
    primary: eval.ComparisonRecord,
    holdout: ?eval.ComparisonRecord,
    holdout_required: bool,
) !Eligibility {
    if (!primary.eligible) return .{ .eligible = false, .reason = primary.reason };
    if (holdout_required and holdout == null) return error.MissingHoldout;
    if (!holdout_required and holdout != null) return error.UnexpectedHoldout;
    if (holdout) |holdout_comparison| {
        if (!holdout_comparison.eligible) return .{ .eligible = false, .reason = "holdout_rejected" };
    }
    return .{ .eligible = true, .reason = "eligible" };
}

/// Applies the final gate atomically after the winner's optional holdout has
/// been evaluated. Primary losers can never remain eligible, and holdout
/// evidence on any loser is rejected so the hidden suite stays winner-only.
pub fn finalize(
    parent_genome_id: []const u8,
    candidates: []eval.CandidateRecord,
    holdout_required: bool,
) !Finalized {
    const winner = primaryWinnerIndex(parent_genome_id, candidates);
    for (candidates, 0..) |contender, index| {
        if (contender.holdout != null and (winner == null or index != winner.?)) return error.NonWinnerHoldout;
    }

    const decision: ?Eligibility = if (winner) |index|
        try deriveWinnerEligibility(candidates[index].primary.?, candidates[index].holdout, holdout_required)
    else
        null;

    for (candidates, 0..) |*candidate, index| {
        candidate.eligible = false;
        if (exclusionReason(parent_genome_id, candidates, index)) |reason| {
            candidate.reason = reason;
        } else if (winner != null and index == winner.?) {
            candidate.eligible = decision.?.eligible;
            candidate.reason = decision.?.reason;
        } else if (candidate.primary != null) {
            candidate.reason = "not_primary_winner";
        }
    }

    return .{
        .primary_winner_index = winner,
        .selected_genome_id = if (winner) |index|
            if (candidates[index].eligible) candidates[index].genome_id else null
        else
            null,
    };
}

const mutation: eval.MutationRecord = .{
    .seed = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    .request_evidence_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    .response_evidence_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
};

fn fakeComparison(delta: i64, score_delta: i64, p: u64, cost: u64, eligible: bool, reason: []const u8) eval.ComparisonRecord {
    return .{
        .suite_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .request_evidence_id = mutation.request_evidence_id,
        .response_evidence_id = mutation.response_evidence_id,
        .pairs = 20,
        .statistical_units = 20,
        .parent_passes = 10,
        .child_passes = 15,
        .wins = 5,
        .losses = 0,
        .ties = 15,
        .critical_regressions = 0,
        .delta_ppm = delta,
        .mean_score_delta_ppm = score_delta,
        .p_value_ppb = p,
        .parent_cost_micros = 100,
        .child_cost_micros = cost,
        .tool_calls_measured = true,
        .parent_tool_calls = 10,
        .child_tool_calls = 10,
        .latency_measured = true,
        .parent_latency_ms = 100,
        .child_latency_ms = 100,
        .eligible = eligible,
        .reason = reason,
    };
}

fn fakeCandidate(id: []const u8, primary: ?eval.ComparisonRecord) eval.CandidateRecord {
    return .{
        .genome_id = id,
        .mutation = mutation,
        .primary = primary,
        .holdout = null,
        .eligible = false,
        .reason = if (primary == null) "unevaluated" else primary.?.reason,
    };
}

test "primary winner is correctness-first then tool calls, cost, and genome ID" {
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", fakeComparison(20, 10, 5, 1, true, "eligible")),
        fakeCandidate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", fakeComparison(30, 10, 5, 100, false, "not_significant")),
    };
    // Parent-relative deltas cannot break an equal-child tie. Candidate zero
    // is cheaper despite having the smaller apparent delta.
    try std.testing.expectEqual(@as(?usize, 0), primaryWinnerIndex("parent", &candidates));

    candidates[0].primary = fakeComparison(30, 10, 5, 50, true, "eligible");
    try std.testing.expectEqual(@as(?usize, 0), primaryWinnerIndex("parent", &candidates));

    candidates[0].primary.?.child_tool_calls = 9;
    candidates[1].primary.?.child_tool_calls = 8;
    try std.testing.expectEqual(@as(?usize, 1), primaryWinnerIndex("parent", &candidates));

    candidates[0].primary.?.child_tool_calls = 8;
    candidates[1].primary.?.child_cost_micros = 50;
    try std.testing.expectEqual(@as(?usize, 1), primaryWinnerIndex("parent", &candidates));

    // One-shot latency is reported, but is too noisy to choose a winner.
    candidates[0].primary.?.child_cost_micros = 50;
    candidates[0].mutation.genome_bytes = 100;
    candidates[1].mutation.genome_bytes = 200;
    candidates[0].primary.?.child_latency_ms = 1_000;
    candidates[1].primary.?.child_latency_ms = 1;
    try std.testing.expectEqual(@as(?usize, 0), primaryWinnerIndex("parent", &candidates));
}

test "critical child safety outranks higher pass rate" {
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", fakeComparison(100, 100, 1, 1, false, "critical_regression")),
        fakeCandidate("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", fakeComparison(0, 0, 1_000_000_000, 100, false, "minimum_delta")),
    };
    candidates[0].primary.?.child_critical_failures = 1;
    candidates[0].primary.?.child_passes = 20;
    candidates[1].primary.?.child_passes = 19;
    try std.testing.expectEqual(@as(?usize, 1), primaryWinnerIndex("parent", &candidates));
}

test "higher pass rate outranks cheaper operation" {
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", fakeComparison(0, 0, 1, 1, false, "minimum_delta")),
        fakeCandidate("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", fakeComparison(0, 0, 1, 100, false, "minimum_delta")),
    };
    candidates[0].primary.?.child_passes = 14;
    candidates[0].primary.?.child_tool_calls = 1;
    candidates[1].primary.?.child_passes = 15;
    candidates[1].primary.?.child_tool_calls = 100;
    try std.testing.expectEqual(@as(?usize, 1), primaryWinnerIndex("parent", &candidates));
}

test "null, parent-identical, and duplicate candidates do not contend" {
    const parent = "1111111111111111111111111111111111111111111111111111111111111111";
    const unique = "2222222222222222222222222222222222222222222222222222222222222222";
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("0000000000000000000000000000000000000000000000000000000000000000", null),
        fakeCandidate(parent, fakeComparison(999, 999, 0, 0, true, "eligible")),
        fakeCandidate(unique, fakeComparison(10, 10, 10, 10, false, "minimum_pairs")),
        fakeCandidate(unique, fakeComparison(999, 999, 0, 0, true, "eligible")),
    };
    try std.testing.expectEqual(@as(?usize, 2), primaryWinnerIndex(parent, &candidates));
}

test "only the primary winner can become finally eligible" {
    const parent = "1111111111111111111111111111111111111111111111111111111111111111";
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", fakeComparison(20, 10, 5, 10, true, "eligible")),
        fakeCandidate("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", fakeComparison(30, 10, 5, 20, true, "eligible")),
    };
    candidates[0].eligible = true;
    candidates[1].holdout = fakeComparison(5, 5, 10, 5, true, "eligible");

    const result = try finalize(parent, &candidates, true);
    try std.testing.expectEqual(@as(?usize, 1), result.primary_winner_index);
    try std.testing.expectEqualStrings(candidates[1].genome_id, result.selected_genome_id.?);
    try std.testing.expect(!candidates[0].eligible);
    try std.testing.expectEqualStrings("not_primary_winner", candidates[0].reason);
    try std.testing.expect(candidates[1].eligible);
}

test "holdout cannot rescue a primary rejection" {
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", fakeComparison(20, 10, 5, 10, false, "not_significant")),
    };
    const result = try finalize("parent", &candidates, true);
    try std.testing.expectEqual(@as(?usize, 0), result.primary_winner_index);
    try std.testing.expect(result.selected_genome_id == null);
    try std.testing.expectEqualStrings("not_significant", candidates[0].reason);
}

test "finalization fails closed around hidden holdout evidence" {
    var candidates = [_]eval.CandidateRecord{
        fakeCandidate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", fakeComparison(30, 10, 5, 10, true, "eligible")),
        fakeCandidate("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", fakeComparison(20, 10, 5, 10, true, "eligible")),
    };
    try std.testing.expectError(error.MissingHoldout, finalize("parent", &candidates, true));
    try std.testing.expect(!candidates[0].eligible);

    candidates[0].holdout = fakeComparison(20, 10, 5, 10, true, "eligible");
    candidates[1].holdout = fakeComparison(20, 10, 5, 10, true, "eligible");
    try std.testing.expectError(error.NonWinnerHoldout, finalize("parent", &candidates, true));
}
