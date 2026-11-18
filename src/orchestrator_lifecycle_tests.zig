//! Lifecycle regression tests for Orchestrator Mode: turn-scoped phase
//! directives across interrupted/direct/replan/error unwinds (#1908),
//! informational Q&A vs multi-step coding gating, and opaque compaction
//! checkpoint preservation + settlement across seat switches (#1906).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const Keys = @import("provider.zig").Keys;
const Provider = @import("provider.zig").Provider;
const tools = @import("tools.zig");
const orchestrator = @import("orchestrator_mode.zig");
const orchestrator_turn = @import("orchestrator_turn.zig");
const orch = @import("orchestration_policy.zig");
const orch_rows = @import("orchestration_rows.zig");
const task_intent = @import("task_intent.zig");
const named_work = @import("named_work.zig");
const checkpoint = @import("compaction_checkpoint.zig");
const compaction_window = @import("compaction_window.zig");
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;

const SavedState = struct {
    mode: orchestrator.Mode,
    cli: bool,
    env: bool,
    phase: orchestrator.Phase,
    handoff: bool,
    plan: ?[]const u8,
    reason: ?[]const u8,
    replan_exhausted: bool,
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
            .replan_exhausted = orchestrator.g_replan_exhausted,
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
        orchestrator.g_replan_exhausted = self.replan_exhausted;
        main_mod.plan_mode = self.plan_mode;
        orch.g_arms = self.arms;
        orch_rows.clearPending();
    }
};

const Script = struct {
    var kind: enum { interrupt_p1, direct, replan_cap_meta, fail_p2_after_replan, compaction_p2 } = .direct;
    var calls: usize = 0;
    var models: [8][]const u8 = @splat("");
    var plan_flags: [8]bool = @splat(false);
    var enter_cap_err: bool = false;
    var session_fixture: ?*SessionFixture = null;

    fn reset(k: @TypeOf(kind)) void {
        kind = k;
        calls = 0;
        models = @splat("");
        plan_flags = @splat(false);
        enter_cap_err = false;
        session_fixture = null;
    }

    fn runPhase(root: *Agent, _: *Keys, arena: Allocator, _: ?*Io.Writer) anyerror![]const u8 {
        const idx = calls;
        calls += 1;
        models[idx] = root.provider.model;
        plan_flags[idx] = main_mod.plan_mode;
        try root.ensureRootTools(root.provider.kind);

        switch (kind) {
            .interrupt_p1 => return error.Interrupted,
            .direct => return "answered directly",
            .replan_cap_meta => {
                if (idx == 0 or idx == 2 or idx == 4) {
                    orchestrator.g_handoff_plan = "edit a and verify";
                    return "planned";
                }
                if (idx == 1 or idx == 3) {
                    orchestrator.g_replan_reason = "schema unclear";
                    return "escalated";
                }
                if (idx == 5) {
                    orchestrator.g_replan_reason = "third replan";
                    return "hit cap";
                }
                // Final pass on planner with g_replan_exhausted == true rejects enter_plan_mode.
                const inp = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"reason\":\"try again\"}", .{});
                const res = try orchestrator.handleMeta(root, .{ .id = "m-cap", .name = orchestrator.enter_tool_name, .input = inp });
                enter_cap_err = res.is_error and std.mem.indexOf(u8, res.text, "replan limit") != null;
                return "finished on planner";
            },
            .fail_p2_after_replan => {
                if (idx == 0 or idx == 2) {
                    orchestrator.g_handoff_plan = "retry execution";
                    return "planned";
                }
                if (idx == 1) {
                    orchestrator.g_replan_reason = "missing detail";
                    return "escalated";
                }
                return error.MockPhase2Boom;
            },
            .compaction_p2 => {
                if (idx == 0) {
                    orchestrator.g_handoff_plan = "inspect outputs";
                    return "planned";
                }
                // Simulate executor minting an opaque compaction blob over oversized tool outputs.
                const big = try arena.alloc(u8, 20 * 1024);
                @memset(big, 'x');
                var before = std.json.Array.init(arena);
                try before.appendSlice(root.messages.items);
                try before.append(try named_work.responsesUserMessage(arena, "work on large files"));
                for (0..12) |n| {
                    var call_obj: std.json.ObjectMap = .empty;
                    try call_obj.put(arena, "type", .{ .string = "function_call" });
                    try call_obj.put(arena, "call_id", .{ .string = try std.fmt.allocPrint(arena, "c{d}", .{n}) });
                    try call_obj.put(arena, "name", .{ .string = "read_file" });
                    try call_obj.put(arena, "arguments", .{ .string = "{}" });
                    try before.append(.{ .object = call_obj });

                    var out_obj: std.json.ObjectMap = .empty;
                    try out_obj.put(arena, "type", .{ .string = "function_call_output" });
                    try out_obj.put(arena, "call_id", .{ .string = try std.fmt.allocPrint(arena, "c{d}", .{n}) });
                    try out_obj.put(arena, "output", .{ .string = big });
                    try before.append(.{ .object = out_obj });
                }
                for (0..6) |_| try before.append(try named_work.responsesUserMessage(arena, "recent context"));
                var blob_obj: std.json.ObjectMap = .empty;
                try blob_obj.put(arena, "type", .{ .string = "compaction" });
                try blob_obj.put(arena, "encrypted_content", .{ .string = "phase2-opaque-blob" });
                const blob: std.json.Value = .{ .object = blob_obj };
                try checkpoint.preserve(root, before.items, &.{blob});
                root.messages.clearRetainingCapacity();
                try root.messages.append(blob);
                try root.messages.append(try named_work.responsesUserMessage(arena, "recent tail"));
                root.compaction_window = try compaction_window.State.canonical(arena, &.{blob});
                return "phase 2 completed";
            },
        }
    }
};

const SessionFixture = struct {
    name: [48]u8,

    fn init() !SessionFixture {
        var raw: [16]u8 = undefined;
        try std.testing.io.randomSecure(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        var f: SessionFixture = .{ .name = undefined };
        @memcpy(f.name[0..16], "orch-life-test--");
        @memcpy(f.name[16..], &hex);
        return f;
    }

    fn deinit(self: *const SessionFixture) void {
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, ".graff/sessions/{s}", .{self.name}) catch return;
        Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    }
};

fn expectNoActiveDirectives(agent: *Agent) !void {
    const body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "[orchestrator mode — phase") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[plan review]") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "exit_plan_mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "enter_plan_mode") == null);
}

test "orchestrator retires phase directives on interrupt, direct exit, replan cap, and error unwind (#1908)" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var keys: Keys = .{ .values = @splat(null) };

    var root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");
    root.compaction_window = .{};

    // 1. Interrupted Phase 1 -> short Auto follow-up stays single-phase without baton directives/tools.
    orchestrator.g_mode = .on;
    Script.reset(.interrupt_p1);
    try std.testing.expectError(error.Interrupted, orchestrator_turn.run(&root, &keys, arena, null, &Script.runPhase));
    try std.testing.expect(!main_mod.plan_mode);
    try std.testing.expect(!orchestrator.handoff_active);
    try std.testing.expectEqual(orchestrator.Phase.none, orchestrator.g_phase);
    try expectNoActiveDirectives(&root);

    orchestrator.g_mode = .auto;
    try root.messages.append(try named_work.responsesUserMessage(arena, "thanks?"));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "thanks?"));
    Script.reset(.direct);
    try std.testing.expectEqualStrings("answered directly", try orchestrator_turn.run(&root, &keys, arena, null, &Script.runPhase));
    try std.testing.expectEqual(@as(usize, 1), Script.calls);
    try std.testing.expect(!Script.plan_flags[0]);
    try std.testing.expect(std.mem.indexOf(u8, root.toolsJson(), orchestrator.exit_tool_name) == null);
    try expectNoActiveDirectives(&root);

    // 2. Direct Phase 1 exit removes the transient Phase 1 directive.
    orchestrator.g_mode = .on;
    Script.reset(.direct);
    try std.testing.expectEqualStrings("answered directly", try orchestrator_turn.run(&root, &keys, arena, null, &Script.runPhase));
    try std.testing.expect(!main_mod.plan_mode);
    try expectNoActiveDirectives(&root);

    // 3. Replan cap rejects further enter_plan_mode on the final pass, then retires all directives.
    Script.reset(.replan_cap_meta);
    try std.testing.expectEqualStrings("finished on planner", try orchestrator_turn.run(&root, &keys, arena, null, &Script.runPhase));
    try std.testing.expect(Script.enter_cap_err);
    try std.testing.expect(!orchestrator.g_replan_exhausted);
    try expectNoActiveDirectives(&root);

    // 4. Error after replan retires active phase and [plan review] directives into history notes.
    Script.reset(.fail_p2_after_replan);
    try std.testing.expectError(error.MockPhase2Boom, orchestrator_turn.run(&root, &keys, arena, null, &Script.runPhase));
    try expectNoActiveDirectives(&root);
    const after_err = try root.buildBody(null, false, true, true);
    defer std.testing.allocator.free(after_err);
    try std.testing.expect(std.mem.indexOf(u8, after_err, "[orchestrator history") != null);
}

test "orchestrator auto routing skips informational questions and substring traps (#1906)" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    orchestrator.g_mode = .auto;

    var root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");

    const stats_q = "I tried the calculator shortcut for this statistics question but my answer is different. Why?";
    const stats_attached = stats_q ++ "\n\nAttached files:\n- /tmp/stats.pdf";
    try std.testing.expectEqual(task_intent.Intent.informational, task_intent.classify(stats_q));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, stats_attached));

    try std.testing.expectEqual(task_intent.Intent.informational, task_intent.classify("Explain how address padding works in wireless packets."));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "Explain how address padding works in wireless packets."));
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root, "Prefix the packet headers in the documentation"));
    try std.testing.expect(orchestrator.shouldPlanAuto(&root, "Refactor src/foo.zig and src/bar.zig to add timeout support and run zig build test"));
}

test "orchestrator preserves existing compaction checkpoints and settles Phase 2 compaction on planner restore (#1906)" {
    const saved = SavedState.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var keys: Keys = .{ .values = @splat(null) };

    var sf = try SessionFixture.init();
    defer sf.deinit();

    // Part (a): pre-existing opaque compaction state skips baton in auto and stays on planner in on.
    var root_existing = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");
    root_existing.session_name = &sf.name;
    root_existing.compaction_window = .{};
    const blob_item = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"compaction\",\"encrypted_content\":\"existing-blob\"}", .{});
    try root_existing.messages.append(blob_item);
    orchestrator.g_mode = .auto;
    try std.testing.expect(!orchestrator.shouldPlanAuto(&root_existing, "Refactor src/foo.zig and src/bar.zig and run zig build test"));

    orchestrator.g_mode = .on;
    Script.reset(.replan_cap_meta);
    Script.kind = .direct;
    // With an active compaction blob, even if Phase 1 produces a handoff plan, Phase 2 keeps planner seat.
    const P2Hook = struct {
        fn run(r: *Agent, _: *Keys, _: Allocator, _: ?*Io.Writer) anyerror![]const u8 {
            const idx = Script.calls;
            Script.calls += 1;
            Script.models[idx] = r.provider.model;
            if (idx == 0) {
                orchestrator.g_handoff_plan = "continue safely";
                return "planned";
            }
            return "executed";
        }
    };
    try std.testing.expectEqualStrings("executed", try orchestrator_turn.run(&root_existing, &keys, arena, null, &P2Hook.run));
    try std.testing.expectEqualStrings("gpt-6-astra", Script.models[1]);

    // Part (b): clean turn mints compaction in Phase 2 over large outputs -> restore settles below compactAt.
    var sf2 = try SessionFixture.init();
    defer sf2.deinit();
    var root = try testAgentFor(arena, "codex", .responses, "gpt-6-astra");
    root.provider.context = 45_000;
    root.session_name = &sf2.name;
    root.compaction_window = .{};
    orchestrator.g_mode = .on;
    Script.reset(.compaction_p2);
    try std.testing.expectEqualStrings("phase 2 completed", try orchestrator_turn.run(&root, &keys, arena, null, &Script.runPhase));
    try std.testing.expectEqual(@as(usize, 2), Script.calls);
    try std.testing.expectEqualStrings("gpt-6-sol", Script.models[1]);
    try std.testing.expectEqualStrings("gpt-6-astra", root.provider.model);
    try std.testing.expect(compaction_window.latestBlob(root.messages.items) == null);
    try std.testing.expect(root.effectiveContextTokens() < root.provider.compactAt());
    try expectNoActiveDirectives(&root);
}
