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
const goal_flow = @import("goal_flow.zig");
const repl_glue = @import("repl_glue.zig");
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
/// The turn-scoped fields matter too - goal_flow.loopTurnDecision reads them
/// to decide whether a /loop continues, and "restored, no work yet" is exactly
/// the state #318's never-completing loop started from.
fn blankRoot(arena: Allocator) Agent {
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
    root.tool_calls_this_turn = 0;
    root.goal_note_fp = 0;
    root.loop_deadline_ms = null;
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

test "/goal over live work supersedes it and never inherits its checklist (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"ship phase 2","status":"active","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"fix the tests","status":"completed","epoch":2},
        \\          {"content":"verify in the browser","status":"pending","epoch":2},
        \\          {"content":"parked earlier","status":"pending","epoch":1}]}
    );
    root.completion_gate_armed = true; // a refusal the old objective was still answering

    const res = goal_flow.applyGoalSet(&root, "ship phase 3", 5_000);
    try std.testing.expect(res.superseded != null);
    try std.testing.expectEqualStrings("ship phase 2", res.superseded.?.objective);
    try std.testing.expectEqual(@as(usize, 2), res.parked_open); // both open items stopped steering
    try std.testing.expectEqual(@as(u64, 3), root.goal.?.epoch); // above the live goal AND every parked epoch
    try std.testing.expect(!root.goal.?.standing); // a typed /goal is retirable; only --goal is standing
    try std.testing.expect(!root.completion_gate_armed); // new objective, new evidence for the double-check
    try std.testing.expectEqual(@as(u64, 0), root.goal_note_fp); // and the note re-states next turn
    // The new objective starts with no plan of its own, and nothing was deleted.
    try std.testing.expectEqualStrings("", goal_state.renderCurrent(&root));
    try std.testing.expectEqual(@as(usize, 3), root.todos.items.len);
}

test "/goal over a retired goal adopts only its OPEN current items (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // A goal that already completed is not live work, so the next /goal is not
    // superseding anything - it takes the adoption branch, like a first /goal.
    // But a COMPLETE goal's epoch is dead (currentEpoch 0), so there is nothing
    // current to adopt and its finished list stays parked where it is.
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"ship phase 2","status":"complete","epoch":2,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"fix the tests","status":"completed","epoch":2},
        \\          {"content":"leftover","status":"pending","epoch":2}]}
    );
    const res = goal_flow.applyGoalSet(&root, "ship phase 3", 5_000);
    try std.testing.expect(res.superseded == null); // nothing live was replaced
    try std.testing.expectEqual(@as(u64, 3), root.goal.?.epoch);
    try std.testing.expect(!goal_state.hasCurrent(root.todos.items, 3));
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, 3));
    // Born with no checklist, so completion is gated rather than free (#318).
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "no checklist") != null);
}

test "the first /goal adopts the in-flight unscoped plan, minus finished work (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // The model planned before the user named the objective: an epoch-0 list.
    // Formalizing it should keep the OPEN items (the plan the /goal serves) and
    // leave the completed ones parked - carrying those in made the fresh goal
    // born "done": openCount 0 with a checklist present, so the double-check's
    // confirm-once arm was skipped and completion was free before any work.
    try root.todos.append(ar, .{ .content = "already done", .status = "completed", .epoch = 0 });
    try root.todos.append(ar, .{ .content = "still open", .status = "in_progress", .epoch = 0 });
    const res = goal_flow.applyGoalSet(&root, "make the tests pass", 5_000);
    try std.testing.expect(res.superseded == null);
    try std.testing.expectEqual(@as(u64, 1), root.goal.?.epoch);
    try std.testing.expectEqualStrings("[~] still open", goal_state.renderCurrent(&root));
    try std.testing.expectEqual(@as(usize, 1), goal_state.openCount(root.todos.items, 1));
    try std.testing.expectEqual(@as(u64, 0), root.todos.items[0].epoch); // the finished item parked
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "1 open") != null);
}

test "/loop: a restored all-[x] list is idle, not accepted (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // A standing --goal survives the resume with its finished checklist intact
    // (reconcileRestored leaves it alone), so this is the exact state a fresh
    // /loop starts from: goal active, every item [x], zero tools run yet. It
    // used to stop at iteration 1 as `accepted` with nothing done.
    try resumeSession(ar, &root,
        \\{"goal":{"objective":"keep the tree green","status":"active","epoch":2,"standing":true,"created_ms":1,"updated_ms":2},
        \\ "todos":[{"content":"fix the tests","status":"completed","epoch":2}]}
    );
    try std.testing.expect(goal_state.allDone(root.todos.items, 2));
    try std.testing.expect(!root.todos_dirty); // the freshness flag is what saves it
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.idle, goal_flow.loopTurnDecision(&root, 25, 0).stop);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status); // and nothing was retired
}

test "/loop: a finished list accepts and retires only a retirable goal (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };
    try root.todos.append(ar, .{ .content = "fix the tests", .status = "completed", .epoch = 1 });
    goal_state.noteTodoWrite(&root); // THIS process finished the list: real evidence
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, goal_flow.loopTurnDecision(&root, 25, 0).stop);
    try std.testing.expect(goal_flow.acceptLoopOutcome(&root));
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, root.goal.?.status);

    // A paused goal is the user stepping in, and a standing --goal is their
    // policy for the whole session: the loop still stops as accepted, but
    // neither objective is the loop's to retire (#318).
    root.goal = .{ .objective = "ship phase 2", .epoch = 1, .status = .paused };
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, goal_flow.loopTurnDecision(&root, 25, 0).stop);
    try std.testing.expect(!goal_flow.acceptLoopOutcome(&root));
    try std.testing.expectEqual(agent_mod.GoalStatus.paused, root.goal.?.status);
    root.goal = .{ .objective = "keep the tree green", .epoch = 1, .standing = true };
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, goal_flow.loopTurnDecision(&root, 25, 0).stop);
    try std.testing.expect(!goal_flow.acceptLoopOutcome(&root));
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
}

test "/loop: a refused completion is work, and a leftover complete goal decides nothing (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };
    try root.todos.append(ar, .{ .content = "verify in the browser", .status = "pending", .epoch = 1 });
    // The completion gate refused: the model called attempt_completion (which
    // is exempt from the tool counter) and got an is_error back to react to.
    // Reading that as silence killed the /loop on the very turn the gate meant
    // to keep alive, so the promised second call could never happen (#318).
    goal_state.noteCompletionRefused(&root);
    try std.testing.expectEqual(@as(u64, 0), root.tool_calls_this_turn);
    try std.testing.expect(std.meta.activeTag(goal_flow.loopTurnDecision(&root, 25, 0)) == .continue_turn);
    // Genuine silence on the same state does stop the loop.
    root.completion_refused = false;
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.idle, goal_flow.loopTurnDecision(&root, 25, 0).stop);

    // A goal left .complete by an earlier run or a resume reconciliation must
    // not label a fresh /loop `accepted` at iteration 1 before anything has
    // happened: it decides nothing, exactly like .active.
    root.goal.?.status = .complete;
    root.tool_calls_this_turn = 3;
    try std.testing.expect(std.meta.activeTag(goal_flow.loopTurnDecision(&root, 25, 0)) == .continue_turn);
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.exhausted, goal_flow.loopTurnDecision(&root, 0, 0).stop);
    root.tool_calls_this_turn = 0;
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.idle, goal_flow.loopTurnDecision(&root, 25, 0).stop);
}

test "a fresh /loop cannot stop accepted off a checklist finished before it (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    // Run A drove the standing goal's checklist to all-done (todos_dirty=true)
    // and stopped accepted. The goal never retires, so its epoch stays live and
    // allDone stays true into run B.
    root.goal = goal_flow.standingGoalFromFlag("keep the tree green", null, root.todos.items, 7);
    try root.todos.append(ar, .{ .content = "done last run", .status = "completed", .epoch = 1 });
    root.todos_dirty = true;
    root.tool_calls_this_turn = 1;
    // Stale evidence reads as work_done -> accepted on B's very first decision...
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, goal_flow.loopTurnDecision(&root, 25, 0).stop);
    // ...which is why mainloop clears todos_dirty when a FRESH /loop arms: the
    // new prompt starts with no completion evidence of its own, and only a
    // todo_write (or attempt_completion) made DURING the run can stop it.
    root.todos_dirty = false;
    try std.testing.expect(std.meta.activeTag(goal_flow.loopTurnDecision(&root, 25, 0)) == .continue_turn);
    goal_state.noteTodoWrite(&root); // the model re-plans and finishes in-run
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, goal_flow.loopTurnDecision(&root, 25, 0).stop);
}

test "/loop: a passed wall-clock deadline stops as expired and flips nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    root.goal = .{ .objective = "ship phase 2", .epoch = 1, .status = .active };
    try root.todos.append(ar, .{ .content = "still open", .status = "pending", .epoch = 1 });
    root.tool_calls_this_turn = 3; // the turn worked; it simply ran out of clock
    root.loop_deadline_ms = 10_000; // `/loop 30m ...` armed this

    // One second short of it the run continues exactly as before.
    try std.testing.expect(std.meta.activeTag(goal_flow.loopTurnDecision(&root, 25, 9_999)) == .continue_turn);
    // On it, the run stops with its own named outcome. This is the deadline's
    // ONLY hard effect: #224 dropped goal budget ENFORCEMENT and that stands,
    // so the goal is untouched and the checklist is left exactly as it is.
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.expired, goal_flow.loopTurnDecision(&root, 25, 10_000).stop);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expectEqual(@as(usize, 1), goal_state.openCount(root.todos.items, 1));
    // expired is not accepted, so mainloop never runs acceptLoopOutcome on it -
    // and if it somehow did, the goal is still active work, not a completion.
    try std.testing.expect(goal_flow.acceptLoopOutcome(&root)); // proof the two paths differ
    root.goal.?.status = .active;

    // Real completion evidence outranks the clock: a run that finished on its
    // last second reports accepted, not expired.
    root.completed = "shipped";
    try std.testing.expectEqual(repl_glue.ContinuationOutcome.accepted, goal_flow.loopTurnDecision(&root, 25, 99_999).stop);
    // And a run with no budget never expires, however long it goes.
    root.completed = null;
    root.loop_deadline_ms = null;
    try std.testing.expect(std.meta.activeTag(goal_flow.loopTurnDecision(&root, 25, 1 << 40)) == .continue_turn);
}

test "an accepted claim while paused still consumes the double-check arm (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = blankRoot(ar);
    root.goal = .{ .objective = "ship", .epoch = 1, .status = .active };
    try root.todos.append(ar, .{ .content = "open", .status = "pending", .epoch = 1 });
    try std.testing.expect((try goal_state.completionGate(ar, &root)) != null);
    goal_state.noteCompletionRefused(&root);
    // The user pauses between the refusal and the promised second call. The
    // gate stands down for a paused goal, the claim is recorded, nothing
    // retires - but the arm must be SPENT, or /goal resume hands the revived
    // goal a free pass on its next claim with the items still open.
    root.goal.?.status = .paused;
    try std.testing.expect((try goal_state.completionGate(ar, &root)) == null);
    try std.testing.expect(!goal_state.retireOnCompletion(&root, 9));
    try std.testing.expect(!root.completion_gate_armed);
    root.goal.?.status = .active; // /goal resume
    try std.testing.expect((try goal_state.completionGate(ar, &root)) != null); // fresh double-check
}
