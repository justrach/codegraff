//! Persistence round-trip tests for the #318 goal/checklist state: what
//! saveSession writes, what loadSession restores, and what goal_state makes of
//! it. Kept out of session.zig (600-line goal) and reached through the
//! `test { _ = ... }` hook in main.zig, mirroring scoring_slot_test.zig.
//!
//! #318 re-entered through this door: todos became durable, so a checklist
//! finished in a PREVIOUS session was read as evidence that the CURRENT prompt
//! was done, and a goal that was really over came back steering an all-[x] list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const agent_mod = @import("agent.zig");
const session = @import("session.zig");
const goal_state = @import("goal_state.zig");
const Agent = agent_mod.Agent;

/// Restore `json` onto `root` the way loadSession does (session.zig): parse the
/// goal, refill the epoch-stamped checklist, drop this-process freshness, then
/// reconcile. The parsing and the reconciliation are the real functions; only
/// the four-statement order is restated here.
fn resumeSession(arena: Allocator, root: *Agent, json: []const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    root.goal = if (parsed.object.get("goal")) |v| session.goalFromValue(v, 1_000) else null;
    root.todos.clearRetainingCapacity();
    if (parsed.object.get("todos")) |tv| try session.appendTodosFromValue(arena, &root.todos, tv);
    root.todos_dirty = false;
    root.completion_gate_armed = false; // the double-check is per-process: an arm from the PREVIOUS session must not close this one's goal (#318)
    root.completion_refused = false;
    _ = goal_state.reconcileRestored(root);
}

/// A root agent in the state loadSession hands back: no live turn behind it.
fn blankRoot(arena: Allocator) Agent {
    var root: Agent = undefined;
    root.arena = arena;
    root.sub = false;
    root.review_mode = false;
    root.todos = .empty;
    root.goal = null;
    root.todos_dirty = false;
    root.completion_gate_armed = false;
    return root;
}

test "resume: an active goal whose checklist is already finished retires (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // Exactly the shape saveSession writes (session.zig): the model finished the
    // work but quit without calling attempt_completion, so the goal is still
    // .active on disk. Epoch 1 carries an item parked by an earlier goal.
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"ship phase 2","status":"active","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"phase 3 audit","status":"pending","epoch":1},
        \\          {"content":"fix the tests","status":"completed","epoch":2},
        \\          {"content":"verify in the browser","status":"completed","epoch":2}]}
    );
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, root.goal.?.status);
    try std.testing.expect(!goal_state.goalActive(&root)); // no steering note on the first resumed turn
    try std.testing.expectEqualStrings("", goal_state.renderCurrent(&root)); // and no all-[x] list to re-paste
    // Reconciliation retires, it never deletes: the parked epoch-1 item and the
    // finished epoch-2 list both survive the round trip (#318 D-PARK).
    try std.testing.expectEqual(@as(usize, 3), root.todos.items.len);
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, 2));
    // The retired goal is not fresh completion evidence either: the first /loop
    // turn of the resumed session must still do real work to stop as accepted.
    try std.testing.expect(!goal_state.checklistFinished(&root));
}

test "resume: open items keep the goal active and the checklist current (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"ship phase 2","status":"active","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"fix the tests","status":"completed","epoch":2},
        \\          {"content":"verify in the browser","status":"pending","epoch":2}]}
    );
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status); // real work is left
    try std.testing.expect(goal_state.goalActive(&root));
    try std.testing.expectEqual(@as(usize, 1), goal_state.openCount(root.todos.items, 2));
    try std.testing.expectEqualStrings("[x] fix the tests\n[ ] verify in the browser", goal_state.renderCurrent(&root));
    try std.testing.expect(!goal_state.checklistFinished(&root));
    // Finishing the restored list only counts once todo_write has run in THIS
    // process - the /loop allDone arm stays inert until then.
    root.todos.items[1].status = "completed";
    try std.testing.expect(goal_state.allDone(root.todos.items, 2));
    try std.testing.expect(!goal_state.checklistFinished(&root));
    goal_state.noteTodoWrite(&root);
    try std.testing.expect(goal_state.checklistFinished(&root));
}

test "resume: a finished epoch-0 leftover cannot end a bare /loop (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // No goal at all, and a checklist the previous session finished. Before the
    // freshness flag this made /loop stop at iteration 1 as `accepted` without
    // the model doing anything.
    try resumeSession(ar, &root,
        \\{"goal":null,
        \\ "todos":[{"content":"old work","status":"completed","epoch":0}]}
    );
    try std.testing.expect(root.goal == null); // nothing to reconcile
    try std.testing.expect(goal_state.allDone(root.todos.items, 0));
    try std.testing.expect(!goal_state.checklistFinished(&root));
    goal_state.noteTodoWrite(&root); // the model restates its plan: now it counts
    try std.testing.expect(goal_state.checklistFinished(&root));
}

test "resume: the completion double-check does not ride in from the previous session (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // The arm survives turns on purpose (a model emits one attempt_completion
    // per turn), so a refusal late in session A left it set. /resume B then
    // restored an active goal with open work and the FIRST attempt_completion
    // of B hit the armed short-circuit: the goal closed, the double-check the
    // user never saw refused nothing.
    root.completion_gate_armed = true;
    root.completion_refused = true;
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"ship phase 2","status":"active","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"verify in the browser","status":"pending","epoch":2}]}
    );
    try std.testing.expect(!root.completion_gate_armed);
    try std.testing.expect(!root.completion_refused);
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "1 open") != null);
}

test "goalFromValue: epoch round-trips; legacy goals default to epoch 0 (#318)" {
    // Moved here from session.zig, which is at the 600-line cap.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"objective\":\"x\",\"status\":\"active\",\"epoch\":3}", .{});
    try std.testing.expectEqual(@as(u64, 3), session.goalFromValue(v, 1).?.epoch);
    const legacy = try std.json.parseFromSliceLeaky(std.json.Value, a, "\"just a string\"", .{});
    try std.testing.expectEqual(@as(u64, 0), session.goalFromValue(legacy, 1).?.epoch);
}

test "resume: a standing --goal round-trips and stays the user's policy (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // The shape saveSession writes for a --goal session: `standing` alongside
    // the epoch. Resume honors it, so the objective survives its own finished
    // checklist instead of being reconciled away on the first resumed turn.
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"keep the tree green","status":"active","epoch":2,"standing":true,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"first task","status":"completed","epoch":2}]}
    );
    try std.testing.expect(root.goal.?.standing);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expect(goal_state.goalActive(&root));
    try std.testing.expectEqualStrings("[x] first task", goal_state.renderCurrent(&root));
    try std.testing.expect((try goal_state.completionGate(ar, &root)) == null); // never gated
    // Sessions written before the field (and every /goal objective) have no
    // standing flag, so they keep the model-retirable behavior exactly.
    var legacy = blankRoot(ar);
    try resumeSession(ar, &legacy,
        \\{"goal":{"objective":"ship phase 2","status":"active","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"first task","status":"completed","epoch":2}]}
    );
    try std.testing.expect(!legacy.goal.?.standing);
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, legacy.goal.?.status);
}

test "resume: a /goal set after restoring parked items lands above them (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // The shape /goal clear leaves on disk: no goal, and its checklist parked at
    // epoch 1. Nothing persists the epoch counter, so the next /goal re-derives
    // it - from the live goal alone that was epoch 1 again, and the restored
    // list became the new objective's work the moment it was set.
    try resumeSession(ar, &root,
        \\{"goal":null,
        \\ "todos":[{"content":"leftover from the cleared goal","status":"pending","epoch":1},
        \\          {"content":"and its finished item","status":"completed","epoch":1}]}
    );
    try std.testing.expect(root.goal == null);
    const epoch = goal_state.nextEpoch(root.goal, root.todos.items);
    try std.testing.expectEqual(@as(u64, 2), epoch);
    goal_state.adoptTodos(root.todos.items, goal_state.currentEpoch(root.goal), epoch); // the /goal set branch
    root.goal = .{ .objective = "a brand new objective", .epoch = epoch };
    try std.testing.expect(!goal_state.hasCurrent(root.todos.items, epoch)); // it starts with no plan of its own
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, epoch));
    try std.testing.expect(!goal_state.checklistFinished(&root));
}

test "resume: a paused or already-complete goal is restored verbatim (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // Paused with a finished checklist: the user stepped in, and reconciliation
    // must not decide the objective is over on their behalf. /goal resume then
    // finds its checklist exactly where it was left.
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"ship phase 2","status":"paused","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"fix the tests","status":"completed","epoch":2}]}
    );
    try std.testing.expectEqual(agent_mod.GoalStatus.paused, root.goal.?.status);
    try std.testing.expectEqual(@as(u64, 2), goal_state.currentEpoch(root.goal)); // paused goals still own their epoch
    // A goal completed before the quit stays complete, with its list parked.
    var root2 = blankRoot(ar);
    try resumeSession(ar, &root2,
        \\{"goal":{"objective":"ship phase 2","status":"complete","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"leftover","status":"pending","epoch":2}]}
    );
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, root2.goal.?.status);
    try std.testing.expectEqual(@as(u64, 0), goal_state.currentEpoch(root2.goal)); // dead epoch: later writes are unscoped
    try std.testing.expectEqualStrings("", goal_state.renderCurrent(&root2));
}
