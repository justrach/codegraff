//! Subagent spawning: the isolated one-level-deep child Agent runner
//! (`execSubagent`/`runSub`), the workflow/judge task wrappers
//! (`workflowTask`/`judgeTask`), the --json GUI event bridge (`guiEmit`), and
//! the ultracode/DGM variant-scoring judge (`variantJudgePrompt`/
//! `scoreVariants`). Split out of main.zig (600-line goal). Sibling-imports
//! tools.zig for `ToolCtx`/`ToolOutput`/`failure`; back-imports main (as
//! `main_mod`) for `Agent` (whose `runTurn`/`systemPrompt` are pub-flipped for
//! this cross-module call), `parseEvalScore`, `utf8Prefix`, `json_mode`,
//! `g_out`/`g_gui_mu` (pub-flipped — guiEmit serializes --json stdout with
//! them), and `g_fleet`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const util = @import("util.zig");
const repl_glue = @import("repl_glue.zig");
const Agent = agent_mod.Agent;
const Provider = @import("provider.zig").Provider;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const failure = tools.failure;

const telemetry = @import("telemetry.zig");
const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;
const providerClass = scoring.providerClass;
const signScore = scoring.signScore;
const fleet = @import("fleet.zig");
const learning_privacy = @import("learning_privacy.zig");
const agentTypePrompt = fleet.agentTypePrompt;
const Isolation = fleet.Isolation;
const jobs = @import("jobs.zig"); // #276 P0-1: agentWorktreeCreate/agentWorktreeFinish/isolationFailureText
const run_budget = @import("run_budget.zig"); // #276 P0-3: default_max_concurrency, reused as the background-agent cap's default value
const cards = @import("cards.zig");
const trace = @import("trace.zig");
const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;

/// Spawn a one-level-deep subagent: fresh arena, fresh history, same shared
/// http client and provider. Runs entirely on this pool thread; its own tool
/// calls fan out further via io.async. `run_in_background:true` (#276 P0-3)
/// instead registers the spawn and returns immediately — see
/// spawnSubBackground below.
pub fn execSubagent(ctx: ToolCtx, input: Value) !ToolOutput {
    if (ctx.from_sub) return .{
        .text = try ctx.gpa.dupe(u8, "subagents cannot spawn subagents — do this work yourself"),
        .is_error = true,
    };
    const label = if (input.object.get("description")) |d| (if (d == .string) d.string else "subagent") else "subagent";
    const prompt = if (input.object.get("prompt")) |p| (if (p == .string) p.string else "") else "";
    if (prompt.len == 0) return .{ .text = try ctx.gpa.dupe(u8, "subagent: missing required \"prompt\" (a self-contained task)"), .is_error = true };
    const sys_override = fleet.resolveOverride(input.object);
    const niche = fleet.resolveNiche(input.object);
    const isolation = fleet.resolveIsolation(input.object);
    const isolation_fallback = fleet.resolveIsolationFallback(input.object);
    const background = if (input.object.get("run_in_background")) |v| v == .bool and v.bool else false;
    if (background) return spawnSubBackground(ctx, label, prompt, sys_override, niche, isolation, isolation_fallback);
    const run = try runSub(ctx, "subagent", label, prompt, sys_override, niche, isolation, isolation_fallback);
    return run.output;
}

const subagent_run = @import("subagent_run.zig");
pub const AgentUsage = subagent_run.AgentUsage;
pub const SubRun = subagent_run.SubRun;
pub const runSub = subagent_run.runSub;
const variantProviderClass = subagent_run.variantProviderClass;
const shapes = @import("shapes.zig");
const FailKind = subagent_run.FailKind;
const classifyFailure = subagent_run.classifyFailure;

// ── Async, fire-and-forget background subagents (#276 P0-3) ────────────────
// Extends jobs.zig's background-bash-job pattern (Job/g_jobs/spawnJob/
// jobOutput/jobKill — stable incrementing ids, a session-global mutex-guarded
// registry, non-blocking spawn) to subagent spawns: `run_in_background:true`
// on `subagent` returns a stable agent id immediately (spawnSubBackground);
// the child runs on io.concurrent, never io.async — io.async may run inline
// and block the spawning call forever on a long-lived child, same reason
// spawnJob avoids it for bash. Completion is polled non-destructively via
// the new `agent_output` tool (agentOutput), mirroring bash_output's
// id/wait_ms shape and its 30s wait cap — except a subagent's report is a
// one-shot value, not a stream, so a completed fetch always replays the
// FULL result rather than consuming a cursor (design point 4).

/// Concurrency ceiling on background subagents actually RUNNING (i.e. past
/// admission, inside their own runSub call) at once. Deliberately a counter
/// of its own, not a reuse of RunBudget.active/acquireConcurrency: a
/// background job's admission slot would otherwise have to stay held for its
/// entire — possibly minutes-long — lifetime, while its OWN internal turns
/// separately acquire per-model-call permits from that very same pool; once
/// enough jobs queued up, every held outer slot would starve the inner
/// acquires each job needs to ever finish and release it — a deadlock. Same
/// admission SHAPE as RunBudget.acquireConcurrency (spin-wait, no failure on
/// saturation) and the same default value, but an independent resource.
const max_concurrent_background_agents: u32 = run_budget.default_max_concurrency;

/// One background subagent spawn: the runSub arguments (gpa-owned copies —
/// the caller's ToolCtx.arena-backed strings do not outlive this tool call's
/// return, the whole point of fire-and-forget) plus its outcome once done.
/// `admitted` is false while queued behind max_concurrent_background_agents;
/// jobs.zig's Job mirrors this shape closely (id/cmd there ~ id/label+prompt
/// here).
const AgentJob = struct {
    id: u32,
    label: []u8,
    prompt: []u8,
    sys_override: ?[]u8 = null,
    niche: []u8,
    isolation: Isolation,
    isolation_fallback: bool,
    ctx: ToolCtx,
    admitted: bool = false,
    done: bool = false,
    is_error: bool = false,
    result: []u8 = &.{}, // gpa-owned once done
    usage: AgentUsage = .{},
    future: Io.Future(void) = undefined, // pump; awaited only by agentJobsReap
};

const AgentJobs = struct {
    mutex: Io.Mutex = .init,
    list: std.ArrayList(*AgentJob) = .empty,
    active: u32 = 0, // admitted and not yet done
    next_id: u32 = 1,

    fn find(self: *AgentJobs, id: u32) ?*AgentJob {
        for (self.list.items) |j| if (j.id == id) return j;
        return null;
    }
};

pub var g_agent_jobs: AgentJobs = .{};

/// Pure admission step: pop the oldest not-yet-admitted job and mark it
/// admitted (bumping `active`), or return null when the cap is full or
/// nothing is queued. No Io — callers hold AgentJobs.mutex around it; kept
/// separate so the queue-not-fail contract (design point 6) is unit-testable
/// without a real Io/thread pool.
fn admitOneLocked(registry: *AgentJobs) ?*AgentJob {
    if (registry.active >= max_concurrent_background_agents) return null;
    for (registry.list.items) |j| {
        if (!j.admitted) {
            j.admitted = true;
            registry.active += 1;
            return j;
        }
    }
    return null;
}

/// Drain admittable jobs, launching each via io.concurrent. Called right
/// after a spawn (start immediately if there's room) and at the end of
/// every job's pump (drain the next queued one) — a small self-perpetuating
/// worker chain, no separate ticker task needed. Never called with the
/// mutex held.
fn admitNext(gpa: Allocator, io: Io) void {
    while (true) {
        g_agent_jobs.mutex.lockUncancelable(io);
        const job = admitOneLocked(&g_agent_jobs);
        g_agent_jobs.mutex.unlock(io);
        const j = job orelse return;
        j.future = io.concurrent(agentJobPump, .{ j, gpa, io }) catch {
            // Pool has no spare concurrency right now — un-admit and stop;
            // the next spawn or completion retries (#276 P0-3 design point
            // 6: queue rather than fail — never surfaced to the model).
            g_agent_jobs.mutex.lockUncancelable(io);
            j.admitted = false;
            g_agent_jobs.active -= 1;
            g_agent_jobs.mutex.unlock(io);
            return;
        };
    }
}

/// The background pump: runs the child to completion off the calling turn,
/// records the structured completion (status/result/usage — never silent,
/// even on failure), then drains the next queued spawn. Mirrors jobPump's
/// shape in jobs.zig.
fn agentJobPump(job: *AgentJob, gpa: Allocator, io: Io) void {
    const t0: Io.Timestamp = .now(io, .awake);
    const run = runSub(job.ctx, "subagent", job.label, job.prompt, job.sys_override, job.niche, job.isolation, job.isolation_fallback) catch |err| SubRun{
        .output = failure(gpa, err),
        .usage = .{ .duration_ms = @intCast(@max(0, t0.untilNow(io, .awake).toMilliseconds())) },
    };
    g_agent_jobs.mutex.lockUncancelable(io);
    job.result = run.output.text;
    job.is_error = run.output.is_error;
    job.usage = run.usage;
    job.done = true;
    g_agent_jobs.active -= 1;
    g_agent_jobs.mutex.unlock(io);
    admitNext(gpa, io);
}

/// `run_in_background:true` path for `subagent` (execSubagent): register the
/// job and return immediately with its id; the child runs on the pool.
/// Never blocks on a free concurrency slot — a spawn beyond the cap is
/// queued, not failed; admitNext drains it once room frees up.
fn spawnSubBackground(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8, isolation: Isolation, isolation_fallback: bool) !ToolOutput {
    const gpa = ctx.gpa;
    const label_c = try gpa.dupe(u8, label);
    errdefer gpa.free(label_c);
    const prompt_c = try gpa.dupe(u8, prompt);
    errdefer gpa.free(prompt_c);
    const sys_c: ?[]u8 = if (sys_override) |s| try gpa.dupe(u8, s) else null;
    errdefer if (sys_c) |s| gpa.free(s);
    const niche_c = try gpa.dupe(u8, niche);
    errdefer gpa.free(niche_c);

    const job = try gpa.create(AgentJob);
    job.* = .{
        .id = 0,
        .label = label_c,
        .prompt = prompt_c,
        .sys_override = sys_c,
        .niche = niche_c,
        .isolation = isolation,
        .isolation_fallback = isolation_fallback,
        .ctx = ctx,
    };

    g_agent_jobs.mutex.lockUncancelable(ctx.io);
    job.id = g_agent_jobs.next_id;
    g_agent_jobs.next_id += 1;
    const appended = blk: {
        g_agent_jobs.list.append(gpa, job) catch break :blk false;
        break :blk true;
    };
    g_agent_jobs.mutex.unlock(ctx.io);
    if (!appended) {
        gpa.free(label_c);
        gpa.free(prompt_c);
        if (sys_c) |s| gpa.free(s);
        gpa.free(niche_c);
        gpa.destroy(job);
        return error.OutOfMemory;
    }
    admitNext(gpa, ctx.io);
    return .{ .text = try std.fmt.allocPrint(
        gpa,
        "[agent {d} started: {s}]\nIt runs in the background across turns. Poll status/result with agent_output (id {d}, optional wait_ms); once it completes, agent_output keeps returning the same result — nothing is consumed.",
        .{ job.id, job.label, job.id },
    ) };
}

/// Pure formatting for agent_output's status line: the "structured
/// completion event" shape (#276 P0-3 design point 3) — running / completed
/// / failed, plus the usage summary, plus the full result once done.
/// Factored out of agentOutput so it's unit-testable without a real Io.
fn agentStatusText(gpa: Allocator, id: u32, done: bool, is_error: bool, usage: AgentUsage, result: []const u8) ![]u8 {
    if (!done) return std.fmt.allocPrint(gpa, "[agent {d}: running]", .{id});
    return std.fmt.allocPrint(
        gpa,
        "[agent {d}: {s} in {d}ms · {d} tool call(s) · ~{d} context token(s) · {d} cache-read token(s)]\n\n{s}",
        .{ id, if (is_error) "failed" else "completed", usage.duration_ms, usage.tool_calls, usage.context_tokens, usage.cache_read_tokens, result },
    );
}

/// Same wait cap as jobs.zig's bash_output (job_wait_cap_ms) — kept as its
/// own constant rather than made pub there, since it's one shared value, not
/// shared state.
const agent_wait_cap_ms: u64 = 30_000;

/// agent_output: fetch a background subagent's status/result. Non-
/// destructive — a completed fetch always replays the full result (unlike
/// bash_output's cursor, a subagent's report is one-shot, not a stream).
/// wait_ms > 0 polls (capped at 30s, like bash_output) while still running.
pub fn agentOutput(gpa: Allocator, io: Io, id: u32, wait_ms: u64) !ToolOutput {
    const deadline = @min(wait_ms, agent_wait_cap_ms);
    var waited: u64 = 0;
    while (true) {
        g_agent_jobs.mutex.lockUncancelable(io);
        const job = g_agent_jobs.find(id) orelse {
            g_agent_jobs.mutex.unlock(io);
            return .{ .text = try std.fmt.allocPrint(gpa, "no background agent {d} — it may never have started; subagent with run_in_background:true returns the id when it launches", .{id}), .is_error = true };
        };
        if (job.done or waited >= deadline) {
            const text = try agentStatusText(gpa, id, job.done, job.is_error, job.usage, job.result);
            const is_err = job.done and job.is_error;
            g_agent_jobs.mutex.unlock(io);
            return .{ .text = text, .is_error = is_err };
        }
        g_agent_jobs.mutex.unlock(io);
        if (Agent.esc_cancel.load(.acquire)) {
            waited = deadline; // render current state on the next pass
            continue;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            waited = deadline;
            continue;
        };
        waited += 100;
    }
}

/// Session end: let every still-running background agent finish naturally —
/// unlike a bash child process (jobs.zig's jobsReap, which flags
/// kill_requested and the pump kills the child within ~200ms), there is no
/// cheap way to abort an in-flight agent turn mid-request, so this mirrors
/// jobsReap's SHAPE (drain the registry, await every pump, free everything
/// before the process exits) but not its KILL semantics — see this feature's
/// commit body for the full rationale. A job still queued (never admitted)
/// at shutdown never started, so it's simply dropped: nothing ran, nothing
/// to lose.
pub fn agentJobsReap(gpa: Allocator, io: Io) void {
    g_agent_jobs.mutex.lockUncancelable(io);
    const list = g_agent_jobs.list.toOwnedSlice(gpa) catch {
        g_agent_jobs.mutex.unlock(io);
        return;
    };
    g_agent_jobs.mutex.unlock(io);
    for (list) |job| {
        if (job.admitted) job.future.await(io);
        gpa.free(job.label);
        gpa.free(job.prompt);
        if (job.sys_override) |s| gpa.free(s);
        gpa.free(job.niche);
        gpa.free(job.result);
        gpa.destroy(job);
    }
    gpa.free(list);
}

test "admitOneLocked: admits up to the cap, queues the rest, FIFO order (#276 P0-3 design point 6)" {
    const gpa = std.testing.allocator;
    var registry: AgentJobs = .{};
    defer registry.list.deinit(gpa);

    var stub_jobs: [max_concurrent_background_agents + 3]AgentJob = undefined;
    for (&stub_jobs, 0..) |*j, i| j.* = .{
        .id = @intCast(i + 1),
        .label = @constCast(""),
        .prompt = @constCast(""),
        .niche = @constCast(""),
        .isolation = .shared_cwd,
        .isolation_fallback = false,
        .ctx = undefined,
    };
    for (&stub_jobs) |*j| try registry.list.append(gpa, j);

    var admitted_order: [stub_jobs.len]u32 = undefined;
    var n: usize = 0;
    while (admitOneLocked(&registry)) |j| : (n += 1) admitted_order[n] = j.id;

    try std.testing.expectEqual(@as(usize, max_concurrent_background_agents), n); // only the cap gets admitted immediately
    try std.testing.expectEqual(max_concurrent_background_agents, registry.active);
    for (admitted_order[0..n], 1..) |id, expect| try std.testing.expectEqual(@as(u32, @intCast(expect)), id); // FIFO

    var still_queued: usize = 0;
    for (stub_jobs) |j| if (!j.admitted) {
        still_queued += 1;
    };
    try std.testing.expectEqual(stub_jobs.len - n, still_queued); // the remainder stay queued, not failed

    // A finished job frees its slot; the next queued one is then admittable.
    registry.active -= 1;
    const next = admitOneLocked(&registry).?;
    try std.testing.expectEqual(@as(u32, max_concurrent_background_agents + 1), next.id);
}

test "agentStatusText: running/completed/failed shapes carry the usage summary, and a failure is never silent (#276 P0-3)" {
    const gpa = std.testing.allocator;

    const running = try agentStatusText(gpa, 7, false, false, .{}, "");
    defer gpa.free(running);
    try std.testing.expectEqualStrings("[agent 7: running]", running);

    const ok = try agentStatusText(gpa, 7, true, false, .{ .duration_ms = 1200, .tool_calls = 3, .context_tokens = 4500, .cache_read_tokens = 100 }, "final report");
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "1200ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "3 tool call") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "final report") != null);

    const failed_text = "subagent sa-014-abcd failed before producing a report: connection reset [transport failure]. retry is likely safe";
    const failed = try agentStatusText(gpa, 9, true, true, .{ .duration_ms = 300 }, failed_text);
    defer gpa.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "failed") != null); // status names the failure — never silent
    try std.testing.expect(std.mem.indexOf(u8, failed, failed_text) != null); // the child's own diagnostic rides along verbatim
}

test "agentStatusText: composes with isolation:\"worktree\" — a kept-worktree note in the result survives verbatim (#276 P0-3 design point 5)" {
    const gpa = std.testing.allocator;
    const result_with_worktree = "final report text\n\n[worktree kept (has changes) — path: .graff/worktrees/agent-sa-001-aa11, branch: graff/agents/sa-001-aa11]";
    const out = try agentStatusText(gpa, 3, true, false, .{ .duration_ms = 500 }, result_with_worktree);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[worktree kept (has changes) — path:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "branch: graff/agents/sa-001-aa11") != null);
}

/// One task inside a workflow phase; never throws, suitable for io.async.
/// `niche` is the task's MAP-Elites cell, threaded through so runSub's
/// fleet:propose — and scoreVariants' submit — tag the variant's genome.
pub fn workflowTask(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8, isolation: Isolation, isolation_fallback: bool) ToolOutput {
    const run = runSub(ctx, "workflow_task", label, prompt, sys_override, niche, isolation, isolation_fallback) catch |err| return failure(ctx.gpa, err);
    return run.output;
}

/// A second workflow attempt has its own explicit budget kind. It still shares
/// the same invocation-wide atomic ceiling and concurrency limiter.
pub fn workflowRetryTask(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8, isolation: Isolation, isolation_fallback: bool) ToolOutput {
    const run = runSub(ctx, "workflow_retry", label, prompt, sys_override, niche, isolation, isolation_fallback) catch |err| return failure(ctx.gpa, err);
    return run.output;
}

/// The --judge LLM-as-judge run (see runEval in main): an isolated subagent
/// scores the work against the rubric and ends with a `score:` line. Mirrors
/// workflowTask — a thin runSub wrapper — so the eval handler can io.async it
/// on a pool thread. Never worktree-isolated: a judge only reads/reasons over
/// text handed to it, never the filesystem, so there's nothing to isolate.
pub fn judgeTask(ctx: ToolCtx, prompt: []const u8) ToolOutput {
    const run = runSub(ctx, "judge_task", "judge", prompt, null, "", .shared_cwd, false) catch |err| return failure(ctx.gpa, err);
    return run.output;
}

/// Build the judge prompt that scores one workflow variant's output against its
/// task on a 0-100 scale (see scoreVariants). Bounded: the task spec and output
/// tail are truncated so a fat phase can't blow up the judge's context.
fn variantJudgePrompt(arena: Allocator, title: []const u8, task: []const u8, output: []const u8) ![]const u8 {
    const spec = util.utf8Prefix(task, 1200);
    const work = if (output.len > 2000) output[output.len - 2000 ..] else output;
    return std.fmt.allocPrint(arena,
        \\An agent variant ran the task below as part of the "{s}" phase of a workflow.
        \\Judge how well its OUTPUT accomplishes the TASK, on a 0-100 scale. Be
        \\discriminating: reward correctness, completeness, and usefulness; penalize
        \\hand-waving, non-answers, and ignored requirements. Do not reward length.
        \\
        \\TASK:
        \\{s}
        \\
        \\VARIANT OUTPUT:
        \\{s}
        \\
        \\Inspect any files the work references if you need to, then end your reply
        \\with a single final line `score: <N>` where N is an integer from 0 to 100.
    , .{ title, spec, work });
}

/// Task-array bound shared with workflow.zig's execWorkflow (phase task caps
/// and the fixed-size scratch arrays both use it) — the single source of truth
/// lives here since scoreVariants (below) needs it too.
pub const max_workflow_tasks = 8;

/// #1 — Score this phase's persona variants and submit niche-tagged fitness to
/// the fleet, turning every ultracode tournament into a DGM scoring round. Each
/// surviving variant task is judged 0-100 against its task; the score is signed
/// and submitted under the task's niche so a MAP-Elites cell accrues real fitness
/// and the promote pass can crown a winner. Mirrors runEval's submit exactly but
/// with a NON-EMPTY niche — the gap that previously forced bootstrap seeding.
/// Best-effort and gated: no judge runs unless ≥2 variants competed and the
/// fleet (telemetry) is on, so ordinary fan-outs pay nothing.
pub fn scoreVariants(
    ctx: ToolCtx,
    arena: Allocator,
    title: []const u8,
    prompts: [][]const u8,
    raws: [][]const u8,
    overrides: []?[]const u8,
    niches: [][]const u8,
    outputs: []ToolOutput,
) void {
    if (!main_mod.g_fleet) return;
    const t = telemetry.g_telem orelse return;

    // Variant tasks that produced a usable result; a tournament needs ≥2.
    var vidx: [max_workflow_tasks]usize = undefined;
    var vn: usize = 0;
    for (overrides, outputs, 0..) |o, out, i| {
        if (o != null and !out.is_error) {
            vidx[vn] = i;
            vn += 1;
        }
    }
    if (vn < 2) return;

    // A tournament must vary exactly ONE axis: if the variants did not all run on
    // the same capability tier, the ranking reflects the model as much as the
    // prompt, and filing it under the prompt fingerprint writes model effects into
    // the genome archive (#290). Bail before spawning a judge — unscoreable round.
    for (1..vn) |k| {
        if (!std.mem.eql(u8, variantProviderClass(ctx, vidx[0]), variantProviderClass(ctx, vidx[k]))) {
            if (ctx.tracer) |tr| tr.note("fleet", "tournament skipped: variants span provider classes");
            return;
        }
    }

    // All fallible work (prompt builds) before any future spawns, so an early
    // return can never abandon a running judge.
    const jprompts = arena.alloc([]const u8, vn) catch return;
    for (jprompts, 0..) |*jp, k| {
        const i = vidx[k];
        jp.* = variantJudgePrompt(arena, title, prompts[i], outputs[i].text) catch return;
    }
    const jfuts = arena.alloc(Io.Future(ToolOutput), vn) catch return;
    for (jfuts, jprompts) |*jf, jp| jf.* = ctx.io.async(judgeTask, .{ ctx, jp });

    const run_id: []const u8 = &scoring.g_run_id;
    // This phase's MAP-Elites slot (#290/#293); "" off-vocabulary. See telemetrySlot.
    const slot = scoring.telemetrySlot(shapes.canonicalSlot(title));
    for (jfuts, 0..) |*jf, k| {
        const i = vidx[k];
        const jout = jf.await(ctx.io);
        defer ctx.gpa.free(jout.text);
        if (jout.is_error) continue;
        const s = repl_glue.parseEvalScore(jout.text) orelse continue;
        if (s <= 0) continue; // skip the total-failure 0 (don't pollute the cell mean), mirroring runEval
        if (s > 100) {
            // Review F8: parseEvalScore does NOT return 0-100 by construction
            // (a stray "score: 9000" line parses as 9000) — guard to [0,100]
            // here, mirroring mainloop /score's explicit rejection. Skip the
            // score AND its paired propose/submit so no s01 > 1 row is ever
            // signed and the submit counter stays in sync with stored scores.
            if (ctx.tracer) |tr| tr.note("fleet", "score skipped: eval score outside [0,100]");
            continue;
        }
        // SCORE SCALE CONTRACT (issue #168 Gap 4): s is guarded to (0,100]
        // above; every score that leaves the client is [0,1], so divide at
        // the emission boundary — s01 is what gets signed and sent.
        const s01 = s / 100.0;
        const pclass = variantProviderClass(ctx, i);
        const genome_fp = promptFingerprint(overrides[i].?);
        const esh_fp = promptFingerprint(raws[i]);
        const genome: []const u8 = &genome_fp;
        const esh: []const u8 = &esh_fp;
        // Truncated to 64 chars and sanitized (tab/newline/CR → ' ', review
        // F7) BEFORE signing (fleetEvent's own niche cap, same as mainloop
        // /score and runEval) so signed bytes equal ingested bytes.
        var niche_buf: [64]u8 = undefined;
        const niche = scoring.sanitizeMetaField(&niche_buf, util.utf8Prefix(niches[i], 64));
        const sig = signScore(genome, "", s01, run_id, "", "", esh, niche, pclass);
        const sig_s: []const u8 = if (scoring.g_score_key != null) &sig else "";
        var provbuf: [512]u8 = undefined;
        // Slot is APPENDED as a 6th component, so a collector indexing 0..4 is
        // unaffected. Advisory like the rest of `prov` (signScore holds the
        // authoritative copies); signing it would need a collector-first deploy.
        const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}", .{ "", "", esh, pclass, niche, slot }) catch "";
        // Genome-send (issue #168 Gap 5), mirroring runEval: ride the variant's
        // text over on a propose (deduped by fingerprint server-side) so the
        // scored cell has a servable genome even when runSub never proposed it.
        // Oversized genomes skip the propose (review F6): a truncated genome
        // would fail the server's fingerprint check and be dropped anyway.
        if (niche.len > 0) {
            if (overrides[i].?.len <= telemetry.Telemetry.max_propose_text)
                t.fleetEvent("propose", niche, genome, "", pclass, "", 0, overrides[i].?)
            else if (ctx.tracer) |tr| tr.note("fleet", "propose skipped: genome > 64KB");
        }
        t.scoreEvent(genome, "", s01, run_id, sig_s, prov);
        t.fleetEvent("submit", niche, genome, "", pclass, esh, 0, "");
    }
}

test "variantJudgePrompt: bounded, names the phase, keeps the score contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big_task = util.repeatBytes("T", 4000);
    const big_out = util.repeatBytes("O", 5000);
    const p = try variantJudgePrompt(a, "code-review", &big_task, &big_out);

    // Names the shared phase so the judge has the tournament context.
    try std.testing.expect(std.mem.indexOf(u8, p, "\"code-review\" phase") != null);
    // Task is prefix-capped and output tail-capped — neither lands verbatim.
    try std.testing.expect(std.mem.indexOf(u8, p, &big_task) == null);
    try std.testing.expect(std.mem.indexOf(u8, p, &big_out) == null);
    // The `score:` contract parseEvalScore depends on is spelled out…
    try std.testing.expect(std.mem.indexOf(u8, p, "score: <N>") != null);
    // …and it round-trips: a judge tail like this parses back to the score.
    try std.testing.expectEqual(@as(?f64, 87), repl_glue.parseEvalScore("ok\nscore: 87"));
}

test "classifyFailure: maps the child's api-error detail to a category + retry-safety" {
    // A stream stall/drop names itself via the error kind — its stale envelope
    // (if any) must not override the transport verdict.
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.StreamStalled, null));
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.StreamDropped, "api error (some_error): stale"));
    // No detail to go on → unknown (and a retry is still allowed to be tried).
    try std.testing.expectEqual(FailKind.unknown, classifyFailure(error.ApiError, null));
    // Real provider envelopes (the shapes sayApiError formats into last_api_error).
    try std.testing.expectEqual(FailKind.quota, classifyFailure(error.ApiError, "api error (rate_limit_error): Number of requests exceeded"));
    try std.testing.expectEqual(FailKind.quota, classifyFailure(error.ApiError, "api error: You have run out of credits or need a Grok subscription."));
    try std.testing.expectEqual(FailKind.auth, classifyFailure(error.ApiError, "api error: The API Key appears to be invalid or may have expired."));
    // invalid_request_error carries "invalid", but a missing-model message is
    // classified as model-availability because that phrase is checked first.
    try std.testing.expectEqual(FailKind.model, classifyFailure(error.ApiError, "api error (invalid_request_error): The model `gpt-foo` does not exist or you do not have access to it."));
    try std.testing.expectEqual(FailKind.invalid, classifyFailure(error.ApiError, "api error (invalid_request_error): This model's maximum context length is 8192 tokens."));
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.ApiError, "network error: HttpConnectionClosing (gave up after 6 attempts)"));

    // Retry-safety contract: transient failures may retry, structural ones must not.
    try std.testing.expect(FailKind.quota.retrySafe());
    try std.testing.expect(FailKind.transport.retrySafe());
    try std.testing.expect(!FailKind.model.retrySafe());
    try std.testing.expect(!FailKind.invalid.retrySafe());
    try std.testing.expect(!FailKind.auth.retrySafe());
}
