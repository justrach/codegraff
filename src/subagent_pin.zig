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
const fleet = @import("fleet.zig");
const selection = @import("subagent_selection.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");

pub const Tier = tier_ladder.Tier;

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

    pub fn isNone(self: Pin) bool {
        return self.model == null and self.tier == null and !self.bad_tier;
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

    pub fn describe(self: Outcome) []const u8 {
        return switch (self) {
            .none => "",
            .pinned => "model pin applied",
            .same => "model pin is already the active model",
            .unknown_model => "model pin ignored: not an available model on this provider — kept the session default",
            .unknown_tier => "tier pin ignored: expected frontier, mid or small — kept the session default",
            .no_ladder => "tier pin ignored: this provider has no tier ladder — kept the session default",
            .no_rung => "tier pin ignored: this provider's ladder has no model at that rung — kept the session default",
        };
    }
};

/// `provider == null` means the spawn keeps whatever it already had.
pub const Resolved = struct { provider: ?Provider = null, outcome: Outcome = .none };

fn trimmed(v: std.json.Value) ?[]const u8 {
    if (v != .string) return null;
    const s = std.mem.trim(u8, v.string, " \t\r\n");
    return if (s.len == 0) null else s;
}

/// The persona's own pin, if `name` matches a loaded agent type. An unknown
/// name is "no opinion", matching resolveOverride/resolveIsolation's
/// never-fail-a-spawn-on-a-typo contract.
pub fn personaPin(name: []const u8) Pin {
    if (name.len == 0) return .{};
    for (fleet.g_agent_types) |t| {
        if (std.mem.eql(u8, t.name, name)) return .{ .model = t.model, .tier = t.tier };
    }
    return .{};
}

/// The pin for one spawn, applying the cross-level half of the precedence
/// rule: an explicit `model`/`tier` on the call replaces the persona's pin
/// wholesale (it does not merge with it), and only a call that states neither
/// falls through to the persona.
pub fn requested(obj: std.json.ObjectMap) Pin {
    var call: Pin = .{};
    if (obj.get("model")) |v| call.model = trimmed(v);
    if (obj.get("tier")) |v| if (trimmed(v)) |raw| {
        call.tier = Tier.parse(raw);
        call.bad_tier = call.tier == null;
    };
    if (!call.isNone()) return call;
    if (obj.get("agent")) |v| if (v == .string) return personaPin(v.string);
    return .{};
}

/// Resolve `pin` against `base` — the provider the child would otherwise use.
/// Provider-local: the answer is always `base` with a different model, or no
/// answer at all.
pub fn resolve(base: Provider, pin: Pin) Resolved {
    if (pin.model) |query| return finish(base, selection.modelForProvider(base.id, query));
    if (pin.tier) |tier| {
        const ladder = tier_ladder.forProvider(base.id) orelse return .{ .outcome = .no_ladder };
        const rung = ladder.modelFor(tier) orelse return .{ .outcome = .no_rung };
        // A ladder rung is still checked against the LIVE catalog: `graff
        // models refresh` can drop a model the compiled ladder names, and a
        // pin resolving to a model the provider no longer serves must fall
        // back rather than send a request that 404s mid-fleet.
        return finish(base, selection.modelForProvider(base.id, rung));
    }
    if (pin.bad_tier) return .{ .outcome = .unknown_tier };
    return .{};
}

fn finish(base: Provider, name: ?[]const u8) Resolved {
    const resolved = name orelse return .{ .outcome = .unknown_model };
    if (std.mem.eql(u8, resolved, base.model)) return .{ .outcome = .same };
    return .{ .provider = base.withModel(resolved), .outcome = .pinned };
}

/// The whole chain for one spawn: read the pin off the call (or its persona),
/// then resolve it provider-locally against `base`.
pub fn forSpawn(base: Provider, obj: std.json.ObjectMap) Resolved {
    const pin = requested(obj);
    if (pin.isNone()) return .{};
    return resolve(base, pin);
}

/// The live persona's OPERATIONAL frontmatter lines — isolation plus #292's
/// model/tier — arena-allocated and newline-terminated, or "" when it has
/// none.
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
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ iso, mdl, rung }) catch "";
    }
    return "";
}
