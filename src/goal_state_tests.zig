//! Unit tests for goal_state.zig's epoch-scoped queries (#226, #318, #394,
//! #1545): kept out of goal_state.zig (600-line goal) and reached through the
//! `test { _ = ... }` hook in main.zig, mirroring goal_persist_tests.zig.

const std = @import("std");
const agent_mod = @import("agent.zig");
const goal_state = @import("goal_state.zig");
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;
const nextEpoch = goal_state.nextEpoch;
const currentEpoch = goal_state.currentEpoch;
const openCount = goal_state.openCount;
const allDone = goal_state.allDone;
const parkedOpenCount = goal_state.parkedOpenCount;
const adoptTodos = goal_state.adoptTodos;
const hasCurrent = goal_state.hasCurrent;
const completionGate = goal_state.completionGate;
const checklistFinished = goal_state.checklistFinished;
const noteTodoWrite = goal_state.noteTodoWrite;
const noteCompletionRefused = goal_state.noteCompletionRefused;
const beginTurn = goal_state.beginTurn;
const resetCompletionGate = goal_state.resetCompletionGate;
const steeringGate = goal_state.steeringGate;
const goalActive = goal_state.goalActive;
const reconcileRestored = goal_state.reconcileRestored;
const renderCurrent = goal_state.renderCurrent;
const renderTodos = goal_state.renderTodos;
const applyGoalSteering = goal_state.applyGoalSteering;
const supersededNote = goal_state.supersededNote;
const clearedNote = goal_state.clearedNote;
const isDropped = goal_state.isDropped;

test "epochs: nextEpoch clears the live goal AND every parked epoch; currentEpoch 0 without a goal" {
    const parked = [_]TodoItem{
        .{ .content = "parked by a cleared goal", .status = "pending", .epoch = 4 },
        .{ .content = "older", .status = "completed", .epoch = 2 },
    };
    try std.testing.expectEqual(@as(u64, 1), nextEpoch(null, &.{}));
    try std.testing.expectEqual(@as(u64, 4), nextEpoch(.{ .objective = "a", .epoch = 3 }, &.{}));
    // No live goal (/goal clear) but parked items: the next goal lands ABOVE
    // them instead of colliding with epoch 1 and adopting someone else's list.
    try std.testing.expectEqual(@as(u64, 5), nextEpoch(null, &parked));
    // A live goal below the high-water mark does not drag the next epoch down.
    try std.testing.expectEqual(@as(u64, 5), nextEpoch(.{ .objective = "a", .epoch = 1 }, &parked));
    try std.testing.expectEqual(@as(u64, 0), currentEpoch(null));
    try std.testing.expectEqual(@as(u64, 7), currentEpoch(.{ .objective = "a", .epoch = 7 }));
    // A completed goal is a dead epoch: later todo_write calls are unscoped
    // again and its own checklist stays parked (#318 D1). Paused/blocked goals
    // are alive - they keep stamping.
    try std.testing.expectEqual(@as(u64, 0), currentEpoch(.{ .objective = "a", .epoch = 7, .status = .complete }));
    try std.testing.expectEqual(@as(u64, 7), currentEpoch(.{ .objective = "a", .epoch = 7, .status = .paused }));
}

test "openCount/allDone are epoch-scoped; empty checklist is never done (#226)" {
    const todos = [_]TodoItem{
        .{ .content = "old work", .status = "pending", .epoch = 1 },
        .{ .content = "done here", .status = "completed", .epoch = 2 },
        .{ .content = "also done", .status = "completed", .epoch = 2 },
    };
    try std.testing.expectEqual(@as(usize, 1), openCount(&todos, 1));
    try std.testing.expectEqual(@as(usize, 0), openCount(&todos, 2));
    try std.testing.expect(!allDone(&todos, 1)); // open item
    try std.testing.expect(allDone(&todos, 2)); // all its items completed
    try std.testing.expect(!allDone(&todos, 3)); // no items at all
    try std.testing.expect(!allDone(&.{}, 0));
}

test "parking retains: superseded items are counted and kept, never deleted (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var todos: std.ArrayList(TodoItem) = .empty;
    try todos.append(ar, .{ .content = "phase3 audit", .status = "pending", .epoch = 1 });
    try todos.append(ar, .{ .content = "phase3 fix", .status = "completed", .epoch = 1 });
    try todos.append(ar, .{ .content = "phase2 test", .status = "in_progress", .epoch = 2 });
    try std.testing.expectEqual(@as(usize, 1), parkedOpenCount(todos.items, 2)); // only the OPEN phase3 item
    try std.testing.expectEqual(@as(usize, 3), todos.items.len); // a mistyped /goal deletes nothing
    try std.testing.expectEqual(@as(u64, 1), todos.items[0].epoch); // parked work keeps its own epoch
    // Retention is safe because every query is epoch-scoped: parked items are
    // invisible to the new goal's open/allDone accounting. (todo_write's
    // epoch-scoped replace lives in goal_todo.zig with its own tests.)
    try std.testing.expectEqual(@as(usize, 1), openCount(todos.items, 2));
    try std.testing.expect(!allDone(todos.items, 2));
}

test "adoptTodos takes OPEN current-epoch items only; finished and parked work stays put" {
    var todos = [_]TodoItem{
        .{ .content = "a", .status = "pending", .epoch = 0 },
        .{ .content = "b", .status = "completed", .epoch = 0 },
        .{ .content = "parked by a finished goal", .status = "pending", .epoch = 3 },
    };
    adoptTodos(&todos, 0, 5);
    try std.testing.expectEqual(@as(u64, 5), todos[0].epoch);
    try std.testing.expectEqual(@as(u64, 0), todos[1].epoch); // finished work is not the new goal's plan
    try std.testing.expectEqual(@as(u64, 3), todos[2].epoch);
    // The new goal inherits only real remaining work, so its accounting is honest.
    try std.testing.expectEqual(@as(usize, 1), openCount(&todos, 5));
    try std.testing.expect(!allDone(&todos, 5));
}

test "a goal formalized over an already-finished list adopts nothing and is not born done (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.sub = false;
    root.review_mode = false;
    root.arena = ar;
    root.todos = .empty;
    root.completion_gate_armed = false;
    root.goal = null;
    try root.todos.append(ar, .{ .content = "done before the goal", .status = "completed", .epoch = 0 });
    adoptTodos(root.todos.items, currentEpoch(root.goal), 1);
    root.goal = .{ .objective = "ship", .epoch = 1 };
    try std.testing.expect(!hasCurrent(root.todos.items, 1)); // nothing adopted
    // Without this the goal would satisfy "checklist present, 0 open" on turn 1
    // and complete before any of its work happened; now the gate asks first.
    const r = try completionGate(ar, &root);
    try std.testing.expect(r != null and std.mem.indexOf(u8, r.?, "no checklist") != null);
}

test "checklistFinished demands THIS process's todo_write; a restored all-[x] list is inert (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.arena = ar;
    root.todos = .empty;
    root.goal = null;
    root.todos_dirty = false; // exactly what loadSession leaves behind
    try root.todos.append(ar, .{ .content = "old work", .status = "completed", .epoch = 0 });
    // The goal == null variant: a goal-less run must not stop at iteration 1 just
    // because a previous session left a finished epoch-0 list on disk.
    try std.testing.expect(allDone(root.todos.items, 0));
    try std.testing.expect(!checklistFinished(&root));
    root.goal = .{ .objective = "ship", .epoch = 2, .status = .active };
    try root.todos.append(ar, .{ .content = "restored item", .status = "completed", .epoch = 2 });
    try std.testing.expect(!checklistFinished(&root)); // same for a restored goal's own list
    // todo_write in this process is the evidence, and it clears the gate arm too.
    root.completion_gate_armed = true;
    noteTodoWrite(&root);
    try std.testing.expect(root.todos_dirty and !root.completion_gate_armed);
    try std.testing.expect(checklistFinished(&root));
    // An open item in the current epoch still blocks it.
    try root.todos.append(ar, .{ .content = "new work", .status = "pending", .epoch = 2 });
    try std.testing.expect(!checklistFinished(&root));
}

test "reconcileRestored retires a restored-active goal whose checklist is already done (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.arena = ar;
    root.todos = .empty;
    root.goal = null;
    try std.testing.expect(!reconcileRestored(&root)); // no goal
    root.goal = .{ .objective = "ship", .epoch = 2, .status = .active };
    try std.testing.expect(!reconcileRestored(&root)); // no checklist is not "done" (#226)
    try root.todos.append(ar, .{ .content = "a", .status = "completed", .epoch = 2 });
    try root.todos.append(ar, .{ .content = "b", .status = "pending", .epoch = 2 });
    try std.testing.expect(!reconcileRestored(&root)); // still open work
    root.todos.items[1].status = "completed";
    try std.testing.expect(reconcileRestored(&root));
    try std.testing.expectEqual(agent_mod.GoalStatus.complete, root.goal.?.status);
    try std.testing.expect(!reconcileRestored(&root)); // idempotent: only an ACTIVE goal reconciles
    // A retired goal stops steering and stops rendering its parked list.
    try std.testing.expectEqualStrings("", renderCurrent(&root));
    // Parked work from an earlier goal never triggers reconciliation.
    root.goal = .{ .objective = "next", .epoch = 3, .status = .active };
    try std.testing.expect(!reconcileRestored(&root));
}

test "renderTodos is epoch-scoped; renderCurrent goes quiet on a dead epoch (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.arena = ar;
    root.todos = .empty;
    root.goal = .{ .objective = "ship", .epoch = 2 };
    try root.todos.append(ar, .{ .content = "old phase3 item", .status = "pending", .epoch = 1 });
    try root.todos.append(ar, .{ .content = "current item", .status = "in_progress", .epoch = 2 });
    try std.testing.expectEqualStrings("[~] current item", renderTodos(&root, 2));
    try std.testing.expectEqualStrings("[ ] old phase3 item", renderTodos(&root, 1)); // retained, still readable
    try std.testing.expectEqualStrings("[~] current item", renderCurrent(&root));
    try std.testing.expectEqualStrings("(no todos)", renderTodos(&root, 9));
    // A completed goal has no current epoch: its list parks, nothing renders.
    root.goal.?.status = .complete;
    try std.testing.expectEqualStrings("", renderCurrent(&root));
}

test "the completion double-check survives the turn boundary, re-arms on change (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.sub = false;
    root.review_mode = false;
    root.arena = ar;
    root.todos = .empty;
    root.completion_gate_armed = false;
    root.completion_refused = false;
    root.goal = .{ .objective = "ship", .epoch = 1 };
    try root.todos.append(ar, .{ .content = "a", .status = "pending", .epoch = 1 });
    // Turn 1: refused; the caller arms the gate and records that the turn worked.
    try std.testing.expect((try completionGate(ar, &root)) != null);
    noteCompletionRefused(&root);
    try std.testing.expect(root.completion_refused);
    // Turn boundary: only the per-turn flag clears. A model emits one
    // attempt_completion per turn, so clearing the arm here made the refusal
    // unresolvable forever - the #318 fix reappearing as the #318 bug.
    beginTurn(&root, true); // a new user ask: the arm still survives it, and the open checklist is not retirable
    try std.testing.expect(!root.completion_refused);
    try std.testing.expect(root.completion_gate_armed);
    try std.testing.expect((try completionGate(ar, &root)) == null);
    // New evidence (todo_write, or a /goal change) restores the double-check.
    resetCompletionGate(&root);
    try std.testing.expect((try completionGate(ar, &root)) != null);
}

test "steeringGate: inject on change, suppress repeats, refresh after the interval, reset on empty" {
    // Empty note (no goal / paused): nothing injected, fingerprint resets so a
    // resumed goal re-injects immediately.
    const off = steeringGate("", 123, 5, 8);
    try std.testing.expect(!off.inject and off.fp == 0 and off.age == 0);
    // First sight of a note: inject.
    const g1 = steeringGate("[standing goal: x]", 0, 0, 8);
    try std.testing.expect(g1.inject);
    // Verbatim repeat: suppressed, age climbs.
    const g2 = steeringGate("[standing goal: x]", g1.fp, g1.age, 8);
    try std.testing.expect(!g2.inject and g2.age == 1);
    // Changed note (new objective/epoch): inject again.
    const g3 = steeringGate("[standing goal: y]", g2.fp, g2.age, 8);
    try std.testing.expect(g3.inject);
    // refresh_every 0 never time-refreshes (ADR 0005: prefix holds the objective).
    const held = steeringGate("[standing goal: y]", g3.fp, 99, 0);
    try std.testing.expect(!held.inject and held.age == 100);
    // A non-zero interval still re-states when it lapses.
    const g4 = steeringGate("[standing goal: y]", g3.fp, 7, 8);
    try std.testing.expect(g4.inject and g4.age == 0);
}

test "completionGate: open list refused once, no-checklist needs confirm, done list accepts, review exempt (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.sub = false;
    root.review_mode = false;
    root.arena = ar;
    root.todos = .empty;
    root.completion_gate_armed = false;
    root.goal = .{ .objective = "ship", .epoch = 1 };
    // No checklist yet: first call must confirm; an armed second call closes.
    const r1 = try completionGate(ar, &root);
    try std.testing.expect(r1 != null and std.mem.indexOf(u8, r1.?, "no checklist") != null);
    root.completion_gate_armed = true;
    try std.testing.expect((try completionGate(ar, &root)) == null);
    // Open current-epoch item: refused with the count.
    root.completion_gate_armed = false;
    try root.todos.append(ar, .{ .content = "a", .status = "pending", .epoch = 1 });
    const r2 = try completionGate(ar, &root);
    try std.testing.expect(r2 != null and std.mem.indexOf(u8, r2.?, "1 open") != null);
    // Fully completed checklist: accepted immediately.
    root.todos.items[0].status = "completed";
    try std.testing.expect((try completionGate(ar, &root)) == null);
    // Review turns never gate (isolated reviews share the root Agent).
    root.review_mode = true;
    root.todos.items[0].status = "pending";
    try std.testing.expect((try completionGate(ar, &root)) == null);
    try std.testing.expect(!goalActive(&root));
}

test "applyGoalSteering: injects once, suppresses repeats, consumes the one-shot note" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.review_mode = false;
    root.goal = .{ .objective = "ship it", .epoch = 1 };
    root.goal_note_fp = 0;
    root.goal_note_age = 0;
    root.pending_goal_note = null;
    const m1 = try applyGoalSteering(ar, &root, "hi");
    try std.testing.expect(std.mem.indexOf(u8, m1, "[standing goal: ship it") != null);
    const m2 = try applyGoalSteering(ar, &root, "hi");
    try std.testing.expectEqualStrings("hi", m2); // verbatim repeat suppressed
    root.pending_goal_note = "[goal update: x]";
    const m3 = try applyGoalSteering(ar, &root, "hi");
    try std.testing.expect(std.mem.indexOf(u8, m3, "[goal update: x]") != null);
    try std.testing.expect(root.pending_goal_note == null); // one-shot consumed
    // Review turns are isolated: no steering, gate state untouched.
    root.review_mode = true;
    root.pending_goal_note = "[goal update: y]";
    try std.testing.expectEqualStrings("hi", try applyGoalSteering(ar, &root, "hi"));
    try std.testing.expect(root.pending_goal_note != null); // preserved for the next normal turn
}

test "supersededNote and clearedNote name the parked work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const s1 = try supersededNote(ar, "phase 3", 4);
    try std.testing.expect(std.mem.indexOf(u8, s1, "supersedes the previous goal \"phase 3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1, "4 unfinished") != null);
    const s2 = try supersededNote(ar, "phase 3", 0);
    try std.testing.expect(std.mem.indexOf(u8, s2, "parked") == null);
    const c = try clearedNote(ar, 2);
    try std.testing.expect(std.mem.indexOf(u8, c, "2 unfinished") != null);
}
