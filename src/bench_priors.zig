//! Bench-derived worker priors: `.harness/bench.json` (project, else
//! personal ~/.harness/bench.json) is a benchmark score/cost sheet — one
//! entry per (model, effort) config, e.g. a DeepSWE leaderboard export — and
//! this module turns it into per-provider tier ladders so worker assignment
//! starts from measured capability and cost instead of the compiled-in hand
//! table in subagent_tier_ladder.zig (which stays as the fallback for
//! providers the sheet cannot cover).
//!
//! Derivation, per provider, over the sheet models that RESOLVE on that
//! provider's live catalog (subagent_selection.modelForProvider — so one
//! sheet feeds every provider serving any of its models, and an unknown or
//! renamed model is skipped, never a load failure). Per-model bests are
//! folded first, then the losers are DISCARDED before any rung is seated
//! (#373): a candidate that another candidate matches-or-beats on score for
//! strictly less money is dominated, and a dominated model is never the
//! right answer at any budget. Rungs come only from the survivors — the
//! sheet's Pareto front for that provider:
//!
//!   frontier = the front's top score  (capability ceiling)
//!   small    = the front's best score-per-dollar below the frontier (the
//!              efficiency knee the sheet's power-law tail points at)
//!   mid      = the best survivor STRICTLY between those two scores, else
//!              null — a rung the data does not contain is not invented
//!
//! Seating from the front is what makes the ladder monotone by construction:
//! score(frontier) >= score(mid) >= score(small), effective cost ordered the
//! other way, and no rung beaten outright by a rung below it. Before #373
//! the three rungs were disjoint leftovers (mid = best score of whatever
//! frontier and small had not already claimed), which on the builtin sheet
//! seated codex mid = gpt-5.5 (0.54 @ $3.2) ABOVE small = gpt-5.6-luna
//! (0.67 @ $0.61) — so the #291 worker descent sent every worker to a model
//! that the rung below it beat on both axes at a fifth of the price.
//!
//! A provider needs at least two SURVIVING models to earn a derived ladder:
//! when one model dominates a provider's whole sheet there is no ladder to
//! derive (builtin openai: luna outright beats gpt-5.5, gpt-5.4 and terra),
//! and the compiled table stands rather than a fabricated descent. Scores
//! accept [0,1] or percent (0,100]; a model the sheet never prices costs
//! +inf — unpriced capability cannot be shown to be worth its price, so any
//! priced model matching its score dominates it, while two unpriced models
//! can never dominate each other. Loaded by fleet.loadAgentTypes, so the
//! session registry and auto-promote's hot-reload refresh it together.
//!
//! PRECEDENCE: project ./.harness/bench.json > personal ~/.harness/bench.json
//! > the BUILTIN sheet below — a shipped community leaderboard snapshot, so
//! every install starts with a measured cost/capability power law rather
//! than a blank. The intended refresher for the builtin is aggregated fleet
//! telemetry (users who opt into data sharing already submit signed
//! niche-tagged scores); serving that aggregate back is backend work — the
//! seam here is just "a sheet from anywhere, highest tier wins".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tier_ladder = @import("subagent_tier_ladder.zig");
const selection = @import("subagent_selection.zig");
const provider_mod = @import("provider.zig");

pub const bench_path = ".harness/bench.json";

/// Bench-derived ladders, consulted by tier_ladder.forProvider ahead of the
/// compiled table. Session-arena strings; empty when no sheet is present.
pub var g_ladders: []const tier_ladder.TierLadder = &.{};

/// Which providers the user is actually logged into / keyed for, snapshotted
/// when startup resolves credentials (noteAvailability, spec-table order).
/// Derivation skips the rest: priors describe YOUR available fleet, not the
/// whole catalog. null (tests, pre-startup) = no opinion, derive everything.
/// A mid-session /login is picked up on next start, like persona files —
/// until then the compiled ladder covers the newly added provider.
pub var g_available: ?[provider_mod.provider_specs.len]bool = null;

/// By VALUE in, by value out — written to ride resolveKeys' return statement
/// (a pointer into its stack Keys would dangle) without costing the capped
/// file a line.
pub fn noteAvailability(keys: provider_mod.Keys) provider_mod.Keys {
    var av: [provider_mod.provider_specs.len]bool = undefined;
    for (keys.values, 0..) |v, i| av[i] = v != null;
    g_available = av;
    return keys;
}

pub const Entry = struct {
    model: []const u8,
    effort: ?[]const u8 = null, // recorded for provenance; ladders name models
    score: f64,
    cost: f64 = 0, // avg $ per task; <= 0 = unknown (no efficiency signal)
};

pub const Sheet = struct {
    suite: []const u8 = "",
    updated: []const u8 = "",
    entries: []Entry = &.{},
};

/// The shipped default sheet: DeepSWE v1.1 (113 tasks, updated 2026-07-25),
/// avg $ per task. Chart-read values (±~2% score, ±~$0.5 cost) — plenty for
/// rung ORDERING, which is all derivation consumes. Models no provider
/// serves (gemini, muse-spark) still belong here: they resolve nowhere today
/// but start working the day a catalog serves them.
pub const builtin_entries = [_]Entry{
    .{ .model = "claude-opus-5", .effort = "max", .score = 74, .cost = 12.0 },
    .{ .model = "claude-fable-5", .effort = "high", .score = 70, .cost = 9.0 },
    .{ .model = "claude-sonnet-5", .effort = "high", .score = 49, .cost = 10.5 },
    .{ .model = "claude-opus-4-8", .effort = "high", .score = 41, .cost = 2.9 },
    .{ .model = "claude-sonnet-4-6", .effort = "high", .score = 31, .cost = 6.5 },
    .{ .model = "k3", .effort = "max", .score = 68, .cost = 4.6 },
    .{ .model = "kimi-k2.7-code", .score = 30, .cost = 2.6 },
    .{ .model = "gpt-5.6-sol", .effort = "max", .score = 73, .cost = 5.5 },
    .{ .model = "gpt-5.6-sol", .effort = "medium", .score = 61, .cost = 1.86 },
    .{ .model = "gpt-5.6-terra", .effort = "medium", .score = 35, .cost = 0.9 },
    .{ .model = "gpt-5.6-luna", .effort = "max", .score = 67, .cost = 0.61 },
    .{ .model = "gpt-5.6-luna", .effort = "medium", .score = 11, .cost = 0.15 },
    .{ .model = "gpt-5.5", .effort = "medium", .score = 54, .cost = 3.2 },
    .{ .model = "gpt-5.4", .effort = "xhigh", .score = 53, .cost = 5.2 },
    .{ .model = "grok-4.5", .effort = "high", .score = 53, .cost = 3.0 },
    .{ .model = "glm-5.2", .effort = "max", .score = 44, .cost = 3.9 },
    .{ .model = "muse-spark-1.1", .effort = "xhigh", .score = 50, .cost = 3.0 },
    .{ .model = "gemini-3.6-flash", .effort = "high", .score = 54, .cost = 3.5 },
    .{ .model = "gemini-3.5-flash", .effort = "medium", .score = 38, .cost = 7.0 },
    .{ .model = "gemini-3.1-pro", .effort = "high", .score = 12, .cost = 9.5 },
};

pub fn loadInto(io: Io, arena: Allocator, home: ?[]const u8) void {
    var sheet = readSheet(io, arena, bench_path);
    if (sheet == null) if (home) |h| {
        const p = std.fmt.allocPrint(arena, "{s}/{s}", .{ h, bench_path }) catch return;
        sheet = readSheet(io, arena, p);
    };
    g_entries = if (sheet) |s| s.entries else &builtin_entries;
    g_ladders = derive(arena, g_entries);
}

fn readSheet(io: Io, arena: Allocator, path: []const u8) ?Sheet {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    return std.json.parseFromSliceLeaky(Sheet, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// [0,1] passes; (1,100] reads as percent; anything else is not a score.
fn normalScore(s: f64) ?f64 {
    if (!(s >= 0)) return null;
    if (s <= 1) return s;
    if (s <= 100) return s / 100.0;
    return null;
}

/// The current sheet's entries (file else builtin) — the score authority
/// subscription-rung ranking consults (subagent_pin.subscriptionRung).
pub var g_entries: []const Entry = &builtin_entries;

/// The session Keys, captured where main() builds its loop context (the
/// pointer targets main's stack frame, alive for the whole loop). Lets the
/// spawn path build a Provider for a logged-in subscription — null in tests
/// and before startup, which reads as "no subscriptions reachable".
pub var g_keys: ?*const provider_mod.Keys = null;

pub fn noteKeys(keys: *provider_mod.Keys) *provider_mod.Keys {
    g_keys = keys;
    return keys;
}

/// Startup composition, riding resolveKeys' return: snapshot availability,
/// then load/derive the sheet — so the #291 worker default (resolved moments
/// later in main) sees the SAME bench ladders as every later /model
/// re-derivation (#371). Without this, startup derived workers from the
/// compiled table while a switch re-derived from the bench one, and the two
/// disagreed (terra vs the data-blessed gpt-5.5 on codex).
pub fn noteKeysAtStartup(keys: provider_mod.Keys, io: Io, arena: Allocator, home: ?[]const u8) provider_mod.Keys {
    const kept = noteAvailability(keys);
    loadInto(io, arena, home);
    return kept;
}

/// Best sheet score for `model` as served by `provider_id`; null when the
/// sheet has no opinion.
pub fn scoreFor(provider_id: []const u8, model: []const u8) ?f64 {
    var best: ?f64 = null;
    for (g_entries) |e| {
        const s = normalScore(e.score) orelse continue;
        const r = selection.modelForProvider(provider_id, e.model) orelse continue;
        if (!std.mem.eql(u8, r, model)) continue;
        if (best == null or s > best.?) best = s;
    }
    return best;
}

const Best = struct { name: []const u8, score: f64 = -1, spd: f64 = -1 };

/// One provider's per-model bests: the max score over that model's configs
/// and the max score-per-dollar, folded across every sheet entry that
/// resolves to it (several efforts of one model collapse into one candidate).
fn foldProvider(arena: Allocator, provider_id: []const u8, entries: []const Entry) []Best {
    var models: std.ArrayList(Best) = .empty;
    for (entries) |e| {
        const score = normalScore(e.score) orelse continue;
        const resolved = selection.modelForProvider(provider_id, e.model) orelse continue;
        const slot = blk: {
            for (models.items) |*m| if (std.mem.eql(u8, m.name, resolved)) break :blk m;
            models.append(arena, .{ .name = resolved }) catch return models.items;
            break :blk &models.items[models.items.len - 1];
        };
        if (score > slot.score) slot.score = score;
        if (e.cost > 0 and score / e.cost > slot.spd) slot.spd = score / e.cost;
    }
    return models.items;
}

/// What a candidate's capability actually costs: the dollar figure implied
/// by its BEST measured efficiency (score / score-per-dollar). Deliberately
/// optimistic when a model's top score and top spd come from different
/// efforts (codex sol: 0.73 max @ $5.5 and 0.61 medium @ $1.86 fold to
/// ~$2.23) — an understated cost only makes a candidate HARDER to dominate,
/// and #373 is about never pruning a rung that might still earn its price.
/// Unpriced (spd < 0: no entry for this model carried a positive cost) is
/// +inf, so any priced model matching its score dominates it, and two
/// unpriced models never dominate each other.
fn effCost(m: Best) f64 {
    return if (m.spd > 0) m.score / m.spd else std.math.inf(f64);
}

/// #373: does `a` beat `b` outright — at least `b`'s score for strictly less
/// money? Then `b` is not a rung, it is a mistake: every task `b` could run,
/// `a` runs at least as well for less.
fn dominates(a: Best, b: Best) bool {
    return a.score >= b.score and effCost(a) < effCost(b);
}

/// The provider's Pareto front: fold's candidates minus everyone another
/// candidate beats outright. Exact ties (same score, same effective cost)
/// both survive — neither is strictly cheaper, so the rule can never eat a
/// whole tie group and leave the provider with nothing.
fn paretoFront(arena: Allocator, models: []const Best) []Best {
    var front: std.ArrayList(Best) = .empty;
    for (models, 0..) |m, i| {
        const beaten = for (models, 0..) |o, j| {
            if (i != j and dominates(o, m)) break true;
        } else false;
        if (!beaten) front.append(arena, m) catch return front.items;
    }
    return front.items;
}

fn derive(arena: Allocator, entries: []const Entry) []const tier_ladder.TierLadder {
    var out: std.ArrayList(tier_ladder.TierLadder) = .empty;
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (g_available) |av| if (!av[i]) continue;
        const models = paretoFront(arena, foldProvider(arena, spec.id, entries));
        if (models.len < 2) continue; // one model beat the whole sheet: no ladder exists to derive
        var frontier: *const Best = &models[0];
        for (models) |*m| if (m.score > frontier.score) {
            frontier = m;
        };
        var small: ?*const Best = null;
        for (models) |*m| {
            if (m == frontier or m.spd < 0) continue;
            if (small == null or m.spd > small.?.spd) small = m;
        }
        const sm = small orelse continue; // capability alone cannot rank efficiency
        // Only a survivor STRICTLY between the two seated rungs earns mid —
        // which is what makes score(frontier) >= score(mid) >= score(small)
        // true by construction (#373) instead of by leftover. The bounds
        // also exclude frontier and sm themselves, so no pointer test is
        // needed; a two-deep front simply has no mid, and the descent in
        // subagent_selection steps frontier -> small on its own.
        var mid: ?*const Best = null;
        for (models) |*m| {
            if (m.score >= frontier.score or m.score <= sm.score) continue;
            if (mid == null or m.score > mid.?.score) mid = m;
        }
        out.append(arena, .{
            .provider = spec.id,
            .frontier = frontier.name,
            .mid = if (mid) |m| m.name else null,
            .small = sm.name,
        }) catch return out.items;
    }
    return out.items;
}

test "bench sheet: score normalization accepts unit and percent, rejects junk" {
    try std.testing.expectEqual(@as(f64, 0.67), normalScore(0.67).?);
    try std.testing.expectEqual(@as(f64, 0.67), normalScore(67).?);
    try std.testing.expect(normalScore(-1) == null);
    try std.testing.expect(normalScore(101) == null);
}

test "derive: rungs come off the Pareto front, never from the leftovers (#373)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Another test (or startup_tests' resolveKeys) may have snapshotted THIS
    // process's credentials; pin "no opinion" so derivation sees all specs.
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    // openai serves gpt-5.6 / gpt-5.6-terra / gpt-5.6-luna in the shipped
    // table, so this exercises real catalog resolution — including two
    // configs of one model collapsing into one candidate.
    const entries = [_]Entry{
        .{ .model = "gpt-5.6", .effort = "max", .score = 73, .cost = 5.5 },
        .{ .model = "gpt-5.6", .effort = "medium", .score = 61, .cost = 1.86 },
        .{ .model = "gpt-5.6-terra", .effort = "medium", .score = 35, .cost = 0.9 },
        .{ .model = "gpt-5.6-luna", .effort = "max", .score = 0.67, .cost = 0.61 },
        .{ .model = "not-a-model-anywhere", .score = 99, .cost = 0.01 }, // skipped, never a failure
    };
    const ladders = derive(a, &entries);
    var openai: ?tier_ladder.TierLadder = null;
    for (ladders) |l| if (std.mem.eql(u8, l.provider, "openai")) {
        openai = l;
    };
    try std.testing.expectEqualStrings("gpt-5.6", openai.?.frontier); // 0.73, nothing scores higher
    try std.testing.expectEqualStrings("gpt-5.6-luna", openai.?.small.?); // 0.67/0.61 ≈ 1.10 beats terra's 0.39
    // terra used to take mid as the leftover. It is DOMINATED: luna scores
    // 0.67 to its 0.35 and costs $0.61 to its $0.90, so terra is never worth
    // buying and the front is two deep. mid stays null rather than seating a
    // rung the sheet says is strictly worse than the rung under it (#373).
    try std.testing.expect(openai.?.mid == null);
    const front = paretoFront(a, foldProvider(a, "openai", &entries));
    try std.testing.expectEqual(@as(usize, 2), front.len);
}

test "builtin sheet: every install derives a codex ladder from the shipped leaderboard" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    const ladders = derive(a, &builtin_entries);
    var codex: ?tier_ladder.TierLadder = null;
    for (ladders) |l| if (std.mem.eql(u8, l.provider, "codex")) {
        codex = l;
    };
    // sol tops capability; luna-max tops score-per-dollar (the leaderboard's
    // "most efficient" config). mid is EMPTY on this sheet: luna (0.67 @
    // $0.61) dominates gpt-5.5 (0.54 @ $3.2), gpt-5.4 (0.53 @ $5.2) and
    // terra (0.35 @ $0.9) — every one of them is beaten on score AND costs
    // more, so none is a rung. This test used to pin mid = gpt-5.5, which is
    // exactly the #373 bug: the #291 descent sent every worker of a sol root
    // to a model luna beat by 13 points at a fifth of the price.
    try std.testing.expectEqualStrings("gpt-5.6-sol", codex.?.frontier);
    try std.testing.expectEqualStrings("gpt-5.6-luna", codex.?.small.?);
    try std.testing.expect(codex.?.mid == null);
    // Same sheet, openai: luna is the ONLY survivor (sol/fable/opus resolve
    // nowhere on it), so the front is one deep and openai earns no derived
    // ladder at all — subagent_tier_ladder's compiled row stands.
    for (ladders) |l| try std.testing.expect(!std.mem.eql(u8, l.provider, "openai"));
}

test "derive: fewer than two resolved models yields no ladder for a provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    const entries = [_]Entry{.{ .model = "grok-4.3", .score = 0.5, .cost = 3.0 }};
    for (derive(a, &entries)) |l| try std.testing.expect(!std.mem.eql(u8, l.provider, "xai"));
}

test "scoreFor: the sheet ranks a provider's models for subscription routing" {
    // Luna's best config (max, 67%) outranks terra's (medium, 35%) on codex.
    try std.testing.expect(scoreFor("codex", "gpt-5.6-luna").? > scoreFor("codex", "gpt-5.6-terra").?);
    try std.testing.expect(scoreFor("codex", "model-nobody-benched") == null);
}

test "derive: availability gate — priors describe only logged-in services" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    var av: [provider_mod.provider_specs.len]bool = @splat(false);
    for (provider_mod.provider_specs, 0..) |spec, i| av[i] = std.mem.eql(u8, spec.id, "codex");
    g_available = av;
    // The full builtin sheet, but only one service logged in → exactly one
    // ladder: the sheet never speaks for a provider the user cannot reach.
    // (codex, not openai: since #373 openai's builtin front collapses to
    // luna alone, so gating on it would test nothing.)
    const ladders = derive(a, &builtin_entries);
    try std.testing.expectEqual(@as(usize, 1), ladders.len);
    try std.testing.expectEqualStrings("codex", ladders[0].provider);
}

test "derive: a real three-rung front keeps its mid — domination prunes, shape does not (#373)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    // Scores descending, costs descending WITH them: nobody here is beaten
    // on both axes, so all three survive and each buys something the others
    // cannot. This is the case the Pareto filter must not over-prune.
    const entries = [_]Entry{
        .{ .model = "gpt-5.6", .effort = "max", .score = 80, .cost = 10.0 }, // spd 0.08
        .{ .model = "gpt-5.6-terra", .effort = "high", .score = 60, .cost = 2.0 }, // spd 0.30
        .{ .model = "gpt-5.6-luna", .effort = "medium", .score = 30, .cost = 0.5 }, // spd 0.60
    };
    var openai: ?tier_ladder.TierLadder = null;
    for (derive(a, &entries)) |l| if (std.mem.eql(u8, l.provider, "openai")) {
        openai = l;
    };
    try std.testing.expectEqualStrings("gpt-5.6", openai.?.frontier);
    try std.testing.expectEqualStrings("gpt-5.6-terra", openai.?.mid.?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", openai.?.small.?);
    try std.testing.expectEqual(@as(usize, 3), paretoFront(a, foldProvider(a, "openai", &entries)).len);
}

test "dominates: unpriced capability loses to any priced model that matches it (#373)" {
    const priced: Best = .{ .name = "priced", .score = 0.5, .spd = 0.25 }; // $2.00
    const dear: Best = .{ .name = "dear", .score = 0.5, .spd = 0.05 }; // $10.00
    const unpriced: Best = .{ .name = "unpriced", .score = 0.9 };
    const unpriced_two: Best = .{ .name = "unpriced-two", .score = 0.4 };
    try std.testing.expect(std.math.isInf(effCost(unpriced)));
    try std.testing.expect(dominates(priced, dear)); // same score, a fifth of the money
    try std.testing.expect(!dominates(dear, priced));
    // A price nobody measured is not a bargain: any priced model reaching
    // its score buys the same capability for a knowable sum, so it wins.
    try std.testing.expect(!dominates(unpriced, priced)); // higher score, but +inf vs $2
    try std.testing.expect(dominates(priced, unpriced_two));
    try std.testing.expect(!dominates(unpriced, unpriced_two)); // +inf < +inf is false
    try std.testing.expect(!dominates(unpriced_two, unpriced));
}

test "derive: every seated ladder is monotone and no rung is beaten by one below it (#373)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    // The invariant #373 buys, checked against the shipped sheet for EVERY
    // provider it derives — not just the codex row the bug was reported on.
    for (derive(a, &builtin_entries)) |l| {
        const models = foldProvider(a, l.provider, &builtin_entries);
        const frontier = candidateNamed(models, l.frontier);
        const small = candidateNamed(models, l.small.?);
        try std.testing.expect(frontier.score >= small.score);
        try std.testing.expect(!dominates(small, frontier));
        try std.testing.expect(!dominates(frontier, small)); // cheaper rung must still buy something
        if (l.mid) |mid_name| {
            const mid = candidateNamed(models, mid_name);
            try std.testing.expect(frontier.score >= mid.score and mid.score >= small.score);
            try std.testing.expect(!dominates(mid, frontier) and !dominates(small, mid));
            try std.testing.expect(!dominates(frontier, mid) and !dominates(mid, small));
        }
    }
}

/// Test-only lookup: the folded candidate a seated rung names. A rung that
/// is not in its own provider's fold is a derivation bug, not a test skip.
fn candidateNamed(models: []const Best, name: []const u8) Best {
    for (models) |m| if (std.mem.eql(u8, m.name, name)) return m;
    unreachable;
}
