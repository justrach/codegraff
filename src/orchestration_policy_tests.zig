//! Tests for the learned orchestration policy: row shapes, the fold and its
//! #290 firewall, and the asymmetric override rule.
//!
//! Mirrors route_policy_tests.zig deliberately — same archive, same fold
//! discipline, same "a sparse cell decides nothing" contract. Where that file
//! proves a (shape, role) cell cannot re-seat a model without evidence, this
//! one proves a (task_class, budget_band, stratum) cell cannot re-rung an
//! orchestration without it.

const std = @import("std");

const orch = @import("orchestration_policy.zig");
const rows = @import("orchestration_rows.zig");

const Rung = orch.Rung;
const Source = orch.Source;
const Key = orch.Key;

fn fold(a: std.mem.Allocator, archive: []const u8) []orch.ArmObs {
    return orch.foldArms(a, archive);
}

fn find(arms: []const orch.ArmObs, want: Rung) ?orch.ArmObs {
    for (arms) |x| if (x.arm == want) return x;
    return null;
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "BudgetBand / ScopeBucket: the buckets the key and the rows are made of" {
    try std.testing.expectEqual(orch.BudgetBand.b15, orch.BudgetBand.of(15));
    try std.testing.expectEqual(orch.BudgetBand.b40, orch.BudgetBand.of(16));
    try std.testing.expectEqual(orch.BudgetBand.b40, orch.BudgetBand.of(27)); // the study's cap-30 runs
    try std.testing.expectEqual(orch.BudgetBand.b100, orch.BudgetBand.of(41));
    try std.testing.expectEqual(orch.BudgetBand.unlimited, orch.BudgetBand.of(101));
    try std.testing.expectEqual(orch.BudgetBand.unlimited, orch.BudgetBand.of(std.math.maxInt(u64)));

    try std.testing.expectEqual(orch.ScopeBucket.s1_2, orch.ScopeBucket.of(1));
    try std.testing.expectEqual(orch.ScopeBucket.s1_2, orch.ScopeBucket.of(2));
    try std.testing.expectEqual(orch.ScopeBucket.s3_5, orch.ScopeBucket.of(3));
    try std.testing.expectEqual(orch.ScopeBucket.s6plus, orch.ScopeBucket.of(6));
}

test "foldArms: pools by (task_class, budget_band, stratum, arm) and reads the stats back" {
    var a = arena();
    defer a.deinit();
    const archive =
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R0","source":"bootstrap","score":1.0,"calls_used":10,"landed":true,"variant_free":true}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R0","source":"bootstrap","score":0.8,"calls_used":12,"landed":true,"variant_free":true}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R2","source":"bootstrap","score":0.0,"calls_used":30,"exhausted":true,"landed":false,"variant_free":true}
        \\{"kind":"route","shape":"review","role":"find","tier":"small","model":"x"}
        \\
    ;
    const arms = fold(a.allocator(), archive);
    try std.testing.expectEqual(@as(usize, 2), arms.len); // the route row is not ours

    const r0 = find(arms, .R0).?;
    try std.testing.expectEqual(@as(u32, 2), r0.n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), r0.mean(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r0.landRate(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), r0.exhaustRate(), 1e-9);

    const r2 = find(arms, .R2).?;
    try std.testing.expectEqual(@as(u32, 1), r2.n);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r2.exhaustRate(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), r2.landRate(), 1e-9);
    try std.testing.expectEqual(@as(u64, 30), r2.p90Calls());
}

test "#290 firewall: explicit rows never fold, variant-contaminated rows never fold" {
    var a = arena();
    defer a.deinit();
    const archive =
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R2","source":"explicit","score":1.0,"calls_used":30,"variant_free":true}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R2","source":"bootstrap","score":1.0,"calls_used":30,"variant_free":false}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R2","source":"bootstrap","score":0.3,"calls_used":29,"variant_free":true}
        \\
    ;
    const arms = fold(a.allocator(), archive);
    // Only the third row survives: the user-intent row would let a run the
    // policy did not choose vote on what the policy should choose, and the
    // variant row measures a prompt tournament as much as the rung.
    try std.testing.expectEqual(@as(usize, 1), arms.len);
    try std.testing.expectEqual(@as(u32, 1), arms[0].n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), arms[0].mean(), 1e-9);
    // `variant_free` DEFAULTS to true, so a row written before the field
    // existed still folds rather than being silently dropped.
    const legacy =
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m1","arm":"R0","source":"bootstrap","score":0.5,"calls_used":9}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), fold(a.allocator(), legacy).len);
}

test "#290 firewall: folding is within a stratum, never across" {
    var a = arena();
    defer a.deinit();
    const archive =
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"frontier-model","arm":"R2","source":"bootstrap","score":1.0,"calls_used":20,"variant_free":true}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"small-model","arm":"R2","source":"bootstrap","score":0.1,"calls_used":30,"variant_free":true}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","arm":"R2","source":"bootstrap","score":0.9,"calls_used":20,"variant_free":true}
        \\
    ;
    const arms = fold(a.allocator(), archive);
    // Two cells, not one averaged cell — a rung that is right for a frontier
    // root is not automatically right for a small one. The third row names no
    // stratum at all and is uncelled rather than pooled into either.
    try std.testing.expectEqual(@as(usize, 2), arms.len);
    for (arms) |x| try std.testing.expectEqual(@as(u32, 1), x.n);
}

test "foldArms: a row missing a coordinate, or carrying an out-of-range score, is skipped" {
    var a = arena();
    defer a.deinit();
    const archive =
        \\{"kind":"orch_outcome","budget_band":"b40","stratum":"m","arm":"R0","source":"bootstrap","score":1.0}
        \\{"kind":"orch_outcome","task_class":"bugfix","stratum":"m","arm":"R0","source":"bootstrap","score":1.0}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m","source":"bootstrap","score":1.0}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m","arm":"R9","source":"bootstrap","score":1.0}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m","arm":"R0","source":"bootstrap","score":88}
        \\{"kind":"orch_outcome","task_class":"bugfix","budget_band":"b40","stratum":"m","arm":"R0","source":"nonsense","score":1.0}
        \\not json at all
        \\
    ;
    // Every one of these is uncelled rather than filed under a default: a
    // mis-celled observation silently steers every future run in that cell.
    try std.testing.expectEqual(@as(usize, 0), fold(a.allocator(), archive).len);
}

fn samples(cs: []const u32) orch.ArmObs {
    var x: orch.ArmObs = .{};
    for (cs) |c| {
        x.sum_score += 1;
        x.n += 1;
        x.calls[x.n_calls] = c;
        x.n_calls += 1;
    }
    return x;
}

test "p90Calls: reports the expensive tail, not the median and not the max" {
    // Nearest-rank, ceil(0.9 * n), 1-based. Over ten samples that is the 9th
    // smallest — deliberately NOT the max, so one pathological run does not
    // veto an arm forever, and deliberately not the median, so a cheap median
    // with an expensive tail cannot sneak past the affordability gate.
    const mostly_cheap = samples(&.{ 8, 9, 9, 10, 10, 11, 11, 12, 12, 48 });
    try std.testing.expectEqual(@as(u64, 12), mostly_cheap.p90Calls());
    // An arm that is expensive in a FIFTH of its runs reads expensive, which
    // is the case the gate exists to refuse.
    const often_costly = samples(&.{ 8, 9, 9, 10, 10, 11, 11, 12, 44, 48 });
    try std.testing.expectEqual(@as(u64, 44), often_costly.p90Calls());
    // Order-independent: the fold appends in archive order, not sorted order.
    try std.testing.expectEqual(@as(u64, 44), samples(&.{ 48, 8, 44, 9, 10, 9, 11, 12, 10, 11 }).p90Calls());
    try std.testing.expectEqual(@as(u64, 7), samples(&.{7}).p90Calls());
    try std.testing.expectEqual(@as(u64, 0), (orch.ArmObs{}).p90Calls());
}

fn arm(key: Key, r: Rung, n: u32, score: f64, calls: u32) orch.ArmObs {
    var x: orch.ArmObs = .{ .key = key, .arm = r };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        x.sum_score += score;
        x.n += 1;
        x.calls[x.n_calls] = calls;
        x.n_calls += 1;
    }
    return x;
}

const k: Key = .{ .task_class = .bugfix, .budget_band = .b40, .stratum = "m1" };

test "override: a sparse cell decides nothing" {
    // Below min_arm_obs on either side, the hand ladder keeps its answer —
    // bootstrap behavior is today's behavior, and one lucky run moves nothing.
    var thin_base = [_]orch.ArmObs{ arm(k, .R2, 2, 0.1, 30), arm(k, .R0, 9, 0.9, 9) };
    try std.testing.expect(orch.override(&thin_base, k, .R2, 27, 6) == null);
    var thin_cand = [_]orch.ArmObs{ arm(k, .R2, 9, 0.1, 30), arm(k, .R0, 2, 0.9, 9) };
    try std.testing.expect(orch.override(&thin_cand, k, .R2, 27, 6) == null);
    // No evidence for the ladder's OWN answer means no basis for comparison.
    var no_base = [_]orch.ArmObs{arm(k, .R0, 9, 0.9, 9)};
    try std.testing.expect(orch.override(&no_base, k, .R2, 27, 6) == null);
}

test "override: trading DOWN needs only not-worse; escalating needs a margin AND affordability" {
    // DOWN — R0 merely matches R2's mean, and still wins: a cheaper answer at
    // equal quality is strictly better, and it also cuts exhaustion risk,
    // which the mean does not price. (#372's asymmetry, lifted to rungs.)
    var equal = [_]orch.ArmObs{ arm(k, .R2, 4, 0.9, 28), arm(k, .R0, 4, 0.9, 9) };
    try std.testing.expectEqual(Rung.R0, orch.override(&equal, k, .R2, 27, 6).?);
    // …but not when it is actually worse.
    var worse = [_]orch.ArmObs{ arm(k, .R2, 4, 0.9, 28), arm(k, .R0, 4, 0.7, 9) };
    try std.testing.expect(orch.override(&worse, k, .R2, 27, 6) == null);

    // UP — a 0.04 improvement is inside the noise band and buys nothing.
    var thin = [_]orch.ArmObs{ arm(k, .R0, 4, 0.90, 9), arm(k, .R2, 4, 0.94, 18) };
    try std.testing.expect(orch.override(&thin, k, .R0, 27, 6) == null);
    // A 0.2 improvement clears the margin, and 18 + 6 fits the 27 left.
    var strong = [_]orch.ArmObs{ arm(k, .R0, 4, 0.7, 9), arm(k, .R2, 4, 0.9, 18) };
    try std.testing.expectEqual(Rung.R2, orch.override(&strong, k, .R0, 27, 6).?);
    // Same evidence, less budget: the arm's p90 no longer fits on top of the
    // reserve, so the expensive answer is refused however good it looks.
    try std.testing.expect(orch.override(&strong, k, .R0, 20, 6) == null);
    // An unlimited pool skips the affordability half — nothing to outspend.
    try std.testing.expectEqual(Rung.R2, orch.override(&strong, k, .R0, std.math.maxInt(u64), 6).?);
}

test "override: never crosses a cell boundary" {
    const other: Key = .{ .task_class = .research, .budget_band = .b40, .stratum = "m1" };
    var mixed = [_]orch.ArmObs{ arm(k, .R2, 4, 0.2, 28), arm(other, .R0, 9, 1.0, 5) };
    // A brilliant R0 in the RESEARCH cell says nothing about the bugfix cell.
    try std.testing.expect(orch.override(&mixed, k, .R2, 27, 6) == null);
}

test "override: among qualifying arms, ties break toward the cheaper rung" {
    var tie = [_]orch.ArmObs{
        arm(k, .R3, 4, 0.5, 28),
        arm(k, .R1, 4, 0.9, 12),
        arm(k, .R0, 4, 0.9, 8),
    };
    // Both beat R3 and both are trades DOWN; the bias of this whole redesign
    // picks the cheaper one.
    try std.testing.expectEqual(Rung.R0, orch.override(&tie, k, .R3, 27, 6).?);
}

test "bootstrap prior: the study's own numbers, weak enough for real rows to outvote" {
    // A fresh install has only this. It says: at cap 30 the bugfix fleet
    // scored 0 and exhausted, and solo scored 1.0 in 10 calls.
    var buf: [8]orch.ArmObs = undefined;
    const prior = orch.priorFor(&buf, k);
    try std.testing.expect(prior.len >= 2);
    const p_r0 = find(prior, .R0).?;
    const p_r2 = find(prior, .R2).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), p_r0.mean(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p_r2.mean(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), p_r2.exhaustRate(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p_r2.landRate(), 1e-9); // it never landed the fix
    // Every pseudo-observation sits BELOW min_arm_obs, so three real local
    // rows in a cell outvote the compiled table completely.
    for (orch.bootstrap_prior) |p| try std.testing.expect(p.n < orch.min_arm_obs);
    // And with only the prior, a ladder answer of R2 in this cell trades down.
    try std.testing.expect(orch.override(prior, k, .R2, 27, 6) == null); // n=2 < 3: sparse, decides nothing
}

test "efficiency: score per call, the number the redesign moves" {
    // The study's headline, both halves: ultracode 0.8 at 30 calls against
    // solo 1.0 at 10.
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), orch.efficiency(1.0, 10), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), orch.efficiency(0.0, 30), 1e-9);
    // Zero calls reads as zero, never as infinity.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), orch.efficiency(1.0, 0), 1e-9);
}

test "rows: a pending decision files exactly one outcome, and carries its flags" {
    rows.clearPending();
    defer rows.clearPending();
    rows.setPending(k, .R2, .bootstrap, 4);
    const p0 = rows.pending().?;
    try std.testing.expectEqual(Rung.R2, p0.arm);
    try std.testing.expectEqual(Source.bootstrap, p0.source);
    try std.testing.expectEqualStrings("m1", p0.key().stratum);
    try std.testing.expect(p0.variant_free);
    try std.testing.expect(!p0.landed);

    // The edit-contract probe and the tournament both write onto it, and both
    // are sticky in the direction that matters.
    rows.notePendingLanded(true);
    rows.notePendingLanded(false);
    rows.notePendingVariants();
    const p1 = rows.pending().?;
    try std.testing.expect(p1.landed);
    try std.testing.expect(!p1.variant_free);

    // Flushing clears, so a second funnel reaching the same decision cannot
    // double-file it. (g_traj is null under test, so emitOutcome is a no-op —
    // what is under test here is the pairing, which is the part with state.)
    rows.flushPending(1.0, 20, 500, false, "esh");
    try std.testing.expect(rows.pending() == null);
    rows.flushPending(1.0, 20, 500, false, "esh");
    try std.testing.expect(rows.pending() == null);
}

test "rows: the pending stratum survives the arena the decision was made in" {
    rows.clearPending();
    defer rows.clearPending();
    var a = arena();
    const owned = try a.allocator().dupe(u8, "gpt-5.6-sol");
    rows.setPending(.{ .task_class = .feature, .budget_band = .b40, .stratum = owned }, .R1, .explore, 0);
    a.deinit(); // exhaustedFatal runs after everything is torn down
    try std.testing.expectEqualStrings("gpt-5.6-sol", rows.pending().?.key().stratum);
}

test "rows: a model-authored stratum cannot turn a row into a megabyte" {
    rows.clearPending();
    defer rows.clearPending();
    // Built with @splat: Zig 0.17.0-dev (what CI pins) rejects the `"m" ** N`
    // repeat form, and @splat over an array compiles on both compilers.
    const huge: [4096]u8 = @splat('m');
    rows.setPending(.{ .task_class = .other, .budget_band = .b15, .stratum = &huge }, .R0, .bootstrap, 0);
    try std.testing.expectEqual(@as(usize, rows.field_cap), rows.pending().?.key().stratum.len);
    try std.testing.expectEqual(@as(usize, rows.field_cap), rows.cappedField(&huge).len);
}

test "round trip: the arm and source spellings a row writes are the ones the fold reads" {
    // The one coupling that would fail silently: emitDecision/emitOutcome
    // write `arm.label()` and `source.label()`, foldArms parses them back with
    // Rung.parse/Source.parse. A rename on either side must break here.
    for ([_]Rung{ .R0, .R1, .R2, .R3 }) |r| {
        try std.testing.expectEqual(r, Rung.parse(r.label()).?);
    }
    for ([_]Source{ .learned, .bootstrap, .explicit, .explore }) |s| {
        try std.testing.expectEqual(s, Source.parse(s.label()).?);
    }
    try std.testing.expect(Rung.parse("R9") == null);
    try std.testing.expect(Source.parse("magic") == null);
    // Same for the key's two enum components.
    for ([_]orch.TaskClass{ .bugfix, .feature, .refactor, .review, .research, .other }) |c| {
        try std.testing.expectEqual(c, orch.TaskClass.parse(c.label()));
    }
    for ([_]orch.BudgetBand{ .b15, .b40, .b100, .unlimited }) |b| {
        try std.testing.expectEqual(b, orch.BudgetBand.parse(b.label()));
    }
}
