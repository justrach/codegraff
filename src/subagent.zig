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
const agentTypePrompt = fleet.agentTypePrompt;
const cards = @import("cards.zig");
const trace = @import("trace.zig");
const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;

/// Spawn a one-level-deep subagent: fresh arena, fresh history, same shared
/// http client and provider. Runs entirely on this pool thread; its own tool
/// calls fan out further via io.async.
pub fn execSubagent(ctx: ToolCtx, input: Value) !ToolOutput {
    if (ctx.from_sub) return .{
        .text = try ctx.gpa.dupe(u8, "subagents cannot spawn subagents — do this work yourself"),
        .is_error = true,
    };
    const label = if (input.object.get("description")) |d| (if (d == .string) d.string else "subagent") else "subagent";
    const prompt = if (input.object.get("prompt")) |p| (if (p == .string) p.string else "") else "";
    if (prompt.len == 0) return .{ .text = try ctx.gpa.dupe(u8, "subagent: missing required \"prompt\" (a self-contained task)"), .is_error = true };
    const sys_override = fleet.resolveOverride(input.object);
    return runSub(ctx, "subagent", label, prompt, sys_override, fleet.resolveNiche(input.object));
}

/// Surface a workflow subagent as a synthetic `tool_call` / `tool_result` on the
/// --json GUI stream so each parallel worker shows as its own live row — the
/// orchestrator's children otherwise run detached (out=null), so the GUI only
/// ever saw the single `workflow` op. Pool-thread safe: serializes on g_gui_mu
/// with Agent.emit (same json stdout writer, g_out). No-op outside --json mode.
fn guiEmit(io: Io, ev: anytype) void {
    if (!main_mod.json_mode) return;
    const w = main_mod.g_out orelse return;
    main_mod.g_gui_mu.lockUncancelable(io);
    defer main_mod.g_gui_mu.unlock(io);
    var s: std.json.Stringify = .{ .writer = w };
    s.write(ev) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

/// Coarse classification of a subagent's underlying API/transport failure, so
/// the tool result can tell the orchestrator what actually broke and whether a
/// retry is worth it — the bare `error.ApiError` propagation carried none of it.
const FailKind = enum {
    quota, // rate limit / out of credits / overloaded
    transport, // network drop / stream stall — usually transient
    model, // model missing / decommissioned / unavailable
    invalid, // bad arguments / unsupported param / context too long
    auth, // key invalid / expired / unauthorized
    unknown, // no detail to classify against

    fn label(self: FailKind) []const u8 {
        return switch (self) {
            .quota => "quota/rate-limit",
            .transport => "transport",
            .model => "model-availability",
            .invalid => "invalid-arguments",
            .auth => "auth",
            .unknown => "unknown",
        };
    }

    /// Is re-running the identical task likely to succeed? Transient failures
    /// (quota backoff, transport flake) yes; a bad model / argument / credential
    /// just fails again until the cause is fixed.
    fn retrySafe(self: FailKind) bool {
        return switch (self) {
            .quota, .transport, .unknown => true,
            .model, .invalid, .auth => false,
        };
    }
};

fn containsAnyCI(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (util.indexOfIgnoreCase(hay, n) != null) return true;
    return false;
}

/// Classify a child turn's failure from its error kind and the child agent's
/// captured `last_api_error` detail (the provider's error type + message, or a
/// transport reason). The detail is the authoritative signal; the error kind
/// only distinguishes a stream stall/drop, whose stale envelope would mislead.
/// Order matters: quota/auth/model phrases are checked before the broad
/// `invalid_request_error` type so a rate-limit or missing-model envelope isn't
/// swallowed as a generic "invalid" just because that type string contains it.
fn classifyFailure(err: anyerror, detail: ?[]const u8) FailKind {
    switch (err) {
        error.StreamStalled, error.StreamDropped => return .transport,
        else => {},
    }
    const msg = detail orelse return .unknown;
    if (containsAnyCI(msg, &.{ "network error", "stream stalled", "stream dropped", "timed out", "connection reset", "connection closed" })) return .transport;
    if (containsAnyCI(msg, &.{ "rate limit", "rate_limit", "quota", "429", "overloaded", "out of credits", "credits", "billing", "too many requests" })) return .quota;
    if (containsAnyCI(msg, &.{ "api key", "unauthorized", "expired", "authentication", "invalid_api_key", "401" })) return .auth;
    if (containsAnyCI(msg, &.{ "does not exist", "not found", "no such model", "decommission", "no longer", "model_not_found", "unavailable", "404" })) return .model;
    if (containsAnyCI(msg, &.{ "context length", "context window", "invalid", "unsupported", "not supported", "must be", "too long", "400", "parameter", "max_tokens", "bad request" })) return .invalid;
    return .unknown;
}

/// Build the is_error tool result for a subagent whose child turn failed at the
/// API/transport layer. Threads the child's own diagnostic — provider status /
/// message, a coarse category, and whether a retry is worth it — up to the
/// orchestrator instead of collapsing to an opaque bare `error: ApiError`.
/// `detail` is the child agent's `last_api_error`; formatted into `gpa` before
/// the child arena that owns it is freed on return.
fn subagentFailure(gpa: Allocator, sub_id: []const u8, err: anyerror, detail: ?[]const u8) ToolOutput {
    const kind = classifyFailure(err, detail);
    const cause = detail orelse @errorName(err);
    const retry = if (kind.retrySafe())
        "retry is likely safe — re-run the same task (after a short backoff for quota/transport)"
    else
        "retry is NOT safe as-is — fix the cause first (switch model, correct arguments, or re-auth)";
    const text = std.fmt.allocPrint(
        gpa,
        "subagent {s} failed before producing a report: {s} [{s} failure]. {s}",
        .{ sub_id, cause, kind.label(), retry },
    ) catch return .{ .is_error = true };
    return .{ .text = text, .is_error = true };
}

/// Run one isolated subagent to completion: fresh arena, fresh history,
/// same shared http client and provider. Runs entirely on this pool thread;
/// its own tool calls fan out further via io.async. `sys_override` swaps the
/// lean default system prompt for a per-child variant (swarm prompt
/// evolution); either way the run is recorded as a trajectory node under
/// the turn that spawned it, with the prompt's fingerprint.
pub fn runSub(ctx: ToolCtx, kind: []const u8, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8) !ToolOutput {
    const gpa = ctx.gpa;
    if (ctx.run_budget) |budget| if (ctx.depth >= budget.max_depth) return .{
        .text = try gpa.dupe(u8, "agent depth limit reached (max depth 1) — do this work in the current agent"),
        .is_error = true,
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = ctx.io,
        .client = ctx.client,
        .provider = ctx.provider,
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = label,
        .out = null,
        .approvals = ctx.approvals,
        .tracer = ctx.tracer,
        .run_budget = ctx.run_budget,
        .depth = ctx.depth + 1,
        .call_kind = if (std.mem.eql(u8, kind, "judge_task"))
            .judge
        else if (std.mem.eql(u8, kind, "workflow_retry"))
            .workflow_retry
        else
            .child,
        .sys_override = sys_override,
    };
    const sub_start = Io.Timestamp.now(ctx.io, .awake);
    if (sys_override) |so| if (telemetry.g_telem) |t| {
        t.countVariant();
        // fleet:propose (docs §9.B) — a niche's elite was mutated into a variant.
        const child_fp = promptFingerprint(so);
        var parent_buf: [16]u8 = undefined;
        var parent_sha: []const u8 = "";
        if (niche.len > 0) if (agentTypePrompt(niche)) |ep| {
            parent_buf = promptFingerprint(ep);
            parent_sha = &parent_buf;
        };
        // Oversized genomes skip the propose (review F6): the server verifies
        // the fingerprint over the carried text, so a truncated genome would
        // be dropped there anyway — and the fingerprint the scores reference
        // stays computed over the full text.
        if (so.len <= telemetry.Telemetry.max_propose_text)
            t.fleetEvent("propose", niche, &child_fp, parent_sha, providerClass(ctx.provider.model), "", 0, so)
        else if (ctx.tracer) |tr| tr.note("fleet", "propose skipped: genome > 64KB");
    };
    // Stable id + sprite for this child's card and its inspectable detail file.
    const ordinal = cards.g_subagent_seq.fetchAdd(1, .monotonic);
    var id_buf: [40]u8 = undefined;
    const sub_id = cards.subagentId(&id_buf, ordinal, label, prompt);
    const sprite = cards.subagentSprite(ordinal);
    cards.subagentLaunchCard(arena, sub_id, sprite, label, kind, prompt);
    // Live agent tree: surface workflow_task children as their own GUI rows.
    const wf_task = std.mem.eql(u8, kind, "workflow_task");
    if (wf_task) guiEmit(ctx.io, .{ .type = "tool_call", .name = "subagent", .input = .{ .description = label } });
    try agent.messages.append(try textMessage(arena, "user", prompt));
    defer agent.tools_used.deinit(gpa);
    const report = agent.runTurn();
    const run_ms: i64 = @intCast(@max(0, sub_start.untilNow(ctx.io, .awake).toMilliseconds()));
    const run_ok = if (report) |r| r.len > 0 else |_| false;
    if (wf_task) guiEmit(ctx.io, .{ .type = "tool_result", .name = "subagent", .is_error = !run_ok });
    const used_tools = agent.tools_used.render(arena);
    const fp = promptFingerprint(agent.systemPrompt());
    if (trace.g_traj) |tj| {
        tj.capturePrompt(fp, agent.systemPrompt());
        tj.node(.{
            .id = tj.nextId(),
            .parent = tj.currentTurn(),
            .kind = kind,
            .label = label,
            .t = tj.elapsedMs(),
            .ms = run_ms,
            .prompt_sha = &fp,
            .prompt_mutated = sys_override != null,
            .niche = niche, // MAP-Elites niche, so a local /agents promote can group scores by it
            .task = util.utf8Prefix(prompt, 160),
            .tools = used_tools,
            .ok = run_ok,
            .context_tokens = agent.effectiveContextTokens(),
        });
    }
    if (telemetry.g_telem) |t| t.runEvent(&fp, sys_override != null, run_ok, run_ms, used_tools);
    // A child API/transport failure used to collapse to a bare "error: ApiError"
    // once execTool's catch ran failure() on the propagated error. Instead
    // surface the child's own diagnostic (provider status/message + a coarse
    // category + retry guidance) as an is_error result, duped into gpa before
    // the child arena that owns last_api_error is freed on return.
    const text = report catch |err|
        return subagentFailure(gpa, sub_id, err, agent.last_api_error);
    const empty = text.len == 0;
    const report_body = if (empty) "subagent finished without a report" else text;
    // Persist the full report + metadata so it can be inspected from the
    // terminal, then render the completion card with the inspect: path.
    const detail = cards.writeSubagentDetail(ctx.io, arena, sub_id, label, kind, prompt, report_body, !empty, run_ms, used_tools);
    cards.subagentDoneCard(arena, sub_id, sprite, label, !empty, run_ms, used_tools, detail);
    if (empty) return .{ .text = try gpa.dupe(u8, report_body), .is_error = true };
    // Append the inspect: path so the orchestrator can cite the detail file.
    if (detail) |p|
        return .{ .text = try std.fmt.allocPrint(gpa, "{s}\n\n[subagent {s} · inspect: {s}]", .{ text, sub_id, p }) };
    return .{ .text = try gpa.dupe(u8, text) };
}

/// One task inside a workflow phase; never throws, suitable for io.async.
/// `niche` is the task's MAP-Elites cell, threaded through so runSub's
/// fleet:propose — and scoreVariants' submit — tag the variant's genome.
pub fn workflowTask(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8) ToolOutput {
    return runSub(ctx, "workflow_task", label, prompt, sys_override, niche) catch |err| failure(ctx.gpa, err);
}

/// A second workflow attempt has its own explicit budget kind. It still shares
/// the same invocation-wide atomic ceiling and concurrency limiter.
pub fn workflowRetryTask(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8) ToolOutput {
    return runSub(ctx, "workflow_retry", label, prompt, sys_override, niche) catch |err| failure(ctx.gpa, err);
}

/// The --judge LLM-as-judge run (see runEval in main): an isolated subagent
/// scores the work against the rubric and ends with a `score:` line. Mirrors
/// workflowTask — a thin runSub wrapper — so the eval handler can io.async it
/// on a pool thread.
pub fn judgeTask(ctx: ToolCtx, prompt: []const u8) ToolOutput {
    return runSub(ctx, "judge_task", "judge", prompt, null, "") catch |err| failure(ctx.gpa, err);
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

    // All fallible work (prompt builds) before any future spawns, so an early
    // return can never abandon a running judge.
    const jprompts = arena.alloc([]const u8, vn) catch return;
    for (jprompts, 0..) |*jp, k| {
        const i = vidx[k];
        jp.* = variantJudgePrompt(arena, title, prompts[i], outputs[i].text) catch return;
    }
    const jfuts = arena.alloc(Io.Future(ToolOutput), vn) catch return;
    for (jfuts, jprompts) |*jf, jp| jf.* = ctx.io.async(judgeTask, .{ ctx, jp });

    const pclass = providerClass(ctx.provider.model);
    const run_id: []const u8 = &scoring.g_run_id;
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
        const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ "", "", esh, pclass, niche }) catch "";
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
