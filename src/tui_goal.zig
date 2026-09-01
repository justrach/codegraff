//! Host-side `/goal` lifecycle for the fullscreen TUI (#716).
//!
//! The pager publishes a `GoalOp`; this module applies the same transitions
//! the line REPL uses (`goal_flow.applyGoalSet`, pause/resume/clear). Typed
//! TUI goals stay non-standing so `attempt_completion` can retire them.
//! Reached through `test_hooks.zig` — without that import these tests compile
//! to nothing and the suite still reports green.

const std = @import("std");
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const goal_flow = @import("goal_flow.zig");
const goal_state = @import("goal_state.zig");
const prompts = @import("prompts.zig");
const repl_glue = @import("repl_glue.zig");
const session = @import("session.zig");
const Agent = agent_mod.Agent;

pub const Op = enum { none, set, clear, pause, unpause };

/// Apply one published TUI `/goal` verb to the live root. `.none` is a no-op
/// so `/strict` and the exit snapshot cannot mint or wipe a goal.
pub fn apply(root: *Agent, op: Op, text: []const u8, now_ms: i64) void {
    switch (op) {
        .none => {},
        .set => {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) return;
            const owned = root.arena.dupe(u8, trimmed) catch return;
            _ = goal_flow.applyGoalSet(root, owned, now_ms);
            prompts.pinStandingGoal(root, root.arena);
        },
        .clear => {
            if (root.goal == null) return;
            root.goal = null;
            goal_state.resetCompletionGate(root);
            root.goal_note_fp = 0;
            prompts.pinStandingGoal(root, root.arena);
        },
        .pause => {
            if (root.goal) |*g| {
                g.status = .paused;
                g.updated_ms = now_ms;
                prompts.pinStandingGoal(root, root.arena);
            }
        },
        .unpause => {
            if (root.goal) |*g| {
                g.status = .active;
                g.updated_ms = now_ms;
                root.goal_note_fp = 0;
                prompts.pinStandingGoal(root, root.arena);
            }
        },
    }
}

fn flowRoot(arena: Allocator) Agent {
    var root: Agent = undefined;
    root.arena = arena;
    root.sys_base = ""; // undefined would skip the empty check in pinStandingGoal
    root.sub = false;
    root.review_mode = false;
    root.todos = .empty;
    root.goal = null;
    root.todos_dirty = false;
    root.completion_gate_armed = false;
    root.completion_refused = false;
    root.completed = null;
    root.goal_note_fp = 0;
    root.pending_goal_note = null;
    root.history_rewrites = 0;
    root.tool_calls_this_turn = 0;
    root.loop_deadline_ms = null;
    return root;
}

/// The loadSession goal slice: parse the saved object, then reconcile.
fn resumeGoal(arena: Allocator, root: *Agent, json: []const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    root.goal = if (parsed.object.get("goal")) |v| session.goalFromValue(v, 1_000) else null;
    root.todos.clearRetainingCapacity();
    if (parsed.object.get("todos")) |tv| try session.appendTodosFromValue(arena, &root.todos, tv);
    root.todos_dirty = false;
    root.completion_gate_armed = false;
    root.completion_refused = false;
    _ = goal_state.reconcileRestored(root);
}

test "#716 typed TUI /goal is retirable and does not steer after resume" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);

    apply(&root, .set, "ship it", 5_000);
    try std.testing.expect(root.goal != null);
    try std.testing.expect(!root.goal.?.standing);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expect((try repl_glue.goalSteeringNote(ar, root.goal)).len > 0);

    // The old host callback minted standing=true, so this returned false and
    // the objective stayed active across /resume.
    try std.testing.expect(goal_state.retireOnCompletion(&root, 9_000));
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, root.goal.?.status);
    try std.testing.expectEqualStrings("", try repl_glue.goalSteeringNote(ar, root.goal));

    const saved = try std.fmt.allocPrint(ar,
        \\{{"goal":{{"objective":"{s}","status":"{s}","epoch":{d},"standing":{s},"created_ms":{d},"updated_ms":{d}}},"todos":[]}}
    , .{
        root.goal.?.objective,
        @tagName(root.goal.?.status),
        root.goal.?.epoch,
        if (root.goal.?.standing) "true" else "false",
        root.goal.?.created_ms,
        root.goal.?.updated_ms,
    });
    var resumed = flowRoot(ar);
    try resumeGoal(ar, &resumed, saved);
    try std.testing.expect(resumed.goal != null);
    try std.testing.expect(!resumed.goal.?.standing);
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, resumed.goal.?.status);
    try std.testing.expectEqualStrings("", try repl_glue.goalSteeringNote(ar, resumed.goal));
}

test "#716 TUI /goal pause stops steering; none does not mint a standing goal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);

    apply(&root, .none, "ship it", 1);
    try std.testing.expect(root.goal == null);

    apply(&root, .set, "ship it", 2);
    apply(&root, .none, "", 3);
    try std.testing.expect(root.goal != null);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);

    apply(&root, .pause, "ship it", 4);
    try std.testing.expectEqual(agent_mod.GoalStatus.paused, root.goal.?.status);
    try std.testing.expectEqualStrings("", try repl_glue.goalSteeringNote(ar, root.goal));

    apply(&root, .unpause, "ship it", 5);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expect((try repl_glue.goalSteeringNote(ar, root.goal)).len > 0);

    apply(&root, .clear, "", 6);
    try std.testing.expect(root.goal == null);
    try std.testing.expectEqualStrings("", try repl_glue.goalSteeringNote(ar, root.goal));
}
