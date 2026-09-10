//! Unresolved verification obligations (#844). A todo_write replace may
//! abandon ordinary open work; acceptance/verification items stay on the
//! checklist until the user changes scope. Dropping them must not satisfy
//! completion, and the armed second attempt_completion cannot waive them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const goal_state = @import("goal_state.zig");
const goal_todo = @import("goal_todo.zig");
const goal_verify_kind = @import("goal_verify_kind.zig");

pub const isVerification = goal_verify_kind.isVerification;

pub fn unresolvedCount(agent: *const Agent) usize {
    const epoch = goal_state.currentEpoch(agent.goal);
    var n: usize = 0;
    for (agent.todos.items) |t| {
        if (t.epoch != epoch or t.retired) continue;
        if (std.mem.eql(u8, t.status, "completed")) continue;
        if (isVerification(t.content)) n += 1;
    }
    return n;
}

pub fn hasUnresolved(agent: *const Agent) bool {
    return unresolvedCount(agent) > 0;
}

pub fn completionGate(arena: Allocator, agent: *Agent) !?[]const u8 {
    if (agent.review_mode or agent.sub) return goal_state.completionGate(arena, agent);
    if (hasUnresolved(agent)) {
        const rendered = goal_state.renderTodos(agent, goal_state.currentEpoch(agent.goal));
        return try std.fmt.allocPrint(arena, "completion deferred: {d} unresolved verification item(s) remain:\n{s}\nDropping or summarizing them does not satisfy completion. Finish the verification, or have the user change scope.", .{ unresolvedCount(agent), rendered });
    }
    return goal_state.completionGate(arena, agent);
}

/// Verified task success, not mere execution. An ordinary return with no
/// goal/eval/verification obligation is vacuously verified so recipe
/// telemetry for chat turns stays usable.
pub fn taskVerified(agent: *const Agent) bool {
    if (hasUnresolved(agent)) return false;
    if (agent.eval_cmd != null) return agent.eval_verified and !agent.eval_repair_pending;
    if (goal_state.goalActive(@constCast(agent))) {
        const epoch = goal_state.currentEpoch(agent.goal);
        if (goal_state.openCount(agent.todos.items, epoch) > 0) return false;
        if (agent.completed == null and !goal_state.checklistFinished(agent)) return false;
    }
    return true;
}

fn todoRoot(arena: Allocator) Agent {
    var root: Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = arena;
    root.sub = false;
    root.review_mode = false;
    root.todos = .empty;
    root.goal = null;
    root.todos_dirty = false;
    root.completion_gate_armed = false;
    root.eval_cmd = null;
    root.eval_verified = false;
    root.eval_repair_pending = false;
    root.completed = null;
    return root;
}

fn todosArg(arena: Allocator, json: []const u8) !?std.json.Value {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    return parsed.object.get("todos");
}

test "#844 replacing the last open verification item with a completed summary keeps the obligation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship the fix", .epoch = 1 };
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"land the helper","status":"completed"},
        \\          {"content":"verify the fix","status":"pending"}]}
    ));
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
    const rendered = (try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"shipped: helper landed and looks good","status":"completed"}]}
    ))).text;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "verify the fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "kept") != null or std.mem.indexOf(u8, rendered, "verify") != null);
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
    try std.testing.expect(!goal_state.checklistFinished(&root));
    try std.testing.expect(!taskVerified(&root));
}

test "#844 completion with unresolved validation is refused even when the gate is armed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship", .epoch = 1 };
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"pending"}]}
    ));
    const first = (try completionGate(ar, &root)).?;
    try std.testing.expect(std.mem.indexOf(u8, first, "unresolved verification") != null);
    root.completion_gate_armed = true; // the promised second call must not waive verification
    const second = (try completionGate(ar, &root)).?;
    try std.testing.expect(std.mem.indexOf(u8, second, "unresolved verification") != null);
}

test "#844 ordinary open work can still be abandoned; verification cannot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship", .epoch = 1 };
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"sketch an alternative","status":"pending"},
        \\          {"content":"verify the fix","status":"pending"}]}
    ));
    const rendered = (try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"verify the fix","status":"in_progress"}]}
    ))).text;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "sketch an alternative") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "verify the fix") != null);
}

test "isVerification matches acceptance language and ignores ordinary chores" {
    try std.testing.expect(isVerification("verify the fix"));
    try std.testing.expect(isVerification("run the tests"));
    try std.testing.expect(isVerification("acceptance: check CI"));
    try std.testing.expect(!isVerification("write the helper"));
    try std.testing.expect(!isVerification("wire it up"));
    try std.testing.expect(!isVerification("sketch an alternative"));
}

test "taskVerified is true for ordinary chat and false with open verification" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    try std.testing.expect(taskVerified(&root));
    root.goal = .{ .objective = "ship", .epoch = 1, .status = .active };
    try root.todos.append(ar, .{ .content = "verify the fix", .status = "pending", .epoch = 1 });
    try std.testing.expect(!taskVerified(&root));
    root.eval_cmd = "true";
    root.eval_verified = false;
    try std.testing.expect(!taskVerified(&root));
}
