//! The escalation ladder as a LEARNED policy.
//!
//! escalation.zig's rungs are hand rules, and hand rules are a bootstrap, not
//! an answer: they encode what one 16-run study measured on one machine with
//! one model. This module is how they erode toward measured reality. Every
//! admission decision writes a `kind:"orch"` row naming the rung it chose and
//! WHY (learned | bootstrap | explicit | explore); every scored run writes a
//! `kind:"orch_outcome"` row naming what that rung actually cost and whether
//! it landed the work; `foldArms` pools them per cell; and where a cell has
//! real evidence, the learned arm replaces the hand rung.
//!
//! Sibling of route_policy.zig, deliberately: same archive, same fold-once
//! pass (bench_priors.loadInto), same #290 discipline. The difference is what
//! is being learned — route_policy learns WHICH MODEL serves a (shape, role)
//! seat; this learns HOW MUCH ORCHESTRATION a (task_class, budget_band,
//! stratum) cell is worth buying. Those are orthogonal, and keeping them in
//! two modules keeps a change to one from silently re-weighting the other.
//!
//! THE #290 FIREWALL, inviolable and enforced in foldArms:
//!
//!   * `source:"explicit"` rows NEVER fold. When the user names the shape,
//!     the arm records user intent, not policy quality; folding it would let
//!     a run the policy did not choose vote on what the policy should choose.
//!   * Folding is WITHIN A STRATUM only — the stratum is part of the key, so
//!     two runs on different models never pool. A rung that is right for a
//!     frontier root is not automatically right for a small one.
//!   * `variant_free:false` rows are excluded. If scoreVariants mutated the
//!     genome mid-run, the score measures a prompt tournament as much as the
//!     rung; only champion-genome runs attribute to the arm.
//!   * Comparisons are per-cell MEANS gated by `min_arm_obs`, never
//!     prompt-level A/B. One lucky run must not move a ladder.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shapes = @import("shapes.zig");

pub const TaskClass = shapes.TaskClass;

// ── the arms ───────────────────────────────────────────────────────────────

/// How much orchestration a run bought. The closed vocabulary both the hand
/// ladder and the learned policy speak.
pub const Rung = enum {
    /// Solo: the root does the work; the workflow tool declines and says so.
    R0,
    /// Solo, DEEPER: decline again after a first failure, but prescribe a
    /// sequential revision — retry carrying the concrete failure evidence,
    /// think longer, verify against the signal that failed. Admitted only
    /// when a verifier exists (failure_evidence.verifierFor): without
    /// external feedback a revision loop converts right answers to wrong
    /// ones, so a verifier-less failure goes straight to R3, where the
    /// judges ARE the feedback.
    R0d,
    /// One scout: a single sweep + synthesize, to keep the parent's context
    /// clean rather than to parallelize.
    R1,
    /// A fleet: the authored shape, possibly downsized to fit the budget.
    R2,
    /// The full shape plus judges — audit-class asks and post-failure retries.
    R3,

    pub fn label(self: Rung) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Rung {
        return std.meta.stringToEnum(Rung, s);
    }

    /// Ordinal, for the trade-down asymmetry in `override`. R0d sits between
    /// solo and scout: it spends no spawns, but it does spend a root retry
    /// the plain R0 decline would not have prescribed.
    pub fn level(self: Rung) u8 {
        return switch (self) {
            .R0 => 0,
            .R0d => 1,
            .R1 => 2,
            .R2 => 3,
            .R3 => 4,
        };
    }
};

/// Which layer produced the rung on a decision row. Named on every row so
/// "why did this run fan out" is a grep, not an inference — the same
/// discipline route_policy.Source applies to model routing.
pub const Source = enum {
    /// A folded cell with enough observations beat the hand ladder.
    learned,
    /// The hand ladder in escalation.zig decided (the default, and what a
    /// fresh install does forever until it has evidence).
    bootstrap,
    /// The USER named the shape/rung. Never folded — see the firewall above.
    explicit,
    /// An ε-greedy probe, taken only where the answer would have been R0.
    explore,

    pub fn label(self: Source) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Source {
        return std.meta.stringToEnum(Source, s);
    }
};

/// `remaining()` bucketed. A rung that is right with 100 calls left is wrong
/// with 15, so the budget has to be part of the key rather than a covariate.
pub const BudgetBand = enum {
    b15,
    b40,
    b100,
    unlimited,

    pub fn of(remaining: u64) BudgetBand {
        if (remaining == std.math.maxInt(u64)) return .unlimited;
        if (remaining <= 15) return .b15;
        if (remaining <= 40) return .b40;
        if (remaining <= 100) return .b100;
        return .unlimited;
    }

    pub fn label(self: BudgetBand) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) BudgetBand {
        return std.meta.stringToEnum(BudgetBand, s) orelse .unlimited;
    }
};

/// How many distinct files the ask names. RECORDED on rows as a signal, never
/// part of the key: three buckets times the key above would quadruple the
/// cell count and no install would ever reach min_arm_obs in any of them.
pub const ScopeBucket = enum {
    s1_2,
    s3_5,
    s6plus,

    pub fn of(files: usize) ScopeBucket {
        if (files <= 2) return .s1_2;
        if (files <= 5) return .s3_5;
        return .s6plus;
    }

    pub fn label(self: ScopeBucket) []const u8 {
        return @tagName(self);
    }
};

/// The niche key. `stratum` is the root's resolved model, per fitness_strata
/// rules (route_policy.stratumOf) — a borrowed slice, valid for the archive
/// read that produced it.
pub const Key = struct {
    task_class: TaskClass = .other,
    budget_band: BudgetBand = .unlimited,
    stratum: []const u8 = "",

    pub fn eql(a: Key, b: Key) bool {
        return a.task_class == b.task_class and a.budget_band == b.budget_band and
            std.mem.eql(u8, a.stratum, b.stratum);
    }
};

// ── folded observations ────────────────────────────────────────────────────

/// A cell needs this many observations of an arm before the policy will speak
/// for it. Three, not two: at n=2 a single outlier is half the evidence.
pub const min_arm_obs: u32 = 3;

/// How much better a learned arm must score before it may ESCALATE past the
/// hand ladder. Trading DOWN is cheaper (see `override`) — the asymmetry is
/// deliberate, because the failure mode this whole redesign exists to fix is
/// over-escalation, and a policy that finds cheaper answers should be able to
/// act on that sooner than one that finds more expensive ones.
pub const override_delta: f64 = 0.05;

/// Call samples kept per arm, for the p90. Bounded so an install with a long
/// history cannot make the fold allocate without limit.
pub const max_call_samples = 64;

pub const ArmObs = struct {
    key: Key = .{},
    arm: Rung = .R0,
    n: u32 = 0,
    sum_score: f64 = 0,
    exhausted_n: u32 = 0,
    landed_n: u32 = 0,
    calls: [max_call_samples]u32 = @splat(0),
    n_calls: usize = 0,

    pub fn mean(self: ArmObs) f64 {
        return if (self.n == 0) 0 else self.sum_score / @as(f64, @floatFromInt(self.n));
    }

    pub fn exhaustRate(self: ArmObs) f64 {
        return if (self.n == 0) 0 else @as(f64, @floatFromInt(self.exhausted_n)) / @as(f64, @floatFromInt(self.n));
    }

    pub fn landRate(self: ArmObs) f64 {
        return if (self.n == 0) 0 else @as(f64, @floatFromInt(self.landed_n)) / @as(f64, @floatFromInt(self.n));
    }

    /// The 90th-percentile call count, by nearest-rank over the retained
    /// samples. Used as the cost half of the override rule: a learned arm may
    /// only be taken when its BAD case still fits, not when its median does.
    pub fn p90Calls(self: ArmObs) u64 {
        if (self.n_calls == 0) return 0;
        var buf: [max_call_samples]u32 = @splat(0);
        @memcpy(buf[0..self.n_calls], self.calls[0..self.n_calls]);
        const s = buf[0..self.n_calls];
        std.mem.sort(u32, s, {}, std.sort.asc(u32));
        // Nearest-rank: ceil(0.9 * n), 1-based, clamped into the slice.
        const rank = (self.n_calls * 9 + 9) / 10;
        return s[@min(rank, s.len) - 1];
    }

    fn note(self: *ArmObs, score: f64, calls: u64, exhausted: bool, landed: bool) void {
        self.sum_score += score;
        self.n += 1;
        if (exhausted) self.exhausted_n += 1;
        if (landed) self.landed_n += 1;
        if (self.n_calls < max_call_samples) {
            self.calls[self.n_calls] = std.math.cast(u32, calls) orelse std.math.maxInt(u32);
            self.n_calls += 1;
        }
    }
};

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn numField(o: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |x| @floatFromInt(x),
        else => null,
    };
}

fn boolField(o: std.json.ObjectMap, key: []const u8, dflt: bool) bool {
    const v = o.get(key) orelse return dflt;
    return if (v == .bool) v.bool else dflt;
}

/// Pool the archive's `kind:"orch_outcome"` rows into (key, arm) cells,
/// applying the #290 firewall. A row missing any coordinate is SKIPPED rather
/// than filed under a default — an uncelled observation is honest, a
/// mis-celled one silently steers every future run in that cell.
pub fn foldArms(arena: Allocator, archive: []const u8) []ArmObs {
    var out: std.ArrayList(ArmObs) = .empty;
    var it = std.mem.splitScalar(u8, archive, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const kind = strField(o, "kind") orelse continue;
        if (!std.mem.eql(u8, kind, "orch_outcome")) continue;

        // FIREWALL 1 — user intent never votes on policy.
        const source = Source.parse(strField(o, "source") orelse "") orelse continue;
        if (source == .explicit) continue;
        // FIREWALL 2 — only champion-genome runs attribute to the arm.
        if (!boolField(o, "variant_free", true)) continue;

        const arm = Rung.parse(strField(o, "arm") orelse "") orelse continue;
        // FIREWALL 3 — the stratum is part of the key, so a row without one
        // cannot be pooled with rows that have one.
        const stratum = strField(o, "stratum") orelse continue;
        if (stratum.len == 0) continue;
        const tc = strField(o, "task_class") orelse continue;
        const bb = strField(o, "budget_band") orelse continue;
        const score = numField(o, "score") orelse continue;
        if (!(score >= 0 and score <= 1)) continue; // the #168 [0,1] contract
        const calls: u64 = blk: {
            const c = numField(o, "calls_used") orelse break :blk 0;
            break :blk if (c < 0) 0 else @intFromFloat(c);
        };
        const key: Key = .{
            .task_class = TaskClass.parse(tc),
            .budget_band = BudgetBand.parse(bb),
            .stratum = stratum,
        };
        const slot: *ArmObs = for (out.items) |*c| {
            if (c.arm == arm and c.key.eql(key)) break c;
        } else blk: {
            out.append(arena, .{ .key = key, .arm = arm }) catch return out.items;
            break :blk &out.items[out.items.len - 1];
        };
        slot.note(score, calls, boolField(o, "exhausted", false), boolField(o, "landed", false));
    }
    return out.items;
}

/// Session-arena cells, folded once by bench_priors.loadInto off the same
/// archive read that feeds route_policy — so the two policies can never
/// disagree about which runs they have seen. Empty = no evidence = the hand
/// ladder decides, which is what a fresh install does.
pub var g_arms: []const ArmObs = &.{};

pub fn loadArms(arena: Allocator, archive: []const u8) void {
    g_arms = foldArms(arena, archive);
}

// ── the bootstrap prior ────────────────────────────────────────────────────

/// What the study measured, as pseudo-observations. These are the ONLY
/// evidence a fresh install has, and they are deliberately weak (n=2, below
/// min_arm_obs) so three real local rows outvote them completely.
///
/// Read the bugfix/b40 pair as the whole story this redesign exists for: at a
/// cap of 30, solo scored 1.0 in 10 calls and the fleet scored 0.0 in 30 and
/// died exhausted. Given an unbounded pool the fleet does eventually get
/// there (0.8 at 48 calls) — it was never WRONG, it was overpriced.
pub const Pseudo = struct {
    task_class: TaskClass,
    budget_band: BudgetBand,
    arm: Rung,
    score: f64,
    calls: u64,
    exhausted: bool = false,
    landed: bool = true,
    n: u32 = 2,
};

pub const bootstrap_prior = [_]Pseudo{
    .{ .task_class = .bugfix, .budget_band = .b40, .arm = .R0, .score = 1.0, .calls = 10 },
    .{ .task_class = .bugfix, .budget_band = .b40, .arm = .R2, .score = 0.0, .calls = 30, .exhausted = true, .landed = false },
    .{ .task_class = .bugfix, .budget_band = .unlimited, .arm = .R0, .score = 1.0, .calls = 10 },
    .{ .task_class = .bugfix, .budget_band = .unlimited, .arm = .R2, .score = 0.8, .calls = 48 },
    .{ .task_class = .feature, .budget_band = .b40, .arm = .R0, .score = 1.0, .calls = 5 },
    .{ .task_class = .feature, .budget_band = .b40, .arm = .R2, .score = 1.0, .calls = 30, .exhausted = true },
    .{ .task_class = .refactor, .budget_band = .b40, .arm = .R0, .score = 1.0, .calls = 9 },
    .{ .task_class = .refactor, .budget_band = .b40, .arm = .R2, .score = 1.0, .calls = 30, .exhausted = true },
    .{ .task_class = .research, .budget_band = .unlimited, .arm = .R1, .score = 1.0, .calls = 12 },
    .{ .task_class = .research, .budget_band = .unlimited, .arm = .R2, .score = 1.0, .calls = 24 },
};

/// The prior for one cell, as ArmObs, so `override` reads one shape of
/// evidence whether it came from the compiled table or the local archive.
pub fn priorFor(buf: []ArmObs, key: Key) []ArmObs {
    var n: usize = 0;
    for (bootstrap_prior) |p| {
        if (n == buf.len) break;
        if (p.task_class != key.task_class or p.budget_band != key.budget_band) continue;
        var obs: ArmObs = .{ .key = key, .arm = p.arm };
        var k: u32 = 0;
        while (k < p.n) : (k += 1) obs.note(p.score, p.calls, p.exhausted, p.landed);
        buf[n] = obs;
        n += 1;
    }
    return buf[0..n];
}

// ── the override rule ──────────────────────────────────────────────────────

fn findArm(arms: []const ArmObs, key: Key, arm: Rung) ?ArmObs {
    for (arms) |a| if (a.arm == arm and a.key.eql(key)) return a;
    return null;
}

/// The learned rung for `key`, or null to keep `ladder` — which is what every
/// sparse, unmeasured or unaffordable case returns, so bootstrap behavior is
/// the hand ladder's behavior.
///
/// Two asymmetric gates, both requiring n >= min_arm_obs:
///
///   ESCALATE (a higher rung than the ladder chose): must beat the ladder
///   arm's folded mean by `override_delta`, AND its p90 call count plus the
///   landing reserve must still fit what is left. Buying more orchestration
///   is the expensive direction and the one that historically went wrong, so
///   it pays for both a quality margin and a worst-case budget check.
///
///   TRADE DOWN (a lower rung): needs only "not worse". #372 established this
///   asymmetry one level down for model seating — a cheaper answer that
///   matches on quality is strictly better and does not owe a margin — and it
///   lifts cleanly to rungs, where the cheaper arm ALSO reduces exhaustion
///   risk, which is a second win the mean does not price.
pub fn override(arms: []const ArmObs, key: Key, ladder: Rung, remaining: u64, landing_reserve: u64) ?Rung {
    const base = findArm(arms, key, ladder) orelse return null;
    if (base.n < min_arm_obs) return null;
    var best: ?ArmObs = null;
    for (arms) |cand| {
        if (cand.arm == ladder or !cand.key.eql(key)) continue;
        if (cand.n < min_arm_obs) continue;
        const down = cand.arm.level() < ladder.level();
        if (down) {
            if (cand.mean() + 1e-9 < base.mean()) continue;
        } else {
            if (cand.mean() < base.mean() + override_delta) continue;
            // Unlimited pools skip the affordability half — there is nothing
            // to outspend — but a finite one must fit the arm's BAD case.
            if (remaining != std.math.maxInt(u64) and cand.p90Calls() + landing_reserve > remaining) continue;
        }
        // Among qualifying arms prefer the higher mean; tie-break toward the
        // CHEAPER rung, which is the direction this redesign is biased in.
        if (best) |b| {
            const better = cand.mean() > b.mean() + 1e-9 or
                (@abs(cand.mean() - b.mean()) <= 1e-9 and cand.arm.level() < b.arm.level());
            if (!better) continue;
        }
        best = cand;
    }
    const w = best orelse return null;
    return w.arm;
}

/// Production entry point: the session's folded arms, falling back to the
/// compiled prior when the local archive has never seen this cell.
pub fn learnedRung(key: Key, ladder: Rung, remaining: u64, landing_reserve: u64) ?Rung {
    if (override(g_arms, key, ladder, remaining, landing_reserve)) |r| return r;
    var buf: [8]ArmObs = undefined;
    return override(priorFor(&buf, key), key, ladder, remaining, landing_reserve);
}

// ── reporting ──────────────────────────────────────────────────────────────

/// Score per model call — the number the whole redesign is trying to move,
/// and the one the study reported as its headline (ultracode: 80 at 3.7x the
/// calls). Zero calls reads as zero rather than as infinity.
pub fn efficiency(score: f64, api_calls: u64) f64 {
    if (api_calls == 0) return 0;
    return score / @as(f64, @floatFromInt(api_calls));
}

/// The two row shapes this policy learns from live next door (600-line cap);
/// re-exported so a caller reaches the whole policy through one import.
pub const rows = @import("orchestration_rows.zig");

test {
    _ = rows;
    _ = @import("orchestration_policy_tests.zig");
}
