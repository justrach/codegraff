//! Tests for the escalation ladder and the edit contract, split out of
//! escalation.zig (600-line cap; the `<mod>_tests.zig` pattern, wired into the
//! test root by test_hooks.zig).
//!
//! The ladder is deliberately PURE over cheap observables, which is what makes
//! this file possible: the whole threshold matrix — scope x budget x
//! audit-language x prior-failure — is driven here with no allocator, no
//! network, no process and no trace file.

const std = @import("std");
const Value = std.json.Value;

const escalation = @import("escalation.zig");
const orch = @import("orchestration_policy.zig");
const pb = @import("phase_budget.zig");
const shapes = @import("shapes.zig");

const Rung = orch.Rung;

/// The observables the study's cap-30 runs actually presented, as a base to
/// vary one axis at a time from. 27 remaining is what is left after the root
/// has read the task and authored a workflow — the real moment `admit` runs.
fn base() escalation.Observables {
    return .{
        .shape = .review,
        .task_class = .bugfix,
        .files = 1,
        .widest = 3,
        .tasks = 5,
        .plan_estimate = 17,
        .audit = false,
        .prior_failure = false,
        .remaining = 27,
        .cap = 30,
    };
}

fn phasesFrom(a: std.mem.Allocator, src: []const u8) []const Value {
    const v = std.json.parseFromSliceLeaky(Value, a, src, .{}) catch unreachable;
    return v.array.items;
}

test "ladder: the study's cap-30 bugfix is R0 — one file is not a fleet" {
    // THE regression. 01-bugfix-B: two buggy functions in stats.py, given five
    // workers and three judges, 30 calls spent, zero edits. Scope decides, and
    // the scope here is one file.
    var o = base();
    try std.testing.expectEqual(Rung.R0, escalation.ladderRung(o));
    // Note WHY it is R0 and not a budget refusal: a review fleet (17) plus the
    // landing reserve (6) does fit the 27 that remain. The budget said yes.
    try std.testing.expect(pb.Ledger.init(30).fits(27, pb.fleetFloor(.review)));
    // Two files is still a pair, not a fan-out.
    o.files = 2;
    try std.testing.expectEqual(Rung.R0, escalation.ladderRung(o));
}

test "ladder: scope alone opens R2, and only at 3+ files with a plan that fans out" {
    var o = base();
    o.files = 3;
    try std.testing.expectEqual(Rung.R2, escalation.ladderRung(o));
    o.files = 8;
    try std.testing.expectEqual(Rung.R2, escalation.ladderRung(o));
    // A plan that authored ONE task per phase is not a fleet however many
    // files the ask names — there is nothing to run in parallel.
    o.widest = 1;
    try std.testing.expectEqual(Rung.R0, escalation.ladderRung(o));
}

test "ladder: budget vetoes R2 even at full scope" {
    var o = base();
    o.files = 6;
    // 12 left, 6 reserved, a review fleet needs 17: the fleet cannot finish,
    // so the answer is the rung that can.
    o.remaining = 12;
    try std.testing.expectEqual(Rung.R0, escalation.ladderRung(o));
    // Raise the ceiling and the same ask fans out.
    o.remaining = 30;
    try std.testing.expectEqual(Rung.R2, escalation.ladderRung(o));
}

test "ladder: audit-class language buys R3, and a prior failed attempt buys it for free" {
    var o = base();
    // Still one file — but the USER asked for breadth, so breadth is what they
    // are paying for. This is the deliberate escape hatch from R0.
    o.audit = true;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
    // …unless it cannot finish. R3 is not exempt from arithmetic.
    o.remaining = 10;
    try std.testing.expectEqual(Rung.R0, escalation.ladderRung(o));
    // First-attempt failure is the free escalation signal: same ask, same
    // scope, but the cheap answer has already been tried and did not stick.
    o = base();
    o.prior_failure = true;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
}

test "ladder: an open-ended research ask is R1, one scout — never a sweep fleet" {
    var o = base();
    o.shape = .research;
    o.task_class = .research;
    o.files = 4; // enough files for R2 on any other shape
    // 05-research-B: three sweepers over three small files, briefs measuring
    // 1.000 similar to each other, 24 calls — for an answer one scout reached.
    try std.testing.expectEqual(Rung.R1, escalation.ladderRung(o));
    // Audit language still overrides upward: "exhaustively map every module"
    // is a real fleet ask even though it is research-shaped.
    o.audit = true;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
}

test "verdictFor: R0 declines non-error, R1 caps at one scout, R2 downsizes to fit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const phases = phasesFrom(a,
        \\[{"title":"find bugs","tasks":[1,2,3,4,5,6]},
        \\ {"title":"synthesize","tasks":[1]}]
    );

    var o = base();
    // R0's advisory is a RESULT, not an error: a declined fleet is not a
    // failed tool call, and is_error here would burn a retry and read to the
    // model as a broken harness.
    switch (escalation.verdictFor(.R0, o, phases)) {
        .solo => |advice| {
            try std.testing.expect(std.mem.indexOf(u8, advice, "R0") != null);
            try std.testing.expect(std.mem.indexOf(u8, advice, "Do it yourself") != null);
            // It also says what would earn a fleet, so the model has a path.
            try std.testing.expect(std.mem.indexOf(u8, advice, "verification fails") != null);
        },
        else => return error.ExpectedSolo,
    }
    try std.testing.expectEqual(@as(usize, 1), (escalation.verdictFor(.R1, o, phases)).downsize);

    // 6 finders (24) + 1 synthesis (2) = 26, against 21 spendable → trim.
    o.plan_estimate = 26;
    const w = (escalation.verdictFor(.R2, o, phases)).downsize;
    try std.testing.expect(w >= 1 and w < 6);
    // A plan that already fits is not touched.
    o.plan_estimate = 14;
    try std.testing.expect(escalation.verdictFor(.R2, o, phases) == .proceed);
}

test "downsizeWidth: trims redundant finders and never the landing phase" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A-fix at width: 4 finders (16) + 1 implementer (6) + 1 verify (3) = 25,
    // against 21 spendable at cap 30 / 27 remaining.
    const phases = phasesFrom(a,
        \\[{"title":"find the defect","tasks":[1,2,3,4]},
        \\ {"title":"implement the fix","tasks":[1]},
        \\ {"title":"verify the diff","tasks":[1]}]
    );
    const w = escalation.downsizeWidth(phases, 30, 27);
    // 3 finders (12) + 6 + 3 = 21 fits exactly; 4 (16+6+3=25) would not.
    try std.testing.expectEqual(@as(usize, 3), w);
    // Whatever the width, the implement phase carries one task, so the edit
    // contract survives every trim — which is §4-P1's inviolable rule.
    try std.testing.expect(w >= 1);
    // Squeeze until only the skinniest plan fits: 1 finder + 1 implementer +
    // 1 verify = 13, on top of the 6-call reserve, so 19 left is the floor.
    try std.testing.expectEqual(@as(usize, 1), escalation.downsizeWidth(phases, 30, 19));
    // And below that, nothing fits — the caller must fall back to solo. Note
    // WHAT does not fit: the landing phase's own implementer, which is the
    // point at which a fleet stops being able to produce a patch at all.
    try std.testing.expectEqual(@as(usize, 0), escalation.downsizeWidth(phases, 30, 18));
    // An unlimited pool never trims.
    try std.testing.expectEqual(@as(usize, 4), escalation.downsizeWidth(phases, 0, std.math.maxInt(u64)));
}

test "decide: an explicit user shape choice is honoured and never overridden (#290)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const phases = phasesFrom(a, "[{\"title\":\"find bugs\",\"tasks\":[1,2,3]}]");
    const key: orch.Key = .{ .task_class = .bugfix, .budget_band = .b40, .stratum = "m" };

    // A learned cell that would normally trade this run DOWN to R0.
    var arms = [_]orch.ArmObs{
        armWith(key, .R2, 3, 0.2, 30),
        armWith(key, .R0, 4, 0.9, 8),
    };

    // Without an explicit choice, the ladder's R0 stands and the source says
    // which layer decided.
    const implicit = escalation.decide(base(), phases, false, &arms, key);
    try std.testing.expectEqual(Rung.R0, implicit.rung);
    try std.testing.expectEqual(orch.Source.bootstrap, implicit.source);

    // With one, the user's intent wins outright: R2 or above, marked explicit,
    // and no learned arm may move it in either direction.
    const explicit = escalation.decide(base(), phases, true, &arms, key);
    try std.testing.expect(explicit.rung.level() >= Rung.R2.level());
    try std.testing.expectEqual(orch.Source.explicit, explicit.source);
    try std.testing.expect(explicit.verdict != .solo);
}

test "decide: a learned cell overrides the hand ladder and says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const phases = phasesFrom(a, "[{\"title\":\"find bugs\",\"tasks\":[1,2,3]}]");
    const key: orch.Key = .{ .task_class = .bugfix, .budget_band = .b40, .stratum = "m" };
    var o = base();
    o.files = 4; // the hand ladder would say R2 here

    var arms = [_]orch.ArmObs{
        armWith(key, .R2, 4, 0.4, 28),
        armWith(key, .R0, 5, 0.95, 9),
    };
    const d = escalation.decide(o, phases, false, &arms, key);
    // Trading DOWN needs only "not worse", and this is much better.
    try std.testing.expectEqual(Rung.R0, d.rung);
    try std.testing.expectEqual(orch.Source.learned, d.source);
}

fn armWith(key: orch.Key, arm: Rung, n: u32, score: f64, calls: u32) orch.ArmObs {
    var a: orch.ArmObs = .{ .key = key, .arm = arm };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a.sum_score += score;
        a.n += 1;
        a.landed_n += 1;
        a.calls[a.n_calls] = calls;
        a.n_calls += 1;
    }
    return a;
}

test "userChoseShape: names the fan-out, not merely the codeword" {
    // The codeword alone is NOT an explicit shape choice — that is the whole
    // premise of the redesign: `ultracode` opts into the ladder, not into a
    // fleet. Only naming the structure counts.
    try std.testing.expect(!escalation.userChoseShape("ultracode fix the bug in stats.py"));
    try std.testing.expect(escalation.userChoseShape("ultracode use shape A on this diff"));
    try std.testing.expect(escalation.userChoseShape("fan out three reviewers"));
    try std.testing.expect(escalation.userChoseShape("spawn one agent per module"));
    try std.testing.expect(escalation.userChoseShape("review these IN PARALLEL"));
    try std.testing.expect(!escalation.userChoseShape("summarize the changelog"));
}

test "countDistinctFiles: paths, not version numbers or sentence periods" {
    // The study's five prompts, as scope evidence.
    try std.testing.expectEqual(@as(usize, 2), escalation.countDistinctFiles(
        "This directory contains stats.py and test_stats.py. Two of the three functions in stats.py have bugs.",
    ));
    try std.testing.expectEqual(@as(usize, 2), escalation.countDistinctFiles(
        "Create a command-line tool wordfreq.py in this directory. There is a sample.txt to test against.",
    ));
    try std.testing.expectEqual(@as(usize, 4), escalation.countDistinctFiles(
        "This directory is a small Python project: engine.py, report.py, main.py and settings.json.",
    ));
    // A trailing period, a version number and a bare sentence are not files.
    try std.testing.expectEqual(@as(usize, 0), escalation.countDistinctFiles(
        "The minimum supported Python version is 3.11. Prefer the most recent source.",
    ));
    // Directory-qualified paths count once each, case-insensitively.
    try std.testing.expectEqual(@as(usize, 2), escalation.countDistinctFiles("src/main.zig and SRC/MAIN.ZIG and src/util.zig"));
    // Bounded: a brief naming hundreds of distinct paths still fits the fixed
    // scratch, and the count saturates rather than growing without limit.
    var many: [9 * 300]u8 = @splat(' ');
    for (0..300) |i| _ = std.fmt.bufPrint(many[i * 9 ..][0..8], "f{d:0>4}.py", .{i}) catch unreachable;
    const n = escalation.countDistinctFiles(&many);
    try std.testing.expectEqual(@as(usize, escalation.max_files_counted), n);
    // Which is still far above the only threshold that reads it.
    try std.testing.expect(n >= escalation.fleet_scope_min);
}

test "ladder: a first small-scope failure with a verifier is R0d — revision before fleet" {
    var o = base();
    o.prior_failure = true;
    o.prior_failure_count = 1;
    o.verifier = .diff;
    try std.testing.expectEqual(Rung.R0d, escalation.ladderRung(o));
    // R0d spends no spawns, so it stays admissible where a fleet is not.
    o.remaining = 3;
    try std.testing.expectEqual(Rung.R0d, escalation.ladderRung(o));
    // A SECOND failure means the revision was already spent: fleet next.
    o = base();
    o.prior_failure = true;
    o.prior_failure_count = 2;
    o.verifier = .diff;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
    // No verifier, no revision loop (Weng's gate): the R3 judges ARE the
    // external feedback a solo retry would lack.
    o.prior_failure_count = 1;
    o.verifier = .none;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
    // A coverage-shaped failure (3+ files) wants breadth, not revision.
    o.verifier = .diff;
    o.files = 4;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
    // Audit language keeps its precedence over the revision rung.
    o = base();
    o.prior_failure = true;
    o.prior_failure_count = 1;
    o.verifier = .diff;
    o.audit = true;
    try std.testing.expectEqual(Rung.R3, escalation.ladderRung(o));
}

test "R0d: the advisory prescribes a revision and carries the parked evidence" {
    escalation.resetSession();
    defer escalation.resetSession();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Bare advisory: a revision prescription with a path to the fleet.
    const bare = escalation.deepRetryAdvice(a, .bugfix);
    try std.testing.expect(std.mem.indexOf(u8, bare, "R0d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "second failure earns the fleet") != null);
    // With parked evidence the advisory embeds it verbatim — the retry acts
    // on the observed signal, not on the reasoning that already missed.
    escalation.failure_evidence.note(.bugfix, "eval RED: score 40.0/100 (target 90, exit 1)");
    const with_ev = escalation.deepRetryAdvice(a, .bugfix);
    try std.testing.expect(std.mem.indexOf(u8, with_ev, "PRIOR ATTEMPT EVIDENCE") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_ev, "eval RED: score 40.0/100") != null);
    // Another class stays bare — evidence never leaks across classes.
    try std.testing.expect(std.mem.indexOf(u8, escalation.deepRetryAdvice(a, .research), "PRIOR ATTEMPT EVIDENCE") == null);
    // resetSession clears the ledger with the rest of the session state.
    escalation.resetSession();
    try std.testing.expectEqualStrings("", escalation.failure_evidence.evidence(.bugfix));
}

test "observe: decline count and the class verifier feed the revision gate" {
    escalation.resetSession();
    defer escalation.resetSession();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const phases = phasesFrom(a, "[{\"title\":\"implement the fix\",\"tasks\":[1]}]");
    escalation.noteDeclined(.bugfix);
    const o = escalation.observe(phases, "fix the bug in stats.py", .review, 27, 30);
    try std.testing.expect(o.prior_failure);
    try std.testing.expectEqual(@as(u8, 1), o.prior_failure_count);
    try std.testing.expectEqual(escalation.failure_evidence.Verifier.diff, o.verifier);
    try std.testing.expectEqual(Rung.R0d, escalation.ladderRung(o));
    // verdictFor(R0d) declines non-error with the revision prescription.
    switch (escalation.verdictFor(.R0d, o, phases)) {
        .solo => |advice| try std.testing.expect(std.mem.indexOf(u8, advice, "revision case") != null),
        else => return error.ExpectedSolo,
    }
}

test "edit contract: a clean tree is is_error, a tree that moved is ok" {
    // The PURE half of §3b, which is the half with the interesting logic — the
    // impure half is one `git status --porcelain` and a string compare.
    //
    // An uncontracted phase is never judged on the tree at all.
    try std.testing.expect(!escalation.contractUnmet(false, "", ""));
    try std.testing.expect(!escalation.contractUnmet(false, " M stats.py\n", " M stats.py\n"));

    // Contracted + clean tree: nothing landed, period. This is the 30-calls-
    // no-edit run, caught by a probe that costs zero model calls.
    try std.testing.expect(escalation.contractUnmet(true, "", ""));
    try std.testing.expect(escalation.contractUnmet(true, "", "   \n \t\n"));

    // Contracted + a tree that moved: the work landed.
    try std.testing.expect(!escalation.contractUnmet(true, "", " M stats.py\n"));
    try std.testing.expect(!escalation.contractUnmet(true, " M stats.py\n", " M stats.py\n M util.py\n"));

    // Contracted + an ALREADY-dirty tree this phase did not touch: also unmet.
    // Without this, any phase run in a workspace with uncommitted work would
    // pass the contract for free, which is most real workspaces.
    try std.testing.expect(escalation.contractUnmet(true, " M stats.py\n", " M stats.py\n"));
    try std.testing.expect(escalation.contractUnmet(true, " M stats.py", " M stats.py\n"));
}

test "the contract's texts say what to DO, not merely that something failed" {
    // The failure text is fed straight back to a worker that gets one retry,
    // so it has to be an instruction.
    try std.testing.expect(std.mem.indexOf(u8, escalation.contract_unmet, "no files changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, escalation.contract_unmet, "changed path") != null);
    // And it must NOT carry the not-retry-safe marker, or the retry the
    // contract depends on would be skipped.
    try std.testing.expect(std.mem.indexOf(u8, escalation.contract_unmet, "retry is NOT safe") == null);
    // The brief boilerplate is codex's changed-path listing requirement.
    try std.testing.expect(std.mem.indexOf(u8, escalation.contract_brief_note, "changed:") != null);
}

test "isContracted / isVariantsPhase read the closed slot vocabulary" {
    try std.testing.expect(escalation.isContracted(shapes.canonicalSlot("implement the fix")));
    try std.testing.expect(escalation.isContracted(shapes.canonicalSlot("build from the winner")));
    try std.testing.expect(!escalation.isContracted(shapes.canonicalSlot("find security bugs")));
    try std.testing.expect(!escalation.isContracted(shapes.canonicalSlot("verify each finding")));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const phases = phasesFrom(a,
        \\[{"title":"variants of the landing page","tasks":[1,2]},
        \\ {"title":"find bugs","tasks":[1]}]
    );
    try std.testing.expect(escalation.isVariantsPhase(phases[0]));
    try std.testing.expect(!escalation.isVariantsPhase(phases[1]));
}

test "prior-failure tracking: the second ask of a class carries the escalation signal" {
    escalation.resetSession();
    defer escalation.resetSession();
    try std.testing.expect(!escalation.priorAttemptFailed(.bugfix));
    escalation.noteDeclined(.bugfix);
    try std.testing.expect(escalation.priorAttemptFailed(.bugfix));
    // Per class: declining a bugfix says nothing about a research ask.
    try std.testing.expect(!escalation.priorAttemptFailed(.research));
    // A pipeline that could not fit has no class, so it counts for all.
    escalation.notePipelineDeclined();
    try std.testing.expect(escalation.priorAttemptFailed(.research));
}

test "observe: reads scope off the ask AND the plan, and classifies the ask" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const phases = phasesFrom(a,
        \\[{"title":"find bugs","tasks":[
        \\   {"prompt":"read report.py and settings.json"},
        \\   {"prompt":"read main.py"}]}]
    );
    const o = escalation.observe(phases, "ultracode fix the bug in stats.py", .review, 27, 30);
    // stats.py from the ASK plus three from the briefs: the ask is scope
    // evidence even when the plan paraphrases it.
    try std.testing.expectEqual(@as(usize, 4), o.files);
    try std.testing.expectEqual(@as(usize, 2), o.tasks);
    try std.testing.expectEqual(@as(usize, 2), o.widest);
    try std.testing.expectEqual(shapes.TaskClass.bugfix, o.task_class);
    try std.testing.expect(!o.audit);
    // 2 finders at 4 calls each.
    try std.testing.expectEqual(@as(u64, 8), o.plan_estimate);
}

test "shapes.classOf / isAuditClass: the study's five prompts land where the ladder needs them" {
    try std.testing.expectEqual(shapes.TaskClass.bugfix, shapes.classOf(
        "Two of the three functions in stats.py have bugs. Fix stats.py so that the whole pytest suite passes.",
    ));
    try std.testing.expectEqual(shapes.TaskClass.refactor, shapes.classOf(
        "Refactor it: 1. Rename the class TaxEngine to LevyEngine.",
    ));
    try std.testing.expectEqual(shapes.TaskClass.research, shapes.classOf(
        "Write summary.md answering these four questions, and cite the file each answer comes from.",
    ));
    try std.testing.expectEqual(shapes.TaskClass.feature, shapes.classOf(
        "Create a command-line tool wordfreq.py in this directory.",
    ));
    // A repair ask that MENTIONS review is still a repair — the precedence
    // that stops shape A from being handed a bugfix.
    try std.testing.expectEqual(shapes.TaskClass.bugfix, shapes.classOf("fix the bug the review found"));
    // …and an ordinary feature spec that happens to say "broken" is NOT a
    // bugfix. The bare needle mis-classified the study's own wordfreq task,
    // caught on the first acceptance run: the full prompt says "ties broken by
    // ascending ASCII order", which is a sort rule, not a defect report.
    const wordfreq_full =
        "Create a command-line tool wordfreq.py in this directory. Output: one line per token, " ++
        "sorted by count descending, ties broken by ascending ASCII order of the token.";
    try std.testing.expectEqual(shapes.TaskClass.feature, shapes.classOf(wordfreq_full));
    // The qualified forms still read as defects.
    try std.testing.expectEqual(shapes.TaskClass.bugfix, shapes.classOf("the parser is broken on empty input"));
    try std.testing.expectEqual(shapes.TaskClass.bugfix, shapes.classOf("two broken tests in the suite"));
    // Audit language is narrow on purpose: a fleet takes an explicit word.
    try std.testing.expect(shapes.isAuditClass("thoroughly audit the auth layer"));
    try std.testing.expect(shapes.isAuditClass("check every file for this pattern"));
    try std.testing.expect(!shapes.isAuditClass("fix the bug in stats.py"));
    try std.testing.expect(!shapes.isAuditClass("add a --top flag"));
}

test "shapes.rawAsk: captured by value, so a freed per-turn arena cannot dangle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena_state.allocator();
    const typed = try std.fmt.allocPrint(a, "ultracode fix {s}", .{"stats.py"});
    _ = try shapes.applyUltracodeSteering(a, typed, typed, false);
    try std.testing.expectEqualStrings("ultracode fix stats.py", shapes.rawAsk());
    // Free the arena the string came from; the capture must survive it.
    arena_state.deinit();
    try std.testing.expectEqualStrings("ultracode fix stats.py", shapes.rawAsk());
    try std.testing.expectEqual(shapes.TaskClass.bugfix, shapes.classOf(shapes.rawAsk()));
}
