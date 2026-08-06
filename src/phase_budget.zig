//! Per-phase budget scaling: a RESERVATION ledger over the shared RunBudget
//! pool.
//!
//! graff already had accounting — `RunBudget` counts every model call the
//! root, the workers, the retries and the judges take from one atomic
//! ceiling, and `remaining()`/`canAfford()` report it honestly. What it did
//! not have was RESERVATION: nobody ever asked "if I spend this phase, will
//! there still be enough left to land the work?", so a fan-out could spend
//! the pool down to zero on evidence-gathering and die at call 30 with the
//! file it was asked to fix untouched. That is not a hypothetical: it is run
//! 01-bugfix-B of the eval study this module was written for — 30 calls,
//! five workers, three judges, one retry, zero edits.
//!
//! The fix is the one codex converged on for the same problem: one pool,
//! drawn down by everyone, with a reserve carved out UP FRONT for the step
//! that actually produces the artifact. Three gates use it:
//!
//!   P1 admission     the whole plan plus the landing reserve must fit
//!                    `remaining()` before anything spawns (escalation.zig).
//!   P2 per-phase     at each phase head, if what is left cannot cover the
//!                    remaining phases plus the reserve, stop early and hand
//!                    back partial evidence with a budget-truncated manifest.
//!                    A synthesis from three of five finders is worth much
//!                    more than a process kill after the fourth.
//!   P3 optional      judges and other nice-to-haves run only when they fit
//!                    ON TOP of the reserve (subagent.scoreVariants).
//!
//! Everything here is PURE arithmetic over cheap observables — no model call,
//! no I/O — so the whole ladder is unit-testable without a network.

const std = @import("std");
const Value = std.json.Value;

const route_policy = @import("route_policy.zig");
const shapes = @import("shapes.zig");

pub const Shape = route_policy.Shape;

// ── the cost table ─────────────────────────────────────────────────────────
// Calls one worker in a role actually spends, measured off the B-run traces
// of the eval study rather than assumed. A worker's cost is dominated by how
// many tool round-trips its job needs before it can write a report: a finder
// reads and greps (4), a skeptic re-checks one claim (3), a synthesizer reads
// {{prev}} and writes (2), a judge reads handed text and emits one score (1,
// once the judge toolset is emptied), and an implementer reads, edits,
// re-reads and self-checks (6 — the most expensive role, and the one the
// landing reserve exists to protect).

pub const cost_find: u64 = 4;
pub const cost_verify: u64 = 3;
pub const cost_synthesize: u64 = 2;
pub const cost_judge: u64 = 1;
pub const cost_implement: u64 = 6;
/// An off-vocabulary phase title still costs something; charge it the median
/// rather than zero, or an uncelled plan would estimate as free.
pub const cost_default: u64 = 3;

/// What one worker in `role` (a canonical slot from shapes.zig, or "") costs.
pub fn roleCost(role: []const u8) u64 {
    const eql = std.mem.eql;
    if (eql(u8, role, "find") or eql(u8, role, "sweep")) return cost_find;
    if (eql(u8, role, "verify")) return cost_verify;
    if (eql(u8, role, "synthesize")) return cost_synthesize;
    if (eql(u8, role, "judge")) return cost_judge;
    if (eql(u8, role, "implement") or eql(u8, role, "build") or eql(u8, role, "variants")) return cost_implement;
    if (eql(u8, role, "scope") or eql(u8, role, "review")) return cost_verify;
    return cost_default;
}

/// Calls a phase of `n_tasks` workers in `role` costs.
pub fn phaseCost(role: []const u8, n_tasks: usize) u64 {
    return roleCost(role) * @as(u64, @intCast(n_tasks));
}

// ── the landing reserve ────────────────────────────────────────────────────

/// Never reserve less than this, however small the cap: below ~6 calls the
/// root cannot read a result, make an edit and verify it, which is the whole
/// point of reserving anything.
pub const min_landing_reserve: u64 = 6;

/// Calls held back so the ROOT can still land the work after the fleet
/// reports. A fifth of the cap tracks the observed shape of these runs: the
/// study's solo baselines finished five ordinary tasks in 5-10 calls each,
/// so a cap of 30 wants ~6 held back and a cap of 100 wants ~20. An
/// unlimited pool (cap 0) still reserves the floor, so the arithmetic below
/// has one meaning everywhere.
pub fn landingReserve(cap: u64) u64 {
    return @max(min_landing_reserve, cap / 5);
}

/// #391: what ONE pre-compaction note-to-self costs. It is a cost, not a
/// second reserve, and that distinction is the whole point. The reserve above
/// already protects the calls the root needs to land and narrate the work
/// (#390); a note with a reserve of its own would be a SECOND ledger over the
/// same pool, and two ledgers each holding back "the last call" double-count
/// it. Charged through `affordsHarnessNote` instead, so the note runs only
/// when it fits on top of the reserve rather than out of it.
pub const cost_precompact_note: u64 = 1;

/// The cheapest honest instantiation of a catalog shape — what a fleet costs
/// at all, before any scaling to the ask. `admit` compares this (plus the
/// reserve) against `remaining()`: below it a fleet cannot finish, so the
/// answer is solo work rather than a fan-out that dies halfway.
pub fn fleetFloor(shape: Shape) u64 {
    return switch (shape) {
        // 3 finders + 1 skeptic + 1 synthesis
        .review => 3 * cost_find + cost_verify + cost_synthesize,
        // 3 sweepers + 1 map
        .research => 3 * cost_find + cost_synthesize,
        // 2 competing implementers + 1 build from the winner
        .design => 3 * cost_implement,
        // scope + implement + review
        .feature => cost_verify + cost_implement + cost_verify,
        // the smallest pipeline that is a pipeline: 2 items x 2 stages
        .migration => 4 * cost_default,
        .adhoc => 3 * cost_default,
    };
}

// ── plan estimates over the authored workflow ──────────────────────────────

/// This phase's canonical slot, "" when the title is off-vocabulary.
fn phaseRole(pv: Value) []const u8 {
    return route_policy.phaseSlot(pv);
}

fn phaseTaskCount(pv: Value) usize {
    if (pv != .object) return 0;
    const tv = pv.object.get("tasks") orelse return 0;
    return if (tv == .array) tv.array.items.len else 0;
}

/// What the workflow the root model just authored will cost, as authored.
pub fn planEstimate(phases: []const Value) u64 {
    var total: u64 = 0;
    for (phases) |pv| total += phaseCost(phaseRole(pv), phaseTaskCount(pv));
    return total;
}

/// The MINIMUM the phases from `from` onward can cost — one worker each,
/// however many the plan authored. This is what P2 tests against: a phase
/// loop should stop when it cannot afford even the skinniest completion of
/// what is left, not when it cannot afford the plan as written (which would
/// early-exit runs that were about to succeed).
pub fn laterPhasesMin(phases: []const Value, from: usize) u64 {
    var total: u64 = 0;
    var i = from;
    while (i < phases.len) : (i += 1) {
        if (phaseTaskCount(phases[i]) == 0) continue;
        total += roleCost(phaseRole(phases[i]));
    }
    return total;
}

/// Phases whose canonical slot is contracted to MUTATE files. Trimming one of
/// these to pay for evidence-gathering is the exact inversion the study
/// documented, so a downsize must never touch them.
pub fn isLandingRole(role: []const u8) bool {
    const eql = std.mem.eql;
    return eql(u8, role, "implement") or eql(u8, role, "build") or eql(u8, role, "repair");
}

// ── the ledger ─────────────────────────────────────────────────────────────

/// A reservation view over one run's shared pool. Holds no pointer to the
/// RunBudget: callers pass `remaining()` in at each decision, because the
/// real pool is atomic and shared with concurrent children, so a cached copy
/// would be a lie the moment a sibling spawned.
pub const Ledger = struct {
    /// The run's `--max-model-calls`; 0 means unlimited.
    cap: u64,
    /// Calls held back for the root to land the work.
    reserve: u64,
    /// Calls this run's phases have already been charged for by `commit`.
    committed: u64 = 0,

    pub fn init(cap: u64) Ledger {
        return .{ .cap = cap, .reserve = landingReserve(cap) };
    }

    /// An unlimited pool cannot exhaust, so every gate below passes; keeping
    /// that in ONE predicate is what stops the arithmetic from accidentally
    /// treating maxInt(u64) as a number.
    pub fn unlimited(self: Ledger) bool {
        return self.cap == 0;
    }

    /// Calls available for fan-out RIGHT NOW: what is left, minus the reserve.
    pub fn spendable(self: Ledger, remaining: u64) u64 {
        if (self.unlimited()) return std.math.maxInt(u64);
        return remaining -| self.reserve;
    }

    /// Does `cost` fit on top of the landing reserve?
    pub fn fits(self: Ledger, remaining: u64, cost: u64) bool {
        return self.spendable(remaining) >= cost;
    }

    /// P2: should the phase loop stop before running the phase at `from`?
    /// True when what is left cannot cover the skinniest completion of the
    /// remaining phases PLUS the reserve — at which point continuing spends
    /// the reserve on more evidence and lands nothing.
    pub fn earlyExit(self: Ledger, remaining: u64, later_min: u64) bool {
        if (self.unlimited()) return false;
        return remaining < later_min + self.reserve;
    }

    /// P3 for the HARNESS's own optional call (#391's pre-compaction note).
    /// Same predicate the judges use, and deliberately so: the note is the
    /// junior liability on this ledger. Narration is mandatory and owns the
    /// reserve; the note is a nice-to-have and must clear it. A run that can
    /// only afford one more call spends it landing, not journaling.
    pub fn affordsHarnessNote(self: Ledger, remaining: u64) bool {
        return self.fits(remaining, cost_precompact_note);
    }

    pub fn commit(self: *Ledger, cost: u64) void {
        self.committed += cost;
    }
};

// ── reading the shared pool ────────────────────────────────────────────────
// Taken as `anytype` so this module never imports run_budget.zig, which sits
// under tools.zig on the import graph — and a null budget (tests, the REPL
// before startup) reads as "unlimited", the same answer RunBudget itself
// gives for max_model_calls == 0.

pub fn capOf(rb: anytype) u64 {
    return if (rb) |b| b.max_model_calls else 0;
}

pub fn remainingOf(rb: anytype) u64 {
    return if (rb) |b| b.remaining() else std.math.maxInt(u64);
}

pub fn usedOf(rb: anytype) u64 {
    return if (rb) |b| b.used() else 0;
}

/// The manifest line a budget-truncated run carries. The root reads the
/// manifest (workflow_progress.buildManifest) — so this is where it learns
/// that its evidence is partial BY DESIGN and it should land what it has,
/// rather than having to infer that from silence.
pub const truncated_note = "budget-truncated: stopped before the remaining phase(s) to keep enough calls to land the work — synthesize from the partial evidence above and make the edits yourself";

test "roleCost: the measured table, and an off-vocabulary role is not free" {
    try std.testing.expectEqual(@as(u64, 4), roleCost("find"));
    try std.testing.expectEqual(@as(u64, 4), roleCost("sweep"));
    try std.testing.expectEqual(@as(u64, 3), roleCost("verify"));
    try std.testing.expectEqual(@as(u64, 2), roleCost("synthesize"));
    try std.testing.expectEqual(@as(u64, 1), roleCost("judge"));
    try std.testing.expectEqual(@as(u64, 6), roleCost("implement"));
    try std.testing.expectEqual(@as(u64, 6), roleCost("build"));
    try std.testing.expectEqual(cost_default, roleCost(""));
    try std.testing.expectEqual(cost_default, roleCost("ponder"));
}

test "landingReserve: a floor below cap 30, a fifth above it" {
    try std.testing.expectEqual(@as(u64, 6), landingReserve(0)); // unlimited still has a floor
    try std.testing.expectEqual(@as(u64, 6), landingReserve(12));
    try std.testing.expectEqual(@as(u64, 6), landingReserve(30));
    try std.testing.expectEqual(@as(u64, 8), landingReserve(40));
    try std.testing.expectEqual(@as(u64, 20), landingReserve(100));
}

test "fleetFloor: every shape costs more than the reserve it must clear" {
    for ([_]Shape{ .review, .research, .design, .feature, .migration, .adhoc }) |s| {
        try std.testing.expect(fleetFloor(s) >= min_landing_reserve);
    }
    // The study's cap-30 bugfix: a review fleet (17) plus the reserve (6) is
    // 23 of the ~27 calls left after the root has read the task — affordable
    // on paper, which is exactly why SCOPE, not budget alone, has to gate it.
    try std.testing.expectEqual(@as(u64, 17), fleetFloor(.review));
    try std.testing.expectEqual(@as(u64, 14), fleetFloor(.research));
    try std.testing.expectEqual(@as(u64, 12), fleetFloor(.feature));
}

test "Ledger: spendable, fits and earlyExit all sit ON TOP of the reserve" {
    var l = Ledger.init(30);
    try std.testing.expectEqual(@as(u64, 6), l.reserve);
    try std.testing.expectEqual(@as(u64, 21), l.spendable(27));
    try std.testing.expect(l.fits(27, 21));
    try std.testing.expect(!l.fits(27, 22)); // one call into the reserve is one too many
    // Saturating, never wrapping: below the reserve there is simply nothing
    // to spend, and no gate may read that as "a very large budget".
    try std.testing.expectEqual(@as(u64, 0), l.spendable(4));
    try std.testing.expect(!l.fits(4, 1));
    // P2: 10 left, 6 reserved, the rest of the plan needs at least 5 → stop.
    try std.testing.expect(l.earlyExit(10, 5));
    try std.testing.expect(!l.earlyExit(12, 5));
    l.commit(12);
    try std.testing.expectEqual(@as(u64, 12), l.committed);
}

test "affordsHarnessNote (#391): the note clears #390's reserve, it does not get one of its own" {
    const l = Ledger.init(30);
    // The boundary is DERIVED from the landing reserve, not from a constant of
    // the note's own: the first `remaining` that admits a note is one call
    // above the reserve #390 holds back. A second, independent reserve would
    // move this boundary and fail here.
    const boundary = landingReserve(30) + cost_precompact_note;
    try std.testing.expect(l.affordsHarnessNote(boundary));
    try std.testing.expect(!l.affordsHarnessNote(boundary - 1)); // exactly the reserve: landing only
    try std.testing.expect(!l.affordsHarnessNote(0));
    // And the note is junior to a phase that fits: whatever spendable() says
    // is available for real work is available for the note too, never more.
    try std.testing.expectEqual(l.fits(boundary, cost_precompact_note), l.affordsHarnessNote(boundary));
    // An unlimited pool always affords it (the reserve is still nominal).
    try std.testing.expect(Ledger.init(0).affordsHarnessNote(std.math.maxInt(u64)));
}

test "Ledger: an unlimited pool never gates" {
    const l = Ledger.init(0);
    try std.testing.expect(l.unlimited());
    try std.testing.expect(l.fits(std.math.maxInt(u64), 1_000_000));
    try std.testing.expect(!l.earlyExit(0, 1_000_000));
}

test "planEstimate / laterPhasesMin read the authored plan, not a guess" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\[{"title":"find the defect","tasks":[1,2,3]},
        \\ {"title":"implement the fix","tasks":[1]},
        \\ {"title":"verify the diff","tasks":[1]}]
    ;
    const v = try std.json.parseFromSliceLeaky(Value, a, src, .{});
    const phases = v.array.items;
    // 3 finders (12) + 1 implementer (6) + 1 skeptic (3)
    try std.testing.expectEqual(@as(u64, 21), planEstimate(phases));
    // From phase 2 onward, one worker each: implement (6) + verify (3).
    try std.testing.expectEqual(@as(u64, 9), laterPhasesMin(phases, 1));
    try std.testing.expectEqual(@as(u64, 3), laterPhasesMin(phases, 2));
    try std.testing.expectEqual(@as(u64, 0), laterPhasesMin(phases, 3));
}

test "isLandingRole names exactly the phases a downsize may never trim" {
    try std.testing.expect(isLandingRole("implement"));
    try std.testing.expect(isLandingRole("build"));
    try std.testing.expect(isLandingRole("repair"));
    try std.testing.expect(!isLandingRole("find"));
    try std.testing.expect(!isLandingRole("verify"));
    try std.testing.expect(!isLandingRole("judge"));
    // The landing roles the catalog can actually produce are canonical slots,
    // so a plan cannot dodge the protection by titling its edit phase
    // naturally — canonicalSlot still resolves it to the protected word.
    try std.testing.expectEqualStrings("implement", shapes.canonicalSlot("implement the fix"));
    try std.testing.expectEqualStrings("build", shapes.canonicalSlot("build from the winner"));
}
