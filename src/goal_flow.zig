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
const utf8Prefix = @import("util.zig").utf8Prefix;
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

/// The checklist render carried into a compaction handoff is capped here: a
/// pathological 200-item list must never eat the very context the compaction
/// was run to reclaim. Over the cap the render is cut at a line boundary and
/// the model is pointed at todo_read for the rest.
pub const snapshot_render_cap: usize = 2_000;

/// The standing state a compaction handoff has to carry across the summary
/// boundary (#318). compact() rebuilds history as [handoff summary] + an ~8k
/// suffix, so the last todo_write result - the ONLY place the live checklist
/// ever reaches the model - is usually gone, and the summarizer may not have
/// seen the item statuses either (trimOldestToolOutputs blanks old outputs
/// before the summary request). The model then rewrote the list from prose,
/// todo_write REPLACED the epoch, three already-completed items came back as
/// pending, allDone flipped false, and the goal could never finish - durably,
/// because the autosave persisted the damaged list. So the harness restates
/// the list itself, once, as part of the new history.
/// Returns null unless a root, non-review agent has an ACTIVE goal, which also
/// excludes subagents and /review turns: they share the Agent struct but not
/// the goal. Allocates from `arena`, which MUST outlive compact()'s temporary
/// compaction arena - the text goes into the history that survives it.
pub fn compactionSnapshot(arena: Allocator, root: *Agent) !?[]const u8 {
    if (!goal_state.goalActive(root)) return null;
    const objective = root.goal.?.objective;
    const rendered = goal_state.renderCurrent(root);
    if (rendered.len == 0)
        return try std.fmt.allocPrint(arena, "[standing state (harness-kept, survives compaction): goal: {s}. No checklist has been written for it yet - plan the work with todo_write, and read the list back with todo_read at any time.]", .{objective});
    const open = goal_state.openCount(root.todos.items, goal_state.currentEpoch(root.goal));
    return try std.fmt.allocPrint(arena, "[standing state (harness-kept, survives compaction): goal: {s}. Checklist ({d} open):\n{s}\nThis list is live harness state, read it back with todo_read at any time. todo_write REPLACES the current goal's whole list, so include already-completed items when rewriting.]", .{ objective, open, try capRender(arena, rendered) });
}

/// Cut an oversized checklist render at a line boundary (never mid-item, never
/// mid-codepoint) and say so, rather than pasting it whole.
fn capRender(arena: Allocator, rendered: []const u8) ![]const u8 {
    if (rendered.len <= snapshot_render_cap) return rendered;
    const head = utf8Prefix(rendered, snapshot_render_cap);
    const cut = std.mem.lastIndexOfScalar(u8, head, '\n') orelse head.len;
    return std.fmt.allocPrint(arena, "{s}\n[checklist truncated for the handoff - call todo_read for the full list]", .{rendered[0..cut]});
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

test "compactionSnapshot: no live goal, no checklist, and a capped render (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);

    // No goal: nothing to restate, and the handoff stays byte-identical.
    try std.testing.expect((try compactionSnapshot(ar, &root)) == null);

    // A goal that has not planned yet gets the list-free variant - never the
    // "(no todos)" placeholder, which reads as a checklist that exists and is
    // empty rather than one the model still has to write.
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };
    const bare = (try compactionSnapshot(ar, &root)).?;
    try std.testing.expect(std.mem.indexOf(u8, bare, "ship phase 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "Checklist (") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "(no todos)") == null);

    // Only an ACTIVE root goal is restated: a paused goal is not steering, and
    // a review turn or subagent shares the Agent struct but not the objective.
    root.goal.?.status = .paused;
    try std.testing.expect((try compactionSnapshot(ar, &root)) == null);
    root.goal.?.status = .active;
    root.review_mode = true;
    try std.testing.expect((try compactionSnapshot(ar, &root)) == null);
    root.review_mode = false;
    root.sub = true;
    try std.testing.expect((try compactionSnapshot(ar, &root)) == null);
    root.sub = false;

    // Parked work never re-enters the handoff, and the open count is the
    // current epoch's.
    try root.todos.append(ar, .{ .content = "parked by an older goal", .status = "pending", .epoch = 0 });
    try root.todos.append(ar, .{ .content = "write the helper", .status = "completed", .epoch = 1 });
    try root.todos.append(ar, .{ .content = "test it", .status = "pending", .epoch = 1 });
    const snap = (try compactionSnapshot(ar, &root)).?;
    try std.testing.expect(std.mem.indexOf(u8, snap, "Checklist (1 open)") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "[x] write the helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "[ ] test it") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "parked by an older goal") == null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "todo_write REPLACES") != null);

    // A pathological list is cut at a line boundary instead of pasted whole:
    // the restatement must not undo the compaction it rides on.
    var i: usize = 0;
    while (i < 400) : (i += 1)
        try root.todos.append(ar, .{ .content = "a checklist item with some measurable length", .status = "pending", .epoch = 1 });
    const capped = (try compactionSnapshot(ar, &root)).?;
    try std.testing.expect(capped.len < snapshot_render_cap + 600);
    try std.testing.expect(std.mem.indexOf(u8, capped, "checklist truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "Checklist (401 open)") != null);
    try std.testing.expect(std.mem.endsWith(u8, capped, "when rewriting.]")); // the REPLACES warning survives the cut
}

test "a compaction does not move the goal note's diff-gate fingerprint (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };
    try root.todos.append(ar, .{ .content = "write the test", .status = "pending", .epoch = 1 });

    // The restatement is HISTORY (compact() appends it to the handoff message),
    // never steering. Routing it through goalSteeringNote would change that
    // note's text on the turn after every compaction, re-fingerprinting the
    // diff-gate whose entire job is to stop the checklist being re-pasted.
    const before = try repl_glue.goalSteeringNote(ar, root.goal);
    const snap = (try compactionSnapshot(ar, &root)).?;
    root.goal_note_fp = 0; // the reset compact()/emergencyTrim really do perform
    const after = try repl_glue.goalSteeringNote(ar, root.goal);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(std.mem.indexOf(u8, after, "write the test") == null); // the note still embeds no checklist
    try std.testing.expect(std.mem.indexOf(u8, snap, "[ ] write the test") != null); // the snapshot is where it lives

    // Both note variants now point at todo_read and warn that a todo_write
    // REPLACES the list: rewriting it from a summary is exactly how the three
    // completed items were lost after every compaction (#318).
    const standing = try repl_glue.goalSteeringNote(ar, .{ .objective = "keep the tree green", .standing = true });
    for ([_][]const u8{ after, standing }) |n| {
        try std.testing.expect(std.mem.indexOf(u8, n, "todo_read") != null);
        try std.testing.expect(std.mem.indexOf(u8, n, "REPLACES") != null);
    }
}
