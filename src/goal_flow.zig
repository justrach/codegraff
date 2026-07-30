//! Goal lifecycle FLOW (#318): the pure helpers a /goal transition needs, plus
//! the scenario tests that walk a whole sequence (set -> work -> clear -> set)
//! instead of one function in isolation. Split out of goal_state.zig, which is
//! at this repo's 600-line file cap. Reached through the `test { _ = ... }`
//! hook in main.zig - without that line these tests silently compile to
//! nothing and the suite still reports green.

const std = @import("std");
const Allocator = std.mem.Allocator;
const agent_mod = @import("agent.zig");
const goal_state = @import("goal_state.zig");
const repl_glue = @import("repl_glue.zig");
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;

/// The Goal `--goal <text>` seeds: a STANDING objective (the flag's documented
/// contract is "every turn, incl. --json/-p/SDK"), stamped above every epoch
/// already present in `todos` so a resumed session's parked checklist can never
/// become its work, and so it never aliases the epoch-0 no-goal bucket (#318).
/// `objective` must already be owned by the session arena. Also used to
/// RE-apply the flag after a resume: loadSession overwrites root.goal with the
/// goal from disk, so `graff -r <session> --goal X` silently dropped X.
pub fn standingGoalFromFlag(objective: []const u8, todos: []const TodoItem, now_ms: i64) agent_mod.Goal {
    return .{
        .objective = objective,
        .status = .active,
        .standing = true,
        .epoch = goal_state.nextEpoch(null, todos),
        .created_ms = now_ms,
        .updated_ms = now_ms,
    };
}

/// A root agent in the shape the goal helpers read; no live turn behind it.
fn flowRoot(arena: Allocator) Agent {
    var root: Agent = undefined;
    root.arena = arena;
    root.sub = false;
    root.review_mode = false;
    root.todos = .empty;
    root.goal = null;
    root.todos_dirty = false;
    root.completion_gate_armed = false;
    root.completion_refused = false;
    root.completed = null;
    return root;
}

test "a --goal standing objective outlives the model's own completion (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    root.goal = standingGoalFromFlag("keep the tree green", root.todos.items, 7);
    try std.testing.expect(root.goal.?.standing);
    try std.testing.expectEqual(@as(u64, 1), root.goal.?.epoch); // never epoch 0: that bucket is the no-goal one

    // The gate never fires for it: there is no close event to double-check, so
    // the arm never arms and open work never produces a refusal either.
    try std.testing.expect((try goal_state.completionGate(ar, &root)) == null);
    try root.todos.append(ar, .{ .content = "an open item", .status = "pending", .epoch = 1 });
    try std.testing.expect((try goal_state.completionGate(ar, &root)) == null);
    try std.testing.expect(!root.completion_gate_armed);

    // attempt_completion: the result is recorded (the handler does that above
    // the branch), but the objective stays active and keeps steering. Before
    // this, one attempt_completion left every later turn of a headless/SDK
    // session unsteered - and the note itself coached the model into making it.
    root.completed = "shipped the first task";
    try std.testing.expect(!goal_state.retireOnCompletion(&root, 99));
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expect(root.completed != null);
    try std.testing.expect(goal_state.goalActive(&root));

    // A /goal-typed objective is unchanged: it still retires on completion.
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };
    try std.testing.expect(goal_state.retireOnCompletion(&root, 99));
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, root.goal.?.status);
    try std.testing.expectEqual(@as(i64, 99), root.goal.?.updated_ms);
}

test "resume never auto-retires a standing goal over a finished checklist (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    // A restored session whose --goal checklist is all done. reconcileRestored
    // retires a /goal objective here (the model finished and quit), but a
    // standing one is the user's policy for the session, not a task that ended.
    root.goal = standingGoalFromFlag("keep the tree green", root.todos.items, 7);
    try root.todos.append(ar, .{ .content = "done", .status = "completed", .epoch = 1 });
    try std.testing.expect(goal_state.allDone(root.todos.items, 1));
    try std.testing.expect(!goal_state.reconcileRestored(&root));
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expectEqualStrings("[x] done", goal_state.renderCurrent(&root)); // still current, still steering
    // The same list under a /goal objective does retire it.
    root.goal.?.standing = false;
    try std.testing.expect(goal_state.reconcileRestored(&root));
}

test "--goal seeded onto a resumed session lands above every restored epoch (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    // What `graff -r <session> --goal X` finds after loadSession: an unscoped
    // finished list plus a parked epoch. Seeding the flag goal at the default
    // epoch 0 aliased the no-goal bucket, so the restored all-[x] items were
    // instantly its "finished checklist" and completion was free.
    try root.todos.append(ar, .{ .content = "old unscoped work", .status = "completed", .epoch = 0 });
    try root.todos.append(ar, .{ .content = "parked", .status = "pending", .epoch = 3 });
    root.goal = standingGoalFromFlag("keep the tree green", root.todos.items, 7);
    try std.testing.expectEqual(@as(u64, 4), root.goal.?.epoch);
    try std.testing.expectEqual(@as(u64, 4), goal_state.currentEpoch(root.goal));
    try std.testing.expect(!goal_state.hasCurrent(root.todos.items, 4));
    try std.testing.expectEqual(@as(usize, 0), goal_state.openCount(root.todos.items, 4));
    try std.testing.expect(!goal_state.allDone(root.todos.items, 4)); // nothing of its own is "done"
    try std.testing.expectEqual(@as(usize, 2), root.todos.items.len); // and nothing was deleted
}

test "a leftover complete goal cannot end a fresh /loop at iteration 1 (#318)" {
    // After a resume reconciliation - or any earlier run that retired the goal -
    // root.goal is .complete while a NEW /loop starts. The controller read the
    // status before the work and stopped at its first decision as `accepted`, so
    // a run that had done nothing reported success.
    const zero_tools = repl_glue.turnStopped(0, false);
    try std.testing.expect(zero_tools);
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.idle, repl_glue.continuationDecision(.complete, false, zero_tools, 25).stop);
    // Real work under the same leftover goal still earns accepted, and an
    // ongoing run keeps its iterations - the status decides nothing either way.
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, repl_glue.continuationDecision(.complete, true, zero_tools, 25).stop);
    try std.testing.expect(std.meta.activeTag(repl_glue.continuationDecision(.complete, false, false, 25)) == .continue_turn);
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.exhausted, repl_glue.continuationDecision(.complete, false, false, 0).stop);
    // paused/blocked are the user's business and are untouched.
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.cancelled, repl_glue.continuationDecision(.paused, false, false, 25).stop);
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.blocked, repl_glue.continuationDecision(.blocked, false, false, 25).stop);
}

test "a cleared goal's finished checklist cannot be reborn as the next goal's list (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);

    // /goal A, a checklist, and the model finishes every item.
    const epoch_a = goal_state.nextEpoch(root.goal, root.todos.items);
    root.goal = .{ .objective = "phase A", .epoch = epoch_a };
    try root.todos.append(ar, .{ .content = "A1", .status = "completed", .epoch = epoch_a });
    goal_state.noteTodoWrite(&root); // todos_dirty is now true and NOTHING in /goal clear or set resets it
    try std.testing.expect(goal_state.checklistFinished(&root));

    // /goal clear: the goal goes, its items park at epoch 1 (retention, #318).
    root.goal = null;
    goal_state.resetCompletionGate(&root);

    // /goal B. nextEpoch used to read the live goal only, so this was epoch 1
    // again and B inherited A's finished list: born done, the first
    // attempt_completion accepted with zero work, and a /loop under B stopped
    // at iteration 1 as `accepted` while flipping B to complete.
    const epoch_b = goal_state.nextEpoch(root.goal, root.todos.items);
    try std.testing.expectEqual(@as(u64, 2), epoch_b);
    goal_state.adoptTodos(root.todos.items, goal_state.currentEpoch(root.goal), epoch_b); // the /goal set branch
    root.goal = .{ .objective = "phase B", .epoch = epoch_b };
    try std.testing.expect(!goal_state.hasCurrent(root.todos.items, epoch_b)); // B starts with no plan
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "no checklist") != null);
    try std.testing.expect(!goal_state.checklistFinished(&root)); // and no all-done list for /loop to read
    // A's work is retained and parked, exactly where it was left.
    try std.testing.expectEqual(@as(usize, 1), root.todos.items.len);
    try std.testing.expectEqual(@as(u64, 1), root.todos.items[0].epoch);
}

test "a cleared goal's OPEN items never become the next goal's work (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    root.goal = .{ .objective = "phase A", .epoch = 1 };
    try root.todos.append(ar, .{ .content = "audit the old phase", .status = "pending", .epoch = 1 });
    root.goal = null; // /goal clear parks the unfinished item

    const epoch_b = goal_state.nextEpoch(root.goal, root.todos.items);
    goal_state.adoptTodos(root.todos.items, goal_state.currentEpoch(root.goal), epoch_b);
    root.goal = .{ .objective = "phase B", .epoch = epoch_b };
    // The colliding epoch made A's leftover item read as B's open work - #318's
    // literal reattachment complaint, reborn one /goal clear later.
    try std.testing.expectEqual(@as(usize, 0), goal_state.openCount(root.todos.items, epoch_b));
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, epoch_b));
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "no checklist") != null);
    try std.testing.expect(std.mem.indexOf(u8, refusal.?, "open checklist item") == null);
    try std.testing.expectEqualStrings("", goal_state.renderCurrent(&root)); // B never renders A's list
}
