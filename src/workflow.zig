//! Dynamic workflows as data: sequential phases of parallel subagents (#1/#2/
//! #4/#5). Split out of main.zig (600-line goal). Pipeline mode (#3) — items
//! mapped through a chain of stages with no inter-item barrier — moved to
//! workflow_pipeline.zig for the same reason, and aliased back below.
//! Sibling-imports tools.zig for `ToolCtx`/`ToolOutput`/`failure` and
//! subagent.zig for `workflowTask`/`runSub`/`scoreVariants`/
//! `max_workflow_tasks` (subagent.zig is the lower-level sibling here, so the
//! shared task-count cap lives there, not here — avoids a circular import).
//! Back-imports main (as `main_mod`) only for `utf8Prefix`.
//!
//! THE ESCALATION GATE. Four thin call sites below implement the ladder in
//! escalation.zig: `admit` before anything spawns, the per-phase budget
//! re-check at the loop head, duplicate-brief collapse before the futures
//! allocate, and the optional-spend gate on the judge tournament. Every rung
//! decision, and every one of its consequences, is decided there; this file
//! only obeys.

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
pub const max_workflow_tasks = subagent.max_workflow_tasks;

// Sibling-imported directly (not through subagent.zig, which sits at the
// 600-line cap): the harness's own retry-safety verdict from subagentFailure,
// consumed at both retry sites below so a task the harness already knows
// can't be helped by a retry (auth, invalid args, an unavailable model)
// doesn't get retried anyway.
const subagent_run = @import("subagent_run.zig");
const failureAllowsRetry = subagent_run.failureAllowsRetry;
const fleet = @import("fleet.zig");
const Isolation = fleet.Isolation; // #276 P0-1
const route_policy = @import("route_policy.zig"); // #372 (shape, role) policy cells
const route_phase = @import("route_phase.zig"); // #376 one learned seat per phase
const route_trace = @import("route_trace.zig"); // #372 per-worker routing trace
const brief_diversity = @import("brief_diversity.zig"); // #382 fleet-brief similarity gate
const vision_ask = @import("vision_ask.zig"); // #380 vision-aware seating + report honesty flag
const telemetry = @import("telemetry.zig");
// #63: stable workflow/phase/task ids + the additive `workflow_progress`
// JSONL event, so the REPL can map a run from state instead of scraping the
// std.debug.print lines below. Also holds the run manifest (see below).
const wfp = @import("workflow_progress.zig");
// The ultracode escalation ladder (admission, the edit contract) and the
// reservation ledger it decides against.
const escalation = @import("escalation.zig");
const report_anchors = @import("report_anchors.zig");
const phase_budget = @import("phase_budget.zig");
const shapes = @import("shapes.zig");
const pipeline_mode = @import("workflow_pipeline.zig");

// Pipeline mode moved to workflow_pipeline.zig (600-line cap); aliased back so
// workflow_test.zig and every other caller still reach it here.
pub const pipelinePrompt = pipeline_mode.pipelinePrompt;
pub const pipelineIsolationError = pipeline_mode.pipelineIsolationError;

const max_workflow_phases = 5;

// Phase budget for {{prev}} (#4, U3): capping every task's output at a flat
// max_prev_per_task made cost QUADRATIC in phase width — N tasks each capped
// at the max feed N tasks in the next phase, so N² chars of substituted prev
// text land in that next prompt (10 tasks -> 10 tasks was 60,000 chars). The
// fix divides one fixed total budget across the phase's own task count
// instead of capping each task flat, so a phase's total {{prev}} contribution
// stays near phase_prev_budget however wide the phase is:
//   per_task_cap = max(min_task_prev_cap, phase_prev_budget / n_tasks)
// min_task_prev_cap keeps a wide fan-out (up to max_workflow_tasks, and
// beyond if that cap ever grows) from shrinking each task's slice past
// readability — e.g. a 50-task phase still gives each result 800 chars
// rather than ~120. Over its cap we keep the head (the substance) plus a
// short tail — which carries the `inspect:` pointer to the full detail
// file — with a truncation marker between, so nothing is actually lost. (A
// synthesis/compress pass is the heavier alternative; this slicing is the
// cheap, no-extra-LLM-call lever.)
pub const phase_prev_budget = 6000;
pub const min_task_prev_cap = 800;
const prev_tail_keep = 600;

// Flat {{prev}} cap for pipeline mode (#3): each pipeline item runs its own
// independent stage chain, so unlike phases there's no fan-in multiplying one
// item's previous-stage text across other items' prompts — no phase-budget
// division needed here, a flat cap is enough.
const pipeline_prev_cap = 6000;

/// Per-task {{prev}} cap for a phase of `n_tasks` tasks (#U3): the fixed
/// phase_prev_budget divided across the phase's width, floored at
/// min_task_prev_cap. Pure, and kept separate from cappedPrevBody so the
/// division arithmetic is independently testable.
pub fn phaseTaskCap(n_tasks: usize) usize {
    return @max(min_task_prev_cap, phase_prev_budget / n_tasks);
}

/// Bound one task's output before it enters the {{prev}} buffer (#4), to the
/// given `cap`. Short outputs pass through untouched; over the cap, head +
/// truncation marker + tail. Saturating subtraction guards a `cap` smaller
/// than prev_tail_keep (not expected from either call site — both stay well
/// above prev_tail_keep — but this keeps the function safe standalone).
pub fn cappedPrevBody(arena: Allocator, text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    const head = util.utf8Prefix(text, cap -| prev_tail_keep);
    const tail = text[text.len -| prev_tail_keep..];
    return std.fmt.allocPrint(arena, "{s}\n\n…[{d} chars truncated — full result in the inspect file below]…\n\n{s}", .{ head, text.len - head.len - tail.len, tail }) catch text;
}

// #248: a failed task's output text is the ONLY place the underlying API error
// survives. The retry gate (failureAllowsRetry) read it and every render site
// then threw it away, so a synthesis phase saw a detail-free "(no result —
// task failed)" and could not tell a rate limit from a bad model id. The cap
// is what makes surfacing it safe: at most max_workflow_tasks ×
// fail_excerpt_cap (~1.7 KB) of error text can reach the next phase's prompt,
// however large the error bodies were.
pub const fail_excerpt_cap = 200;

/// One-line, capped excerpt of a failed task's output, for the three render
/// sites (#248). Head-biased because subagentFailure puts the cause right
/// after its "subagent … failed …:" prefix. Newlines and tabs collapse to
/// spaces so the excerpt can never break the "### label" header layout; blank
/// input returns "" so callers keep the bare header.
pub fn failExcerpt(arena: Allocator, text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    const head = util.utf8Prefix(trimmed, fail_excerpt_cap);
    const flat = arena.dupe(u8, head) catch return "";
    for (flat) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    if (head.len == trimmed.len) return flat;
    return std.fmt.allocPrint(arena, "{s}…", .{flat}) catch flat;
}

/// #5 conditional-phase gate: a phase carrying a non-empty `when` runs only when
/// that substring appears (case-insensitively) in the previous phase's results —
/// e.g. gate a synthesis phase on a findings sentinel so it never runs when the
/// earlier phase turned up nothing. Empty `when` (or phase 1, no prev) → runs.
pub fn gateAllows(prev: []const u8, when: []const u8) bool {
    return when.len == 0 or util.indexOfIgnoreCase(prev, when) != null;
}

/// Prepend the workflow/pipeline-level shared "context" (if any) to a raw
/// task or stage prompt, BEFORE {{prev}}/{{item}} substitution runs on the
/// result: context, blank line, raw prompt (U5). Absent/empty context
/// returns `raw` unchanged (no allocation), so the composed prompt stays
/// byte-identical to today's behavior when no context is set.
pub fn withContext(arena: Allocator, context: []const u8, raw: []const u8) ![]const u8 {
    if (context.len == 0) return raw;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ context, raw });
}

// U2's all-failed abort text, the run manifest and PhaseTally moved to
// workflow_progress.zig alongside the #63 structured events (this file is at
// the 600-line cap and both are "what did this run do" reporting). Aliased
// back so workflow_test.zig and the call sites below still reach them here.
pub const PhaseTally = wfp.PhaseTally;
pub const buildAbortText = wfp.buildAbortText;
pub const buildManifest = wfp.buildManifest;

test { // a new module's tests run only when something references it (see main.zig)
    _ = wfp;
    _ = report_anchors;
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
    const outer_context: []const u8 = if (obj.get("context")) |cv| (if (cv == .string) cv.string else "") else "";
    if (obj.get("pipeline")) |pv| return pipeline_mode.run(ctx, pv, outer_context);
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
    // U5 — shared context slot: one string, set once on the workflow object,
    // prepended to every task prompt below (before {{prev}} substitution) so
    // repo/task boilerplate is paid for once instead of per task.
    const context_str = outer_context; // read once above, shared with the pipeline branch

    // All intermediate strings live in this arena; the final result is
    // duped into gpa for the caller.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // #63 — one stable id per run; every phase/task event below keys to it.
    const run_id = try wfp.nextRunId(arena);
    // #372 — which catalog shape the root model actually instantiated, read
    // off the phase titles it authored rather than taken on trust. The first
    // component of every worker's policy cell for this run.
    const shape = route_policy.shapeOfPhases(phases);

    // ADMISSION (escalation §1b). One call, on cheap observables, before a
    // single future is allocated: which rung does this ask actually deserve?
    // R0 hands back a non-error advisory and the root does the work itself —
    // which on ordinary tasks is both cheaper and better, measured.
    const ledger = phase_budget.Ledger.init(phase_budget.capOf(ctx.run_budget));
    const admission = escalation.admit(escalation.ctxFrom(ctx, arena), phases, shape);
    switch (admission.verdict) {
        .solo => |advice| return .{ .text = try gpa.dupe(u8, advice) },
        else => {},
    }
    // A post-failure fleet attacks the OBSERVED failure: prepend the class's
    // parked evidence to the shared context so every brief carries it.
    const evidence = if (admission.rung == .R3) escalation.evidenceForAsk() else "";
    const run_context = if (evidence.len == 0) context_str else try std.fmt.allocPrint(arena, "{s}{s}PRIOR ATTEMPT EVIDENCE (address this directly):\n{s}", .{ context_str, @as([]const u8, if (context_str.len == 0) "" else "\n\n"), evidence });
    // §4-P1: a downsized admission caps every phase's width. Wide phases are
    // redundant finders; the landing phase carries one task and a cap of >=1
    // never touches it — see escalation.downsizeWidth.
    const width_cap: usize = switch (admission.verdict) {
        .downsize => |w| w,
        else => max_workflow_tasks,
    };
    // P2 set this when it stopped early, so the manifest can say so.
    var truncated = false;
    var phases_ran: usize = 0;

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
        // §4-P2: stop BEFORE a phase whose remaining plan cannot be followed
        // through on. Returning three finders' evidence and enough calls for
        // the root to land the fix beats spending the last call on a fourth
        // finder and dying with the file untouched — which is exactly how the
        // study's cap-30 bugfix run ended.
        if (ledger.earlyExit(phase_budget.remainingOf(ctx.run_budget), phase_budget.laterPhasesMin(phases, phase_no - 1))) {
            truncated = true;
            break;
        }
        if (phase_val != .object) return .{ .text = try gpa.dupe(u8, "each phase must be an object"), .is_error = true };
        const phase = phase_val.object;
        const title = if (phase.get("title")) |t| (if (t == .string) t.string else "phase") else "phase";
        // §3b: this phase's slot is contracted to MUTATE files, so its briefs
        // carry the changed-path contract and its results face a porcelain probe.
        const contracted = escalation.isContracted(shapes.canonicalSlot(title));
        // The report contract's mirror image: this phase's slot REPORTS, so
        // its briefs carry the anchor contract and its results face a
        // cited-path resolution probe (report_anchors.zig).
        const report_phase = report_anchors.isReportSlot(shapes.canonicalSlot(title));
        const tasks_val = phase.get("tasks") orelse return .{
            .text = try gpa.dupe(u8, "each phase needs a tasks array"),
            .is_error = true,
        };
        if (tasks_val != .array) return .{ .text = try gpa.dupe(u8, "phase tasks must be an array"), .is_error = true };
        const authored = tasks_val.array.items;
        if (authored.len == 0 or authored.len > max_workflow_tasks) return .{
            .text = try std.fmt.allocPrint(gpa, "each phase needs 1-{d} tasks", .{max_workflow_tasks}),
            .is_error = true,
        };
        const tasks = authored[0..@min(authored.len, @max(width_cap, 1))];
        // #5 — conditional phase: skip when its `when` substring is absent from
        // the previous phase's results (case-insensitive). Phase 1 has no prev so
        // its `when` never gates; a skipped phase leaves {{prev}} untouched, so a
        // skipped final phase just returns the prior phase's results (early-exit).
        if (phase_no > 1) if (phase.get("when")) |wv| if (wv == .string and !gateAllows(prev_results, wv.string)) {
            std.debug.print("  [workflow] phase {d}/{d}: {s} — SKIPPED (when \"{s}\" absent)\n", .{ phase_no, phases.len, title, wv.string });
            wfp.phase(ctx.io, arena, run_id, phase_no, phases.len, title, "skipped", tasks.len); // #63
            tallies[phase_no - 1] = .{ .phase_no = phase_no, .total_phases = phases.len, .title = title, .ok = 0, .total = tasks.len, .retried = 0, .skipped_when = wv.string };
            phases_ran = phase_no;
            continue;
        };
        std.debug.print("  [workflow] phase {d}/{d}: {s} ({d} task(s))\n", .{ phase_no, phases.len, title, tasks.len });
        wfp.phase(ctx.io, arena, run_id, phase_no, phases.len, title, "started", tasks.len); // #63

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
            // §3b, stolen from codex's patch-biased delegation: a contracted
            // worker is told to MAKE the edits and to end by listing every
            // changed path, so verify and the root review a diff, not a claim.
            const noted = if (contracted)
                try withContext(arena, escalation.contract_brief_note, raw)
            else if (report_phase)
                try withContext(arena, report_anchors.anchor_brief_note, raw)
            else
                raw;
            const based = try withContext(arena, run_context, noted);
            if (phase_no == 1) {
                prompt.* = based;
            } else if (std.mem.indexOf(u8, based, "{{prev}}") != null) {
                const size = std.mem.replacementSize(u8, based, "{{prev}}", prev_results);
                const buf = try arena.alloc(u8, size);
                _ = std.mem.replace(u8, based, "{{prev}}", prev_results, buf);
                prompt.* = buf;
            } else {
                prompt.* = try std.fmt.allocPrint(arena, "{s}\n\nResults from the previous workflow phase:\n\n{s}", .{ based, prev_results });
            }
        }

        const diversity = brief_diversity.check(arena, ctx.tracer, title, raws, overrides); // #382: every brief in hand, nothing spawned yet
        // §2b — duplicate-brief collapse, here because this is the last moment
        // every brief is in hand and nothing has spawned. Tasks carrying the
        // same genome AND the same brief are one worker asked twice; the
        // duplicate spawns nothing and reads the survivor's result.
        const dup = brief_diversity.collapse(arena, raws, overrides, escalation.isVariantsPhase(phase_val));
        // The porcelain snapshot the edit contract compares against, taken
        // before any worker can touch the tree. "" for an uncontracted phase.
        const tree_before = escalation.treeSnapshot(arena, gpa, ctx.io, ctx.agent_cwd, contracted);
        // Join ALL tasks before any fallible work, so an early error return
        // can never abandon running subagents or free their result slots.
        const futures = try arena.alloc(Io.Future(ToolOutput), tasks.len);
        const outputs = try arena.alloc(ToolOutput, tasks.len);
        // #376 — ONE seat for the whole phase, resolved once here and shared by
        // every worker below (never per task, which is what #290 forbids). It
        // is the session route unless the learned (shape, role) policy found a
        // strictly better-value model for this phase's cell; either way the
        // #372 trace names the rung, the cell and the layer that decided.
        // #380: …then asked whether any task in it names an image the seat
        // cannot see. A re-seat stays phase-UNIFORM, so #290 is untouched.
        const seat = vision_ask.phaseSeat(route_phase.forPhase(subagent_run.childProvider(ctx.provider, ctx.subagent_provider, ctx.subagent_cross_provider), shape, title, niches, ctx.subagent_provider != null), prompts, ctx.subagent_provider != null);
        for (labels, prompts, overrides, niches, isolations, isolation_fallbacks, futures, 0..) |label, prompt, override, niche, isolation, isolation_fallback, *fut, i| {
            if (dup.rep[i] != i) continue; // §2b: a collapsed duplicate spawns nothing
            wfp.task(ctx.io, arena, run_id, phase_no, i + 1, tasks.len, label, "running"); // #63
            route_trace.emitSpawnProvider(ctx.io, ctx.tracer, label, seat.provider, seat.cellOf(niche), seat.sourceFor(override != null), override, niche);
            fut.* = ctx.io.async(workflowTask, .{ ctx, label, prompt, override, niche, isolation, isolation_fallback, seat.pin });
        }
        for (futures, outputs, labels, prompts, 0..) |*fut, *out, label, prompt, i| {
            if (dup.rep[i] != i) continue;
            // §3b — the edit contract, post-await: a contracted phase whose
            // porcelain never moved becomes is_error, which the retry below
            // then picks up. #380's honesty flag composes inside it.
            out.* = escalation.contractCheck(gpa, ctx.io, ctx.agent_cwd, contracted, tree_before, report_anchors.anchorCheck(gpa, ctx.io, ctx.agent_cwd, report_phase, vision_ask.flagReport(gpa, fut.await(ctx.io), vision_ask.forPrompt(prompt))));
            // #63 — terminal per task, so a UI can settle that row without
            // waiting for the phase (and before the retry pass below reruns it).
            wfp.task(ctx.io, arena, run_id, phase_no, i + 1, tasks.len, label, if (out.is_error) "failed" else "completed");
        }
        // Fan the survivor's result into every slot that collapsed into it, so
        // the next phase's {{prev}} reads exactly what it would have read. Must
        // run before the free-defer below, or a collapsed slot would be freed
        // uninitialized.
        for (outputs, 0..) |*out, i| if (dup.rep[i] != i) {
            out.* = .{ .text = gpa.dupe(u8, outputs[dup.rep[i]].text) catch "", .is_error = outputs[dup.rep[i]].is_error };
        };
        defer for (outputs) |out| gpa.free(out.text);
        wf_tasks += dup.survivors.len;

        // #2 — Retry transient failures once. A single flaky subagent (an empty
        // report, a dropped stream) shouldn't fail the phase or poison {{prev}}
        // for the next one. We can't reliably tell a transient failure from a
        // deterministic one, so we retry every failure exactly once: a permanent
        // failure just costs one more attempt and stays failed.
        // Failures the harness already classified as not retry-safe (auth, an
        // invalid argument, an unavailable model — see failureAllowsRetry) are
        // excluded here: retrying the whole phase would only double the cost
        // of a broken run for zero chance of success.
        // §4 — a budget-exhausted failure is GLOBAL, not per-task: the shared
        // pool is dry, so every other retry in this pass would fail the same
        // way and each would still be CHARGED for trying. Abort the whole pass
        // and let P2 end the run with partial evidence instead.
        var budget_dry = false;
        for (outputs) |out| if (out.is_error and subagent_run.isBudgetExhausted(out.text)) {
            budget_dry = true;
        };
        if (budget_dry) truncated = true;
        var fidx: [max_workflow_tasks]usize = undefined;
        var nf: usize = 0;
        for (outputs, 0..) |out, i| if (!budget_dry and out.is_error and failureAllowsRetry(out.text)) {
            fidx[nf] = i;
            nf += 1;
        };
        if (nf > 0) {
            const refut = try arena.alloc(Io.Future(ToolOutput), nf);
            for (refut, 0..) |*rf, k| {
                const i = fidx[k];
                rf.* = ctx.io.async(workflowRetryTask, .{ ctx, labels[i], prompts[i], overrides[i], niches[i], isolations[i], isolation_fallbacks[i], seat.pin });
            }
            for (refut, 0..) |*rf, k| {
                const i = fidx[k];
                const retry = vision_ask.flagReport(gpa, rf.await(ctx.io), vision_ask.forPrompt(prompts[i])); // #380
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
            // #248 — thread each failed task's own error into the abort text,
            // so the caller reads the API error, not a wall of bare headers.
            const details = try arena.alloc([]const u8, outputs.len);
            for (outputs, details) |out, *d| d.* = failExcerpt(arena, out.text);
            const abort_text = try buildAbortText(arena, labels, details, phase_no, phases.len, title);
            // The all-failed abort is the harness's own observation of a
            // failed attempt — parked as evidence for the next escalation.
            escalation.failure_evidence.note(shapes.classOf(shapes.rawAsk()), abort_text);
            return .{ .text = try gpa.dupe(u8, abort_text), .is_error = true };
        }

        // #1 — Ultracode → DGM engine: when ≥2 persona variants competed this
        // phase, score each survivor and submit its niche-tagged fitness so the
        // fleet can rank and promote the winner (docs/hyperagents.md §9.B). The
        // propose half already fired in runSub; this closes the loop runEval left
        // open (it submits niche=""). Gated on the fleet — no judge cost otherwise.
        // §4-P3: and on the budget. A tournament is OPTIONAL spend — one call
        // per surviving variant post-§2c — so it runs only when it fits ON TOP
        // of the landing reserve. This is run_budget.canAfford's documented use
        // case, which until now had zero call sites.
        if (ledger.fits(phase_budget.remainingOf(ctx.run_budget), @as(u64, @intCast(dup.survivors.len)) * phase_budget.cost_judge))
            scoreVariants(ctx, arena, seat, prompts, raws, overrides, niches, outputs);

        tallies[phase_no - 1] = .{ .phase_no = phase_no, .total_phases = phases.len, .title = title, .ok = tasks.len - phase_failed, .total = tasks.len, .retried = nf, .diversity = wfp.joinNotes(arena, diversity, brief_diversity.collapseNote(arena, dup)) };
        phases_ran = phase_no;

        // Divide the {{prev}} budget across THIS phase's own task count so a
        // wide phase's total contribution to the next phase's prompt stays near
        // phase_prev_budget instead of growing with tasks.len — see the
        // phase_prev_budget doc comment above for the quadratic-cost story.
        const per_task_cap = phaseTaskCap(tasks.len);
        var aw: Io.Writer.Allocating = .init(arena);
        for (labels, outputs) |label, out| {
            if (out.is_error) {
                // Keep the failure visible to the next phase, but never feed its
                // raw error text into {{prev}} as if it were a real result (#2).
                // #248 sends a capped one-line excerpt of that error through,
                // so a synthesis task can adapt to (say) a rate limit.
                try aw.writer.print("### {s} (no result — task failed)\n", .{label});
                const detail = failExcerpt(arena, out.text);
                if (detail.len > 0) try aw.writer.print("{s}\n", .{detail});
                try aw.writer.writeAll("\n");
            } else {
                try aw.writer.print("### {s}\n{s}\n\n", .{ label, cappedPrevBody(arena, out.text, per_task_cap) });
            }
        }
        prev_results = std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
    }
    // Only the phases that actually ran are tallied: P2 can break out of the
    // loop, leaving the rest of `tallies` uninitialized.
    const manifest = try buildManifest(arena, tallies[0..phases_ran]);
    const final_text = try std.fmt.allocPrint(arena, "{s}\n\n{s}{s}", .{
        prev_results,
        manifest,
        if (truncated) "\n" ++ phase_budget.truncated_note else "",
    });
    return .{ .text = try gpa.dupe(u8, final_text) };
}
