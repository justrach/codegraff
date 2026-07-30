//! Dynamic workflows as data: sequential phases of parallel subagents (#1/#2/
//! #4/#5), plus pipeline mode (#3) — items mapped through a chain of stages
//! with no inter-item barrier. Split out of main.zig (600-line goal).
//! Sibling-imports tools.zig for `ToolCtx`/`ToolOutput`/`failure` and
//! subagent.zig for `workflowTask`/`runSub`/`scoreVariants`/
//! `max_workflow_tasks` (subagent.zig is the lower-level sibling here, so the
//! shared task-count cap lives there, not here — avoids a circular import).
//! Back-imports main (as `main_mod`) only for `utf8Prefix`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const util = @import("util.zig");

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const failure = tools.failure;

const subagent = @import("subagent.zig");
const workflowTask = subagent.workflowTask;
const workflowRetryTask = subagent.workflowRetryTask;
const runSub = subagent.runSub;
const scoreVariants = subagent.scoreVariants;
const max_workflow_tasks = subagent.max_workflow_tasks;

// Sibling-imported directly (not through subagent.zig, which sits at the
// 600-line cap): the harness's own retry-safety verdict from subagentFailure,
// consumed at both retry sites below so a task the harness already knows
// can't be helped by a retry (auth, invalid args, an unavailable model)
// doesn't get retried anyway.
const subagent_run = @import("subagent_run.zig");
const failureAllowsRetry = subagent_run.failureAllowsRetry;

const fleet = @import("fleet.zig");
const Isolation = fleet.Isolation; // #276 P0-1
const telemetry = @import("telemetry.zig");

const max_workflow_phases = 5;

// Per-task cap on each phase result fed into {{prev}} (#4): a wide or runaway
// phase would otherwise push its full output into every next-phase task, so
// phase N+1 pays N× context. Over the cap we keep the head (the substance) plus
// a short tail — which carries the `inspect:` pointer to the full detail file —
// with a truncation marker between, so nothing is actually lost. (A synthesis/
// compress pass is the heavier alternative; per-task slicing is the cheap,
// no-extra-LLM-call lever.)
const max_prev_per_task = 6000;
const prev_tail_keep = 600;

/// Bound one task's output before it enters the {{prev}} buffer (#4). Short
/// outputs pass through untouched; over the cap, head + truncation marker + tail.
fn cappedPrevBody(arena: Allocator, text: []const u8) []const u8 {
    if (text.len <= max_prev_per_task) return text;
    const head = util.utf8Prefix(text, max_prev_per_task - prev_tail_keep);
    const tail = text[text.len - prev_tail_keep ..];
    return std.fmt.allocPrint(arena, "{s}\n\n…[{d} chars truncated — full result in the inspect file below]…\n\n{s}", .{ head, text.len - head.len - tail.len, tail }) catch text;
}

/// #5 conditional-phase gate: a phase carrying a non-empty `when` runs only when
/// that substring appears (case-insensitively) in the previous phase's results —
/// e.g. gate a synthesis phase on a findings sentinel so it never runs when the
/// earlier phase turned up nothing. Empty `when` (or phase 1, no prev) → runs.
fn gateAllows(prev: []const u8, when: []const u8) bool {
    return when.len == 0 or util.indexOfIgnoreCase(prev, when) != null;
}

// ── Pipeline mode (#3) ──────────────────────────────────────────────────────
// Phases fan out then synthesize: a barrier between phases, since every
// next-phase task waits on ALL of the previous phase via {{prev}}. Pipeline
// instead maps each ITEM through a chain of STAGES with NO barrier — item A can
// be in stage 3 while item B is still in stage 1, so wall-clock is the slowest
// single chain, not the sum of slowest-per-stage. Use it for per-item work
// (transform/verify each file); use phases for fan-out + synthesis.
const max_pipeline_items = 8;
const max_pipeline_stages = 5;

const StageSpec = struct {
    label: []const u8,
    prompt: []const u8, // raw; may contain {{item}} / {{prev}}
    override: ?[]const u8,
    niche: []const u8,
    isolation: Isolation = .shared_cwd, // #276 P0-1
    isolation_fallback: bool = false,
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
fn pipelinePrompt(arena: Allocator, raw: []const u8, item: []const u8, prev: []const u8, stage_no: usize) ![]const u8 {
    const cp = if (stage_no > 1) cappedPrevBody(arena, prev) else "";
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
/// runPipeline). Stages run SEQUENTIALLY here via DIRECT runSub calls — never a
/// nested io.async, which on a bounded pool could deadlock; different items run
/// concurrently. A failed stage is retried once (#2); a stage that still fails
/// ends the chain with a terse marker rather than feeding its error downstream.
fn pipelineChain(ctx: ToolCtx, item: []const u8, stages: []const StageSpec) ToolOutput {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prev: []const u8 = "";
    for (stages, 1..) |st, stage_no| {
        const prompt = pipelinePrompt(arena, st.prompt, item, prev, stage_no) catch |e| return failure(gpa, e);
        var out = if (runSub(ctx, "workflow_task", st.label, prompt, st.override, st.niche, st.isolation, st.isolation_fallback)) |r| r.output else |e| failure(gpa, e);
        if (out.is_error) {
            // Only spend the one retry (#2) when the harness's own
            // classification hasn't already ruled it out (auth, invalid
            // args, an unavailable model) — those stay failed below without
            // wasting a second attempt.
            if (failureAllowsRetry(out.text)) {
                gpa.free(out.text);
                out = if (runSub(ctx, "workflow_retry", st.label, prompt, st.override, st.niche, st.isolation, st.isolation_fallback)) |r| r.output else |e| failure(gpa, e);
            }
            if (out.is_error) {
                gpa.free(out.text);
                return .{
                    .text = std.fmt.allocPrint(gpa, "(pipeline stopped at stage {d}/{d} \"{s}\": task failed)", .{ stage_no, stages.len, st.label }) catch (gpa.dupe(u8, "(pipeline stage failed)") catch ""),
                    .is_error = true,
                };
            }
        }
        const duped = arena.dupe(u8, out.text) catch {
            gpa.free(out.text);
            return failure(gpa, error.OutOfMemory);
        };
        gpa.free(out.text);
        prev = duped;
    }
    return .{ .text = gpa.dupe(u8, prev) catch "" };
}

/// Pipeline mode entry (#3): validate {items, stages}, then run one independent
/// chain per item concurrently (no barrier) and return the labeled final-stage
/// result for each item.
fn runPipeline(ctx: ToolCtx, pv: Value) !ToolOutput {
    const gpa = ctx.gpa;
    if (pv != .object) return .{ .text = try gpa.dupe(u8, "pipeline must be an object with items + stages"), .is_error = true };
    const items_val = pv.object.get("items") orelse return .{ .text = try gpa.dupe(u8, "pipeline needs an items array"), .is_error = true };
    const stages_val = pv.object.get("stages") orelse return .{ .text = try gpa.dupe(u8, "pipeline needs a stages array"), .is_error = true };
    if (items_val != .array or stages_val != .array) return .{ .text = try gpa.dupe(u8, "pipeline items and stages must both be arrays"), .is_error = true };
    const items = items_val.array.items;
    const stage_vals = stages_val.array.items;
    if (items.len == 0 or items.len > max_pipeline_items) return .{ .text = try std.fmt.allocPrint(gpa, "pipeline needs 1-{d} items", .{max_pipeline_items}), .is_error = true };
    if (stage_vals.len == 0 or stage_vals.len > max_pipeline_stages) return .{ .text = try std.fmt.allocPrint(gpa, "pipeline needs 1-{d} stages", .{max_pipeline_stages}), .is_error = true };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parse stages once — shared (read-only) by every item chain.
    const stages = try arena.alloc(StageSpec, stage_vals.len);
    for (stage_vals, stages) |sv, *sp| {
        if (sv != .object) return .{ .text = try gpa.dupe(u8, "each pipeline stage must be an object"), .is_error = true };
        const so = sv.object;
        sp.label = if (so.get("description")) |d| (if (d == .string) d.string else "stage") else "stage";
        const raw = if (so.get("prompt")) |p| (if (p == .string) p.string else "") else "";
        if (raw.len == 0) return .{ .text = try gpa.dupe(u8, "each pipeline stage needs a non-empty \"prompt\""), .is_error = true };
        sp.prompt = raw;
        sp.override = fleet.resolveOverride(so);
        const an = fleet.resolveNiche(so);
        sp.niche = if (an.len > 0) an else sp.label;
        sp.isolation = fleet.resolveIsolation(so);
        sp.isolation_fallback = fleet.resolveIsolationFallback(so);
    }

    const item_strs = try arena.alloc([]const u8, items.len);
    for (items, item_strs) |iv, *is| {
        if (iv != .string or iv.string.len == 0) return .{ .text = try gpa.dupe(u8, "pipeline items must be non-empty strings"), .is_error = true };
        is.* = iv.string;
    }

    const wf_start = Io.Timestamp.now(ctx.io, .awake);
    std.debug.print("  [workflow] pipeline: {d} item(s) × {d} stage(s), no barrier\n", .{ items.len, stages.len });

    // Spawn one chain per item — all joined before any fallible work so an early
    // return can never abandon a running chain.
    const futures = try arena.alloc(Io.Future(ToolOutput), items.len);
    const outputs = try arena.alloc(ToolOutput, items.len);
    for (item_strs, futures) |item, *fut| fut.* = ctx.io.async(pipelineChain, .{ ctx, item, stages });
    for (futures, outputs) |*fut, *out| out.* = fut.await(ctx.io);
    defer for (outputs) |out| gpa.free(out.text);

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

// ── U2: all-failed abort + run manifest ─────────────────────────────────────
// A phase where every task failed used to still feed {{prev}} — a bare
// "(no result — task failed)" header per task — into the next phase, so a
// synthesis stage confidently answered from zero evidence (the worst output
// class: a wrong answer that looks researched). buildAbortText and
// buildManifest are kept PURE (no ctx/io) so both are unit-testable without
// running a real subagent.

const PhaseTally = struct {
    phase_no: usize,
    total_phases: usize,
    title: []const u8,
    ok: usize,
    total: usize,
    retried: usize,
    skipped_when: ?[]const u8 = null,
};

/// Build the hard-stop text for a phase where every task failed: the
/// assembled per-task failure headers plus a line naming the phase, so the
/// caller (or a human) can see exactly why the run stopped instead of
/// silently receiving empty "evidence".
fn buildAbortText(arena: Allocator, labels: []const []const u8, phase_no: usize, total_phases: usize, title: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (labels) |label| {
        try aw.writer.print("### {s} (no result — task failed)\n\n", .{label});
    }
    try aw.writer.print("workflow aborted: every task in phase {d}/{d} ({s}) failed", .{ phase_no, total_phases, title });
    return aw.writer.buffered();
}

/// Build the trailing "## workflow" manifest block from one tally per phase —
/// currently the only way the orchestrator learns a phase was skipped, or
/// that a synthesis stage is about to work from partial (some-tasks-failed)
/// evidence rather than a clean phase.
fn buildManifest(arena: Allocator, tallies: []const PhaseTally) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("## workflow\n");
    for (tallies) |t| {
        if (t.skipped_when) |w| {
            try aw.writer.print("phase {d}/{d} {s}: SKIPPED (when=\"{s}\")\n", .{ t.phase_no, t.total_phases, t.title, w });
        } else {
            try aw.writer.print("phase {d}/{d} {s}: {d}/{d} ok, {d} retried\n", .{ t.phase_no, t.total_phases, t.title, t.ok, t.total, t.retried });
        }
    }
    return std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
}

/// Dynamic workflows as data: sequential phases, parallel tasks. Each task
/// is an isolated subagent; "{{prev}}" in a task prompt is replaced with
/// the labeled results of the previous phase (appended when omitted).
/// Returns the final phase's results.
pub fn execWorkflow(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    if (ctx.from_sub) return .{
        .text = try gpa.dupe(u8, "subagents cannot run workflows — do this work yourself"),
        .is_error = true,
    };
    // Pipeline mode (#3): {pipeline:{items,stages}} maps each item through the
    // stages with no barrier — distinct from phases (fan-out + synthesis).
    const obj = tools.json_args.object(input) orelse return .{
        .text = try gpa.dupe(u8, "workflow: arguments must be a JSON object with a \"phases\" array (or a \"pipeline\" object)"),
        .is_error = true,
    };
    if (obj.get("pipeline")) |pv| return runPipeline(ctx, pv);
    const phases_val = obj.get("phases") orelse return .{
        .text = try gpa.dupe(u8, "workflow needs a \"phases\" array (or a \"pipeline\" object)"),
        .is_error = true,
    };
    const phases = tools.json_args.list(phases_val) orelse return .{
        .text = try gpa.dupe(u8, "workflow: \"phases\" must be an array of phase objects"),
        .is_error = true,
    };
    if (phases.len == 0 or phases.len > max_workflow_phases) return .{
        .text = try std.fmt.allocPrint(gpa, "workflow needs 1-{d} phases", .{max_workflow_phases}),
        .is_error = true,
    };

    // All intermediate strings live in this arena; the final result is
    // duped into gpa for the caller.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Telemetry: one "workflow" record per run — phase/task/failure counts
    // and wall-clock — emitted however the run ends.
    const wf_start = Io.Timestamp.now(ctx.io, .awake);
    var wf_tasks: usize = 0;
    var wf_failed: usize = 0;
    defer if (telemetry.g_telem) |t| t.workflowEvent(
        phases.len,
        wf_tasks,
        wf_failed,
        @intCast(@max(0, wf_start.untilNow(ctx.io, .awake).toMilliseconds())),
    );

    var prev_results: []const u8 = "";
    const tallies = try arena.alloc(PhaseTally, phases.len);
    for (phases, 1..) |phase_val, phase_no| {
        if (phase_val != .object) return .{ .text = try gpa.dupe(u8, "each phase must be an object"), .is_error = true };
        const phase = phase_val.object;
        const title = if (phase.get("title")) |t| (if (t == .string) t.string else "phase") else "phase";
        const tasks_val = phase.get("tasks") orelse return .{
            .text = try gpa.dupe(u8, "each phase needs a tasks array"),
            .is_error = true,
        };
        if (tasks_val != .array) return .{ .text = try gpa.dupe(u8, "phase tasks must be an array"), .is_error = true };
        const tasks = tasks_val.array.items;
        if (tasks.len == 0 or tasks.len > max_workflow_tasks) return .{
            .text = try std.fmt.allocPrint(gpa, "each phase needs 1-{d} tasks", .{max_workflow_tasks}),
            .is_error = true,
        };
        // #5 — conditional phase: skip when its `when` substring is absent from
        // the previous phase's results (case-insensitive). Phase 1 has no prev so
        // its `when` never gates; a skipped phase leaves {{prev}} untouched, so a
        // skipped final phase just returns the prior phase's results (early-exit).
        if (phase_no > 1) if (phase.get("when")) |wv| if (wv == .string and !gateAllows(prev_results, wv.string)) {
            std.debug.print("  [workflow] phase {d}/{d}: {s} — SKIPPED (when \"{s}\" absent)\n", .{ phase_no, phases.len, title, wv.string });
            tallies[phase_no - 1] = .{ .phase_no = phase_no, .total_phases = phases.len, .title = title, .ok = 0, .total = tasks.len, .retried = 0, .skipped_when = wv.string };
            continue;
        };
        std.debug.print("  [workflow] phase {d}/{d}: {s} ({d} task(s))\n", .{ phase_no, phases.len, title, tasks.len });

        // Resolve prompts: substitute or append the previous phase results.
        // raws keeps each task's pre-substitution spec (a stable eval-set id for
        // scoring, unlike the prev-injected prompt); niches is its MAP-Elites
        // cell — the agent type, else the phase title for an inline variant.
        const prompts = try arena.alloc([]const u8, tasks.len);
        const labels = try arena.alloc([]const u8, tasks.len);
        const overrides = try arena.alloc(?[]const u8, tasks.len);
        const raws = try arena.alloc([]const u8, tasks.len);
        const niches = try arena.alloc([]const u8, tasks.len);
        const isolations = try arena.alloc(Isolation, tasks.len); // #276 P0-1
        const isolation_fallbacks = try arena.alloc(bool, tasks.len);
        for (tasks, prompts, labels, overrides, raws, niches, isolations, isolation_fallbacks) |task_val, *prompt, *label, *override, *rawp, *niche, *isolation, *isolation_fallback| {
            if (task_val != .object) return .{ .text = try gpa.dupe(u8, "each task must be an object"), .is_error = true };
            const task = task_val.object;
            label.* = if (task.get("description")) |d| (if (d == .string) d.string else "task") else "task";
            override.* = fleet.resolveOverride(task);
            const agent_niche = fleet.resolveNiche(task);
            niche.* = if (agent_niche.len > 0) agent_niche else title;
            isolation.* = fleet.resolveIsolation(task);
            isolation_fallback.* = fleet.resolveIsolationFallback(task);
            const raw = if (task.get("prompt")) |p| (if (p == .string) p.string else "") else "";
            if (raw.len == 0) return .{ .text = try gpa.dupe(u8, "each task needs a non-empty \"prompt\""), .is_error = true };
            rawp.* = raw;
            if (phase_no == 1) {
                prompt.* = raw;
            } else if (std.mem.indexOf(u8, raw, "{{prev}}") != null) {
                const size = std.mem.replacementSize(u8, raw, "{{prev}}", prev_results);
                const buf = try arena.alloc(u8, size);
                _ = std.mem.replace(u8, raw, "{{prev}}", prev_results, buf);
                prompt.* = buf;
            } else {
                prompt.* = try std.fmt.allocPrint(arena, "{s}\n\nResults from the previous workflow phase:\n\n{s}", .{ raw, prev_results });
            }
        }

        // Join ALL tasks before any fallible work, so an early error return
        // can never abandon running subagents or free their result slots.
        const futures = try arena.alloc(Io.Future(ToolOutput), tasks.len);
        const outputs = try arena.alloc(ToolOutput, tasks.len);
        for (labels, prompts, overrides, niches, isolations, isolation_fallbacks, futures) |label, prompt, override, niche, isolation, isolation_fallback, *fut| {
            fut.* = ctx.io.async(workflowTask, .{ ctx, label, prompt, override, niche, isolation, isolation_fallback });
        }
        for (futures, outputs) |*fut, *out| out.* = fut.await(ctx.io);
        defer for (outputs) |out| gpa.free(out.text);
        wf_tasks += tasks.len;

        // #2 — Retry transient failures once. A single flaky subagent (an empty
        // report, a dropped stream) shouldn't fail the phase or poison {{prev}}
        // for the next one. We can't reliably tell a transient failure from a
        // deterministic one, so we retry every failure exactly once: a permanent
        // failure just costs one more attempt and stays failed.
        // Failures the harness already classified as not retry-safe (auth, an
        // invalid argument, an unavailable model — see failureAllowsRetry) are
        // excluded here: retrying the whole phase would only double the cost
        // of a broken run for zero chance of success.
        var fidx: [max_workflow_tasks]usize = undefined;
        var nf: usize = 0;
        for (outputs, 0..) |out, i| if (out.is_error and failureAllowsRetry(out.text)) {
            fidx[nf] = i;
            nf += 1;
        };
        if (nf > 0) {
            const refut = try arena.alloc(Io.Future(ToolOutput), nf);
            for (refut, 0..) |*rf, k| {
                const i = fidx[k];
                rf.* = ctx.io.async(workflowRetryTask, .{ ctx, labels[i], prompts[i], overrides[i], niches[i], isolations[i], isolation_fallbacks[i] });
            }
            for (refut, 0..) |*rf, k| {
                const retry = rf.await(ctx.io);
                const i = fidx[k];
                if (!retry.is_error) {
                    gpa.free(outputs[i].text);
                    outputs[i] = retry;
                } else gpa.free(retry.text);
            }
        }
        // Tally this phase's surviving failures into the run total (post-retry,
        // so a recovered task no longer counts). Accumulates across phases, like
        // wf_tasks, for the single end-of-run workflowEvent. phase_failed is the
        // same tally scoped to just this phase, for the all-failed hard stop
        // below and the run-manifest ok count.
        var phase_failed: usize = 0;
        for (outputs) |out| if (out.is_error) {
            wf_failed += 1;
            phase_failed += 1;
        };

        // U2 hard stop: a phase where every task failed (post-retry) must never
        // feed {{prev}} — the next phase, or a synthesis stage, would receive
        // nothing but bare "task failed" headers and could still confidently
        // answer from zero evidence. Abort the whole run instead of continuing;
        // the per-phase defers above already free `outputs`.
        if (phase_failed == tasks.len) {
            const abort_text = try buildAbortText(arena, labels, phase_no, phases.len, title);
            return .{ .text = try gpa.dupe(u8, abort_text), .is_error = true };
        }

        // #1 — Ultracode → DGM engine: when ≥2 persona variants competed this
        // phase, score each survivor and submit its niche-tagged fitness so the
        // fleet can rank and promote the winner (docs/hyperagents.md §9.B). The
        // propose half already fired in runSub; this closes the loop runEval left
        // open (it submits niche=""). Gated on the fleet — no judge cost otherwise.
        scoreVariants(ctx, arena, title, prompts, raws, overrides, niches, outputs);

        tallies[phase_no - 1] = .{ .phase_no = phase_no, .total_phases = phases.len, .title = title, .ok = tasks.len - phase_failed, .total = tasks.len, .retried = nf };

        var aw: Io.Writer.Allocating = .init(arena);
        for (labels, outputs) |label, out| {
            if (out.is_error) {
                // Keep the failure visible to the next phase, but never feed its
                // raw error text into {{prev}} as if it were a real result (#2).
                try aw.writer.print("### {s} (no result — task failed)\n\n", .{label});
            } else {
                try aw.writer.print("### {s}\n{s}\n\n", .{ label, cappedPrevBody(arena, out.text) });
            }
        }
        prev_results = std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
    }
    const manifest = try buildManifest(arena, tallies);
    const final_text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ prev_results, manifest });
    return .{ .text = try gpa.dupe(u8, final_text) };
}

test "cappedPrevBody bounds a wide phase output, keeps head + inspect tail (#4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A short result passes through untouched — most outputs never hit the cap.
    try std.testing.expectEqualStrings("hi", cappedPrevBody(a, "hi"));

    // A huge result is capped: head kept, the trailing inspect: pointer kept,
    // a truncation marker added, and the full text never lands verbatim.
    const big = util.repeatBytes("X", 9000) ++ "\n[subagent sa-007-abcd · inspect: .graff/subagents/sa-007-abcd.md]";
    const capped = cappedPrevBody(a, big);
    try std.testing.expect(capped.len < big.len);
    try std.testing.expect(capped.len <= max_prev_per_task + 200); // head + tail + marker overhead
    try std.testing.expect(std.mem.indexOf(u8, capped, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "inspect: .graff/subagents/sa-007-abcd.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, big) == null);
}

test "gateAllows: empty when always runs, else case-insensitive substring (#5)" {
    try std.testing.expect(gateAllows("anything", "")); // no gate → always run
    try std.testing.expect(gateAllows("found 3 ISSUES here", "issues")); // case-insensitive hit
    try std.testing.expect(!gateAllows("all clean, no findings", "ISSUE")); // absent → skip
    try std.testing.expect(!gateAllows("", "ready")); // empty prev → skip
}

test "buildAbortText names the phase index and title, and lists every failed task (U2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const labels = [_][]const u8{ "scan A", "scan B" };
    const text = try buildAbortText(a, &labels, 2, 3, "Recon");

    // Every failed task's header survives, so a human can see what was tried.
    try std.testing.expect(std.mem.indexOf(u8, text, "### scan A (no result — task failed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### scan B (no result — task failed)") != null);
    // The abort line names the phase index/total and title — the whole point
    // of this text existing instead of a silent empty {{prev}}.
    try std.testing.expect(std.mem.indexOf(u8, text, "workflow aborted: every task in phase 2/3 (Recon) failed") != null);
}

test "buildManifest reports ok/retried per phase and SKIPPED for a gated phase (U2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tallies = [_]PhaseTally{
        .{ .phase_no = 1, .total_phases = 3, .title = "Gather", .ok = 3, .total = 3, .retried = 1 },
        .{ .phase_no = 2, .total_phases = 3, .title = "Verify", .ok = 0, .total = 2, .retried = 0, .skipped_when = "no findings" },
        .{ .phase_no = 3, .total_phases = 3, .title = "Report", .ok = 1, .total = 2, .retried = 0 },
    };
    const block = try buildManifest(a, &tallies);

    try std.testing.expect(std.mem.startsWith(u8, block, "## workflow"));
    try std.testing.expect(std.mem.indexOf(u8, block, "phase 1/3 Gather: 3/3 ok, 1 retried") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "phase 2/3 Verify: SKIPPED (when=\"no findings\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "phase 3/3 Report: 1/2 ok, 0 retried") != null);
    // A skipped phase must never claim an ok/retried count it never earned.
    try std.testing.expect(std.mem.indexOf(u8, block, "phase 2/3 Verify: 0/2") == null);
}

test "pipelinePrompt substitutes {{item}}/{{prev}} and appends when omitted (#3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // {{item}} substituted on stage 1; no previous-stage section.
    const s1 = try pipelinePrompt(a, "Audit {{item}} for bugs.", "src/x.zig", "", 1);
    try std.testing.expect(std.mem.indexOf(u8, s1, "Audit src/x.zig for bugs.") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1, "previous stage") == null);

    // {{item}} and {{prev}} both substituted on stage 2.
    const s2 = try pipelinePrompt(a, "Given {{prev}}, fix {{item}}.", "src/x.zig", "BUG: off-by-one", 2);
    try std.testing.expect(std.mem.indexOf(u8, s2, "Given BUG: off-by-one, fix src/x.zig.") != null);

    // Omitted placeholders are appended (item on stage 1, prev on stage 2+).
    const s3 = try pipelinePrompt(a, "Summarize the result.", "ticket-7", "DONE", 2);
    try std.testing.expect(std.mem.indexOf(u8, s3, "Item: ticket-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3, "Result from the previous stage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3, "DONE") != null);
}

test "execWorkflow rejects a non-object argument tree instead of dereferencing it" {
    var ctx: ToolCtx = undefined;
    ctx.gpa = std.testing.allocator;
    ctx.from_sub = false;

    const out1 = try execWorkflow(ctx, .{ .string = "do it" });
    try std.testing.expect(out1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out1.text, "object") != null);
    std.testing.allocator.free(out1.text);

    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"phases\":\"nope\"}", .{});
    defer parsed.deinit();
    const out2 = try execWorkflow(ctx, parsed.value);
    try std.testing.expect(out2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out2.text, "array") != null);
    std.testing.allocator.free(out2.text);
}

test "execSubagent rejects a non-object argument tree instead of dereferencing it" {
    var ctx: ToolCtx = undefined;
    ctx.gpa = std.testing.allocator;
    ctx.from_sub = false;

    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "[1,2]", .{});
    defer parsed.deinit();
    const out = try subagent.execSubagent(ctx, parsed.value);
    try std.testing.expect(out.is_error);
    std.testing.allocator.free(out.text);
}
