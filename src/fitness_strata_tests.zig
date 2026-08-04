//! Tests for #376 increment 1 — rung stratification of the local fitness
//! archive. Split out of fitness_strata.zig for the 600-line cap; wired into
//! the test root through fitness_strata.zig's own `test {}` block and
//! test_hooks.zig.

const std = @import("std");

const strata = @import("fitness_strata.zig");
const policy = @import("route_policy.zig");

/// One niche ("reviewer"), four genomes, three routing strata.
///
///   A, B  — ranked against each other on gpt-5.6-luna (a real comparison)
///   C     — a lone genome that happened to run on the DEARER gpt-5.6-terra
///   D     — pre-#376 rows: scored, but naming no model at all
///
/// Pooling every score under a prompt_sha (what promoteAgents did before
/// #376) crowns D (1.00), then C (0.95) — i.e. the two rows that were never
/// compared to anything. Stratified, the only stratum that actually ran a
/// tournament is luna's, and A wins it on 0.90.
const mixed_archive =
    \\{"kind":"prompt","prompt_sha":"aa","text":"genome A"}
    \\{"kind":"workflow_task","prompt_sha":"aa","niche":"reviewer"}
    \\{"kind":"score","prompt_sha":"aa","score":0.9,"model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"aa","score":0.9,"model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"aa","score":0.9,"model":"gpt-5.6-luna"}
    \\{"kind":"prompt","prompt_sha":"bb","text":"genome B"}
    \\{"kind":"workflow_task","prompt_sha":"bb","niche":"reviewer"}
    \\{"kind":"score","prompt_sha":"bb","score":0.6,"model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"bb","score":0.6,"model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"bb","score":0.6,"model":"gpt-5.6-luna"}
    \\{"kind":"prompt","prompt_sha":"cc","text":"genome C"}
    \\{"kind":"workflow_task","prompt_sha":"cc","niche":"reviewer"}
    \\{"kind":"score","prompt_sha":"cc","score":0.95,"model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"cc","score":0.95,"model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"cc","score":0.95,"model":"gpt-5.6-terra"}
    \\{"kind":"prompt","prompt_sha":"dd","text":"genome D"}
    \\{"kind":"workflow_task","prompt_sha":"dd","niche":"reviewer"}
    \\{"kind":"score","prompt_sha":"dd","score":1}
    \\{"kind":"score","prompt_sha":"dd","score":1}
    \\{"kind":"score","prompt_sha":"dd","score":1}
;

test "#376: a fitness row's stratum is the resolved model, and a missing one is `unknown`" {
    try std.testing.expectEqualStrings("gpt-5.6-luna", policy.stratumOf("gpt-5.6-luna"));
    try std.testing.expectEqualStrings("gpt-5.6-terra", policy.stratumOf("gpt-5.6-terra"));
    // Two models scoring.providerClass still pools (sol and bare gpt-5.6,
    // both "frontier") are distinct strata here — that separation is the
    // whole increment.
    try std.testing.expect(!std.mem.eql(u8, policy.stratumOf("gpt-5.6-sol"), policy.stratumOf("gpt-5.6")));
    // A row that names no model is its own bucket, never an empty string that
    // would compare equal to another absent one by accident.
    try std.testing.expectEqualStrings("unknown", policy.stratumOf(""));
    try std.testing.expectEqualStrings(policy.stratum_unknown, policy.stratumOf(""));
}

test "#376: genomes are ranked inside one stratum, never across rungs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const champs = strata.champions(arena_state.allocator(), mixed_archive);

    try std.testing.expectEqual(@as(usize, 1), champs.len); // one champion per niche
    const c = champs[0];
    try std.testing.expectEqualStrings("reviewer", c.niche);
    // The stratum that actually ran a tournament speaks for the niche...
    try std.testing.expectEqualStrings("gpt-5.6-luna", c.stratum);
    try std.testing.expectEqual(@as(u32, 2), c.rivals);
    // ...and its winner is the better PROMPT, not the higher raw number: both
    // the 0.95 (dearer model) and the 1.00 (unrecorded model) lose to 0.90
    // because neither was ever compared to anything.
    try std.testing.expectEqualStrings("aa", c.sha);
    try std.testing.expectEqualStrings("genome A", c.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), c.mean, 1e-9);
    try std.testing.expectEqual(@as(u32, 3), c.n);
}

test "#376: pre-#376 rows form their own `unknown` stratum, never merged into a measured one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The exact rows every archive written before #372's self-describing
    // capture contains: a score with no model column at all. Alone, they still
    // promote (nothing changes for a legacy-only archive) — and they say so,
    // rather than claiming a rung nobody recorded.
    const legacy =
        \\{"kind":"prompt","prompt_sha":"aa","text":"legacy genome"}
        \\{"kind":"child","prompt_sha":"aa","niche":"researcher"}
        \\{"kind":"score","prompt_sha":"aa","score":0.4}
        \\{"kind":"score","prompt_sha":"aa","score":0.6}
    ;
    const only_legacy = strata.champions(a, legacy);
    try std.testing.expectEqual(@as(usize, 1), only_legacy.len);
    try std.testing.expectEqualStrings("unknown", only_legacy[0].stratum);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), only_legacy[0].mean, 1e-9);

    // Mixed with measured rows for the SAME genome, the two never pool: the
    // unknown half cannot inflate (or deflate) the luna half's mean.
    const mixed =
        \\{"kind":"prompt","prompt_sha":"aa","text":"legacy genome"}
        \\{"kind":"child","prompt_sha":"aa","niche":"researcher"}
        \\{"kind":"score","prompt_sha":"aa","score":0}
        \\{"kind":"score","prompt_sha":"aa","score":0}
        \\{"kind":"score","prompt_sha":"aa","score":1,"model":"gpt-5.6-luna"}
        \\{"kind":"score","prompt_sha":"aa","score":1,"model":"gpt-5.6-luna"}
    ;
    const both = strata.champions(a, mixed);
    try std.testing.expectEqual(@as(usize, 1), both.len);
    // Pooled, this genome would read 0.5. Each stratum keeps its own truth,
    // and the tie between two one-genome strata is broken by first-seen order,
    // which is the unknown one here — so the reported mean is 0, not 0.5.
    try std.testing.expectEqualStrings("unknown", both[0].stratum);
    try std.testing.expectApproxEqAbs(@as(f64, 0), both[0].mean, 1e-9);
    try std.testing.expectEqual(@as(u32, 2), both[0].n);
}

test "#376: an unscoreable or uncelled genome still promotes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // No captured text → nothing to write into a persona file. No niche → no
    // cell to write it into. Both were already true before #376.
    const no_text =
        \\{"kind":"child","prompt_sha":"aa","niche":"reviewer"}
        \\{"kind":"score","prompt_sha":"aa","score":0.9,"model":"gpt-5.6-luna"}
    ;
    try std.testing.expectEqual(@as(usize, 0), strata.champions(a, no_text).len);
    const no_niche =
        \\{"kind":"prompt","prompt_sha":"aa","text":"g"}
        \\{"kind":"score","prompt_sha":"aa","score":0.9,"model":"gpt-5.6-luna"}
    ;
    try std.testing.expectEqual(@as(usize, 0), strata.champions(a, no_niche).len);
    try std.testing.expectEqual(@as(usize, 0), strata.champions(a, "").len);
    try std.testing.expectEqual(@as(usize, 0), strata.champions(a, "not json\n{}\n").len);
}

test "#376: separate niches promote separately, each inside its own stratum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const two =
        \\{"kind":"prompt","prompt_sha":"aa","text":"A"}
        \\{"kind":"child","prompt_sha":"aa","niche":"reviewer"}
        \\{"kind":"score","prompt_sha":"aa","score":0.7,"model":"gpt-5.6-luna"}
        \\{"kind":"prompt","prompt_sha":"bb","text":"B"}
        \\{"kind":"child","prompt_sha":"bb","niche":"researcher"}
        \\{"kind":"score","prompt_sha":"bb","score":0.8,"model":"gpt-5.6-terra"}
    ;
    const champs = strata.champions(arena_state.allocator(), two);
    try std.testing.expectEqual(@as(usize, 2), champs.len);
    for (champs) |c| {
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, c.niche, "reviewer")) "gpt-5.6-luna" else "gpt-5.6-terra", c.stratum);
    }
}
