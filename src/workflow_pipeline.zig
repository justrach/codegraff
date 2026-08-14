//! Pipeline mode (#3), split out of workflow.zig (600-line cap).
//!
//! Phases fan out then synthesize: a barrier between phases, since every
//! next-phase task waits on ALL of the previous one via {{prev}}. Pipeline
//! instead maps each ITEM through a chain of STAGES with NO barrier — item A
//! can be in stage 3 while item B is still in stage 1, so wall-clock is the
//! slowest single chain, not the sum of slowest-per-stage. Use it for
//! per-item work (transform/verify each file); use phases for fan-out +
//! synthesis.
//!
//! Why its own file: it is a genuinely separate execution mode that shares
//! only prompt-substitution helpers with the phases loop, and keeping it here
//! is what buys workflow.zig the room for the escalation gate. It also gets
//! its OWN admission check — the phases path's `admit` sits after the
//! pipeline dispatch, so before this split a pipeline was the one way to fan
//! out with no budget gate at all. That is not academic: the eval study's
//! refactor run instantiated a 4-item x 2-stage pipeline, retried all four
//! items, and burned the entire 30-call cap.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const failure = tools.failure;

const subagent = @import("subagent.zig");
const runSub = subagent.runSub;
const subagent_run = @import("subagent_run.zig");
const failureAllowsRetry = subagent_run.failureAllowsRetry;

const fleet = @import("fleet.zig");
const Isolation = fleet.Isolation;
const route_policy = @import("route_policy.zig");
const route_phase = @import("route_phase.zig"); // #376 one learned seat per stage
const route_trace = @import("route_trace.zig");
const pipeline_score = @import("pipeline_score.zig"); // #296 stage-level fitness
const telemetry = @import("telemetry.zig");
const wfp = @import("workflow_progress.zig");
const escalation = @import("escalation.zig");
const phase_budget = @import("phase_budget.zig");
const workflow = @import("workflow.zig");
const tick_gate = @import("tick_gate.zig"); // #tui-tick/#444: activity lines land at a line boundary, and never in a test binary

const max_pipeline_items = 8;
const max_pipeline_stages = 5;

// Flat {{prev}} cap for pipeline mode (#3): each pipeline item runs its own
// independent stage chain, so unlike phases there's no fan-in multiplying one
// item's previous-stage text across other items' prompts — no phase-budget
// division needed here, a flat cap is enough.
const pipeline_prev_cap = 6000;

const StageSpec = struct {
    label: []const u8,
    prompt: []const u8, // raw; may contain {{item}} / {{prev}}
    override: ?[]const u8,
    niche: []const u8,
    isolation: Isolation = .shared_cwd, // #276 P0-1
    isolation_fallback: bool = false,
    role: []const u8 = "", // #372: this stage's canonical slot, for its route trace
    /// #376 applied to stages: the ONE seat every item's worker for this
    /// stage runs on, resolved once in run(). Stage-uniform, so #290's
    /// no-per-task-variation rule holds across items exactly as it does
    /// across a phase's tasks — which is what makes the stage scoreable as
    /// a unit (#296).
    seat: route_phase.Seat = .{ .provider = undefined },
};

/// Replace every `needle` in `hay` with `repl` (arena-allocated); returns `hay`
/// unchanged when the needle is absent.
fn replacePlaceholder(arena: Allocator, hay: []const u8, needle: []const u8, with: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, hay, needle) == null) return hay;
    const size = std.mem.replacementSize(u8, hay, needle, with);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, hay, needle, with, buf);
    return buf;
}

/// Resolve a pipeline stage prompt for one item: substitute {{item}}, and from
/// stage 2 {{prev}} = this item's bounded previous-stage result. Either is
/// appended when its placeholder is omitted (mirrors phases-mode {{prev}}).
pub fn pipelinePrompt(arena: Allocator, raw: []const u8, item: []const u8, prev: []const u8, stage_no: usize) ![]const u8 {
    const cp = if (stage_no > 1) workflow.cappedPrevBody(arena, prev, pipeline_prev_cap) else "";
    var p = raw;
    if (std.mem.indexOf(u8, p, "{{item}}") != null)
        p = try replacePlaceholder(arena, p, "{{item}}", item)
    else
        p = try std.fmt.allocPrint(arena, "{s}\n\nItem: {s}", .{ p, item });
    if (std.mem.indexOf(u8, p, "{{prev}}") != null)
        p = try replacePlaceholder(arena, p, "{{prev}}", cp)
    else if (stage_no > 1)
        p = try std.fmt.allocPrint(arena, "{s}\n\nResult from the previous stage:\n\n{s}", .{ p, cp });
    return p;
}

/// One item's journey through every stage, run on a pool thread (spawned by
/// run). Stages run SEQUENTIALLY here via DIRECT runSub calls — never a
/// nested io.async, which on a bounded pool could deadlock; different items run
/// concurrently. A failed stage is retried once (#2); a stage that still fails
/// ends the chain with a terse marker plus a capped one-line excerpt of its
/// error (#248), rather than feeding the whole error downstream.
fn pipelineChain(ctx: ToolCtx, item: []const u8, stages: []const StageSpec, stats: []pipeline_score.StageStat) ToolOutput {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prev: []const u8 = "";
    for (stages, stats, 1..) |st, *stat, stage_no| {
        const prompt = pipelinePrompt(arena, st.prompt, item, prev, stage_no) catch |e| return failure(gpa, e);
        // #372: say out loud which route this stage worker actually got, and
        // under which cell. The seat was resolved ONCE per stage in run()
        // (#376), so every item's worker reports — and runs — the same model;
        // #292's per-spawn pins still reach `subagent` only.
        route_trace.emitSpawnProvider(ctx.io, ctx.tracer, st.label, st.seat.provider, st.seat.cellOf(st.niche), st.seat.sourceFor(st.override != null), st.override, st.niche);
        // Counters only — the fitness fold happens per STAGE after run()'s
        // join (#296), never here where it would be a per-item row (#290).
        stat.noteAttempt();
        var out = if (runSub(ctx, "workflow_task", st.label, prompt, st.override, st.niche, st.isolation, st.isolation_fallback, st.seat.pin, null)) |r| r.output else |e| failure(gpa, e);
        if (out.is_error) {
            // Only spend the one retry (#2) when the harness's own
            // classification hasn't already ruled it out (auth, invalid
            // args, an unavailable model, a dry model-call pool) — those
            // stay failed below without wasting a second attempt.
            if (failureAllowsRetry(out.text)) {
                gpa.free(out.text);
                // The SAME seat: a retry that changed model would break the
                // stage uniformity the fitness row attributes to.
                out = if (runSub(ctx, "workflow_retry", st.label, prompt, st.override, st.niche, st.isolation, st.isolation_fallback, st.seat.pin, null)) |r| r.output else |e| failure(gpa, e);
            }
            if (out.is_error) {
                // #248 — excerpt the stage's own error BEFORE freeing it, so
                // the item's result says why the chain stopped, not just that
                // it did.
                const detail = workflow.failExcerpt(arena, out.text);
                gpa.free(out.text);
                const msg = if (detail.len > 0)
                    std.fmt.allocPrint(gpa, "(pipeline stopped at stage {d}/{d} \"{s}\": task failed)\n{s}", .{ stage_no, stages.len, st.label, detail })
                else
                    std.fmt.allocPrint(gpa, "(pipeline stopped at stage {d}/{d} \"{s}\": task failed)", .{ stage_no, stages.len, st.label });
                return .{
                    .text = msg catch (gpa.dupe(u8, "(pipeline stage failed)") catch ""),
                    .is_error = true,
                };
            }
        }
        stat.noteOk();
        const duped = arena.dupe(u8, out.text) catch {
            gpa.free(out.text);
            return failure(gpa, error.OutOfMemory);
        };
        gpa.free(out.text);
        prev = duped;
    }
    return .{ .text = gpa.dupe(u8, prev) catch "" };
}

/// Comptime-formatted refusal message for a worktree-isolated stage past 0.
fn stageIsoMsg(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("pipeline stage {d} requests worktree isolation, but a pipeline is a dependent chain over one item -- stage {d} must see what earlier stages did, and worktree isolation would silently hide that work. Only stage 0 may isolate with its own worktree. If you wanted real per-item isolation, use phases instead (phases run independently, with no such dependency).", .{ n, n });
}

/// Pure guard-rail predicate for pipeline-stage isolation: a pipeline chains
/// dependent stages over one item, so only stage 0 (index 0) may resolve to
/// worktree isolation -- any later stage in its own worktree cannot see what
/// the prior stage did, and the run would silently produce nonsense (#295
/// territory covers the real per-item-worktree redesign; this only refuses
/// the broken config). Returns the refusal message, or null when allowed.
pub fn pipelineIsolationError(stage_index: usize, iso: Isolation) ?[]const u8 {
    if (stage_index == 0 or iso != .worktree) return null;
    return switch (stage_index) {
        1 => stageIsoMsg(1),
        2 => stageIsoMsg(2),
        3 => stageIsoMsg(3),
        4 => stageIsoMsg(4),
        else => "pipeline stage requests worktree isolation, but a pipeline is a dependent chain over one item -- only stage 0 may isolate with its own worktree. If you wanted real per-item isolation, use phases instead (phases run independently).",
    };
}

/// What a pipeline of `items` x `stages` will cost, at each stage's role
/// cost. `transform` rejoined the vocabulary for stage-level SCORING (#296)
/// but deliberately has no entry in phase_budget's pricing table, so a
/// mechanical stage is still charged the default median — the estimate the
/// study's refactor run would have failed, unchanged by the scoring path.
pub fn pipelineEstimate(items: usize, stage_roles: []const []const u8) u64 {
    var per_item: u64 = 0;
    for (stage_roles) |r| per_item += phase_budget.roleCost(r);
    return per_item * @as(u64, @intCast(items));
}

/// The refusal a pipeline gets when it cannot finish inside the pool. Same
/// doctrine as the R0 advisory: non-error, and it says what to do instead.
pub const too_big_advice =
    "workflow declined (escalation, pipeline): this pipeline's items x stages cannot finish inside the " ++
    "remaining model-call budget while leaving enough calls to land the work. Either run it yourself " ++
    "(a mechanical edit across a handful of files is solo work), or split it into a pipeline over fewer " ++
    "items and re-invoke.";

/// Pipeline mode entry (#3): validate {items, stages}, then run one independent
/// chain per item concurrently (no barrier) and return the labeled final-stage
/// result for each item.
pub fn run(ctx: ToolCtx, pv: Value, outer_context: []const u8) !ToolOutput {
    const gpa = ctx.gpa;
    if (pv != .object) return .{ .text = try gpa.dupe(u8, "pipeline must be an object with items + stages"), .is_error = true };
    const items_val = pv.object.get("items") orelse return .{ .text = try gpa.dupe(u8, "pipeline needs an items array"), .is_error = true };
    const stages_val = pv.object.get("stages") orelse return .{ .text = try gpa.dupe(u8, "pipeline needs a stages array"), .is_error = true };
    if (items_val != .array or stages_val != .array) return .{ .text = try gpa.dupe(u8, "pipeline items and stages must both be arrays"), .is_error = true };
    const items = items_val.array.items;
    const stage_vals = stages_val.array.items;
    if (items.len == 0 or items.len > max_pipeline_items) return .{ .text = try std.fmt.allocPrint(gpa, "pipeline needs 1-{d} items", .{max_pipeline_items}), .is_error = true };
    if (stage_vals.len == 0 or stage_vals.len > max_pipeline_stages) return .{ .text = try std.fmt.allocPrint(gpa, "pipeline needs 1-{d} stages", .{max_pipeline_stages}), .is_error = true };
    // Shared context slot: one string prepended to every stage prompt below
    // (before {{item}}/{{prev}}). Readable in BOTH places the tool schema says
    // it is - on the pipeline object, or top-level alongside it - because the
    // dispatch to run happens before the top-level read, so a pipeline
    // call silently ignored the documented top-level field.
    const context_str: []const u8 = if (pv.object.get("context")) |cv| (if (cv == .string) cv.string else outer_context) else outer_context;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse stages once — shared (read-only) by every item chain. `base` is
    // the model every stage worker would have used before #376's seats.
    const base = subagent_run.childProvider(ctx.provider, ctx.subagent_provider, ctx.subagent_cross_provider);
    const stages = try arena.alloc(StageSpec, stage_vals.len);
    for (stage_vals, stages, 0..) |sv, *sp, stage_index| {
        if (sv != .object) return .{ .text = try gpa.dupe(u8, "each pipeline stage must be an object"), .is_error = true };
        const so = sv.object;
        sp.label = if (so.get("description")) |d| (if (d == .string) d.string else "stage") else "stage";
        const raw = if (so.get("prompt")) |p| (if (p == .string) p.string else "") else "";
        if (raw.len == 0) return .{ .text = try gpa.dupe(u8, "each pipeline stage needs a non-empty \"prompt\""), .is_error = true };
        sp.prompt = try workflow.withContext(arena, context_str, raw);
        sp.override = fleet.resolveOverride(so);
        const an = fleet.resolveNiche(so);
        sp.niche = if (an.len > 0) an else sp.label;
        sp.isolation = fleet.resolveIsolation(so);
        // A pipeline is a dependent chain over one item: stage 2+ must see
        // what earlier stages did, which worktree isolation would silently
        // hide (#295 territory). Reject rather than run the chain wrong.
        if (pipelineIsolationError(stage_index, sp.isolation)) |msg|
            return .{ .text = try gpa.dupe(u8, msg), .is_error = true };
        sp.isolation_fallback = fleet.resolveIsolationFallback(so);
        sp.role = route_policy.roleOf(sp.label, sp.niche); // #372
        // #376 for stages: ONE learned seat per stage, shared by every item's
        // chain — stage-uniform, so #290 holds across items. Same guardrails
        // as a phase seat: only a ladder-descended session may move, only to
        // a rung that dominates on the bench sheet, provider-local always.
        sp.seat = route_phase.forPhase(base, .migration, sp.label, &.{sp.niche}, ctx.subagent_provider != null);
    }

    // Admission, pipeline flavour. The phases path runs the full escalation
    // ladder; a pipeline is already committed to per-item work, so the only
    // question worth asking is the budget one — and asking it is what stops a
    // chain from spending the pool and landing nothing.
    const cap = phase_budget.capOf(ctx.run_budget);
    const roles = try arena.alloc([]const u8, stages.len);
    for (stages, roles) |st, *r| r.* = st.role;
    const estimate = pipelineEstimate(items.len, roles);
    if (!phase_budget.Ledger.init(cap).fits(phase_budget.remainingOf(ctx.run_budget), estimate)) {
        escalation.notePipelineDeclined();
        return .{ .text = try gpa.dupe(u8, too_big_advice) };
    }

    const item_strs = try arena.alloc([]const u8, items.len);
    for (items, item_strs) |iv, *is| {
        if (iv != .string or iv.string.len == 0) return .{ .text = try gpa.dupe(u8, "pipeline items must be non-empty strings"), .is_error = true };
        is.* = iv.string;
    }

    const wf_start = Io.Timestamp.now(ctx.io, .awake);
    tick_gate.workerPrint("  [workflow] pipeline: {d} item(s) × {d} stage(s), no barrier\n", .{ items.len, stages.len });
    // #63 — same fact, as state: phase_index 0 is the run-level event, since a
    // pipeline has stages rather than phases. Per-stage events would have to be
    // threaded into pipelineChain (one chain per item, on its own pool thread);
    // that is left to the follow-up that renders them.
    const run_id = try wfp.nextRunId(arena);
    wfp.phase(ctx.io, arena, run_id, 0, stages.len, "pipeline", "started", items.len);

    // Spawn one chain per item — all joined before any fallible work so an early
    // return can never abandon a running chain.
    const futures = try arena.alloc(Io.Future(ToolOutput), items.len);
    const outputs = try arena.alloc(ToolOutput, items.len);
    const stats = try arena.alloc(pipeline_score.StageStat, stages.len);
    for (stats) |*s| s.* = .{};
    for (item_strs, futures) |item, *fut| fut.* = ctx.io.async(pipelineChain, .{ ctx, item, stages, stats });
    for (futures, outputs) |*fut, *out| out.* = fut.await(ctx.io);
    defer for (outputs) |out| gpa.free(out.text);

    // #296 — the stage-level fitness fold: one judge-free row per stage per
    // run, under the stage's (migration, slot) cell and its one seat. After
    // the join, so per-item outcomes can never become per-item fitness rows
    // (#290: items differ by design, and ranking them would confound item
    // difficulty with genome quality). Observation only — nothing reads it.
    for (stages, stats) |st, *stat| _ = pipeline_score.captureStage(st.seat.provider, st.label, st.niche, st.override orelse st.prompt, stat);

    var failed: usize = 0;
    for (outputs) |out| if (out.is_error) {
        failed += 1;
    };
    if (telemetry.g_telem) |t| t.workflowEvent(stages.len, items.len * stages.len, failed, @intCast(@max(0, wf_start.untilNow(ctx.io, .awake).toMilliseconds())));

    var aw: Io.Writer.Allocating = .init(arena);
    for (item_strs, outputs) |item, out| {
        try aw.writer.print("### {s}{s}\n{s}\n\n", .{ item, if (out.is_error) " (failed)" else "", out.text });
    }
    return .{ .text = try gpa.dupe(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n")) };
}

test "pipelineEstimate prices a chain per item, so a wide pipeline is not free" {
    // The study's refactor run: 4 items x 2 off-vocabulary stages. At the
    // median role cost that is 24 calls, which does not fit a cap-30 pool
    // once the landing reserve (7) is held back from the ~27 that remain.
    const roles = [_][]const u8{ "", "" };
    try std.testing.expectEqual(@as(u64, 24), pipelineEstimate(4, &roles));
    try std.testing.expect(!phase_budget.Ledger.init(30).fits(27, 24));
    // Two items over the same chain does fit, and should.
    try std.testing.expectEqual(@as(u64, 12), pipelineEstimate(2, &roles));
    try std.testing.expect(phase_budget.Ledger.init(30).fits(27, 12));
}
