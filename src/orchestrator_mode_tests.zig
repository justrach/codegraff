//! Unit tests for Orchestrator Mode: mode parsing, settings/env/CLI precedence,
//! same-wire executor resolution, auto-gating, meta-tool overlay/batch rules,
//! same-chat Phase 1 -> Phase 2 baton handoff & replan caps, and ACP surface.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const provider_mod = @import("provider.zig");
const Keys = provider_mod.Keys;
const Provider = provider_mod.Provider;
const schema = @import("schema.zig");
const tools = @import("tools.zig");
const orchestrator = @import("orchestrator_mode.zig");
const orchestrator_turn = @import("orchestrator_turn.zig");
const orch = @import("orchestration_policy.zig");
const orch_rows = @import("orchestration_rows.zig");
const acp_orch = @import("acp_orchestrator.zig");
const acp_models = @import("acp_models_rpc.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const proto = @import("acp_protocol.zig");
const session_wake = @import("session_wake.zig");
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;

const SavedState = struct {
    mode: orchestrator.Mode,
    cli: bool,
    env: bool,
    phase: orchestrator.Phase,
    handoff: bool,
    plan: ?[]const u8,
    reason: ?[]const u8,
    plan_mode: bool,
    arms: []const orch.ArmObs,

    fn save() SavedState {
        return .{
            .mode = orchestrator.g_mode,
            .cli = orchestrator.cli_set,
            .env = orchestrator.env_set,
            .phase = orchestrator.g_phase,
            .handoff = orchestrator.handoff_active,
            .plan = orchestrator.g_handoff_plan,
            .reason = orchestrator.g_replan_reason,
            .plan_mode = main_mod.plan_mode,
            .arms = orch.g_arms,
        };
    }

    fn restore(self: SavedState) void {
        orchestrator.g_mode = self.mode;
        orchestrator.cli_set = self.cli;
        orchestrator.env_set = self.env;
        orchestrator.g_phase = self.phase;
        orchestrator.handoff_active = self.handoff;
        orchestrator.g_handoff_plan = self.plan;
        orchestrator.g_replan_reason = self.reason;
        main_mod.plan_mode = self.plan_mode;
        orch.g_arms = self.arms;
        orch_rows.clearPending();
    }
};

test "Mode.parse, compiled default, and CLI > env > settings precedence" {
    const saved = SavedState.save();
    defer saved.restore();

    try std.testing.expectEqual(orchestrator.Mode.auto, orchestrator.default_mode);
    try std.testing.expectEqual(orchestrator.Mode.off, orchestrator.Mode.parse("off").?);
    try std.testing.expectEqual(orchestrator.Mode.off, orchestrator.Mode.parse("FALSE").?);
    try std.testing.expectEqual(orchestrator.Mode.off, orchestrator.Mode.parse("0").?);
    try std.testing.expectEqual(orchestrator.Mode.auto, orchestrator.Mode.parse(" auto ").?);
    try std.testing.expectEqual(orchestrator.Mode.on, orchestrator.Mode.parse("on").?);
    try std.testing.expectEqual(orchestrator.Mode.on, orchestrator.Mode.parse("true").?);
    try std.testing.expectEqual(orchestrator.Mode.on, orchestrator.Mode.parse("1").?);
    try std.testing.expect(orchestrator.Mode.parse("invalid") == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".harness");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = orchestrator.settings_path,
        .data = "{\"allow\":[\"git status\"],\"yolo\":false}\n",
    });

    orchestrator.g_mode = .off;
    orchestrator.cli_set = false;
    orchestrator.env_set = false;
    try orchestrator.saveSettingsAt(std.testing.io, tmp.dir, arena, .on);
    try std.testing.expectEqual(orchestrator.Mode.on, orchestrator.g_mode);

    const saved_raw = try tmp.dir.readFileAlloc(std.testing.io, orchestrator.settings_path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, saved_raw, "\"allow\":[\"git status\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved_raw, "\"orchestrator\":\"on\"") != null);

    // Settings load updates mode when neither CLI nor env was explicitly set.
    orchestrator.g_mode = .off;
    orchestrator.loadSettingsFrom(std.testing.io, tmp.dir, arena);
    try std.testing.expectEqual(orchestrator.Mode.on, orchestrator.g_mode);

    // Env overrides settings, and blocks subsequent settings overwrite.
    orchestrator.applyEnv("off");
    orchestrator.loadSettingsFrom(std.testing.io, tmp.dir, arena);
    try std.testing.expectEqual(orchestrator.Mode.off, orchestrator.g_mode);

    // CLI overrides both env and settings.
    orchestrator.setFromCli(.auto);
    orchestrator.applyEnv("on");
    orchestrator.loadSettingsFrom(std.testing.io, tmp.dir, arena);
    try std.testing.expectEqual(orchestrator.Mode.auto, orchestrator.g_mode);
}

test "resolveExecutor keeps same provider/wire, descends 1 rung, and excludes bottom/single seats" {
    const Case = struct {
        id: []const u8,
        kind: Provider.Kind,
        model: []const u8,
        want: ?[]const u8,
    };
    const cases = [_]Case{
        .{ .id = "codex", .kind = .responses, .model = "gpt-6-astra", .want = "gpt-6-sol" },
        .{ .id = "codex", .kind = .responses, .model = "gpt-6-sol", .want = "gpt-6-luna" },
        .{ .id = "codex", .kind = .responses, .model = "gpt-6-luna", .want = null },
        .{ .id = "chatgpt-new", .kind = .responses, .model = "gpt-6-astra", .want = "gpt-6.1-sol" },
        .{ .id = "anthropic", .kind = .anthropic, .model = "claude-opus-5-5", .want = "claude-sonnet-5-5" },
        .{ .id = "anthropic", .kind = .anthropic, .model = "claude-fable-5-2", .want = "claude-sonnet-5-5" },
        .{ .id = "anthropic", .kind = .anthropic, .model = "claude-sonnet-5-5", .want = "claude-haiku-5-5" },
        .{ .id = "anthropic", .kind = .anthropic, .model = "claude-haiku-5-5", .want = null },
        .{ .id = "claude-agent", .kind = .anthropic, .model = "claude-opus-5-5", .want = "claude-sonnet-5-5" },
        .{ .id = "codegraff", .kind = .anthropic, .model = "claude-opus-5-5", .want = "claude-sonnet-5-5" },
        .{ .id = "codegraff", .kind = .responses, .model = "gpt-6-astra", .want = "gpt-6-sol" },
        .{ .id = "codegraff", .kind = .openai, .model = "gemini-4-argon", .want = "gemini-3.8-flash" },
        .{ .id = "codegraff", .kind = .openai, .model = "deepseek-v4-pro", .want = "deepseek-v4-flash" },
        .{ .id = "xiaomi", .kind = .openai, .model = "mimo-v2.6-pro", .want = "mimo-v2.6-flash" },
        .{ .id = "xai", .kind = .openai, .model = "grok-4.7", .want = null },
        .{ .id = "kimi", .kind = .openai, .model = "kimi-for-coding", .want = null },
    };
    for (cases) |tc| {
        const p: Provider = .{ .id = tc.id, .kind = tc.kind, .auth = .bearer, .url = "", .api_key = "k", .model = tc.model, .context = 200_000 };
        const exec = orchestrator.resolveExecutor(p, .high);
        if (tc.want) |expected| {
            try std.testing.expect(exec != null);
            try std.testing.expectEqualStrings(expected, exec.?.model);
            try std.testing.expectEqualStrings(tc.id, exec.?.id);
            try std.testing.expectEqual(tc.kind, exec.?.kind);
        } else {
            try std.testing.expect(exec == null);
        }
    }
    const custom: Provider = .{ .id = "custom", .kind = .openai, .auth = .bearer, .url = "http://127.0.0.1:8000/v1", .api_key = "k", .model = "gpt-6-astra", .context = 200_000 };
    try std.testing.expect(orchestrator.resolveExecutor(custom, .high) == null);
}

test "shouldPlanAuto skips Q&A and trivial edits, triggers on multi-file tasks, honors learned R0" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");

    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, ""));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "What does DEFAULT_POLICY contain?"));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "Fix off-by-one in app/pagination.py"));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "Now implement the change"));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "Fix typo\n\n[standing state (harness-kept, survives context rewrites): refactor pipeline across multiple files]"));
    try std.testing.expect(orchestrator.shouldPlanAuto(&root, "Implement a token-bucket rate limiter with per-route burst overrides and unit tests"));

    const multi = "Refactor sched/scheduler.py across sched/dag.py and sched/runner.py and update tests";
    try std.testing.expect(orchestrator.shouldPlanAuto(&root, multi));

    const key = orchestrator.resolveTaskKey(&root, multi);
    var r0_calls: [orch.max_call_samples]u32 = @splat(0);
    r0_calls[0..4].* = .{ 5, 5, 5, 5 };
    var baton_calls: [orch.max_call_samples]u32 = @splat(0);
    baton_calls[0..4].* = .{ 10, 10, 10, 10 };
    const r0_stat: orch.ArmObs = .{ .key = key, .arm = .R0, .n = 4, .sum_score = 4.0, .landed_n = 4, .calls = r0_calls, .n_calls = 4 };
    const baton_stat: orch.ArmObs = .{ .key = key, .arm = .baton, .n = 4, .sum_score = 2.0, .landed_n = 4, .calls = baton_calls, .n_calls = 4 };
    const stats = [_]orch.ArmObs{ r0_stat, baton_stat };
    orch.g_arms = &stats;
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, multi));
}

test "meta-tools append only while handoff_active and enforce phase + solo batch rules" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    orchestrator.handoff_active = false;
    const base_specs = try schema.effectiveRootSpecs(arena);
    for (base_specs) |s| try std.testing.expect(!orchestrator.isMetaTool(s.name));

    orchestrator.handoff_active = true;
    const active_specs = try schema.effectiveRootSpecs(arena);
    try std.testing.expectEqual(base_specs.len + 2, active_specs.len);
    try std.testing.expect(orchestrator.isMetaTool(active_specs[base_specs.len].name));
    try std.testing.expect(orchestrator.isMetaTool(active_specs[base_specs.len + 1].name));

    var root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");
    const mixed = [_]tools.ToolCall{
        .{ .id = "c1", .name = "read_file", .input = .{ .object = .empty } },
        .{ .id = "c2", .name = "exit_plan_mode", .input = .{ .object = .empty } },
    };
    var results: [2]tools.ExecResult = undefined;
    try std.testing.expect(try orchestrator.rejectMixedBatch(&root, &mixed, &results));
    try std.testing.expect(results[0].is_error and results[1].is_error);

    orchestrator.g_phase = .planning;
    const empty_plan = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"plan\":\"  \"}", .{}) catch unreachable;
    const r_empty = try orchestrator.handleMeta(&root, .{ .id = "c3", .name = "exit_plan_mode", .input = empty_plan });
    try std.testing.expect(r_empty.is_error);
    try std.testing.expect(root.yielded == null);

    const good_plan = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"plan\":\"Step 1: edit a.py\"}", .{}) catch unreachable;
    const r_ok = try orchestrator.handleMeta(&root, .{ .id = "c4", .name = "exit_plan_mode", .input = good_plan });
    try std.testing.expect(!r_ok.is_error);
    try std.testing.expectEqualStrings("Step 1: edit a.py", root.yielded.?);
}

const MockScript = struct {
    var calls: usize = 0;
    var models: [8][]const u8 = undefined;
    var plan_flags: [8]bool = undefined;
    var tools_hashes: [8]u64 = undefined;
    var mode_kind: enum { direct, handoff, replan_cap, fail_phase2 } = .handoff;

    fn reset(kind: @TypeOf(mode_kind)) void {
        calls = 0;
        mode_kind = kind;
    }

    fn runPhase(root: *Agent, _: *Keys, _: Allocator, _: ?*Io.Writer) anyerror![]const u8 {
        const idx = calls;
        calls += 1;
        models[idx] = root.provider.model;
        plan_flags[idx] = main_mod.plan_mode;
        try root.ensureRootTools(root.provider.kind);
        tools_hashes[idx] = std.hash.Wyhash.hash(0, root.toolsJson());
        switch (mode_kind) {
            .direct => return "direct answer",
            .handoff => {
                if (idx == 0) {
                    orchestrator.g_handoff_plan = "edit a and verify";
                    return "planned";
                }
                return "executed";
            },
            .replan_cap => {
                if (idx == 0 or idx == 2 or idx == 4) {
                    orchestrator.g_handoff_plan = "plan iteration";
                    return "planned";
                }
                if (idx == 1 or idx == 3 or idx == 5) {
                    orchestrator.g_replan_reason = "need schema check";
                    return "escalated";
                }
                return "finished by cap";
            },
            .fail_phase2 => {
                if (idx == 0) {
                    orchestrator.g_handoff_plan = "plan before error";
                    return "planned";
                }
                return error.MockPhase2Boom;
            },
        }
    }
};

test "orchestrator_turn drives direct answer, KV-identical handoff, replan cap, and error cleanup" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    orchestrator.g_mode = .on;
    var keys: Keys = .{ .values = @splat(null) };

    var root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");
    root.fallback_active = true;
    root.subagent_provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-6-sol", .context = 200_000 };

    // 1. Phase 1 direct answer skips Phase 2 cleanly.
    MockScript.reset(.direct);
    try std.testing.expectEqualStrings("direct answer", try orchestrator_turn.run(&root, &keys, arena, null, &MockScript.runPhase));
    try std.testing.expectEqual(@as(usize, 1), MockScript.calls);
    try std.testing.expect(MockScript.plan_flags[0]);
    try std.testing.expect(!main_mod.plan_mode);

    // 2. Phase 1 -> Phase 2 seat swap preserves toolsJson() hash, fallback_active, and subagent_provider.
    MockScript.reset(.handoff);
    try std.testing.expectEqualStrings("executed", try orchestrator_turn.run(&root, &keys, arena, null, &MockScript.runPhase));
    try std.testing.expectEqual(@as(usize, 2), MockScript.calls);
    try std.testing.expectEqualStrings("gpt-6-astra", MockScript.models[0]);
    try std.testing.expectEqualStrings("gpt-6-sol", MockScript.models[1]);
    try std.testing.expect(MockScript.plan_flags[0]);
    try std.testing.expect(!MockScript.plan_flags[1]);
    try std.testing.expectEqual(MockScript.tools_hashes[0], MockScript.tools_hashes[1]);
    try std.testing.expectEqualStrings("gpt-6-astra", root.provider.model);
    try std.testing.expect(root.fallback_active);
    try std.testing.expectEqualStrings("gpt-6-sol", root.subagent_provider.?.model);

    // 3. Replan loop caps at max_replans (2) and finishes final pass on planner seat.
    MockScript.reset(.replan_cap);
    try std.testing.expectEqualStrings("finished by cap", try orchestrator_turn.run(&root, &keys, arena, null, &MockScript.runPhase));
    try std.testing.expectEqual(@as(usize, 7), MockScript.calls);
    try std.testing.expectEqualStrings("gpt-6-astra", MockScript.models[6]);

    // 4. Error in Phase 2 unwinds phase, handoff_active, plan_mode, and planner seat.
    MockScript.reset(.fail_phase2);
    try std.testing.expectError(error.MockPhase2Boom, orchestrator_turn.run(&root, &keys, arena, null, &MockScript.runPhase));
    try std.testing.expectEqual(orchestrator.Phase.none, orchestrator.g_phase);
    try std.testing.expect(!orchestrator.handoff_active);
    try std.testing.expect(!main_mod.plan_mode);
    try std.testing.expectEqualStrings("gpt-6-astra", root.provider.model);

    // 5. Active non-standing /goal loop runs single-phase even when orchestrator is on.
    MockScript.reset(.direct);
    root.goal = .{ .objective = "wait for build", .status = .active, .standing = false };
    try std.testing.expectEqualStrings("direct answer", try orchestrator_turn.run(&root, &keys, arena, null, &MockScript.runPhase));
    root.goal = null;
    try std.testing.expectEqual(@as(usize, 1), MockScript.calls);
    try std.testing.expect(!MockScript.plan_flags[0]);

    // 6. Reactive notice wake runs single-phase even when orchestrator is on.
    MockScript.reset(.direct);
    try root.messages.append(try session_wake.message(arena, "background job finished across all modules"));
    try std.testing.expectEqualStrings("direct answer", try orchestrator_turn.run(&root, &keys, arena, null, &MockScript.runPhase));
    try std.testing.expectEqual(@as(usize, 1), MockScript.calls);
    try std.testing.expect(!MockScript.plan_flags[0]);
}

test "ACP orchestrator configOption and graff/models metadata match seat capability" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var keys: Keys = .{ .values = @splat(null) };
    var root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = undefined };
    orchestrator.g_mode = .auto;

    const opt = (try acp_orch.option(&live, arena)).?;
    try std.testing.expectEqualStrings("orchestrator", opt.id);
    try std.testing.expectEqualStrings("auto", opt.currentValue);
    try std.testing.expectEqual(@as(usize, 3), opt.options.len);

    var aw: Io.Writer.Allocating = .init(arena);
    const req: proto.Request = .{ .id = .{ .integer = 1 }, .method = "graff/models", .params = .null };
    try std.testing.expect(try acp_models.liveModels(&live, arena, &aw.writer, req));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.writer.buffered(), .{});
    const cur = parsed.object.get("result").?.object.get("current").?.object;
    try std.testing.expectEqualStrings("auto", cur.get("orchestrator").?.string);
    try std.testing.expect(cur.get("orchestratorSupported").?.bool);
    try std.testing.expectEqualStrings("gpt-6-sol", cur.get("executorModel").?.string);

    // Unsupported bottom/single seat hides option and rejects set.
    root.provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.7", .context = 256_000 };
    try std.testing.expect((try acp_orch.option(&live, arena)) == null);
    try std.testing.expect(!try acp_orch.set(&live, "on"));
}
