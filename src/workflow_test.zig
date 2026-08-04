//! Tests for the workflow engine (phases + pipeline). Split out of
//! src/workflow.zig, which crossed the 600-line cap once the audit fixes for
//! the {{prev}} phase budget, the all-failed abort, the shared context slot
//! and the pipeline isolation guard rail all landed in it. Reached through the
//! `test { _ = ... }` hook in main.zig - without that line these silently
//! compile to nothing and the suite still reports green.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const workflow = @import("workflow.zig");
const subagent = @import("subagent.zig");
const subagent_run = @import("subagent_run.zig");
const json_args = @import("json_args.zig");
const tools = @import("tools.zig");
const util = @import("util.zig");
const ToolCtx = tools.ToolCtx;
const cappedPrevBody = workflow.cappedPrevBody;
const phaseTaskCap = workflow.phaseTaskCap;
const withContext = workflow.withContext;
const gateAllows = workflow.gateAllows;
const buildAbortText = workflow.buildAbortText;
const failExcerpt = workflow.failExcerpt;
const fail_excerpt_cap = workflow.fail_excerpt_cap;
const buildManifest = workflow.buildManifest;
const pipelinePrompt = workflow.pipelinePrompt;
const pipelineIsolationError = workflow.pipelineIsolationError;
const phase_prev_budget = workflow.phase_prev_budget;
const PhaseTally = workflow.PhaseTally;
const min_task_prev_cap = workflow.min_task_prev_cap;
const max_workflow_tasks = workflow.max_workflow_tasks;
const execWorkflow = workflow.execWorkflow;

test "cappedPrevBody bounds a wide phase output, keeps head + inspect tail at several caps (#4/U3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A short result passes through untouched — most outputs never hit the
    // cap, at any cap size.
    try std.testing.expectEqualStrings("hi", cappedPrevBody(a, "hi", phase_prev_budget));
    try std.testing.expectEqualStrings("hi", cappedPrevBody(a, "hi", min_task_prev_cap));

    // A huge result is capped at several different cap sizes (the divided
    // per-task cap varies with phase width): head kept, the trailing
    // inspect: pointer never truncated away, a truncation marker added, and
    // the full text never lands verbatim.
    const big = util.repeatBytes("X", 9000) ++ "\n[subagent sa-007-abcd · inspect: .graff/subagents/sa-007-abcd.md]";
    for ([_]usize{ phase_prev_budget, 3000, 1500, min_task_prev_cap }) |cap| {
        const capped = cappedPrevBody(a, big, cap);
        try std.testing.expect(capped.len < big.len);
        try std.testing.expect(capped.len <= cap + 200); // head + tail + marker overhead
        try std.testing.expect(std.mem.indexOf(u8, capped, "truncated") != null);
        try std.testing.expect(std.mem.indexOf(u8, capped, "inspect: .graff/subagents/sa-007-abcd.md") != null);
        try std.testing.expect(std.mem.indexOf(u8, capped, big) == null);
    }
}

test "phaseTaskCap divides the phase budget across tasks, floored at min_task_prev_cap (#U3)" {
    // Narrow phases: budget/n_tasks comfortably clears the floor.
    try std.testing.expectEqual(@as(usize, phase_prev_budget), phaseTaskCap(1));
    try std.testing.expectEqual(@as(usize, phase_prev_budget / 2), phaseTaskCap(2));

    // Wide phases (up to max_workflow_tasks, and beyond): the divided cap
    // would fall below min_task_prev_cap, so the floor wins — never an
    // unreadably tiny per-task slice.
    try std.testing.expect(phase_prev_budget / max_workflow_tasks < min_task_prev_cap);
    try std.testing.expectEqual(@as(usize, min_task_prev_cap), phaseTaskCap(max_workflow_tasks));
    try std.testing.expectEqual(@as(usize, min_task_prev_cap), phaseTaskCap(50));
}

test "withContext: set prepends context + blank line; absent/empty is byte-identical (U5)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Context set: context, blank line, raw task — nothing else.
    const with = try withContext(a, "Repo: zig 0.16, 600-line file cap.", "Implement the thing.");
    try std.testing.expectEqualStrings("Repo: zig 0.16, 600-line file cap.\n\nImplement the thing.", with);

    // Context absent → byte-identical to the raw task (no stray blank line).
    const absent = try withContext(a, "", "Implement the thing.");
    try std.testing.expectEqualStrings("Implement the thing.", absent);

    // Context present but empty string behaves the same as absent.
    const empty = try withContext(a, "", "Do the other thing.");
    try std.testing.expectEqualStrings("Do the other thing.", empty);
}

test "gateAllows: empty when always runs, else case-insensitive substring (#5)" {
    try std.testing.expect(gateAllows("anything", "")); // no gate → always run
    try std.testing.expect(gateAllows("found 3 ISSUES here", "issues")); // case-insensitive hit
    try std.testing.expect(!gateAllows("all clean, no findings", "ISSUE")); // absent → skip
    try std.testing.expect(!gateAllows("", "ready")); // empty prev → skip
}

test "buildAbortText names the phase index and title, and surfaces each failed task's error (U2/#248)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const labels = [_][]const u8{ "scan A", "scan B" };
    // Parallel per-task excerpts: one real API error, one task that left
    // nothing to report.
    const details = [_][]const u8{ "subagent sa-001 failed before producing a report: 429 rate_limit_exceeded [quota failure].", "" };
    const text = try buildAbortText(a, &labels, &details, 2, 3, "Recon");

    // Every failed task's header survives, so a human can see what was tried.
    try std.testing.expect(std.mem.indexOf(u8, text, "### scan A (no result — task failed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### scan B (no result — task failed)") != null);
    // #248 — the underlying API error travels WITH the header instead of being
    // consumed by the retry gate and dropped. This is the whole ask on the
    // issue: a caller that only reads "task failed" cannot adapt.
    try std.testing.expect(std.mem.indexOf(u8, text, "429 rate_limit_exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### scan A (no result — task failed)\nsubagent sa-001 failed") != null);
    // The abort line names the phase index/total and title — the whole point
    // of this text existing instead of a silent empty {{prev}}.
    try std.testing.expect(std.mem.indexOf(u8, text, "workflow aborted: every task in phase 2/3 (Recon) failed") != null);
}

test "failExcerpt keeps the API error on one capped line, and stays empty when there is none (#248)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A real subagentFailure text: the cause survives, flattened, so it can sit
    // under a "### label" header without breaking that layout.
    const raw = "subagent sa-001 failed before producing a report:\n{\"error\":\"rate_limit_exceeded\"}\t[quota failure].";
    const one = failExcerpt(a, raw);
    try std.testing.expect(std.mem.indexOf(u8, one, "rate_limit_exceeded") != null);
    try std.testing.expect(std.mem.indexOfAny(u8, one, "\n\r\t") == null);

    // A huge error body is capped, so one failure can never blow up the next
    // phase's prompt — the reason the excerpt is bounded at all.
    const huge = util.repeatBytes("E", 5000);
    const capped = failExcerpt(a, &huge);
    try std.testing.expect(capped.len < huge.len);
    try std.testing.expect(capped.len <= fail_excerpt_cap + 8); // + the "…" marker
    try std.testing.expect(std.mem.endsWith(u8, capped, "…"));

    // Nothing to report → "" so the render sites keep the bare header rather
    // than printing an empty detail line.
    try std.testing.expectEqualStrings("", failExcerpt(a, "  \n\t "));
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

test "#382: a phase's diversity note rides the manifest, under its own phase line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The manifest is where the ROOT reads a run's shape, so it is where a
    // note addressed to the orchestrator belongs — a phase's own results are
    // summarised into {{prev}} and go to the next phase's WORKERS instead.
    const note = "diversity warning: 3 variant briefs are ~62% similar — proceed if intentional.";
    const tallies = [_]PhaseTally{
        .{ .phase_no = 1, .total_phases = 2, .title = "variants", .ok = 3, .total = 3, .retried = 0, .diversity = note },
        .{ .phase_no = 2, .total_phases = 2, .title = "build", .ok = 1, .total = 1, .retried = 0 },
    };
    const block = try buildManifest(a, &tallies);

    const phase1 = std.mem.indexOf(u8, block, "phase 1/2 variants: 3/3 ok, 0 retried").?;
    const warned = std.mem.indexOf(u8, block, note).?;
    const phase2 = std.mem.indexOf(u8, block, "phase 2/2 build").?;
    try std.testing.expect(phase1 < warned and warned < phase2);

    // A quiet phase adds nothing at all — no "diversity ok" line to train the
    // root to skim past.
    const quiet = [_]PhaseTally{.{ .phase_no = 1, .total_phases = 1, .title = "variants", .ok = 3, .total = 3, .retried = 0 }};
    try std.testing.expectEqualStrings("## workflow\nphase 1/1 variants: 3/3 ok, 0 retried", try buildManifest(a, &quiet));
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

test "pipelineIsolationError: stage 0 may isolate, stage 1+ worktree is refused naming the stage, non-worktree is always allowed (#295 guard rail)" {
    // Stage 0 (the first stage) may isolate with its own worktree.
    try std.testing.expect(pipelineIsolationError(0, .worktree) == null);

    // Stage 1+ requesting worktree isolation is refused — a pipeline is a
    // dependent chain over one item, so a later stage in its own worktree
    // cannot see what the prior stage did.
    const msg1 = pipelineIsolationError(1, .worktree) orelse return error.TestExpectedNonNull;
    try std.testing.expect(std.mem.indexOf(u8, msg1, "stage 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg1, "phases") != null);

    const msg3 = pipelineIsolationError(3, .worktree) orelse return error.TestExpectedNonNull;
    try std.testing.expect(std.mem.indexOf(u8, msg3, "stage 3") != null);

    // Non-worktree isolation (shared_cwd) is allowed at any stage index.
    try std.testing.expect(pipelineIsolationError(0, .shared_cwd) == null);
    try std.testing.expect(pipelineIsolationError(1, .shared_cwd) == null);
    try std.testing.expect(pipelineIsolationError(4, .shared_cwd) == null);
}

test "a 5xx outage is transient, so a fan-out keeps retrying it (U1 regression guard)" {
    // The classifier was advisory prose until failureAllowsRetry made it control
    // flow. Its .model arm matched the bare word "unavailable", so "503 Service
    // Unavailable" - the single most common transient failure - classified as a
    // dead model and stopped the whole phase retrying.
    for ([_][]const u8{ "503 Service Unavailable", "502 Bad Gateway", "500 internal server error", "upstream temporarily unavailable" }) |detail|
        try std.testing.expectEqual(subagent_run.FailKind.transport, subagent_run.classifyFailure(error.Unexpected, detail));
    // A genuinely dead model still classifies as .model and still stops retrying.
    for ([_][]const u8{ "model unavailable", "no such model", "model_not_found" }) |detail|
        try std.testing.expectEqual(subagent_run.FailKind.model, subagent_run.classifyFailure(error.Unexpected, detail));
}

test "the ROOT permission gate refuses a malformed bash call instead of dereferencing it" {
    // gateTool is root-only (subagents take the early return at its top), so
    // the json_args guards added across the workflow/subagent paths in v0.0.223
    // never covered it. A model that sends bash arguments as a bare string or
    // array reaches this gate on the ordinary single-agent path.
    for ([_]std.json.Value{ .{ .string = "rm -rf /" }, .null, .{ .integer = 7 } }) |bad|
        try std.testing.expect(json_args.object(bad) == null);
    // The shape the gate actually wants still resolves, so the guard is not
    // simply refusing everything.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const good = try std.json.parseFromSliceLeaky(Value, arena_state.allocator(), "{\"command\":\"ls\"}", .{});
    const ok = json_args.object(good) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("ls", ok.get("command").?.string);
}
