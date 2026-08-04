//! The two trajectory rows the orchestration policy learns from, and the
//! parked decision that connects them.
//!
//! Split from orchestration_policy.zig (600-line cap) along the obvious seam:
//! that module owns the ARITHMETIC (fold, override, priors), this one owns the
//! WIRE — what a decision and its outcome look like on disk, and the little
//! bit of session state needed to pair them up.
//!
//! Both are additive to .graff/trajectories/*.jsonl, exactly like #372's
//! `kind:"route"` and #382's `kind:"diversity"`: NEW row shapes rather than
//! extra columns on existing ones, so an offline reader can join orchestration
//! decisions to the runs they produced without a single existing row changing
//! underneath it.

const std = @import("std");

const orch = @import("orchestration_policy.zig");
const trace = @import("trace.zig");
const util = @import("util.zig");

const Key = orch.Key;
const Rung = orch.Rung;
const Source = orch.Source;
const ScopeBucket = orch.ScopeBucket;
const BudgetBand = orch.BudgetBand;

/// Cap on free-text fields copied onto a row, matching route_trace.field_cap:
/// a model-authored label must not be able to turn one row into a megabyte.
pub const field_cap = 64;

pub fn cappedField(s: []const u8) []const u8 {
    return util.utf8Prefix(s, field_cap);
}

/// Everything a decision row says. Built by escalation.admit, which owns the
/// ladder; this module owns the row shape, orchestration_policy the fold that
/// reads it back.
pub const DecisionRow = struct {
    key: Key = .{},
    arm: Rung = .R0,
    source: Source = .bootstrap,
    remaining: u64 = 0,
    scope: ScopeBucket = .s1_2,
    files: usize = 0,
    tasks_authored: usize = 0,
    tasks_collapsed: usize = 0,
    downsized_from: usize = 0,
    /// #382's measurement, carried PRE-SPAWN. Before this the diversity gate
    /// printed to stderr and rode a manifest the root only saw afterwards —
    /// so the one moment the number could still change a decision was the one
    /// moment nothing structured could read it.
    diversity_mean: f64 = 0,
    diversity_warn: bool = false,
};

/// `remaining` as JSON: an unlimited pool is maxInt(u64), and writing that
/// literal into a row would make every offline percentile meaningless. -1 is
/// the honest spelling of "no ceiling".
fn remainingField(remaining: u64) i64 {
    if (remaining == std.math.maxInt(u64)) return -1;
    return std.math.cast(i64, remaining) orelse -1;
}

pub fn emitDecision(d: DecisionRow) void {
    const tj = trace.g_traj orelse return;
    tj.node(.{
        .kind = "orch",
        .task_class = d.key.task_class.label(),
        .budget_band = d.key.budget_band.label(),
        .stratum = cappedField(d.key.stratum),
        .arm = d.arm.label(),
        .source = d.source.label(),
        .remaining = remainingField(d.remaining),
        .scope_bucket = d.scope.label(),
        .files_named = d.files,
        .tasks_authored = d.tasks_authored,
        .tasks_collapsed = d.tasks_collapsed,
        .downsized_from = d.downsized_from,
        .diversity_mean = d.diversity_mean,
        .diversity_warn = d.diversity_warn,
        .t = tj.elapsedMs(),
    });
}

pub const OutcomeRow = struct {
    key: Key = .{},
    arm: Rung = .R0,
    source: Source = .bootstrap,
    /// [0,1], the #168 contract.
    score: f64 = 0,
    calls_used: u64 = 0,
    wall_ms: i64 = 0,
    exhausted: bool = false,
    /// The edit-contract probe's verdict: did anything actually change on disk?
    landed: bool = false,
    /// False when scoreVariants mutated a genome during the run — see the
    /// #290 firewall at the top of orchestration_policy.zig.
    variant_free: bool = true,
    eval_set_hash: []const u8 = "",
};

pub fn emitOutcome(o: OutcomeRow) void {
    const tj = trace.g_traj orelse return;
    tj.node(.{
        .kind = "orch_outcome",
        .task_class = o.key.task_class.label(),
        .budget_band = o.key.budget_band.label(),
        .stratum = cappedField(o.key.stratum),
        .arm = o.arm.label(),
        .source = o.source.label(),
        .score = o.score,
        .calls_used = o.calls_used,
        .wall_ms = o.wall_ms,
        .exhausted = o.exhausted,
        .landed = o.landed,
        .variant_free = o.variant_free,
        .eval_set_hash = cappedField(o.eval_set_hash),
        .efficiency = orch.efficiency(o.score, o.calls_used),
        .t = tj.elapsedMs(),
    });
}

// ── the pending decision ───────────────────────────────────────────────────
// A decision is made at admission and only PAID FOR much later — when a score
// lands, or when the pool runs dry. Nothing in between carries the key, so it
// is parked here.
//
// A fixed stratum buffer rather than a borrowed slice, for the same reason
// shapes.rawAsk() uses one: the decision is made inside a per-turn arena and
// read from `exhaustedFatal`, which runs after everything has been torn down.

var g_pending_stratum: [field_cap]u8 = undefined;
var g_pending: ?Pending = null;

pub const Pending = struct {
    task_class: orch.TaskClass,
    budget_band: BudgetBand,
    stratum_len: usize,
    arm: Rung,
    source: Source,
    calls_at_start: u64,
    variant_free: bool = true,
    landed: bool = false,

    pub fn key(self: Pending) Key {
        return .{
            .task_class = self.task_class,
            .budget_band = self.budget_band,
            .stratum = g_pending_stratum[0..self.stratum_len],
        };
    }
};

pub fn setPending(k: Key, arm: Rung, source: Source, calls_at_start: u64) void {
    const s = cappedField(k.stratum);
    const n = @min(s.len, g_pending_stratum.len);
    @memcpy(g_pending_stratum[0..n], s[0..n]);
    g_pending = .{
        .task_class = k.task_class,
        .budget_band = k.budget_band,
        .stratum_len = n,
        .arm = arm,
        .source = source,
        .calls_at_start = calls_at_start,
    };
}

pub fn pending() ?Pending {
    return g_pending;
}

pub fn clearPending() void {
    g_pending = null;
}

/// The edit-contract probe's verdict, folded into whatever outcome row this
/// decision eventually files. Sticky in the TRUE direction: one phase that
/// really changed files is enough to call the run landed.
pub fn notePendingLanded(landed: bool) void {
    if (g_pending) |*p| p.landed = p.landed or landed;
}

/// A judge tournament ran, so this run's score is no longer attributable to
/// the ARM alone (#290 firewall). Sticky: once contaminated, always.
pub fn notePendingVariants() void {
    if (g_pending) |*p| p.variant_free = false;
}

/// File the outcome for the parked decision and clear it, so one decision
/// files exactly one outcome however many funnels reach this function.
/// `used` is the run budget's current call count; the delta from admission is
/// what this decision actually cost.
pub fn flushPending(score: f64, used: u64, wall_ms: i64, exhausted: bool, eval_set_hash: []const u8) void {
    const p = g_pending orelse return;
    g_pending = null;
    emitOutcome(.{
        .key = p.key(),
        .arm = p.arm,
        .source = p.source,
        .score = score,
        .calls_used = used -| p.calls_at_start,
        .wall_ms = wall_ms,
        .exhausted = exhausted,
        .landed = p.landed,
        .variant_free = p.variant_free,
        .eval_set_hash = eval_set_hash,
    });
}
