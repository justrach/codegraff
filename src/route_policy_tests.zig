//! Tests for #372 — the routing trace (route_trace.zig) and the learned
//! (shape, role) tier policy (route_policy.zig). Split out so both modules
//! stay under the 600-line cap; wired into the test root by test_hooks.zig.

const std = @import("std");
const Io = std.Io;

const policy = @import("route_policy.zig");
const route_trace = @import("route_trace.zig");
const bench = @import("bench_priors.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const pin_mod = @import("subagent_pin.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const trace = @import("trace.zig");

const Cell = policy.Cell;
const Decision = policy.Decision;

fn codex(model: []const u8) Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = model, .context = 272_000 };
}

/// The synthetic bench sheet the demonstration below runs against. Chosen so
/// the SHEET ALONE keeps the compiled ladder's answer: terra outscores luna
/// (0.60 vs 0.40) and is not dominated by it, so any re-seating that happens
/// is provably the lived evidence talking, not the priors.
const demo_sheet = [_]bench.Entry{
    .{ .model = "gpt-5.6-terra", .effort = "medium", .score = 0.60, .cost = 0.9 }, // effective $0.90
    .{ .model = "gpt-5.6-luna", .effort = "max", .score = 0.40, .cost = 0.61 }, // effective $0.61
};

/// Lived scores from a `research` shape's `sweep` phase: terra (the ladder's
/// mid rung) did badly, luna did well. Written in the exact self-describing
/// `kind:"score"` shape route_trace.captureScore emits.
const demo_archive =
    \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
    \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
;

test "#372 trace line: every source kind renders its own attribution, absent fields render -" {
    var buf: [320]u8 = undefined;
    // The line the issue specifies, field for field.
    try std.testing.expectEqualStrings(
        "shape=research role=sweep tier=mid resolved_model=gpt-5.6-terra source=ladder policy_or_genome_id=ladder:codex",
        policy.formatDecision(&buf, .{ .shape = .research, .role = "sweep", .tier = .mid, .resolved_model = "gpt-5.6-terra", .source = .ladder, .policy_id = "ladder:codex" }),
    );
    // Each source kind is spelled with hyphens on the wire, and each is
    // distinguishable — that is the whole point of the field.
    const Case = struct { src: policy.Source, want: []const u8 };
    for ([_]Case{
        .{ .src = .explicit_pin, .want = "source=explicit-pin" },
        .{ .src = .persona, .want = "source=persona" },
        .{ .src = .learned_policy, .want = "source=learned-policy" },
        .{ .src = .workflow_override, .want = "source=workflow-override" },
        .{ .src = .session_default, .want = "source=session-default" },
        .{ .src = .ladder, .want = "source=ladder" },
    }) |case| {
        const line = policy.formatDecision(&buf, .{ .source = case.src });
        try std.testing.expect(std.mem.indexOf(u8, line, case.want) != null);
    }
    // An uncelled worker (off-vocabulary title, off-ladder model) still emits
    // a complete, splittable line rather than empty `key=` fields.
    try std.testing.expectEqualStrings(
        "shape=adhoc role=- tier=- resolved_model=- source=session-default policy_or_genome_id=-",
        policy.formatDecision(&buf, .{}),
    );
    // A model-authored label cannot blow the line up.
    const long: [400]u8 = @splat('x');
    const capped = policy.formatDecision(&buf, .{ .role = &long, .resolved_model = &long, .policy_id = &long });
    try std.testing.expect(capped.len > 0 and capped.len < buf.len);
}

test "#372 trace: the --json agent_route event carries the same six fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sink: Io.Writer.Allocating = .init(arena_state.allocator());
    route_trace.g_test_sink = &sink;
    defer route_trace.g_test_sink = null;

    route_trace.emitSpawn(std.testing.io, null, "sweep the callers", "codex", "gpt-5.6-terra", .{ .shape = .research, .role = "sweep" }, .ladder, "");
    const line = std.mem.trimEnd(u8, sink.writer.buffered(), "\n");
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null); // one complete object per line
    const ev = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), line, .{});
    try std.testing.expectEqualStrings("agent_route", ev.object.get("type").?.string);
    try std.testing.expectEqualStrings("research", ev.object.get("shape").?.string);
    try std.testing.expectEqualStrings("sweep", ev.object.get("role").?.string);
    try std.testing.expectEqualStrings("gpt-5.6-terra", ev.object.get("resolved_model").?.string);
    try std.testing.expectEqualStrings("ladder", ev.object.get("source").?.string);
    try std.testing.expectEqualStrings("sweep the callers", ev.object.get("task").?.string);
    // The tier is READ BACK off the resolved model, so an inherited route —
    // the exact case #372 reports as invisible — still names its rung.
    try std.testing.expectEqualStrings("mid", ev.object.get("tier").?.string);
    try std.testing.expectEqualStrings("ladder:codex", ev.object.get("policy_or_genome_id").?.string);
}

test "#372: the shape is read off the phase titles the root model authored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn f(alloc: std.mem.Allocator, json: []const u8) []std.json.Value {
            const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{}) catch unreachable;
            return v.array.items;
        }
    }.f;
    // The real run the issue describes: sweep -> synthesize is shape B.
    try std.testing.expectEqual(policy.Shape.research, policy.shapeOfPhases(parse(a, "[{\"title\":\"sweep the repo\"},{\"title\":\"synthesize\"}]")));
    try std.testing.expectEqual(policy.Shape.review, policy.shapeOfPhases(parse(a, "[{\"title\":\"find security bugs\"},{\"title\":\"verify\"},{\"title\":\"synthesize\"}]")));
    try std.testing.expectEqual(policy.Shape.design, policy.shapeOfPhases(parse(a, "[{\"title\":\"variants\"},{\"title\":\"build it\"}]")));
    try std.testing.expectEqual(policy.Shape.feature, policy.shapeOfPhases(parse(a, "[{\"title\":\"scope\"},{\"title\":\"implement\"},{\"title\":\"review\"}]")));
    // Off-vocabulary titles mint no shape — uncelled, exactly like an
    // off-vocabulary slot (shapes.canonicalSlot's rule).
    try std.testing.expectEqual(policy.Shape.adhoc, policy.shapeOfPhases(parse(a, "[{\"title\":\"ponder\"},{\"title\":\"code review\"}]")));
    try std.testing.expectEqual(policy.Shape.adhoc, policy.shapeOfPhases(parse(a, "[]")));
    // Shape.parse is the closed-vocabulary inverse (an archive row's `shape`
    // column back into the enum); off-vocabulary reads as adhoc, never a guess.
    try std.testing.expectEqual(policy.Shape.research, policy.Shape.parse("research"));
    try std.testing.expectEqual(policy.Shape.adhoc, policy.Shape.parse("Research"));
    try std.testing.expectEqual(policy.Shape.adhoc, policy.Shape.parse(""));
    // The role is the phase's own slot, else the persona niche's slot.
    try std.testing.expectEqualStrings("sweep", policy.roleOf("sweep the repo", "researcher"));
    try std.testing.expectEqualStrings("review", policy.roleOf("do the thing", "review the diff"));
    try std.testing.expectEqualStrings("", policy.roleOf("do the thing", "some-persona"));
    // tierOf is the ladder inverse the trace needs for an unpinned worker.
    try std.testing.expectEqual(tier_ladder.Tier.mid, policy.tierOf("codex", "gpt-5.6-terra").?);
    try std.testing.expectEqual(tier_ladder.Tier.frontier, policy.tierOf("codex", "gpt-5.6-sol").?);
    try std.testing.expect(policy.tierOf("codex", "claude-opus-4-8") == null); // off this ladder
    try std.testing.expectEqualStrings("", policy.tierLabelFor("xai", "grok-4.3")); // no ladder at all
}

test "#372 foldCells: only self-describing score rows become observations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const archive =
        \\{"kind":"score","prompt_sha":"aa","score":0.5,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"aa","score":0.7,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"zz","score":0.9}
        \\{"kind":"score","prompt_sha":"zz","score":0.9,"shape":"research","role":"sweep","tier":"mid"}
        \\{"kind":"score","prompt_sha":"zz","score":40,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-luna"}
        \\{"kind":"recipe","prompt_sha":"aa","model":"gpt-5.6-luna","effort":"max"}
        \\not json at all
    ;
    const cells = policy.foldCells(a, archive);
    // The bare pre-#372 score row, the coordinate-less one, the 0-100-scale
    // one and the recipe row are all skipped rather than mis-filed.
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqualStrings("research", cells[0].shape);
    try std.testing.expectEqualStrings("sweep", cells[0].role);
    try std.testing.expectEqualStrings("mid", cells[0].tier);
    try std.testing.expectEqualStrings("gpt-5.6-terra", cells[0].model);
    try std.testing.expectEqual(@as(u32, 2), cells[0].n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), cells[0].mean(), 1e-9);
    // An archive with nothing in it is the bootstrap case: zero cells, so
    // every resolution below falls straight through to the ladder.
    try std.testing.expectEqual(@as(usize, 0), policy.foldCells(a, "").len);
}

test "#372 DEMONSTRATION: a dominated mid rung is re-seated, an unobserved cell keeps the ladder answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cells = policy.foldCells(arena_state.allocator(), demo_archive);
    const ladder_mid = tier_ladder.forProvider("codex").?.mid.?; // today's answer: gpt-5.6-terra
    try std.testing.expectEqualStrings("gpt-5.6-terra", ladder_mid);

    // BASELINE — the sheet alone, no lived evidence: terra outscores luna on
    // the sheet, so nothing dominates it and today's ladder answer stands.
    try std.testing.expect(policy.learnedRungIn(&.{}, &demo_sheet, "codex", .{ .shape = .research, .role = "sweep" }, ladder_mid) == null);

    // LEARNED — with the archive folded in, terra blends to (0.60*3 +
    // 0.20*3)/6 = 0.40 while luna blends to (0.40*3 + 0.95*3)/6 = 0.675.
    // luna now matches-and-beats terra's quality for $0.61 against $0.90, so
    // it DOMINATES it and the (research, sweep) mid rung is re-seated.
    const reseated = policy.learnedRungIn(cells, &demo_sheet, "codex", .{ .shape = .research, .role = "sweep" }, ladder_mid);
    try std.testing.expectEqualStrings("gpt-5.6-luna", reseated.?);

    // SPARSE — a cell nobody has ever scored has no basis to move anything,
    // so it falls through the whole hierarchy to today's ladder answer.
    try std.testing.expect(policy.learnedRungIn(cells, &demo_sheet, "codex", .{ .shape = .feature, .role = "implement" }, ladder_mid) == null);
    // ...and so does a role whose shape has evidence but whose SHAPE-level
    // pool still lacks the ladder's own answer to compare against.
    try std.testing.expect(policy.learnedRungIn(cells, &demo_sheet, "codex", .{ .shape = .review, .role = "find" }, ladder_mid) == null);
}

test "#372 hierarchy: exact cell decides, a silent cell borrows its shape, a silent shape keeps the ladder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ladder_mid = tier_ladder.forProvider("codex").?.mid.?;

    // A DIFFERENT role in the same shape has no rows of its own, so it
    // borrows the shape-level pool (`sweep`'s evidence) — rung two.
    const cells = policy.foldCells(a, demo_archive);
    try std.testing.expectEqualStrings("gpt-5.6-luna", policy.learnedRungIn(cells, &demo_sheet, "codex", .{ .shape = .research, .role = "synthesize" }, ladder_mid).?);

    // But an exact cell that HAS evidence decides for itself, including
    // deciding to keep the ladder's answer — it must not fall through to a
    // shape-level pool that would have overridden it. Here `synthesize` says
    // terra is excellent and luna is poor, so terra survives.
    const keeps =
        \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"aa","score":0.2,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
        \\{"kind":"score","prompt_sha":"bb","score":0.95,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
        \\{"kind":"score","prompt_sha":"cc","score":1,"shape":"research","role":"synthesize","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"cc","score":1,"shape":"research","role":"synthesize","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"dd","score":0,"shape":"research","role":"synthesize","tier":"small","model":"gpt-5.6-luna"}
        \\{"kind":"score","prompt_sha":"dd","score":0,"shape":"research","role":"synthesize","tier":"small","model":"gpt-5.6-luna"}
    ;
    const split = policy.foldCells(a, keeps);
    try std.testing.expect(policy.learnedRungIn(split, &demo_sheet, "codex", .{ .shape = .research, .role = "synthesize" }, ladder_mid) == null);
    try std.testing.expectEqualStrings("gpt-5.6-luna", policy.learnedRungIn(split, &demo_sheet, "codex", .{ .shape = .research, .role = "sweep" }, ladder_mid).?);

    // A single lucky run is SPARSE (min_model_obs) and moves nothing.
    const one_run =
        \\{"kind":"score","prompt_sha":"aa","score":0.1,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"bb","score":1,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    ;
    try std.testing.expect(policy.learnedRungIn(policy.foldCells(a, one_run), &demo_sheet, "codex", .{ .shape = .research, .role = "sweep" }, ladder_mid) == null);
}

test "#372: the learned policy can only ever trade DOWN on cost, never up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // The mirror image of the demonstration: luna is the loved model but it
    // is also the CHEAP one, so asking about the `small` rung can never be
    // answered with the pricier terra however well terra scored.
    const archive =
        \\{"kind":"score","prompt_sha":"aa","score":1,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"aa","score":1,"shape":"research","role":"sweep","tier":"mid","model":"gpt-5.6-terra"}
        \\{"kind":"score","prompt_sha":"bb","score":0,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
        \\{"kind":"score","prompt_sha":"bb","score":0,"shape":"research","role":"sweep","tier":"small","model":"gpt-5.6-luna"}
    ;
    const cells = policy.foldCells(arena_state.allocator(), archive);
    const small = tier_ladder.forProvider("codex").?.small.?;
    try std.testing.expectEqualStrings("gpt-5.6-luna", small);
    try std.testing.expect(policy.learnedRungIn(cells, &demo_sheet, "codex", .{ .shape = .research, .role = "sweep" }, small) == null);
}

test "#372: a learned cell reroutes a TIER pin, and an explicit model pin still outranks it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // Install the demonstration's evidence as the session's live policy.
    const saved_cells = policy.g_cells;
    const saved_entries = bench.g_entries;
    const saved_ladders = bench.g_ladders;
    defer {
        policy.g_cells = saved_cells;
        bench.g_entries = saved_entries;
        bench.g_ladders = saved_ladders;
    }
    bench.g_ladders = &.{}; // compiled ladder only, so the baseline is pinned
    bench.g_entries = &demo_sheet;
    policy.g_cells = policy.foldCells(arena_state.allocator(), demo_archive);

    const root = codex("gpt-5.6-sol");
    const cell: Cell = .{ .shape = .research, .role = "sweep" };

    // A `tier: mid` ask in this cell now resolves to the model the cell
    // measured as strictly better value, and says so.
    const learned = pin_mod.resolveIn(root, .{ .tier = .mid }, cell);
    try std.testing.expectEqualStrings("gpt-5.6-luna", learned.provider.?.model);
    try std.testing.expectEqual(pin_mod.Source.learned_policy, learned.source);
    try std.testing.expectEqualStrings("codex", learned.provider.?.id); // provider-local, always

    // The SAME ask in an unmeasured cell keeps today's ladder answer.
    const unmeasured = pin_mod.resolveIn(root, .{ .tier = .mid }, .{ .shape = .feature, .role = "implement" });
    try std.testing.expectEqualStrings("gpt-5.6-terra", unmeasured.provider.?.model);
    try std.testing.expectEqual(pin_mod.Source.ladder, unmeasured.source);

    // AN EXPLICIT USER PIN OUTRANKS EVERYTHING LEARNED. Same cell, same
    // session, but the call named a model: the learned layer is never even
    // consulted, and the trace attributes the choice to the human.
    const explicit = pin_mod.resolveIn(root, .{ .model = "gpt-5.6-terra" }, cell);
    try std.testing.expectEqualStrings("gpt-5.6-terra", explicit.provider.?.model);
    try std.testing.expectEqual(pin_mod.Source.explicit_pin, explicit.source);
    // A persona's exact `model:` frontmatter pin likewise wins, and is
    // attributed to the persona rather than to the user's call.
    const persona = pin_mod.resolveIn(root, .{ .model = "gpt-5.6-terra", .from_persona = true }, cell);
    try std.testing.expectEqualStrings("gpt-5.6-terra", persona.provider.?.model);
    try std.testing.expectEqual(pin_mod.Source.persona, persona.source);
    // And the cell-less entry point (every pre-#372 caller) is unchanged.
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.resolve(root, .{ .tier = .mid }).provider.?.model);
}

test "#372 round trip: what captureVariant writes is exactly what foldCells learns from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A real Trajectory, writing the real rows, into memory.
    var out: Io.Writer.Allocating = .init(a);
    var traj: trace.Trajectory = .{ .io = std.testing.io, .gpa = std.testing.allocator, .out = &out.writer, .start = Io.Timestamp.now(std.testing.io, .awake) };
    defer traj.deinit();
    const saved = trace.g_traj;
    defer trace.g_traj = saved;
    trace.g_traj = &traj;

    // Three judged `sweep` variants on the mid rung, three on the small one —
    // the capture the scoring path makes, with no hand-written JSON anywhere.
    for (0..3) |_| route_trace.captureVariant(codex("gpt-5.6-terra"), .research, "sweep the repo", "sweep", "aa", 0.2);
    for (0..3) |_| route_trace.captureVariant(codex("gpt-5.6-luna"), .research, "sweep the repo", "sweep", "bb", 0.95);

    const cells = policy.foldCells(a, out.writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), cells.len);
    // The rung is derived from the model, not asserted by the caller.
    for (cells) |c| {
        try std.testing.expectEqualStrings("research", c.shape);
        try std.testing.expectEqualStrings("sweep", c.role);
        try std.testing.expectEqual(@as(u32, 3), c.n);
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, c.model, "gpt-5.6-terra")) "mid" else "small", c.tier);
    }
    // ...and the policy reaches the same verdict as the hand-written archive.
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        policy.learnedRungIn(cells, &demo_sheet, "codex", .{ .shape = .research, .role = "sweep" }, "gpt-5.6-terra").?,
    );
}

test "#372/#376 firewall: a phase task takes the PHASE's seat, and still no per-task pin (#290)" {
    // The trace makes routing VISIBLE; #376 lets the policy make it VARY —
    // but only per PHASE, never per task inside one. workflowTask and
    // workflowRetryTask are the only doors a phase task goes through, and
    // both hand runSub the `seat` their caller resolved once for the whole
    // phase (route_phase.forPhase), plus a null EFFORT: no axis of a phase
    // task's configuration is readable off the task itself, so scoreVariants
    // keeps ranking prompt genomes that ran on one identical configuration.
    // Pinned as source text because the property is about the call site, not
    // about any value a unit test could observe at runtime.
    const src = @embedFile("subagent.zig");
    const wf = std.mem.indexOf(u8, src, "pub fn workflowTask(").?;
    const wf_end = std.mem.indexOf(u8, src[wf..], "\n}").?;
    try std.testing.expect(std.mem.indexOf(u8, src[wf .. wf + wf_end], "isolation_fallback, seat, null, \"\")") != null);
    const rt = std.mem.indexOf(u8, src, "pub fn workflowRetryTask(").?;
    const rt_end = std.mem.indexOf(u8, src[rt..], "\n}").?;
    try std.testing.expect(std.mem.indexOf(u8, src[rt .. rt + rt_end], "isolation_fallback, seat, null, \"\")") != null);
    // `seat` is a parameter of both, never derived from the task's own fields.
    try std.testing.expect(std.mem.indexOf(u8, src[wf .. wf + wf_end], "isolation_fallback: bool, seat: ?Provider)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src[rt .. rt + rt_end], "isolation_fallback: bool, seat: ?Provider)") != null);
}
