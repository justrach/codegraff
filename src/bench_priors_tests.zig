//! Tests for bench_priors.zig — the bench-sheet priors, Pareto rung seating
//! (#373), and the DGM→Pareto lived-score feedback (#374 follow-on). Split
//! out so the module stays under the 600-line cap; wired into the test root
//! by test_hooks.zig.

const std = @import("std");

const bench = @import("bench_priors.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const provider_mod = @import("provider.zig");

const Entry = bench.Entry;
const Best = bench.Best;
const builtin_entries = bench.builtin_entries;
const normalScore = bench.normalScore;
const derive = bench.derive;
const paretoFront = bench.paretoFront;
const dominates = bench.dominates;
const foldObservations = bench.foldObservations;
const foldProvider = bench.foldProvider;
const effCost = bench.effCost;
const blend = bench.blend;
const scoreFor = bench.scoreFor;

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
    const saved = bench.g_available;
    defer bench.g_available = saved;
    bench.g_available = null;
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
    const saved = bench.g_available;
    defer bench.g_available = saved;
    bench.g_available = null;
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
    const saved = bench.g_available;
    defer bench.g_available = saved;
    bench.g_available = null;
    const entries = [_]Entry{.{ .model = "grok-4.3", .score = 0.5, .cost = 3.0 }};
    for (derive(a, &entries)) |l| try std.testing.expect(!std.mem.eql(u8, l.provider, "xai"));
}

test "foldObservations: recipe→score join through prompt_sha, junk and out-of-range skipped (#374)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const archive =
        \\{"kind":"recipe","prompt_sha":"aaaa","model":"gpt-5.6-luna","effort":"max"}
        \\{"kind":"score","prompt_sha":"aaaa","score":0.2}
        \\{"kind":"score","prompt_sha":"aaaa","score":0.4}
        \\{"kind":"score","prompt_sha":"orphan","score":1.0}
        \\{"kind":"score","prompt_sha":"aaaa","score":40}
        \\not json at all
        \\{"kind":"session"}
    ;
    const obs = foldObservations(a, archive);
    try std.testing.expectEqual(@as(usize, 1), obs.len);
    try std.testing.expectEqualStrings("gpt-5.6-luna", obs[0].model);
    try std.testing.expectEqual(@as(u32, 2), obs[0].n); // orphan sha and the 0-100-scale 40 never joined
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), obs[0].sum, 1e-9);
}

test "blend: lived scores re-weight the sheet and reshape the Pareto front (#374)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = bench.g_available;
    defer bench.g_available = saved;
    bench.g_available = null;
    // Three zero-score lived runs for luna-max: blended = (0.67*3 + 0)/6 = 0.335.
    const archive =
        \\{"kind":"recipe","prompt_sha":"aaaa","model":"gpt-5.6-luna","effort":"max"}
        \\{"kind":"score","prompt_sha":"aaaa","score":0}
        \\{"kind":"score","prompt_sha":"aaaa","score":0}
        \\{"kind":"score","prompt_sha":"aaaa","score":0}
    ;
    const blended = blend(a, &builtin_entries, archive);
    var luna_max: ?f64 = null;
    for (blended) |e| {
        if (std.mem.eql(u8, e.model, "gpt-5.6-luna") and e.effort != null and std.mem.eql(u8, e.effort.?, "max")) luna_max = e.score;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0.335), luna_max.?, 1e-9);
    // The reshaped front re-seats a mid rung: with luna demoted below terra
    // (0.335 < 0.35), terra escapes domination and slots between sol and
    // luna — lived experience literally reroutes the default workers. (5.5
    // stays pruned: sol's optimistic effective cost ~$2.23 dominates it.)
    const ladders = derive(a, blended);
    var codex: ?tier_ladder.TierLadder = null;
    for (ladders) |l| if (std.mem.eql(u8, l.provider, "codex")) {
        codex = l;
    };
    try std.testing.expectEqualStrings("gpt-5.6-sol", codex.?.frontier);
    try std.testing.expectEqualStrings("gpt-5.6-terra", codex.?.mid.?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", codex.?.small.?);
}

test "blend: an unbenched lived config joins score-only and never claims the efficiency rung (#374)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const archive =
        \\{"kind":"recipe","prompt_sha":"bbbb","model":"totally-new-model","effort":"high"}
        \\{"kind":"score","prompt_sha":"bbbb","score":0.99}
    ;
    const blended = blend(a, &builtin_entries, archive);
    var found: ?Entry = null;
    for (blended) |e| if (std.mem.eql(u8, e.model, "totally-new-model")) {
        found = e;
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.99), found.?.score, 1e-9);
    try std.testing.expect(found.?.cost == 0); // +inf effective cost: capability candidate, never `small`
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
    const saved = bench.g_available;
    defer bench.g_available = saved;
    var av: [provider_mod.provider_specs.len]bool = @splat(false);
    for (provider_mod.provider_specs, 0..) |spec, i| av[i] = std.mem.eql(u8, spec.id, "codex");
    bench.g_available = av;
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
    const saved = bench.g_available;
    defer bench.g_available = saved;
    bench.g_available = null;
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
    const saved = bench.g_available;
    defer bench.g_available = saved;
    bench.g_available = null;
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
