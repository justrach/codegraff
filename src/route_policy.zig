//! #372 — learned orchestration policy, and the per-worker routing trace.
//!
//! Before this module an ultracode run LOOKED learned and was not. The root
//! model picked a shape out of the fixed catalog (shapes.zig), authored the
//! workflow JSON, and every worker it spawned silently inherited the session
//! route; the fleet then scored the prompt genome only. Nobody ever recorded
//! — let alone learned — whether a cheaper rung or another model was the
//! better quality/cost policy for "the researchers of a research sweep".
//!
//! Two things live here, in that order:
//!
//!  1. THE ROUTING TRACE (the mandatory minimum). Every spawned worker emits
//!     one line naming the whole decision:
//!
//!       shape=research role=sweep tier=mid resolved_model=gpt-5.6-terra
//!         source=ladder policy_or_genome_id=ladder:codex
//!
//!     on three paths at once — the tracer note stream (`ev:"route"` in
//!     .graff/traces), a `kind:"route"` DGM archive row, and an `agent_route`
//!     --json event. `source` is the closed vocabulary the issue asks for:
//!     explicit-pin > persona > learned-policy > workflow-override >
//!     session-default > ladder, highest-precedence layer that actually
//!     decided this worker's model. So "which came from the fixed catalog,
//!     which the root model authored, which came from fleet fitness" is a
//!     grep, not an inference.
//!
//!  2. THE LEARNED TIER POLICY (the first learning increment). Scored runs
//!     now record the (shape, role, tier, model) coordinates on their local
//!     DGM `kind:"score"` rows, foldCells pools them per cell, and
//!     `learnedRung` lets tier→model resolution consult that evidence with a
//!     strict hierarchy: exact (shape, role) cell → shape-level pool →
//!     nothing (the provider ladder / bench priors answer, exactly as
//!     today). A sparse cell therefore cannot move anything, and an install
//!     with no archive behaves bit-for-bit like before.
//!
//! WHAT THE POLICY IS ALLOWED TO DO. Only ever replace the ladder's own
//! answer with a candidate that DOMINATES it in bench_priors' sense — at
//! least its quality for strictly less money (bench.dominates/effCost, the
//! same Pareto machinery #373 seats the ladders with; there is deliberately
//! no second scoring scheme). It can never escalate cost, never raise the
//! tier, and never name a model the cell has no lived evidence for. When the
//! ladder's answer is not itself in the cell, the policy has no basis for a
//! comparison and stays silent.
//!
//! #290 FIREWALL. The policy is keyed on (shape, role, tier) and NEVER on a
//! prompt genome, and it is consulted at the tier-resolution layer only —
//! below every explicit pin (subagent_pin's precedence is untouched: an
//! explicit `model` bypasses this module entirely, and an explicit `tier`
//! only chooses WHICH model serves that rung). Workflow PHASE tasks still
//! take no PER-TASK pins at all: #376 applies this policy once for a whole
//! phase (route_phase.zig), so every worker in it runs the SAME model and
//! scoreVariants keeps ranking prompt variants that ran on one identical
//! configuration. What varies across RUNS is now recorded instead of being
//! averaged over — see `stratumOf` below and fitness_strata.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shapes = @import("shapes.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const bench = @import("bench_priors.zig");
const selection = @import("subagent_selection.zig");
const util = @import("util.zig");

pub const Tier = tier_ladder.Tier;

/// The fixed shape catalog (shapes.zig) as a closed identifier: the FIRST
/// component of a policy cell. Derived from the phase titles the root model
/// authored rather than declared by it — the model picks a shape by naming
/// its phases with slot words, so the slots are the ground truth for which
/// catalog entry actually ran. `adhoc` covers a bare `subagent` spawn and any
/// workflow whose titles are off-vocabulary: both still run, they just do not
/// accrue shape-partitioned fitness.
pub const Shape = enum {
    review, // A — find/verify/synthesize
    research, // B — sweep/synthesize
    design, // C — variants/build
    migration, // D — pipeline (transform/verify); never scored, see #296
    feature, // E — scope/implement/review
    adhoc,

    pub fn label(self: Shape) []const u8 {
        return @tagName(self);
    }

    /// Exact, closed vocabulary — anything else is `adhoc`, never a guess.
    pub fn parse(s: []const u8) Shape {
        return std.meta.stringToEnum(Shape, s) orelse .adhoc;
    }
};

/// The highest-precedence layer that CONFIGURED this worker. Listed in
/// precedence order.
///
/// `workflow_override` deserves its own note, because it is the answer to
/// "which decisions did the root model author": the root model wrote this
/// task's inline `system_prompt` genome, and `policy_or_genome_id` carries
/// that genome's fingerprint. Its `resolved_model` is by construction still
/// the session's route — #290 keeps per-task MODEL pins out of a scored
/// phase — and making that visible on every such line is precisely the gap
/// #372 reports: the UX read as if the root model had chosen a route it
/// never had the power to choose.
pub const Source = enum {
    explicit_pin, // `model`/`tier` on the spawn call itself
    persona, // `.harness/agents/<name>.md` frontmatter pin
    vision_ask, // #380: the task names an image and the automatic seat was blind
    learned_policy, // a (shape, role) cell re-seated the tier's rung
    workflow_override, // the root model authored this worker's genome
    session_default, // --subagent-model, or the root the child inherits
    ladder, // the #291/#373 provider tier ladder (bench-derived or compiled)

    /// The wire spelling the issue pins: hyphens, not underscores.
    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .explicit_pin => "explicit-pin",
            .persona => "persona",
            .vision_ask => "vision-ask",
            .learned_policy => "learned-policy",
            .workflow_override => "workflow-override",
            .session_default => "session-default",
            .ladder => "ladder",
        };
    }
};

/// The policy partition key: (shape, role). `role` is kept inside shapes.zig's
/// CLOSED slot vocabulary on purpose — free-text roles would mint a fresh cell
/// per run and nothing would ever accumulate, the same reason canonical_slots
/// exists for #290's MAP-Elites key.
pub const Cell = struct {
    shape: Shape = .adhoc,
    role: []const u8 = "",
};

/// One worker's complete routing decision — everything the trace line needs.
pub const Decision = struct {
    shape: Shape = .adhoc,
    role: []const u8 = "",
    tier: ?Tier = null,
    resolved_model: []const u8 = "",
    source: Source = .session_default,
    /// The learned cell id (`research/sweep@mid`) when fleet fitness decided
    /// this, else the genome fingerprint / persona / ladder id that did.
    policy_id: []const u8 = "",
};

/// Free-text fields are model-authored; cap them so one absurd label cannot
/// turn a trace line into a megabyte.
const field_cap = 64;
const line_cap = 320;

fn dash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else util.utf8Prefix(s, field_cap);
}

fn tierName(t: ?Tier) []const u8 {
    return if (t) |x| x.label() else "";
}

/// The #372 routing-trace line, verbatim in the issue's field order. Every
/// absent field renders `-` rather than an empty `key=` so the line is
/// unambiguous to split on.
pub fn formatDecision(buf: []u8, d: Decision) []const u8 {
    return std.fmt.bufPrint(buf, "shape={s} role={s} tier={s} resolved_model={s} source={s} policy_or_genome_id={s}", .{
        d.shape.label(),
        dash(d.role),
        dash(tierName(d.tier)),
        dash(d.resolved_model),
        d.source.label(),
        dash(d.policy_id),
    }) catch buf[0..0];
}

/// The worker's ROLE inside its shape: the canonical slot its phase title or
/// task description names, else the slot its persona niche names, else "" —
/// uncelled, exactly like an off-vocabulary phase title (shapes.canonicalSlot).
pub fn roleOf(label: []const u8, niche: []const u8) []const u8 {
    const from_label = shapes.canonicalSlot(label);
    return if (from_label.len > 0) from_label else shapes.canonicalSlot(niche);
}

/// The canonical slot of one workflow phase object, "" when off-vocabulary.
pub fn phaseSlot(pv: std.json.Value) []const u8 {
    if (pv != .object) return "";
    const t = pv.object.get("title") orelse return "";
    return if (t == .string) shapes.canonicalSlot(t.string) else "";
}

/// Which catalog shape this workflow actually instantiated, read off the
/// phase titles. Checked most-distinctive first: `sweep` only exists in B,
/// `find` only in A, `variants`/`build` only in C; `scope`/`implement`/
/// `review` are E's. A workflow naming none of them is `adhoc`.
pub fn shapeOfPhases(phases: []const std.json.Value) Shape {
    var research = false;
    var review = false;
    var design = false;
    var feature = false;
    for (phases) |pv| {
        const slot = phaseSlot(pv);
        if (slot.len == 0) continue;
        if (std.mem.eql(u8, slot, "sweep")) research = true;
        if (std.mem.eql(u8, slot, "find")) review = true;
        if (std.mem.eql(u8, slot, "variants") or std.mem.eql(u8, slot, "build")) design = true;
        if (std.mem.eql(u8, slot, "scope") or std.mem.eql(u8, slot, "implement") or std.mem.eql(u8, slot, "review")) feature = true;
    }
    if (research) return .research;
    if (review) return .review;
    if (design) return .design;
    if (feature) return .feature;
    return .adhoc;
}

/// Which rung of its provider's ladder `model` sits on, or null when the
/// model is off-ladder. The inverse of TierLadder.modelFor — needed because a
/// worker that inherited the session default has a model but no stated tier,
/// and the trace (and the policy cell it feeds) is keyed on the rung.
pub fn tierOf(provider_id: []const u8, model: []const u8) ?Tier {
    const l = tier_ladder.forProvider(provider_id) orelse return null;
    if (std.mem.eql(u8, l.frontier, model)) return .frontier;
    if (l.mid) |m| if (std.mem.eql(u8, m, model)) return .mid;
    if (l.small) |s| if (std.mem.eql(u8, s, model)) return .small;
    return null;
}

/// The rung label `model` sits on, for the archive's `tier` column. "" when
/// the model is off-ladder — an uncelled observation, which foldCells skips
/// rather than filing under a rung nobody can compare it against.
pub fn tierLabelFor(provider_id: []const u8, model: []const u8) []const u8 {
    return if (tierOf(provider_id, model)) |t| t.label() else "";
}

/// #376 — the fitness STRATUM one scored observation belongs to: the resolved
/// model the worker actually ran on.
///
/// Until now the only routing axis a fitness row carried was
/// scoring.providerClass, whose needle table then bucketed gpt-5.6-sol,
/// -terra and -luna IDENTICALLY as "frontier" (closed since — terra/luna are
/// tier-distinct needles now — though a class still pools distinct models:
/// sol and bare gpt-5.6 share "frontier"). A rung-only difference was
/// therefore invisible
/// to every comparison built on it — which is precisely why #290 had to
/// forbid phase workers from varying their model at all: nothing downstream
/// could have told the model's contribution from the prompt's.
///
/// Recording the resolved model per row removes that blindness. A cross-run
/// comparison of two prompt genomes can then be restricted to rows that ran
/// on the same model (fitness_strata.zig) instead of pooling across rungs,
/// which is what makes the phase-uniform routing in route_phase.zig safe.
///
/// A row that names no model — every fitness row written before #372, and
/// mainloop /score's, which never recorded one — reads as `unknown`: its own
/// bucket, ranked only against other unknowns, never silently merged into a
/// measured one.
pub const stratum_unknown = "unknown";

pub fn stratumOf(model: []const u8) []const u8 {
    return if (model.len == 0) stratum_unknown else model;
}

// ── the learned tier policy ────────────────────────────────────────────────

/// One (shape, role, tier, model) observation pooled out of the local DGM
/// archive: how well that worker configuration scored, and how often. Quality
/// only — the COST half comes from the bench sheet (bench_priors), whose
/// units are $/task; mixing a second cost notion in here is exactly what the
/// issue rules out.
pub const CellObs = struct {
    shape: []const u8,
    role: []const u8,
    tier: []const u8,
    model: []const u8,
    sum: f64 = 0,
    n: u32 = 0,

    pub fn mean(self: CellObs) f64 {
        return if (self.n == 0) 0 else self.sum / @as(f64, @floatFromInt(self.n));
    }
};

/// Session-arena cells, folded once by bench_priors.loadInto (which already
/// reads the archive) and refreshed by auto-promote's hot reload alongside
/// the ladders. Empty = no lived evidence = today's behavior everywhere.
pub var g_cells: []const CellObs = &.{};

/// A (cell, model) candidate needs at least this many scored runs before the
/// policy will speak for it. Below it the cell is SPARSE and falls through —
/// one lucky run must not reroute a fleet.
pub const min_model_obs: u32 = 2;

/// Cheap ceiling on how many distinct models one cell can offer. A provider
/// ladder is three rungs deep; eight leaves room for retired names without
/// needing an allocator on the hot resolution path.
pub const max_candidates = 8;

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Pool the archive's self-describing `kind:"score"` rows into cells. A score
/// row only counts when it carries ALL the coordinates — the rows written
/// before #372 (and mainloop /score's) simply have no shape, so they are
/// skipped rather than pooled into a cell they were never observed in.
/// Scores are [0,1] by the #168 contract; anything else is junk.
pub fn foldCells(arena: Allocator, archive: []const u8) []CellObs {
    var out: std.ArrayList(CellObs) = .empty;
    var it = std.mem.splitScalar(u8, archive, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const kind = strField(o, "kind") orelse continue;
        if (!std.mem.eql(u8, kind, "score")) continue;
        const shape = strField(o, "shape") orelse continue;
        const tier = strField(o, "tier") orelse continue;
        const model = strField(o, "model") orelse continue;
        if (shape.len == 0 or tier.len == 0 or model.len == 0) continue;
        const role = strField(o, "role") orelse "";
        const sv = o.get("score") orelse continue;
        const s: f64 = switch (sv) {
            .float => |f| f,
            .integer => |x| @floatFromInt(x),
            else => continue,
        };
        if (!(s >= 0 and s <= 1)) continue;
        const slot: *CellObs = for (out.items) |*c| {
            if (std.mem.eql(u8, c.shape, shape) and std.mem.eql(u8, c.role, role) and
                std.mem.eql(u8, c.tier, tier) and std.mem.eql(u8, c.model, model)) break c;
        } else blk: {
            out.append(arena, .{ .shape = shape, .role = role, .tier = tier, .model = model }) catch return out.items;
            break :blk &out.items[out.items.len - 1];
        };
        slot.sum += s;
        slot.n += 1;
    }
    return out.items;
}

/// Refresh the policy from one archive read. Called by bench_priors.loadInto
/// with the very archive it already blends into the sheet, so the ladders and
/// the cells can never disagree about which runs they have seen.
pub fn loadCells(arena: Allocator, archive: []const u8) void {
    g_cells = foldCells(arena, archive);
}

/// What the bench sheet knows about one model on one provider: its best
/// measured score and best score-per-dollar, i.e. exactly bench.foldProvider
/// restricted to a single name. An unpriced model keeps spd -1, which
/// bench.effCost reads as +inf.
fn sheetCandidate(provider_id: []const u8, model: []const u8, entries: []const bench.Entry) bench.Best {
    var b: bench.Best = .{ .name = model };
    for (entries) |e| {
        const s = bench.normalScore(e.score) orelse continue;
        const r = selection.modelForProvider(provider_id, e.model) orelse continue;
        if (!std.mem.eql(u8, r, model)) continue;
        if (s > b.score) b.score = s;
        if (e.cost > 0 and s / e.cost > b.spd) b.spd = s / e.cost;
    }
    return b;
}

/// This cell's candidates as bench_priors Bests: lived quality blended into
/// the sheet's prior with the SAME pseudo-count damping blend() uses, and the
/// sheet's cost kept verbatim (units stay $/task — blending prices in would
/// poison every domination comparison). `role_exact` false pools the whole
/// shape, which is the second rung of the hierarchy.
fn cellCandidates(
    buf: []bench.Best,
    cells: []const CellObs,
    entries: []const bench.Entry,
    provider_id: []const u8,
    cell: Cell,
    role_exact: bool,
) []bench.Best {
    var n: usize = 0;
    for (cells) |c| {
        if (c.n < min_model_obs) continue;
        if (!std.mem.eql(u8, c.shape, cell.shape.label())) continue;
        if (role_exact and !std.mem.eql(u8, c.role, cell.role)) continue;
        // Deliberately NOT filtered by rung. A model's quality in the "sweep
        // researcher" role does not change because the ladder relabelled it,
        // and filtering to same-rung evidence would make the policy unable to
        // ever learn that the rung BELOW is the better buy — which is the one
        // thing #372 asks it to learn. The rung is still recorded on every
        // observation (provenance, and the cell id a trace line reports), and
        // the ANSWER stays per-tier because each tier's ladder answer — the
        // baseline a challenger must dominate — is different.
        // Provider-local by construction: a name this provider does not serve
        // is not a candidate for its ladder, however well it scored elsewhere.
        const resolved = selection.modelForProvider(provider_id, c.model) orelse continue;
        const sheet = sheetCandidate(provider_id, resolved, entries);
        const cn: f64 = @floatFromInt(c.n);
        // blend() keeps the sheet's COST and re-derives score-per-dollar from
        // the blended score; do the same, or a model that scored badly here
        // would look CHEAPER for it (score/spd with a stale spd) and dominate
        // on an artifact of the arithmetic instead of on its price.
        const cost = bench.effCost(sheet); // +inf when the sheet never priced it
        var cand: bench.Best = .{ .name = sheet.name };
        cand.score = if (sheet.score >= 0)
            (sheet.score * bench.sheet_weight + c.mean() * cn) / (bench.sheet_weight + cn)
        else
            c.mean();
        cand.spd = if (std.math.isInf(cost) or !(cost > 0)) -1 else cand.score / cost;
        // At shape level one model can arrive through several roles; keep the
        // strongest evidence rather than double-counting it as two candidates.
        const seen: ?*bench.Best = for (buf[0..n]) |*b| {
            if (std.mem.eql(u8, b.name, cand.name)) break b;
        } else null;
        if (seen) |b| {
            if (cand.score > b.score) b.* = cand; // score AND its derived spd
            continue;
        }
        if (n == buf.len) continue;
        buf[n] = cand;
        n += 1;
    }
    return buf[0..n];
}

/// One level of the hierarchy's verdict, or null when this level has nothing
/// to say (fewer than two candidates, or no evidence at all for the rung the
/// ladder currently seats — with no measurement of today's answer there is
/// nothing to compare a challenger against).
fn seatFor(cands: []const bench.Best, ladder_answer: []const u8) ?[]const u8 {
    if (cands.len < 2) return null;
    var base: ?bench.Best = null;
    for (cands) |c| if (std.mem.eql(u8, c.name, ladder_answer)) {
        base = c;
    };
    const b = base orelse return null;
    var win = b;
    // Only a strict Pareto improvement may re-seat: >= quality for < money.
    // Among several, the cheapest — the whole point is the efficiency knee.
    for (cands) |c| {
        if (bench.dominates(c, b) and bench.effCost(c) < bench.effCost(win)) win = c;
    }
    return win.name;
}

/// The learned answer for `tier` in `cell` on `provider_id`, or null to keep
/// `ladder_answer` — which is what every sparse, unmeasured or ambiguous case
/// returns, so bootstrap behavior is today's behavior.
pub fn learnedRungIn(
    cells: []const CellObs,
    entries: []const bench.Entry,
    provider_id: []const u8,
    cell: Cell,
    ladder_answer: []const u8,
) ?[]const u8 {
    var buf: [max_candidates]bench.Best = undefined;
    // Strict hierarchy: a cell with real evidence DECIDES, even when it
    // decides to keep the ladder's answer. Only a silent cell falls through
    // to its shape's pooled evidence, and a silent shape to the ladder.
    const exact = seatFor(cellCandidates(&buf, cells, entries, provider_id, cell, true), ladder_answer);
    const answer = exact orelse
        seatFor(cellCandidates(&buf, cells, entries, provider_id, cell, false), ladder_answer) orelse
        return null;
    return if (std.mem.eql(u8, answer, ladder_answer)) null else answer;
}

/// Production entry point: the session's folded cells against the session's
/// live bench sheet. `ladder_answer` is the CATALOG-resolved model the
/// provider ladder seats at the tier being resolved, so the tier is carried
/// implicitly and correctly.
pub fn learnedRung(provider_id: []const u8, cell: Cell, ladder_answer: []const u8) ?[]const u8 {
    return learnedRungIn(g_cells, bench.g_entries, provider_id, cell, ladder_answer);
}

/// `research/sweep@mid` — the id a learned-policy trace line reports, so a
/// user can find the exact cell that moved their worker.
pub fn cellId(buf: []u8, cell: Cell, tier: Tier) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}@{s}", .{ cell.shape.label(), dash(cell.role), tier.label() }) catch buf[0..0];
}

test {
    _ = @import("route_policy_tests.zig");
}
