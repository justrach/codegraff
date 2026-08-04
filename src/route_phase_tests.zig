//! Tests for #376 increment 2 — one learned seat per workflow phase.
//! Split out of route_phase.zig for the 600-line cap; reached from its
//! `test {}` block and from test_hooks.zig.

const std = @import("std");
const Io = std.Io;

const phase = @import("route_phase.zig");
const policy = @import("route_policy.zig");
const route_trace = @import("route_trace.zig");
const bench = @import("bench_priors.zig");
const selection = @import("subagent_selection.zig");
const pin_mod = @import("subagent_pin.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const Provider = @import("provider.zig").Provider;

fn codex(model: []const u8) Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "sk-test", .model = model, .context = 272_000 };
}

/// The same synthetic sheet #372's demonstration uses: on the SHEET ALONE
/// terra outscores luna and is not dominated by it, so anything that moves
/// below is provably the lived evidence talking, not the priors.
const demo_sheet = [_]bench.Entry{
    .{ .model = "gpt-5.6-terra", .effort = "medium", .score = 0.60, .cost = 0.9 }, // effective $0.90
    .{ .model = "gpt-5.6-luna", .effort = "max", .score = 0.40, .cost = 0.61 }, // effective $0.61
};

/// Lived scores from a `research` shape's `sweep` phase: the ladder's mid rung
/// (terra) did badly there, the cheap rung (luna) did well. Exactly the rows
/// route_trace.captureScore writes — no recipe rows, so bench_priors' own
/// #374 sheet feedback is deliberately NOT what is being exercised here.
const demo_archive =
    \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
;

/// Install `demo_archive` + `demo_sheet` as the session's live policy, with
/// the session's worker route coming from the #291 ladder descent (the one
/// opening #376 gives the policy). Returns a restorer for `defer`.
const Env = struct {
    cells: []const policy.CellObs,
    entries: []const bench.Entry,
    ladders: []const tier_ladder.TierLadder,
    from_ladder: bool,

    fn install(arena: std.mem.Allocator, archive: []const u8, from_ladder: bool) Env {
        const saved: Env = .{
            .cells = policy.g_cells,
            .entries = bench.g_entries,
            .ladders = bench.g_ladders,
            .from_ladder = selection.g_default_from_ladder,
        };
        bench.g_ladders = &.{}; // compiled ladder only, so the baseline is pinned
        bench.g_entries = &demo_sheet;
        policy.g_cells = policy.foldCells(arena, archive);
        selection.g_default_from_ladder = from_ladder;
        return saved;
    }

    fn restore(self: Env) void {
        policy.g_cells = self.cells;
        bench.g_entries = self.entries;
        bench.g_ladders = self.ladders;
        selection.g_default_from_ladder = self.from_ladder;
    }
};

/// The two workers of a `sweep` phase, as workflow.zig hands them over: the
/// niche is the persona name (or the phase title for an inline variant).
const sweep_niches = [_][]const u8{ "researcher", "skeptic" };

test "#376 uniformRole: a phase routes only when all of its workers agree on one role" {
    // The phase title's own canonical slot is the role every worker reports
    // (policy.roleOf reads the title first), whatever their niches are.
    try std.testing.expectEqualStrings("sweep", phase.uniformRole("sweep the repo", &sweep_niches));
    try std.testing.expectEqualStrings("sweep", phase.uniformRole("sweep the repo", &.{}));
    // An off-vocabulary title falls back to the niches — and only when they
    // agree, since a phase whose workers file under different cells has no
    // single cell to route on.
    try std.testing.expectEqualStrings("review", phase.uniformRole("do the thing", &.{ "review the diff", "review again" }));
    try std.testing.expectEqualStrings("", phase.uniformRole("do the thing", &.{ "review the diff", "sweep the repo" }));
    try std.testing.expectEqualStrings("", phase.uniformRole("do the thing", &.{"some-persona"}));
    try std.testing.expectEqualStrings("", phase.uniformRole("do the thing", &.{}));
    // Whatever it answers, it agrees with what every worker's trace reports.
    for (sweep_niches) |n| {
        try std.testing.expectEqualStrings(phase.uniformRole("sweep the repo", &sweep_niches), policy.roleOf("sweep the repo", n));
    }
}

test "#376 DEMONSTRATION: an observed phase re-seats EVERY worker; an unobserved one keeps today's route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const env = Env.install(arena_state.allocator(), demo_archive, true);
    defer env.restore();

    // The session descended the #291 ladder to terra; the (research, sweep)
    // cell has measured luna as strictly better value there.
    const base = codex("gpt-5.6-terra");
    const seat = phase.forPhase(base, .research, "sweep the repo", &sweep_niches, true);
    try std.testing.expect(seat.pin != null);
    try std.testing.expectEqualStrings("gpt-5.6-luna", seat.provider.model);
    try std.testing.expectEqualStrings("gpt-5.6-luna", seat.pin.?.model);

    // PHASE-UNIFORM: one seat, so every worker of the phase resolves to the
    // same model and files under the same cell — with or without a
    // root-authored genome. That is the property #290 needs preserved.
    for (sweep_niches) |niche| {
        try std.testing.expectEqualStrings("gpt-5.6-luna", seat.provider.model);
        const cell = seat.cellOf(niche);
        try std.testing.expectEqual(policy.Shape.research, cell.shape);
        try std.testing.expectEqualStrings("sweep", cell.role);
        try std.testing.expectEqual(policy.Source.learned_policy, seat.sourceFor(false));
        try std.testing.expectEqual(policy.Source.learned_policy, seat.sourceFor(true));
    }

    // An UNOBSERVED phase in the same session is untouched: same session, same
    // ladder, no evidence for its cell — so it keeps exactly today's behavior,
    // including today's `source` attribution.
    const quiet = phase.forPhase(base, .feature, "implement the fix", &.{"implementer"}, true);
    try std.testing.expect(quiet.pin == null);
    try std.testing.expectEqualStrings("gpt-5.6-terra", quiet.provider.model);
    try std.testing.expectEqual(policy.Source.ladder, quiet.sourceFor(false));
    try std.testing.expectEqual(policy.Source.workflow_override, quiet.sourceFor(true));
}

test "#376: the re-seated phase's trace says learned-policy on every worker" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env = Env.install(a, demo_archive, true);
    defer env.restore();

    var sink: Io.Writer.Allocating = .init(a);
    route_trace.g_test_sink = &sink;
    defer route_trace.g_test_sink = null;

    // Drive the exact emission workflow.zig makes, once per worker.
    const seat = phase.forPhase(codex("gpt-5.6-terra"), .research, "sweep the repo", &sweep_niches, true);
    for (sweep_niches) |niche| {
        route_trace.emitSpawnProvider(std.testing.io, null, niche, seat.provider, seat.cellOf(niche), seat.sourceFor(false), null, niche);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, sink.writer.buffered(), "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |ln| : (n += 1) {
        const ev = try std.json.parseFromSliceLeaky(std.json.Value, a, ln, .{});
        try std.testing.expectEqualStrings("agent_route", ev.object.get("type").?.string);
        try std.testing.expectEqualStrings("gpt-5.6-luna", ev.object.get("resolved_model").?.string);
        try std.testing.expectEqualStrings("learned-policy", ev.object.get("source").?.string);
        try std.testing.expectEqualStrings("research", ev.object.get("shape").?.string);
        try std.testing.expectEqualStrings("sweep", ev.object.get("role").?.string);
        // The rung is read back off the seated model, and the id names the
        // exact cell that moved the phase.
        try std.testing.expectEqualStrings("small", ev.object.get("tier").?.string);
        try std.testing.expectEqualStrings("research/sweep@small", ev.object.get("policy_or_genome_id").?.string);
        try std.testing.expectEqualStrings("codex", ev.object.get("provider").?.string);
    }
    try std.testing.expectEqual(sweep_niches.len, n);
}

test "#376: an explicitly chosen worker model outranks the phase policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const base = codex("gpt-5.6-terra");

    // --subagent-model: the session named the worker model, so the route is
    // `session-default`, not the ladder's, and evidence never overrides a
    // human's stated choice.
    {
        const env = Env.install(arena_state.allocator(), demo_archive, false);
        defer env.restore();
        const seat = phase.forPhase(base, .research, "sweep the repo", &sweep_niches, true);
        try std.testing.expect(seat.pin == null);
        try std.testing.expectEqualStrings("gpt-5.6-terra", seat.provider.model);
        try std.testing.expectEqual(policy.Source.session_default, seat.sourceFor(false));
    }
    // A plain inherit-the-root (no worker provider at all) is the same story:
    // `session-default` is a choice, not a default the policy may improve on.
    {
        const env = Env.install(arena_state.allocator(), demo_archive, true);
        defer env.restore();
        const seat = phase.forPhase(base, .research, "sweep the repo", &sweep_niches, false);
        try std.testing.expect(seat.pin == null);
        try std.testing.expectEqual(policy.Source.session_default, seat.sourceFor(false));
    }
}

test "#376: the phase seat can only trade DOWN on cost, and never leaves the provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The mirror image of the demonstration: terra is the loved model but it
    // is also the DEARER one, so a phase already seated on luna can never be
    // moved up to it however well terra scored in the cell.
    const upward =
        \\{"kind":"score","prompt_sha":"aa","score":1,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"aa","score":1,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"bb","score":0,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
        \\{"kind":"score","prompt_sha":"bb","score":0,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    ;
    const env = Env.install(a, upward, true);
    defer env.restore();
    const seat = phase.forPhase(codex("gpt-5.6-luna"), .research, "sweep the repo", &sweep_niches, true);
    try std.testing.expect(seat.pin == null);
    try std.testing.expectEqualStrings("gpt-5.6-luna", seat.provider.model);

    // And whatever it decides, the seat is provider-local by construction: the
    // id, the credential and the account all ride across unchanged, so no
    // phase can move prompts or billing to a second vendor. Cross-provider
    // workers keep needing --subagent-provider + the consent flag, and the
    // sub-first flat-rate routing in subagent_pin is reached only by an
    // explicit `tier` ask, which a phase task never makes.
    const env2 = Env.install(a, demo_archive, true);
    defer env2.restore();
    const base = codex("gpt-5.6-terra");
    const moved = phase.forPhase(base, .research, "sweep the repo", &sweep_niches, true);
    try std.testing.expect(moved.pin != null);
    try std.testing.expectEqualStrings(base.id, moved.provider.id);
    try std.testing.expectEqualStrings(base.api_key, moved.provider.api_key);
    try std.testing.expect(pin_mod.rungAffordable(base.model, moved.provider.model));
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("route_phase.zig"), "subscriptionRung") == null);
}

test "#376: an uncelled phase, and a bootstrap install, keep today's behavior exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = codex("gpt-5.6-terra");
    {
        const env = Env.install(a, demo_archive, true);
        defer env.restore();
        // Off-vocabulary title, niches that disagree → no single role, so the
        // evidence that WOULD have moved a `sweep` phase moves nothing.
        const seat = phase.forPhase(base, .research, "ponder", &.{ "researcher", "review the diff" }, true);
        try std.testing.expect(seat.pin == null);
        try std.testing.expectEqualStrings("gpt-5.6-terra", seat.provider.model);
    }
    {
        // An install with no archive at all: zero cells, nothing to say.
        const env = Env.install(a, "", true);
        defer env.restore();
        const seat = phase.forPhase(base, .research, "sweep the repo", &sweep_niches, true);
        try std.testing.expect(seat.pin == null);
        try std.testing.expectEqual(policy.Source.ladder, seat.sourceFor(false));
    }
}

test "#376 firewall: the seat is resolved ONCE per phase, outside the task loop" {
    // The property is about the CALL SITE — that no task can influence its own
    // model — so it is pinned as source text, the same way #372 pinned the
    // no-per-task-pin invariant it replaces.
    const src = @embedFile("workflow.zig");
    // #380 wraps the same one-shot resolution in vision_ask.phaseSeat, which
    // may swap the phase's model but still yields ONE seat for the whole
    // phase — the property this test exists to protect.
    const seat_at = std.mem.indexOf(u8, src, "const seat = vision_ask.phaseSeat(route_phase.forPhase(").?;
    // (The loop indexes from 0 rather than 1 since the §2b collapse gate needs
    // the task INDEX to look up its survivor, not a 1-based display number.)
    const loop_at = std.mem.indexOf(u8, src, "for (labels, prompts, overrides, niches, isolations, isolation_fallbacks, futures, 0..)").?;
    try std.testing.expect(seat_at < loop_at); // resolved before the fan-out
    // Every spawn in the phase — first attempt and retry alike — receives that
    // one value verbatim; nothing per task is ever passed as a model pin.
    try std.testing.expect(std.mem.indexOf(u8, src, "isolation_fallback, seat.pin }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "isolation_fallbacks[i], seat.pin }") != null);
}
