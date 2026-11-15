//! Same-conversation Phase 1 (Plan) -> Phase 2 (Execute) turn driver.
//!
//! Coordinates read-only planning on the user's root model, in-place seat
//! switching to the resolved cheaper executor model, bounded [plan review]
//! escalations back to the planner, and guaranteed state restoration.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const Provider = @import("provider.zig").Provider;
const providers = @import("providers.zig");
const Keys = @import("provider.zig").Keys;
const orchestrator = @import("orchestrator_mode.zig");
const messages = @import("messages.zig");
const named_work = @import("named_work.zig");
const session_wake = @import("session_wake.zig");
const engine_sink = @import("engine_sink.zig");
const orch = @import("orchestration_policy.zig");
const orch_rows = @import("orchestration_rows.zig");
const trace = @import("trace.zig");

pub const max_replans: u8 = 2;

pub const SinglePhaseFn = *const fn (root: *Agent, keys: *Keys, arena: Allocator, out: ?*Io.Writer) anyerror![]const u8;

fn appendHarnessNotice(root: *Agent, text: []const u8) !void {
    const alloc = root.historyAlloc();
    var msg = try named_work.userNudge(alloc, root.provider.kind, text);
    try msg.object.put(alloc, session_wake.origin_key, .{ .string = "notification" });
    try root.messages.append(msg);
}

fn emitStatus(root: *Agent, out: ?*Io.Writer, text: []const u8) void {
    engine_sink.forSession(root, out).emit(root.io, .{ .session_notice = .{ .text = text, .tone = .dim } });
}

fn switchSeatInPlace(root: *Agent, arena: Allocator, target: Provider, saved_fallback_active: bool) !void {
    root.closeCodexWs();
    _ = try providers.applyProviderInner(root, arena, target, false);
    root.fallback_active = saved_fallback_active;
}

fn isOrchestratorNotice(item: std.json.Value) bool {
    if (item != .object) return false;
    const content = item.object.get("content") orelse return false;
    const text: []const u8 = switch (content) {
        .string => |s| s,
        .array => |arr| blk: {
            for (arr.items) |blk_val| {
                if (blk_val != .object) continue;
                const tx = blk_val.object.get("text") orelse continue;
                if (tx == .string) break :blk tx.string;
            }
            return false;
        },
        else => return false,
    };
    return std.mem.startsWith(u8, text, "[orchestrator mode ") or
        std.mem.startsWith(u8, text, "[plan review]");
}

fn isWakeOrSteerOrigin(item: std.json.Value) bool {
    if (item != .object) return false;
    const v = item.object.get(session_wake.origin_key) orelse return false;
    return v == .string and (std.mem.eql(u8, v.string, "notification") or
        std.mem.eql(u8, v.string, session_wake.steer_origin));
}

fn activeAutonomousGoal(root: *const Agent) bool {
    const g = root.goal orelse return false;
    return g.status == .active and !g.standing;
}

fn isAutonomousOrNoticeTurn(items: []const std.json.Value, raw_user_text: []const u8) bool {
    if (std.mem.indexOf(u8, raw_user_text, "[harness note: this is an autonomous run.") != null or
        std.mem.indexOf(u8, raw_user_text, "[pace:") != null) return true;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        // Skip orchestrator's own internal phase/review directives left in history.
        if (isOrchestratorNotice(items[i])) continue;
        if (isWakeOrSteerOrigin(items[i])) return true;
        if (messages.userPromptText(items[i]) != null) return false;
    }
    return false;
}

pub fn run(root: *Agent, keys: *Keys, arena: Allocator, out: ?*Io.Writer, singlePhase: SinglePhaseFn) anyerror![]const u8 {
    if (root.fallback_blocked or root.sub or main_mod.plan_mode or root.text_only or
        root.output_schema != null or root.review_mode or orchestrator.g_mode == .off or
        activeAutonomousGoal(root))
    {
        return singlePhase(root, keys, arena, out);
    }

    const exec_provider = orchestrator.resolveExecutor(root.provider, root.reasoning) orelse {
        return singlePhase(root, keys, arena, out);
    };
    const raw_user_text = messages.latestUserText(root.messages.items);
    if (isAutonomousOrNoticeTurn(root.messages.items, raw_user_text)) {
        return singlePhase(root, keys, arena, out);
    }
    const user_text = std.mem.trim(u8, orchestrator.stripHarnessNotes(raw_user_text), " \t\r\n");
    if (orchestrator.g_mode == .auto and !orchestrator.shouldPlanAuto(root, user_text)) {
        return singlePhase(root, keys, arena, out);
    }

    const saved_planner = root.provider;
    const saved_plan_mode = main_mod.plan_mode;
    const saved_fallback_active = root.fallback_active;
    const saved_subagent_provider = root.subagent_provider;
    const task_key = orchestrator.resolveTaskKey(root, user_text);
    const remaining = if (root.run_budget) |b| b.remaining() else std.math.maxInt(u64);
    const calls_start = if (root.run_budget) |b| b.used() else 0;
    const decided_source: orch.Source = if (orchestrator.g_mode == .on) .explicit else .bootstrap;
    orch_rows.emitDecision(.{
        .key = task_key,
        .arm = .baton,
        .source = decided_source,
        .remaining = remaining,
    });
    orch_rows.setPending(task_key, .baton, decided_source, calls_start);

    var outcome_flushed = false;
    errdefer if (!outcome_flushed) orch_rows.clearPending();

    defer {
        orchestrator.g_phase = .none;
        orchestrator.handoff_active = false;
        orchestrator.g_handoff_plan = null;
        orchestrator.g_replan_reason = null;
        main_mod.plan_mode = saved_plan_mode;
        if (!std.mem.eql(u8, root.provider.id, saved_planner.id) or
            !std.mem.eql(u8, root.provider.model, saved_planner.model))
        {
            root.closeCodexWs();
            _ = providers.applyProviderInner(root, arena, saved_planner, false) catch {};
        }
        root.fallback_active = saved_fallback_active;
        root.subagent_provider = saved_subagent_provider;
        root.invalidateRootTools();
    }

    // Phase 1: read-only planning on the root frontier seat.
    orchestrator.handoff_active = true;
    orchestrator.g_phase = .planning;
    orchestrator.g_handoff_plan = null;
    orchestrator.g_replan_reason = null;
    main_mod.plan_mode = true;
    root.invalidateRootTools();

    const p1_banner = try std.fmt.allocPrint(
        arena,
        "[orchestrator] phase 1: planning on {s} (executor: {s})",
        .{ saved_planner.model, exec_provider.model },
    );
    emitStatus(root, out, p1_banner);
    if (root.tracer) |tr| tr.note("orchestrator_phase", p1_banner);

    try appendHarnessNotice(root,
        \\[orchestrator mode — phase 1: plan]
        \\Investigate read-only first using read/search/check tools.
        \\- If code changes or mutating commands are needed, call `exit_plan_mode(plan)` alone with concrete file paths, exact edits, and verification steps.
        \\- If this is purely a question requiring no edits or mutating commands, answer directly without calling `exit_plan_mode`.
    );

    const phase1_text = try singlePhase(root, keys, arena, out);
    var current_plan = orchestrator.g_handoff_plan orelse {
        orch_rows.clearPending();
        outcome_flushed = true;
        return phase1_text;
    };

    var replans_used: u8 = 0;
    while (true) {
        // Phase 2: hand execution baton to cheaper seat in-place.
        orchestrator.g_phase = .executing;
        orchestrator.g_replan_reason = null;
        main_mod.plan_mode = false;
        try switchSeatInPlace(root, arena, exec_provider, saved_fallback_active);

        const p2_banner = try std.fmt.allocPrint(
            arena,
            "[orchestrator] handing off plan -> {s}",
            .{exec_provider.model},
        );
        emitStatus(root, out, p2_banner);
        if (root.tracer) |tr| tr.note("orchestrator_handoff", p2_banner);

        const exec_note = try std.fmt.allocPrint(
            arena,
            \\[orchestrator mode — phase 2: execute]
            \\Carry out the approved plan below verbatim, make the edits, and verify with the relevant tests/commands.
            \\If a step fails repeatedly or hits an unresolvable missing assumption, call `enter_plan_mode(reason)` alone to escalate back for replanning.
            \\
            \\Approved plan:
            \\{s}
        ,
            .{current_plan},
        );
        try appendHarnessNotice(root, exec_note);

        const phase2_text = try singlePhase(root, keys, arena, out);
        const blocker = orchestrator.g_replan_reason orelse {
            if (root.eval_cmd == null) {
                orch_rows.flushPending(1.0, if (root.run_budget) |b| b.used() else 0, 0, false, "");
            } else {
                orch_rows.clearPending();
            }
            outcome_flushed = true;
            return phase2_text;
        };

        if (replans_used >= max_replans) {
            try switchSeatInPlace(root, arena, saved_planner, saved_fallback_active);
            orchestrator.g_phase = .executing;
            main_mod.plan_mode = false;
            emitStatus(root, out, "[orchestrator] replan cap reached; finishing on planner seat");
            const cap_note = try std.fmt.allocPrint(
                arena,
                \\[orchestrator mode — final pass]
                \\Replan limit ({d}) reached after escalation:
                \\{s}
                \\Finish or report exact blockers directly.
            ,
                .{ max_replans, blocker },
            );
            try appendHarnessNotice(root, cap_note);
            const final_text = try singlePhase(root, keys, arena, out);
            if (root.eval_cmd == null) {
                orch_rows.flushPending(1.0, if (root.run_budget) |b| b.used() else 0, 0, false, "");
            } else {
                orch_rows.clearPending();
            }
            outcome_flushed = true;
            return final_text;
        }

        replans_used += 1;
        orchestrator.g_phase = .planning;
        orchestrator.g_handoff_plan = null;
        main_mod.plan_mode = true;
        try switchSeatInPlace(root, arena, saved_planner, saved_fallback_active);

        const esc_banner = try std.fmt.allocPrint(
            arena,
            "[orchestrator] escalating to {s} for plan review ({d}/{d})",
            .{ saved_planner.model, replans_used, max_replans },
        );
        emitStatus(root, out, esc_banner);
        if (root.tracer) |tr| tr.note("orchestrator_replan", esc_banner);

        const review_note = try std.fmt.allocPrint(
            arena,
            \\[plan review]
            \\Execution escalated back with blocker:
            \\{s}
            \\Inspect the current workspace state read-only and call `exit_plan_mode(plan)` with a revised plan to resume execution, or answer directly if blocked on user input.
        ,
            .{blocker},
        );
        try appendHarnessNotice(root, review_note);

        const replan_text = try singlePhase(root, keys, arena, out);
        current_plan = orchestrator.g_handoff_plan orelse {
            orch_rows.clearPending();
            outcome_flushed = true;
            return replan_text;
        };
    }
}
