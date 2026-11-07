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
        if (t.closed()) continue; // #1545: cancelled after a scope change is parked, not owed
        if (isVerification(t.content)) n += 1;
    }
    return n;
}

/// #1545: a verification item the user moved away from is parked, which ends
/// the obligation to finish it but is never evidence that the task verified.
fn cancelledVerification(agent: *const Agent) bool {
    const epoch = goal_state.currentEpoch(agent.goal);
    for (agent.todos.items) |t| {
        if (t.epoch != epoch or t.retired) continue;
        if (std.mem.eql(u8, t.status, "cancelled") and isVerification(t.content)) return true;
    }
    return false;
}

pub fn hasUnresolved(agent: *const Agent) bool {
    return unresolvedCount(agent) > 0;
}

pub fn completionGate(arena: Allocator, agent: *Agent) !?[]const u8 {
    if (agent.review_mode or agent.sub) return goal_state.completionGate(arena, agent);
    if (hasUnresolved(agent)) {
        const rendered = goal_state.renderTodos(agent, goal_state.currentEpoch(agent.goal));
        return try std.fmt.allocPrint(arena, "completion deferred: {d} unresolved verification item(s) remain:\n{s}\nDropping or summarizing them does not satisfy completion. Finish the verification, or have the user change scope. If the user already withdrew this work or handed it elsewhere (a newer message or an ask_user answer), set those items to status \"cancelled\" with todo_write, each with a short \"reason\" naming who withdrew it or where it went. A cancelled item stays on the list and is never counted as verified.", .{ unresolvedCount(agent), rendered });
    }
    return goal_state.completionGate(arena, agent);
}

/// Verified task success, not mere execution. An ordinary return with no
/// goal/eval/verification obligation is vacuously verified so recipe
/// telemetry for chat turns stays usable.
pub fn taskVerified(agent: *const Agent) bool {
    if (hasUnresolved(agent) or cancelledVerification(agent)) return false;
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
    root.messages = std.json.Array.init(arena); // #1545: applyTodoWrite fingerprints the latest user request
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

test "#1545 a verification item cannot be cancelled within the request that wrote it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    const textMessage = @import("messages.zig").textMessage;
    try root.messages.append(try textMessage(ar, "user", "implement the feature and run the tests"));
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"write the helper","status":"completed"},
        \\          {"content":"run the tests","status":"pending"}]}
    ));
    // Same request, no user message since: the #844 obligation stands.
    const refused = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"cancelled","reason":"taking too long"}]}
    ));
    try std.testing.expect(std.mem.indexOf(u8, refused.reply(), "were not cancelled") != null);
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
    const gate = (try completionGate(ar, &root)).?;
    try std.testing.expect(std.mem.indexOf(u8, gate, "cancelled") != null); // the gate names the way out
}

test "#1545 after a newer user message, a cancelled verification item is parked, not owed and not verified" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    const textMessage = @import("messages.zig").textMessage;
    try root.messages.append(try textMessage(ar, "user", "implement the feature and run the tests"));
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"write the helper","status":"completed"},
        \\          {"content":"run the tests","status":"pending"}]}
    ));
    // The user changes scope; the old verification is no longer the task.
    try root.messages.append(try textMessage(ar, "user", "stop that, file an issue about it instead"));
    const res = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"cancelled","reason":"user switched to filing an issue"},
        \\          {"content":"file the issue","status":"completed"}]}
    ));
    try std.testing.expect(std.mem.indexOf(u8, res.reply(), "were not cancelled") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.reply(), "1 cancelled") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "[-] run the tests") != null);
    try std.testing.expectEqual(@as(usize, 0), unresolvedCount(&root)); // no longer blocks completion
    try std.testing.expect(!taskVerified(&root)); // ...but never reads as verified
    // Omitted later, the cancelled item stays as history instead of reviving the obligation.
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"file the issue","status":"completed"}]}
    ));
    try std.testing.expectEqual(@as(usize, 0), unresolvedCount(&root));
}

test "#1545 ordinary work can be cancelled any time; a brand-new verification item cannot start cancelled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    const textMessage = @import("messages.zig").textMessage;
    try root.messages.append(try textMessage(ar, "user", "ship it"));
    const res = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"sketch an alternative","status":"cancelled","reason":"not needed"},
        \\          {"content":"verify the fix","status":"cancelled","reason":"not needed"}]}
    ));
    try std.testing.expect(std.mem.indexOf(u8, res.text, "[-] sketch an alternative") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.text, "[ ] verify the fix") != null);
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
}

test "#1520 withdrawn verification: omission is restored, a reasonless cancel is rejected, a reasoned cancel lets completion through unverified" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship the fix", .epoch = 1 };
    const textMessage = @import("messages.zig").textMessage;
    try root.messages.append(try textMessage(ar, "user", "fix it, run the tests, then publish and verify the release"));
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"land the fix","status":"completed"},
        \\          {"content":"run the tests","status":"in_progress"},
        \\          {"content":"verify the published release","status":"pending"}]}
    ));
    // The user withdraws publication and hands it to another session.
    try root.messages.append(try textMessage(ar, "user", "do not publish; the release session owns that now"));
    // Leaving the item out still keeps it as an unresolved obligation.
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"completed"}]}
    ));
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
    try std.testing.expect((try completionGate(ar, &root)) != null);
    // Cancelling without a reason is rejected whole: nothing changes.
    const bare = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"completed"},
        \\          {"content":"verify the published release","status":"cancelled"}]}
    ));
    try std.testing.expect(bare.rejected);
    try std.testing.expect(std.mem.indexOf(u8, bare.text, "\"reason\"") != null);
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
    // With a reason, the item is closed, stays on the list, and shows why.
    const ok = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"completed"},
        \\          {"content":"verify the published release","status":"cancelled","reason":"delegated to the release session"}]}
    ));
    try std.testing.expect(!ok.rejected);
    try std.testing.expect(std.mem.indexOf(u8, ok.text, "[-] verify the published release (cancelled: delegated to the release session)") != null);
    try std.testing.expectEqual(@as(usize, 0), unresolvedCount(&root));
    try std.testing.expect((try completionGate(ar, &root)) == null);
    try std.testing.expect(!taskVerified(&root)); // closed, never verified
    // A later write that omits it keeps the record and its reason.
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"run the tests","status":"completed"}]}
    ));
    try std.testing.expect(std.mem.indexOf(u8, goal_state.renderTodos(&root, 1), "(cancelled: delegated to the release session)") != null);
    try std.testing.expectEqual(@as(usize, 0), unresolvedCount(&root));
}

test "#1520 an ask_user answer counts as the user's scope change for cancelling verification" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    const answers = @import("ask_user_answers.zig");
    defer answers.reset();
    try root.messages.append(try @import("messages.zig").textMessage(ar, "user", "publish to the old target and verify it"));
    _ = try goal_todo.applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"verify the old target","status":"pending"}]}
    ));
    const cancel =
        \\{"todos":[{"content":"verify the old target","status":"cancelled","reason":"user replaced the target in a clarification"}]}
    ;
    const before = try goal_todo.applyTodoWrite(&root, try todosArg(ar, cancel));
    try std.testing.expect(std.mem.indexOf(u8, before.reply(), "were not cancelled") != null);
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(&root));
    answers.record(answers.turnKey("publish to the old target and verify it"), "yes, use the new target instead");
    const after = try goal_todo.applyTodoWrite(&root, try todosArg(ar, cancel));
    try std.testing.expect(std.mem.indexOf(u8, after.reply(), "were not cancelled") == null);
    try std.testing.expectEqual(@as(usize, 0), unresolvedCount(&root));
}
