//! #296 — judge-free stage-level fitness for pipeline runs (shape D).
//!
//! Pipelines were the one execution mode with no scoring path at all: stages
//! call runSub directly and never reach scoreVariants, so a slot the catalog
//! named only inside shape D advertised a MAP-Elites cell nothing could ever
//! fill (`transform` was dropped from canonical_slots for exactly that).
//!
//! The honest unit is the STAGE, never the item. One stage runs ONE genome
//! (one system_prompt override, one prompt template) over N items that
//! differ per worker BY DESIGN — ranking items against each other would
//! confound item difficulty with genome quality, the per-task variation
//! #290 forbids attributing fitness across. So each stage files exactly one
//! row per run: the fraction of items that completed the stage without
//! error, under the stage's (migration, slot) cell and its one resolved
//! seat. Judge-free — no model call is ever spent on it.
//!
//! Scale note: migration cells hold completion fractions while phase cells
//! hold judged quality. Both are [0,1] and they never pool — only pipeline
//! stages write shape=migration (shapeOfPhases cannot produce it), so
//! learnedRung always compares like with like inside one cell.
//!
//! Local capture only (the #372 discipline): rows go through
//! route_trace.captureVariant into the local DGM archive, which runs with
//! telemetry OFF too. Nothing here reaches scoreEvent/fleetEvent, so no new
//! bytes can leave the machine. The edit-landed signal (edit_contract's
//! porcelain probe) is deliberately NOT folded in: pipeline briefs carry no
//! contract note, and item chains interleave in one shared cwd, so a
//! per-stage snapshot pair could not attribute a tree change to one stage.

const std = @import("std");

const main_mod = @import("main.zig");
const route_policy = @import("route_policy.zig");
const route_trace = @import("route_trace.zig");
const scoring = @import("scoring.zig");
const util = @import("util.zig");
const Provider = @import("provider.zig").Provider;

/// Per-stage outcome counters, shared by every item's chain. Chains run
/// concurrently on pool threads; the futures join in workflow_pipeline.run
/// is the read barrier, so monotonic increments suffice.
pub const StageStat = struct {
    /// Items whose chain reached this stage and ran it.
    attempted: std.atomic.Value(u32) = .init(0),
    /// Items whose attempt (including the one #2 retry) ended without error.
    ok: std.atomic.Value(u32) = .init(0),

    pub fn noteAttempt(self: *StageStat) void {
        _ = self.attempted.fetchAdd(1, .monotonic);
    }

    pub fn noteOk(self: *StageStat) void {
        _ = self.ok.fetchAdd(1, .monotonic);
    }
};

/// One stage's score, or null when the run carries no signal: a stage no
/// item reached says nothing about its genome, and a total failure is
/// skipped rather than filed as 0 (scoreVariants' s<=0 rule — an all-fail
/// stage is far more often an environment failure than genome evidence,
/// and a 0 row would poison the cell mean).
pub fn stageScore(attempted: u32, ok: u32) ?f64 {
    if (attempted == 0 or ok == 0 or ok > attempted) return null;
    return @as(f64, @floatFromInt(ok)) / @as(f64, @floatFromInt(attempted));
}

/// File ONE fitness row for one stage of one pipeline run. `provider` is the
/// stage's resolved seat — every item ran on it, stage-uniform (#290/#376) —
/// and `genome_text` the stage's one configuration (its system_prompt
/// override, else its prompt template; only its fingerprint is recorded).
/// Returns whether a row was written, so the call site and the tests can
/// tell a gated round from a scored one.
pub fn captureStage(provider: Provider, label: []const u8, niche: []const u8, genome_text: []const u8, stat: *const StageStat) bool {
    if (!main_mod.g_fleet) return false;
    // An off-vocabulary stage stays uncelled, exactly like an off-vocabulary
    // phase title: execution is unaffected, only fitness accrual needs a slot.
    if (route_policy.roleOf(label, niche).len == 0) return false;
    const s01 = stageScore(stat.attempted.load(.monotonic), stat.ok.load(.monotonic)) orelse return false;
    const fp = scoring.promptFingerprint(genome_text);
    var niche_buf: [64]u8 = undefined;
    const clean = scoring.sanitizeMetaField(&niche_buf, util.utf8Prefix(niche, 64));
    route_trace.captureVariant(provider, .migration, label, clean, &fp, s01);
    return true;
}

// ── tests ──────────────────────────────────────────────────────────────────

const Io = std.Io;
const trace = @import("trace.zig");

fn codex(model: []const u8) Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "sk-test", .model = model, .context = 272_000 };
}

/// A real Trajectory writing real rows into memory, installed as the live
/// archive sink. Restore via the returned prior value.
fn installTraj(traj: *trace.Trajectory) ?*trace.Trajectory {
    const saved = trace.g_traj;
    trace.g_traj = traj;
    return saved;
}

test "#296: a pipeline stage accrues exactly ONE fitness row, celled on its slot — never per item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out: Io.Writer.Allocating = .init(a);
    var traj: trace.Trajectory = .{ .io = std.testing.io, .gpa = std.testing.allocator, .out = &out.writer, .start = Io.Timestamp.now(std.testing.io, .awake) };
    defer traj.deinit();
    const saved = installTraj(&traj);
    defer trace.g_traj = saved;
    const saved_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    defer main_mod.g_fleet = saved_fleet;

    // Five items reached the stage, four finished clean: five per-item
    // outcomes, ONE stage-level row at 0.8.
    var stat: StageStat = .{};
    for (0..5) |_| stat.noteAttempt();
    for (0..4) |_| stat.noteOk();
    try std.testing.expect(captureStage(codex("gpt-5.6-terra"), "transform each file", "transform each file", "Apply the codemod; keep behavior identical.", &stat));
    const rows = out.writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "\"kind\":\"score\""));

    // And the row round-trips into exactly the cell the policy learns from —
    // `transform` claims a fillable MAP-Elites cell, closing the #296 gap.
    const cells = route_policy.foldCells(a, rows);
    try std.testing.expectEqual(@as(usize, 1), cells.len);
    try std.testing.expectEqualStrings("migration", cells[0].shape);
    try std.testing.expectEqualStrings("transform", cells[0].role);
    try std.testing.expectEqualStrings("mid", cells[0].tier);
    try std.testing.expectEqualStrings("gpt-5.6-terra", cells[0].model);
    try std.testing.expectEqual(@as(u32, 1), cells[0].n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), cells[0].mean(), 1e-9);
}

test "#296: rounds with no signal file nothing — unreached, all-fail, off-vocabulary, fleet off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var out: Io.Writer.Allocating = .init(arena_state.allocator());
    var traj: trace.Trajectory = .{ .io = std.testing.io, .gpa = std.testing.allocator, .out = &out.writer, .start = Io.Timestamp.now(std.testing.io, .awake) };
    defer traj.deinit();
    const saved = installTraj(&traj);
    defer trace.g_traj = saved;
    const saved_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    defer main_mod.g_fleet = saved_fleet;

    // A stage no item reached says nothing about its genome.
    var unreached: StageStat = .{};
    try std.testing.expect(!captureStage(codex("gpt-5.6-terra"), "transform each file", "", "g", &unreached));
    // Total failure is skipped, not filed as a cell-poisoning 0.
    var all_fail: StageStat = .{};
    all_fail.noteAttempt();
    try std.testing.expect(!captureStage(codex("gpt-5.6-terra"), "transform each file", "", "g", &all_fail));
    // An off-vocabulary stage runs fine but stays uncelled, like a phase.
    var clean: StageStat = .{};
    clean.noteAttempt();
    clean.noteOk();
    try std.testing.expect(!captureStage(codex("gpt-5.6-terra"), "polish the files", "some-persona", "g", &clean));
    // The fleet master switch gates local capture the same way it gates
    // scoreVariants.
    main_mod.g_fleet = false;
    try std.testing.expect(!captureStage(codex("gpt-5.6-terra"), "transform each file", "", "g", &clean));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out.writer.buffered(), "\"kind\":\"score\""));
}

test "#296/#290 firewall: capture is per STAGE after the join, and every item runs the stage's one seat" {
    // The property is about the CALL SITE — no per-item path may write
    // fitness, and no item may influence its own model — so it is pinned as
    // source text, the same way #376 pinned the phase-seat invariant.
    const src = @embedFile("workflow_pipeline.zig");
    // Exactly one capture call, sitting AFTER the all-chains join: per-item
    // outcomes are folded into it and can never become per-item rows.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "pipeline_score.captureStage("));
    const join_at = std.mem.indexOf(u8, src, "out.* = fut.await(ctx.io)").?;
    try std.testing.expect(std.mem.indexOf(u8, src, "pipeline_score.captureStage(").? > join_at);
    // The seat is resolved once per stage, in the parse loop, before any
    // chain spawns — route_phase.forPhase, the same door phases go through.
    const seat_at = std.mem.indexOf(u8, src, "sp.seat = route_phase.forPhase(").?;
    try std.testing.expect(seat_at < std.mem.indexOf(u8, src, "ctx.io.async(pipelineChain").?);
    // Both spawn attempts — first try and retry — receive that seat verbatim.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "st.isolation_fallback, st.seat.pin, null)"));
}
