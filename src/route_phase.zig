//! #376 — ONE learned seat per workflow phase.
//!
//! #372 gave every phase worker full routing visibility, and made it
//! CONTRIBUTE observations to the learned (shape, role) tier policy. It
//! deliberately changed none of their models: #290's firewall ("workflow
//! tasks take no per-task pins") stood, because scoreVariants ranks the
//! prompt variants of one phase against each other and files the winner under
//! the prompt fingerprint. A phase whose tasks could differ in model would
//! attribute the model's effect to the genome — and nothing downstream could
//! have caught it, since scoring.providerClass then bucketed gpt-5.6-sol,
//! -terra and -luna identically (route_policy.stratumOf tells that story in
//! full).
//!
//! The confound is PER-TASK variation, not the model. This module applies the
//! #372 policy exactly once for a whole phase:
//!
//!   * every worker in the phase resolves to the SAME model, so within-phase
//!     prompt comparability — the thing #290 protects — is untouched;
//!   * across runs the rung is now recorded on every fitness row and the
//!     cross-run genome comparison stratifies on it (fitness_strata.zig), so
//!     the axis this module varies is exactly the axis that became visible.
//!
//! WHAT MAY MOVE A PHASE, AND WHAT MAY NOT.
//!
//!   explicit user pin  >  persona  >  session default  >  learned policy
//!
//! So the seat is offered ONLY when this session's worker model came from the
//! automatic #291 ladder descent (`source=ladder`). An explicit
//! --subagent-model / --subagent-provider, or a plain inherit-the-root, is a
//! human decision about which model does the work and is never overridden by
//! evidence. Within that opening the #372 guardrails all still apply: the
//! learned answer must DOMINATE the model the phase would otherwise have used
//! (bench_priors' Pareto sense — at least its quality for strictly less
//! money), the cost ceiling is re-cleared for the swapped model, and the swap
//! is provider-local by construction (Provider.withModel), so cross-provider
//! consent and the sub-first flat-rate routing in subagent_pin are reached by
//! nothing here.
//!
//! A phase with no single role — an off-vocabulary title whose tasks name
//! different persona slots — has no cell to consult and keeps today's
//! behavior exactly, as does every phase in an archive with no evidence.

const std = @import("std");

const Provider = @import("provider.zig").Provider;
const policy = @import("route_policy.zig");
const route_trace = @import("route_trace.zig");
const pin_mod = @import("subagent_pin.zig");
const shapes = @import("shapes.zig");

pub const Cell = policy.Cell;
pub const Shape = policy.Shape;
pub const Source = policy.Source;

/// One phase's routing decision, resolved once and shared by every worker in
/// it. `pin` is what the spawn path receives: non-null ONLY when the learned
/// policy re-seated the phase, so an unobserved phase still hands runSub the
/// null it handed it before #376.
pub const Seat = struct {
    /// The model every worker in this phase runs on.
    provider: Provider,
    /// The re-seat, or null to keep the session default.
    pin: ?Provider = null,
    shape: Shape = .adhoc,
    /// The phase title the root model authored — the trace's role source, and
    /// the label scoreVariants judges against.
    title: []const u8 = "",
    /// The one canonical slot every worker in this phase reports, "" when the
    /// phase has no single role (and therefore no cell to route on).
    role: []const u8 = "",
    /// What decided the model when the learned policy did not: `ladder` for
    /// the #291 descent, `session-default` for an explicit pin or a plain
    /// inherit. Exactly what #372 reported for these workers.
    base_source: Source = .session_default,
    /// #380: `pin` was set because a task in this phase names an image and
    /// the seat could not see one — a capability requirement, not a measured
    /// preference, so it must not be reported as `learned-policy`.
    vision: bool = false,
    /// `pin` was set by the search-role prior (a hand rule, not evidence),
    /// so the source must stay the ladder's, not claim `learned-policy`.
    role_prior: bool = false,

    /// The (shape, role) cell one worker files its score under. Identical for
    /// every worker of a routed phase by construction: `uniformRole` only
    /// yields a role when policy.roleOf agrees on it for every task.
    pub fn cellOf(self: Seat, niche: []const u8) Cell {
        return .{ .shape = self.shape, .role = policy.roleOf(self.title, niche) };
    }

    /// The #372 `source` for one worker of this phase. A phase the policy
    /// moved reports `learned-policy` for ALL of its workers — that is the
    /// decision that actually chose their model, and reporting it per worker
    /// is what keeps the trace honest about a phase-level choice.
    pub fn sourceFor(self: Seat, has_override: bool) Source {
        if (self.vision) return .vision_ask; // #380 — a capability, not a preference
        if (self.pin != null) return if (self.role_prior) self.base_source else .learned_policy;
        return if (has_override) .workflow_override else self.base_source;
    }
};

/// The roles whose work is reading and reporting — the search half of every
/// shape. Their whole benefit is a summary, so the role prior seats them at
/// the ladder's SMALL rung; verify/review/implement/synthesize keep the
/// session rung (their work is judged or lands edits).
fn searchRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "find") or std.mem.eql(u8, role, "sweep");
}

/// The one role a whole phase can be routed under: the phase title's own
/// canonical slot when it names one (policy.roleOf then reports it for every
/// task regardless of niche), else the slot every task's niche agrees on,
/// else "" — no single role, no phase cell, no re-seating.
pub fn uniformRole(title: []const u8, niches: []const []const u8) []const u8 {
    const from_title = shapes.canonicalSlot(title);
    if (from_title.len > 0) return from_title;
    if (niches.len == 0) return "";
    const first = shapes.canonicalSlot(niches[0]);
    if (first.len == 0) return "";
    for (niches[1..]) |n| {
        if (!std.mem.eql(u8, shapes.canonicalSlot(n), first)) return "";
    }
    return first;
}

/// Resolve the seat for one workflow phase. `base` is the provider every
/// worker would have used before #376 (subagent_run.childProvider's answer);
/// `session_pinned` is whether the session named a worker provider at all,
/// the same bit route_trace.sessionSource reads.
pub fn forPhase(
    base: Provider,
    shape: Shape,
    title: []const u8,
    niches: []const []const u8,
    session_pinned: bool,
) Seat {
    var seat: Seat = .{
        .provider = base,
        .shape = shape,
        .title = title,
        .role = uniformRole(title, niches),
        .base_source = route_trace.sessionSource(session_pinned),
    };
    // Only the automatic ladder descent is the policy's to improve on; an
    // explicit pin and a plain inherit are the user's own choice.
    if (seat.base_source != .ladder or seat.role.len == 0) return seat;
    // The baseline a challenger must dominate is the model this phase would
    // otherwise have run — so the comparison is against reality, not against
    // a rung nobody was going to use.
    const learned = policy.learnedRung(base.id, .{ .shape = shape, .role = seat.role }, base.model) orelse {
        // No lived evidence for this cell. Search roles then ride the small
        // rung by default ("different things get different things") — their
        // whole product is a summary. resolveIn re-runs the tier chain
        // (catalog check, cost ceiling), so the worst case is today's answer;
        // once real evidence lands in the cell, it decides instead.
        if (searchRole(seat.role)) {
            const r = pin_mod.resolveIn(base, .{ .tier = .small }, .{ .shape = shape, .role = seat.role });
            if (r.provider) |p| if (!std.mem.eql(u8, p.model, seat.provider.model)) {
                seat.pin = p;
                seat.provider = p;
                seat.role_prior = true;
            };
        }
        return seat;
    };
    // Re-clear the cost ceiling for the swapped model: learning may descend
    // price, never escalate it, and a swap that somehow fails the ceiling is
    // dropped rather than failing the phase.
    if (!pin_mod.rungAffordableOn(base, learned)) return seat;
    seat.pin = base.withModel(learned);
    seat.provider = seat.pin.?;
    return seat;
}

test {
    _ = @import("route_phase_tests.zig");
}
