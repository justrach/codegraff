//! One isolated subagent run: provider selection, failure classification,
//! worktree lifecycle, usage emission, and trajectory recording.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const util = @import("util.zig");
const goal_pacing = @import("goal_pacing.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const telemetry = @import("telemetry.zig");
const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;
const providerClass = scoring.providerClass;
const fleet = @import("fleet.zig");
const Isolation = fleet.Isolation;
const learning_privacy = @import("learning_privacy.zig");
const jobs = @import("jobs.zig");
const cards = @import("cards.zig");
const trace = @import("trace.zig");
const textMessage = @import("messages.zig").textMessage;

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

pub const FailKind = enum {
    quota,
    transport,
    model,
    invalid,
    auth,
    unknown,

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

    pub fn retrySafe(self: FailKind) bool {
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

pub fn classifyFailure(err: anyerror, detail: ?[]const u8) FailKind {
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

/// Advisory text appended to a subagentFailure message when the classified
/// cause is transient (quota/transport/unknown) — the model sees this exact
/// string, and failureAllowsRetry below keys off it, so keep them in sync.
pub const retry_ok_note = "retry is likely safe — re-run the same task (after a short backoff for quota/transport)";
/// Advisory text appended when the cause is NOT transient (model/invalid/
/// auth) — retrying would just double the cost of a broken run for zero
/// chance of success. failureAllowsRetry keys off this exact string.
pub const retry_unsafe_note = "retry is NOT safe as-is — fix the cause first (switch model, correct arguments, or re-auth)";

fn subagentFailure(gpa: Allocator, sub_id: []const u8, err: anyerror, detail: ?[]const u8) ToolOutput {
    const kind = classifyFailure(err, detail);
    const cause = detail orelse @errorName(err);
    const retry = if (kind.retrySafe()) retry_ok_note else retry_unsafe_note;
    const text = std.fmt.allocPrint(
        gpa,
        "subagent {s} failed before producing a report: {s} [{s} failure]. {s}",
        .{ sub_id, cause, kind.label(), retry },
    ) catch return .{ .is_error = true };
    return .{ .text = text, .is_error = true };
}

/// Whether a workflow retry site should re-run a failed task. Failures that
/// went through subagentFailure carry retry_unsafe_note when the harness's
/// own classification (FailKind.retrySafe) already ruled retrying out — auth
/// or an invalid/unavailable model — so retrying the whole phase would only
/// double the cost of a broken run for zero chance of success. Any failure
/// text that did NOT come from subagentFailure (an empty report, an
/// isolation-setup failure) carries no marker and keeps retrying, since those
/// are exactly the transient cases retry exists for.
pub fn failureAllowsRetry(text: []const u8) bool {
    return std.mem.indexOf(u8, text, retry_unsafe_note) == null;
}

pub fn childProvider(root: Provider, pinned: ?Provider, allow_cross_provider: bool) Provider {
    const child = pinned orelse return root;
    return if (std.mem.eql(u8, child.id, root.id) or allow_cross_provider) child else root;
}

/// Capability tier ("frontier" | "mid" | "small") of the model that ran variant
/// `i` of a workflow phase — the provider-class axis of the MAP-Elites cell.
///
/// Today every child in a phase resolves through the same session-level
/// subagent provider, so this returns the same value for every `i`. It is
/// written per-variant regardless, because this is exactly the seam that
/// per-persona / per-spawn model pins (#292) extend: with the class hoisted to
/// a phase-level constant, the first heterogeneous fan-out would keep reporting
/// the ROOT's class for every variant and quietly file model effects under the
/// prompt genome. Keeping the lookup per-variant means #292 changes this one
/// function instead of having to notice a stale constant.
///
/// NOTE (#291): providerClass cannot currently distinguish gpt-5.6-sol from
/// gpt-5.6-terra/-luna — all three classify as "frontier". Until that is
/// resolved this axis cannot separate ladder rungs, and the matched-tournament
/// guard in scoreVariants is correspondingly blind to a rung-only difference.
pub fn variantProviderClass(ctx: tools.ToolCtx, i: usize) []const u8 {
    _ = i; // per-variant model pins land in #292
    return scoring.providerClass(childProvider(ctx.provider, ctx.subagent_provider, ctx.subagent_cross_provider).model);
}

pub const AgentUsage = struct {
    duration_ms: u64 = 0,
    tool_calls: u32 = 0,
    context_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
};

const AgentUsageEvent = struct {
    type: []const u8 = "agent_usage",
    id: []const u8,
    ok: bool,
    duration_ms: u64,
    tool_calls: u32,
    context_tokens: u64,
    cache_read_tokens: u64,
};

fn agentUsageEvent(sub_id: []const u8, ok: bool, usage: AgentUsage) AgentUsageEvent {
    return .{
        .id = sub_id,
        .ok = ok,
        .duration_ms = usage.duration_ms,
        .tool_calls = usage.tool_calls,
        .context_tokens = usage.context_tokens,
        .cache_read_tokens = usage.cache_read_tokens,
    };
}

pub const SubRun = struct { output: ToolOutput, usage: AgentUsage };

pub fn runSub(ctx: ToolCtx, kind: []const u8, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8, isolation: Isolation, isolation_fallback: bool) !SubRun {
    const gpa = ctx.gpa;
    if (ctx.run_budget) |budget| if (ctx.depth >= budget.max_depth) return .{
        .output = .{
            .text = try gpa.dupe(u8, "agent depth limit reached (max depth 1) — do this work in the current agent"),
            .is_error = true,
        },
        .usage = .{},
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const child_provider = childProvider(ctx.provider, ctx.subagent_provider, ctx.subagent_cross_provider);

    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = ctx.io,
        .client = ctx.client,
        .provider = child_provider,
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = label,
        .out = null,
        .approvals = ctx.approvals,
        .tracer = ctx.tracer,
        .run_budget = ctx.run_budget,
        .loop_deadline_ms = ctx.loop_deadline_ms, // a timed run's deadline reaches grandchildren too, not just depth 1
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
        if (fleet.promptIsPublic(so)) _ = learning_privacy.approveTemplate(ctx.io, so);
        t.countVariant();
        const child_fp = promptFingerprint(so);
        var parent_buf: [16]u8 = undefined;
        var parent_sha: []const u8 = "";
        if (niche.len > 0) if (fleet.agentTypePrompt(niche)) |ep| {
            parent_buf = promptFingerprint(ep);
            parent_sha = &parent_buf;
        };
        if (so.len <= telemetry.Telemetry.max_propose_text)
            t.fleetEvent("propose", niche, &child_fp, parent_sha, providerClass(agent.provider.model), "", 0, so)
        else if (ctx.tracer) |tr| tr.note("fleet", "propose skipped: genome > 64KB");
    };

    const ordinal = cards.g_subagent_seq.fetchAdd(1, .monotonic);
    var id_buf: [40]u8 = undefined;
    const sub_id = cards.subagentId(&id_buf, ordinal, label, prompt);
    const sprite = cards.subagentSprite(ordinal);
    cards.subagentLaunchCard(arena, sub_id, sprite, label, kind, prompt);

    var wt: ?jobs.AgentWorktree = null;
    var isolation_note: []const u8 = "";
    if (isolation == .worktree) {
        if (jobs.agentWorktreeCreate(gpa, ctx.io, arena, sub_id)) |created| {
            wt = created;
        } else |err| {
            if (!isolation_fallback) return .{
                .output = .{ .text = try gpa.dupe(u8, jobs.isolationFailureText(err)), .is_error = true },
                .usage = .{},
            };
            isolation_note = "\n\n[note: isolation:\"worktree\" failed and fell back to the shared working tree — isolation_fallback:true allowed it]";
        }
    }
    agent.agent_cwd = if (wt) |w| w.path else null;

    const wf_task = std.mem.eql(u8, kind, "workflow_task");
    if (wf_task) guiEmit(ctx.io, .{ .type = "tool_call", .name = "subagent", .input = .{ .description = label } });
    // A /loop deadline on the parent reaches the child as guidance on its own
    // task prompt (goal_pacing.childTaskPrompt): same absolute deadline, minus
    // the margin the parent needs to integrate the result. No-op without one.
    const task_prompt = try goal_pacing.childTaskPrompt(arena, prompt, ctx.loop_deadline_ms, util.unixMs(ctx.io));
    try agent.messages.append(try textMessage(arena, "user", task_prompt));
    defer agent.tools_used.deinit(gpa);
    const report = agent.runTurn();
    const run_ms: i64 = @intCast(@max(0, sub_start.untilNow(ctx.io, .awake).toMilliseconds()));
    const run_ok = if (report) |r| r.len > 0 else |_| false;
    if (wf_task) guiEmit(ctx.io, .{ .type = "tool_result", .name = "subagent", .is_error = !run_ok });
    const used_tools = agent.tools_used.render(arena);
    const usage: AgentUsage = .{
        .duration_ms = @intCast(run_ms),
        .tool_calls = @intCast(agent.tools_used.count()),
        .context_tokens = agent.effectiveContextTokens(),
        .cache_read_tokens = agent.last_cache_read,
    };
    guiEmit(ctx.io, agentUsageEvent(sub_id, run_ok, usage));
    const fp = promptFingerprint(agent.systemPrompt());
    if (trace.g_traj) |tj| {
        tj.capturePrompt(fp, agent.systemPrompt());
        tj.node(.{
            .id = tj.nextId(),
            .parent = tj.currentTurn(),
            .kind = kind,
            .label = label,
            .provider = agent.provider.id,
            .model = agent.provider.model,
            .t = tj.elapsedMs(),
            .ms = run_ms,
            .prompt_sha = &fp,
            .prompt_mutated = sys_override != null,
            .niche = niche,
            .task = util.utf8Prefix(prompt, 160),
            .tools = used_tools,
            .ok = run_ok,
            .context_tokens = agent.effectiveContextTokens(),
        });
    }
    if (telemetry.g_telem) |t| t.runEvent(&fp, sys_override != null, run_ok, run_ms, used_tools);
    const text = report catch |err| {
        var out = subagentFailure(gpa, sub_id, err, agent.last_api_error);
        if (wt) |w| {
            const combined = std.fmt.allocPrint(gpa, "{s}\n\n[worktree left in place after failure — path: {s}, branch: {s}]", .{ out.text, w.path, w.branch }) catch return .{ .output = out, .usage = usage };
            gpa.free(out.text);
            out.text = combined;
        }
        return .{ .output = out, .usage = usage };
    };
    const empty = text.len == 0;
    const report_body = if (empty) "subagent finished without a report" else text;
    const detail = cards.writeSubagentDetail(ctx.io, arena, sub_id, label, kind, prompt, report_body, !empty, run_ms, used_tools);
    cards.subagentDoneCard(arena, sub_id, sprite, label, !empty, run_ms, used_tools, detail);

    var extra: []const u8 = isolation_note;
    var extra_owned = false;
    if (wt) |w| {
        const outcome = jobs.agentWorktreeFinish(gpa, ctx.io, w);
        if (outcome.kept) {
            extra = std.fmt.allocPrint(gpa, "\n\n[worktree kept (has changes) — path: {s}, branch: {s}]", .{ w.path, w.branch }) catch "";
            extra_owned = extra.len > 0;
        }
    }
    defer if (extra_owned) gpa.free(extra);

    if (empty) return .{
        .output = .{ .text = try std.fmt.allocPrint(gpa, "{s}{s}", .{ report_body, extra }), .is_error = true },
        .usage = usage,
    };
    if (detail) |p| return .{
        .output = .{ .text = try std.fmt.allocPrint(gpa, "{s}\n\n[subagent {s} · inspect: {s}]{s}", .{ text, sub_id, p, extra }) },
        .usage = usage,
    };
    return .{ .output = .{ .text = try std.fmt.allocPrint(gpa, "{s}{s}", .{ text, extra }) }, .usage = usage };
}

test "child model pin crosses the current root provider only with consent" {
    const codex_root: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5.6-sol", .context = 272_000 };
    const terra: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5.6-terra", .context = 272_000 };
    const anthropic_root: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = "claude", .context = 200_000 };
    try std.testing.expectEqualStrings("gpt-5.6-terra", childProvider(codex_root, terra, false).model);
    try std.testing.expectEqualStrings("claude", childProvider(anthropic_root, terra, false).model);
    try std.testing.expectEqualStrings("gpt-5.6-terra", childProvider(anthropic_root, terra, true).model);
}

test "agentUsageEvent maps AgentUsage fields onto the wire event" {
    const ev = agentUsageEvent("sa-007-abcd", true, .{ .duration_ms = 4110, .tool_calls = 6, .context_tokens = 1820, .cache_read_tokens = 340 });
    try std.testing.expectEqualStrings("agent_usage", ev.type);
    try std.testing.expectEqualStrings("sa-007-abcd", ev.id);
    try std.testing.expect(ev.ok);
    try std.testing.expectEqual(@as(u64, 4110), ev.duration_ms);
    try std.testing.expectEqual(@as(u32, 6), ev.tool_calls);
    try std.testing.expectEqual(@as(u64, 1820), ev.context_tokens);
    try std.testing.expectEqual(@as(u64, 340), ev.cache_read_tokens);
    const failed = agentUsageEvent("sa-008-efgh", false, .{});
    try std.testing.expect(!failed.ok);
    try std.testing.expectEqual(@as(u64, 0), failed.duration_ms);
}

test "failureAllowsRetry keys off the harness's own retry-safety classification" {
    const gpa = std.testing.allocator;

    // A real auth failure: subagentFailure classifies it .auth (retrySafe:
    // false) and appends retry_unsafe_note — the gate must block a retry.
    const auth = subagentFailure(gpa, "sa-001", error.Unexpected, "401 unauthorized: invalid_api_key");
    defer gpa.free(auth.text);
    try std.testing.expect(!failureAllowsRetry(auth.text));

    // A real transport/transient failure: classifies .transport (retrySafe:
    // true) and appends retry_ok_note — the gate must keep allowing retries.
    const transient = subagentFailure(gpa, "sa-002", error.StreamStalled, null);
    defer gpa.free(transient.text);
    try std.testing.expect(failureAllowsRetry(transient.text));

    // A failure text with no subagentFailure marker at all (e.g. the
    // empty-report path, or an isolation-setup failure) — no marker means no
    // classification was made, so it must keep retrying like before this fix.
    try std.testing.expect(failureAllowsRetry("subagent finished without a report"));
}
