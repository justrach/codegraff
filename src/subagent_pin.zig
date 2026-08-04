//! Per-persona and per-spawn worker model pins (#292).
//!
//! #291 (4f9e7a7) made the worker model a SESSION-wide decision: absent an
//! explicit --subagent-model, every child descends one rung of the provider's
//! tier ladder. That is still the default; this module adds the two finer
//! grains the issue asks for, on top of it rather than beside it.
//!
//!   1. A persona in `.harness/agents/<name>.md` may pin itself in
//!      frontmatter — `model: gpt-5.6-terra` (exact) or `tier: mid` (a rung
//!      of whatever ladder the current provider is on). Parsed in fleet.zig
//!      into AgentType.model/.tier; resolved here.
//!   2. One `subagent` call may pin `model` / `tier` for that spawn only.
//!
//! The same two grains can pin reasoning EFFORT — frontmatter `effort: max`
//! or an `effort` param on the call (low|medium|high|xhigh|max — the /effort
//! vocabulary minus `ultra`, which is the ultracode prompt switch, not a
//! depth a worker should inherit). Effort is an INDEPENDENT AXIS from
//! model/tier: each falls through spawn → persona → session default on its
//! own, so an effort-only override keeps the persona's model pin (and vice
//! versa). Unlike a model pin it needs no catalog resolution — a model that
//! rejects reasoning_effort already degrades per request (effort_rejected in
//! agent_request.zig) — so an effort pin is either applied as stated or
//! reported off-vocabulary, never provider-dependent.
//!
//! PRECEDENCE (what the tool schema advertises, implemented by `requested`
//! and `resolve` below):
//!
//!     explicit spawn param  >  persona frontmatter  >  session default
//!     (--subagent-model / the #291 ladder)  >  root model
//!
//! Within one level an exact `model` beats a `tier`: it is the more specific
//! statement. Across levels the level wins, so a spawn that says `tier: small`
//! overrides a persona that says `model: gpt-5.6-sol` — otherwise a per-spawn
//! override could not lower a persona's pin, which is its whole point.
//!
//! PROVIDER LOCALITY. A pin resolves only against the catalog rows of the
//! provider the child was ALREADY going to use (root, or --subagent-provider
//! once --allow-cross-provider-subagents consented). So a pin can never move
//! prompts, code, or billing to a second provider: that decision stays with
//! the startup flag and its consent gate, exactly as #292 requires, and
//! Provider.withModel makes it structurally impossible here.
//!
//! GRACEFUL FALLBACK. Every failure to honour a pin resolves to a null
//! provider, which the spawn path reads as "keep the session default".
//! Unknown model name, a name that is real but not served by this provider,
//! an ambiguous abbreviation, an off-vocabulary tier, a provider with no
//! ladder, a rung the family does not have — all of them still produce a
//! working spawn. A fan-out must never die halfway through because one
//! persona file names a model the catalog has since renamed; Outcome.describe
//! supplies the human-readable reason for the trace instead.
//!
//! FLEET SAFETY (#290). Pins are wired into the `subagent` tool only, not
//! workflow phases / pipeline stages. scoreVariants judges the variants of one
//! phase against each other and files the result under the prompt genome, so
//! letting phase tasks vary the model would reintroduce exactly the confound
//! #290 closed. subagent_run.variantProviderClass documents that seam.

const std = @import("std");

const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const pricing = @import("pricing.zig");
const bench_priors = @import("bench_priors.zig");
const fleet = @import("fleet.zig");
const selection = @import("subagent_selection.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const route_policy = @import("route_policy.zig"); // #372 learned (shape, role) tier policy

pub const Tier = tier_ladder.Tier;
pub const Cell = route_policy.Cell;
pub const Source = route_policy.Source;

/// Worker reasoning depth (main.zig's ReasoningEffort) — pinnable per persona
/// or per spawn since the #292 follow-up; parsed by `parseEffort` below.
pub const Effort = @import("main.zig").ReasoningEffort;

/// A requested pin, before it has been checked against any catalog. All
/// fields at their defaults means "no opinion" — keep the session default.
pub const Pin = struct {
    model: ?[]const u8 = null,
    /// A parsed ladder rung. Only consulted when `model` is null.
    tier: ?Tier = null,
    /// The request named a `tier` whose value is off-vocabulary. Kept
    /// distinct from "no tier" so a typo is reported rather than silently
    /// falling through to a persona pin the caller was trying to override.
    bad_tier: bool = false,
    /// Reasoning-effort pin — an axis of its own (see module doc), with the
    /// same typo discipline as `bad_tier`.
    effort: ?Effort = null,
    bad_effort: bool = false,
    /// #372 routing trace: the model/tier axis fell through to the persona's
    /// frontmatter rather than being stated on the call, so the trace can say
    /// `source=persona` instead of claiming the user typed it.
    from_persona: bool = false,

    pub fn isNone(self: Pin) bool {
        return self.model == null and self.tier == null and !self.bad_tier and self.effort == null and !self.bad_effort;
    }
};

/// Why a pin did or did not change the child's model. Carried to the trace so
/// an ignored pin is visible rather than silent — the failure a hard error
/// would have made obvious is instead made observable.
pub const Outcome = enum {
    none, // no pin was requested
    pinned, // honored
    same, // resolved to the model the child already had
    unknown_model, // not an available model on this provider (or ambiguous)
    unknown_tier, // `tier` was not one of frontier/mid/small
    no_ladder, // this provider has no tier ladder
    no_rung, // the ladder has no model at that rung
    rung_pricier, // the rung would cost more than the child's current model
    sub_routed, // the rung went to a logged-in flat-rate subscription instead

    pub fn describe(self: Outcome) []const u8 {
        return switch (self) {
            .none => "",
            .pinned => "model pin applied",
            .same => "model pin is already the active model",
            .unknown_model => "model pin ignored: not an available model on this provider — kept the session default",
            .unknown_tier => "tier pin ignored: expected frontier, mid or small — kept the session default",
            .no_ladder => "tier pin ignored: this provider has no tier ladder — kept the session default",
            .no_rung => "tier pin ignored: this provider's ladder has no model at that rung — kept the session default",
            .rung_pricier => "tier pin ignored: that rung is pricier than this agent's model — cost never escalates implicitly; pin the model by name to escalate",
            .sub_routed => "tier routed to a logged-in flat-rate subscription — marginal cost zero outranks metered spend; the login is the user's standing consent for that vendor",
        };
    }
};

/// The effort half of Outcome — its own enum because the axes resolve
/// independently and one spawn may need a note about each.
pub const EffortOutcome = enum {
    none,
    pinned,
    unknown_effort,

    pub fn describe(self: EffortOutcome) []const u8 {
        return switch (self) {
            .none => "",
            .pinned => "effort pin applied",
            .unknown_effort => "effort pin ignored: expected low, medium, high, xhigh or max — kept the session default",
        };
    }
};

/// `provider == null` means the spawn keeps whatever it already had; `effort
/// == null` likewise (the worker default, not the root's /effort).
///
/// `source` (#372) names WHICH layer chose the model, for the routing trace:
/// an exact pin reports explicit-pin/persona, a tier reports learned-policy
/// when the (shape, role) cell re-seated the rung and ladder when it did not.
/// A no-opinion Resolved keeps the default, and the caller reports the
/// session-level decision it fell back to.
pub const Resolved = struct { provider: ?Provider = null, outcome: Outcome = .none, effort: ?Effort = null, effort_outcome: EffortOutcome = .none, source: Source = .session_default };

fn trimmed(v: std.json.Value) ?[]const u8 {
    if (v != .string) return null;
    const s = std.mem.trim(u8, v.string, " \t\r\n");
    return if (s.len == 0) null else s;
}

/// The `effort` pin vocabulary: /effort's levels minus `ultra`, which is the
/// ultracode prompt switch rather than a reasoning depth a delegated worker
/// should inherit. Off-vocabulary parses to null — the caller decides whether
/// that is "no opinion" (a frontmatter load) or a reportable typo (a spawn's
/// stated override).
pub fn parseEffort(s: []const u8) ?Effort {
    const e = std.meta.stringToEnum(Effort, s) orelse return null;
    return if (e == .ultra) null else e;
}

/// The persona's own pin, if `name` matches a loaded agent type. An unknown
/// name is "no opinion", matching resolveOverride/resolveIsolation's
/// never-fail-a-spawn-on-a-typo contract.
pub fn personaPin(name: []const u8) Pin {
    if (name.len == 0) return .{};
    for (fleet.g_agent_types) |t| {
        if (std.mem.eql(u8, t.name, name)) return .{ .model = t.model, .tier = t.tier, .effort = t.effort };
    }
    return .{};
}

/// The pin for one spawn, applying the cross-level half of the precedence
/// rule PER AXIS: an explicit `model`/`tier` on the call replaces the
/// persona's model pin wholesale (it does not merge with it), an explicit
/// `effort` replaces the persona's effort, and each axis the call leaves
/// unstated falls through to the persona on its own — so an effort-only
/// override keeps the persona's model pin, and vice versa. A stated typo
/// (`bad_tier`/`bad_effort`) blocks that axis's fallthrough: the caller was
/// trying to override, and a silent substitution would hide it.
pub fn requested(obj: std.json.ObjectMap) Pin {
    var call: Pin = .{};
    if (obj.get("model")) |v| call.model = trimmed(v);
    if (obj.get("tier")) |v| if (trimmed(v)) |raw| {
        call.tier = Tier.parse(raw);
        call.bad_tier = call.tier == null;
    };
    if (obj.get("effort")) |v| if (trimmed(v)) |raw| {
        call.effort = parseEffort(raw);
        call.bad_effort = call.effort == null;
    };
    const persona: Pin = blk: {
        const v = obj.get("agent") orelse break :blk .{};
        break :blk if (v == .string) personaPin(v.string) else .{};
    };
    if (call.model == null and call.tier == null and !call.bad_tier) {
        call.model = persona.model;
        call.tier = persona.tier;
        call.from_persona = persona.model != null or persona.tier != null;
    }
    if (call.effort == null and !call.bad_effort) call.effort = persona.effort;
    return call;
}

/// Resolve `pin` against `base` — the provider the child would otherwise use.
/// Provider-local: the answer is always `base` with a different model, or no
/// answer at all. Cell-less: the learned policy has no partition to consult
/// and the ladder answers alone, exactly as before #372.
pub fn resolve(base: Provider, pin: Pin) Resolved {
    return resolveIn(base, pin, .{});
}

/// The same resolution, told WHICH (shape, role) policy cell this spawn
/// belongs to. The cell is consulted at exactly ONE point — choosing which
/// model serves an already-requested tier — and only ever to swap in a
/// candidate that DOMINATES the ladder's own answer on quality-per-dollar.
/// An explicit `model` returns before it, so a user pin still outranks every
/// learned preference; the cost ceiling is re-cleared for the swapped model,
/// so learning can never escalate spend either.
pub fn resolveIn(base: Provider, pin: Pin, cell: Cell) Resolved {
    const pin_src: Source = if (pin.from_persona) .persona else .explicit_pin;
    if (pin.model) |query| return finish(base, selection.modelForProvider(base.id, query), pin_src);
    if (pin.tier) |tier| {
        const ladder = tier_ladder.forProvider(base.id) orelse return .{ .outcome = .no_ladder };
        const rung = ladder.modelFor(tier) orelse return .{ .outcome = .no_rung };
        // A ladder rung is still checked against the LIVE catalog: `graff
        // models refresh` can drop a model the compiled ladder names, and a
        // pin resolving to a model the provider no longer serves must fall
        // back rather than send a request that 404s mid-fleet.
        const resolved = selection.modelForProvider(base.id, rung) orelse return .{ .outcome = .unknown_model };
        // COST CEILING: a tier rung may DESCEND price, never raise it — on a
        // multi-vendor catalog (the codegraff gateway serves everything up to
        // opus-class) an automatic rung must not spend more than the model
        // the user chose. Escalation stays possible, but only by naming the
        // model in the call — visible, never implicit.
        if (!rungAffordable(base.model, resolved)) return .{ .outcome = .rung_pricier };
        // #372: the learned layer sits HERE, below every explicit pin. It is
        // handed the CATALOG-resolved ladder answer and may return a measured
        // improvement on it; a swap that somehow fails the same cost ceiling
        // is dropped rather than failing the spawn, so the worst case is
        // today's ladder answer.
        if (route_policy.learnedRung(base.id, cell, resolved)) |learned| {
            if (rungAffordable(base.model, learned)) return finish(base, learned, .learned_policy);
        }
        return finish(base, resolved, .ladder);
    }
    if (pin.bad_tier) return .{ .outcome = .unknown_tier };
    return .{};
}

/// Flat-rate, device-login subscription providers, in fallback preference
/// order (bench scores rank them when several are logged in). codegraff's
/// license is deliberately absent: it fronts the metered multi-vendor
/// gateway this policy protects the user's wallet FROM. `pub` since #380:
/// vision_ask.visionSeat searches the same candidates under the same rule.
pub const subscription_providers = [_][]const u8{ "codex", "kimi" };

/// SUB-FIRST TIER ROUTING (explicit `tier` asks only — the silent no-tier
/// default still inherits the user's chosen family): a logged-in flat-rate
/// subscription is marginal-cost-zero, so its rung outranks ANY metered
/// model — a deepseek session's tier:"small" goes to luna on the codex sub,
/// not to a metered gateway row — and the login itself is the user's
/// standing consent for that vendor. Metered cross-provider routing keeps
/// the explicit --subagent-provider + --allow-cross-provider-subagents bar.
/// When several subs serve the rung, the bench sheet's score picks.
fn subscriptionRung(tier: Tier, base: Provider) ?Resolved {
    const keys = bench_priors.g_keys orelse return null;
    var best: ?Resolved = null;
    var best_score: f64 = -1;
    for (subscription_providers) |sid| {
        if (std.mem.eql(u8, sid, base.id)) continue; // the base's own ladder handles it provider-locally
        const ladder = tier_ladder.forProvider(sid) orelse continue;
        const rung = ladder.modelFor(tier) orelse continue;
        const resolved = selection.modelForProvider(sid, rung) orelse continue;
        const prov = keys.providerById(sid, resolved) catch continue; // not logged in → not a candidate
        const s = bench_priors.scoreFor(sid, resolved) orelse 0;
        if (best == null or s > best_score) {
            // source=ladder: it IS a ladder rung, just the subscription's own.
            best = .{ .provider = prov, .outcome = .sub_routed, .source = .ladder };
            best_score = s;
        }
    }
    return best;
}

/// Summed in+out $/1M. An unpriced BASE has no ceiling to enforce (whole
/// subscription families like codex carry no per-token price — blocking
/// there would kill every intra-family rung); a priced base with an unpriced
/// rung cannot prove the rung is not an escalation, so it blocks.
pub fn rungAffordable(base_model: []const u8, rung_model: []const u8) bool {
    const bp = pricing.priceFor(base_model) orelse return true;
    const rp = pricing.priceFor(rung_model) orelse return false;
    return rp.in + rp.out <= bp.in + bp.out;
}

fn finish(base: Provider, name: ?[]const u8, source: Source) Resolved {
    const resolved = name orelse return .{ .outcome = .unknown_model };
    if (std.mem.eql(u8, resolved, base.model)) return .{ .outcome = .same, .source = source };
    return .{ .provider = base.withModel(resolved), .outcome = .pinned, .source = source };
}

/// The whole chain for one spawn: read the pin off the call (or its persona),
/// route an explicit tier to a logged-in subscription when one serves it
/// better (subscriptionRung; `sub_ok` false = the session pinned workers
/// with --subagent-provider, an explicit human choice no auto-route may
/// override), else resolve the model axis provider-locally against `base`;
/// the effort axis rides through verbatim (it needs no catalog).
pub fn forSpawn(base: Provider, obj: std.json.ObjectMap, sub_ok: bool) Resolved {
    return forSpawnIn(base, obj, sub_ok, .{});
}

/// forSpawn with the spawn's #372 policy cell attached — the only difference
/// is which (shape, role) evidence the tier axis may consult.
pub fn forSpawnIn(base: Provider, obj: std.json.ObjectMap, sub_ok: bool, cell: Cell) Resolved {
    const pin = requested(obj);
    if (pin.isNone()) return .{};
    var out: Resolved = blk: {
        if (sub_ok and pin.model == null) if (pin.tier) |t| if (subscriptionRung(t, base)) |r| break :blk r;
        break :blk resolveIn(base, pin, cell);
    };
    if (pin.effort) |e| {
        out.effort = e;
        out.effort_outcome = .pinned;
    } else if (pin.bad_effort) out.effort_outcome = .unknown_effort;
    return out;
}

/// The live persona's OPERATIONAL frontmatter lines — isolation plus #292's
/// model/tier/effort — arena-allocated and newline-terminated, or "" when it
/// has none.
///
/// Promotion (fleet.promoteAgents) replaces a niche's genome with a better
/// scoring one, and rewrites `<niche>.md` from scratch to do it. Without this
/// the rewrite would silently drop the persona's execution policy, so
/// `/agents promote` would un-pin every persona that had been given a worktree
/// default or a model rung — a config change nobody asked for, made by a
/// command about prompts. Genome and policy are different things; only the
/// former is what promotion is ranking.
pub fn personaPolicyFrontmatter(arena: std.mem.Allocator, name: []const u8) []const u8 {
    for (fleet.g_agent_types) |t| {
        if (!std.mem.eql(u8, t.name, name)) continue;
        const iso = if (t.isolation) |i| std.fmt.allocPrint(arena, "isolation: {s}\n", .{@tagName(i)}) catch "" else "";
        const mdl = if (t.model) |m| std.fmt.allocPrint(arena, "model: {s}\n", .{m}) catch "" else "";
        const rung = if (t.tier) |x| std.fmt.allocPrint(arena, "tier: {s}\n", .{x.label()}) catch "" else "";
        const eff = if (t.effort) |e| std.fmt.allocPrint(arena, "effort: {s}\n", .{@tagName(e)}) catch "" else "";
        return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ iso, mdl, rung, eff }) catch "";
    }
    return "";
}
