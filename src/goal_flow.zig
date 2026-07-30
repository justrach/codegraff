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
/// contract is "every turn, incl. --json/-p/SDK"), stamped above `old` (the
/// goal it displaces, if any) and every epoch already present in `todos`, so a
/// resumed session's parked checklist can never become its work and it never
/// aliases the epoch-0 no-goal bucket (#318).
/// `objective` must already be owned by the session arena. Re-application over
/// a loadSession goes through reapplyFlagGoal, which keeps the same objective's
/// goal instead of re-minting it.
pub fn standingGoalFromFlag(objective: []const u8, old: ?agent_mod.Goal, todos: []const TodoItem, now_ms: i64) agent_mod.Goal {
    return .{
        .objective = objective,
        .status = .active,
        .standing = true,
        .epoch = goal_state.nextEpoch(old, todos),
        .created_ms = now_ms,
        .updated_ms = now_ms,
    };
}

/// Re-apply the --goal flag over whatever loadSession restored (#318). The flag
/// wins, but idempotently: resuming the SAME standing objective keeps the
/// restored goal - epoch, checklist and timestamps - instead of minting a new
/// epoch and parking the objective's own work on every restart. A different
/// restored goal is displaced like any supersession; when it was live with open
/// items the returned note must be queued (pending_goal_note, always null right
/// after a load) so neither the model nor the user loses the boundary silently.
pub fn reapplyFlagGoal(arena: Allocator, root: *Agent, objective: []const u8, now_ms: i64) !?[]const u8 {
    if (root.goal) |*g| {
        if (g.standing and std.mem.eql(u8, g.objective, objective)) {
            // Same policy, same goal - but the flag passed TODAY outranks a saved
            // pause: --goal on the command line means steer. Without this, a
            // paused standing goal came back paused and the flag produced no
            // steering and no completion gate at all, silently (#318).
            g.status = .active;
            g.updated_ms = now_ms;
            root.goal_note_fp = 0; // a revived goal re-states its note, not by caller-ordering luck
            return null;
        }
    }
    const displaced: ?agent_mod.Goal = if (root.goal) |old| (if (old.status == .complete) null else old) else null;
    root.goal = standingGoalFromFlag(objective, root.goal, root.todos.items, now_ms);
    root.goal_note_fp = 0; // re-state the (now standing) note on the next turn
    goal_state.resetCompletionGate(root); // a new objective is fresh evidence for the double-check
    if (displaced) |old| {
        const parked = goal_state.parkedOpenCount(root.todos.items, root.goal.?.epoch);
        if (parked > 0) return try goal_state.supersededNote(arena, old.objective, parked);
    }
    return null;
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
        return try std.fmt.allocPrint(arena, "[standing state (harness-kept, survives context rewrites): goal: {s}. No checklist has been written for it yet - plan the work with todo_write, and read the list back with todo_read at any time.]", .{objective});
    const open = goal_state.openCount(root.todos.items, goal_state.currentEpoch(root.goal));
    return try std.fmt.allocPrint(arena, "[standing state (harness-kept, survives context rewrites): goal: {s}. Checklist ({d} open):\n{s}\nThis list is live harness state, read it back with todo_read at any time. todo_write REPLACES the current goal's whole list; completed items you omit are kept automatically, open items you omit are dropped.]", .{ objective, open, try capRender(arena, rendered) });
}

/// Cut an oversized checklist render at a line boundary (never mid-item, never
/// mid-codepoint) and say so, rather than pasting it whole.
fn capRender(arena: Allocator, rendered: []const u8) ![]const u8 {
    if (rendered.len <= snapshot_render_cap) return rendered;
    const head = utf8Prefix(rendered, snapshot_render_cap);
    const cut = std.mem.lastIndexOfScalar(u8, head, '\n') orelse head.len;
    return std.fmt.allocPrint(arena, "{s}\n[checklist truncated for the handoff - call todo_read for the full list]", .{rendered[0..cut]});
}

pub const GoalSetResult = struct {
    /// The live goal this one replaced, or null when there was nothing to
    /// supersede (no goal, or one already retired). The caller prints it and
    /// queues the supersession note.
    superseded: ?agent_mod.Goal,
    /// Open items that do NOT belong to the new epoch, i.e. the work that
    /// stopped steering. Retained, never deleted (#318).
    parked_open: usize,
};

/// The pure state transition behind `/goal <objective>` (set and replace are
/// the same transition): the new epoch, the adopt-or-supersede choice, the
/// goal assignment, and the gate/fingerprint resets. Printing, tracing and the
/// session save stay with the caller, which is what makes the rules here
/// unit-testable - the two riskiest of them had no test at all before, since
/// they only existed inside a slash-command handler.
/// `objective` must already be owned by the session arena. `standing` is left
/// at its default false: a typed /goal is a task the model may complete, only
/// the --goal flag makes an objective standing (goal_flow.standingGoalFromFlag).
pub fn applyGoalSet(root: *Agent, objective: []const u8, now_ms: i64) GoalSetResult {
    const epoch = goal_state.nextEpoch(root.goal, root.todos.items);
    // A COMPLETE goal is already retired and its checklist already parked
    // (#318 D1), so the next /goal is not superseding live work: it takes the
    // adoption branch, exactly like a first /goal.
    const superseded: ?agent_mod.Goal = if (root.goal) |old| (if (old.status == .complete) null else old) else null;
    // Formalizing an in-flight plan keeps its checklist; work parked by a
    // finished or superseded goal stays parked and is never resurrected.
    if (superseded == null)
        goal_state.adoptTodos(root.todos.items, goal_state.currentEpoch(root.goal), epoch);
    const parked_open = goal_state.parkedOpenCount(root.todos.items, epoch);
    root.goal = .{ .objective = objective, .status = .active, .epoch = epoch, .created_ms = now_ms, .updated_ms = now_ms };
    root.goal_note_fp = 0; // re-state the note on the next turn, not a stale-suppressed repeat
    goal_state.resetCompletionGate(root); // a new objective is new evidence for the completion double-check
    return .{ .superseded = superseded, .parked_open = parked_open };
}

/// The /loop controller's per-turn decision, assembled from root state. Split
/// out of mainloop (#318) so the composition itself is testable: which turns
/// count as work, which count as silence, and which goal status is read.
/// work_done is the only evidence that may complete the goal and the only
/// thing that earns `accepted` - a checklist restored from disk is not it
/// (checklistFinished gates on this-process freshness). A zero-tool turn ends
/// the LOOP as `idle` (codex RegularTask semantics: no /loop burns 25
/// continuations on a one-turn prompt), but a REFUSED attempt_completion is
/// work, not silence. A session with no goal reads as .active, so a bare /loop
/// is governed by its work and its iteration bound alone.
pub fn loopTurnDecision(root: *Agent, iters_left: u32, now_ms: i64) repl_glue.ContinuationDecision {
    const work_done = root.completed != null or goal_state.checklistFinished(root);
    const model_stopped = repl_glue.turnStopped(root.tool_calls_this_turn, root.completion_refused);
    const gstatus: agent_mod.GoalStatus = if (root.goal) |g| g.status else .active;
    const d = repl_glue.continuationDecision(gstatus, work_done, model_stopped, iters_left);
    // A deadline is the run's ONLY hard effect (#224 dropped goal budget
    // enforcement): it stops the run and names the outcome, flipping no goal
    // status. accepted (real evidence) and cancelled/blocked (the USER is
    // needed) outrank the clock; expired renames only uninformative stops.
    if (root.loop_deadline_ms) |dl| if (now_ms >= dl) {
        return switch (d) {
            .continue_turn => .{ .stop = .expired },
            .stop => |o| if (o == .idle or o == .exhausted) .{ .stop = .expired } else d,
        };
    };
    return d;
}

/// The steering appended to each autonomous /loop continuation turn (the
/// continuation_steering_item analog): keep working the checklist, verify, and
/// stop only when done or blocked - not a per-turn user note. Moved here from
/// repl_glue.zig, which is at the 600-line cap.
/// `paste_list` is the diff-gate's verdict (goal_state.steeringGate over the
/// render). It used to be unconditional, so a 25-iteration /loop wrote up to 25
/// near-identical checklist copies into root.messages - autosaved, and fed
/// verbatim into the next compaction's summary input. That is the exact
/// re-pasting this branch removed from the goal note, left behind in its one
/// remaining every-turn paster (#318). When the list has not changed the model
/// is still pointed at it, just not handed another copy; the harness restates
/// the full list on the first continuation after a compaction, where the old
/// copies died with the old history.
pub fn continuationSteeringNote(arena: Allocator, todos_render: []const u8, paste_list: bool) ![]const u8 {
    if (todos_render.len == 0)
        return "[continuing autonomously (/loop): make the next concrete step toward the goal, then verify it. Do not ask for confirmation between routine steps. Stop only when the work is complete or you hit a blocker that needs the user.]";
    if (!paste_list)
        return "[continuing autonomously (/loop): keep working the current checklist (unchanged, see your latest todo_write result, or call todo_read) - do the next incomplete item, mark it in_progress then completed, and verify. Do not ask for confirmation between routine steps. Stop only when every item is done or you are blocked.]";
    return std.fmt.allocPrint(arena, "[continuing autonomously (/loop): keep working the checklist below — do the next incomplete item, mark it in_progress then completed, and verify. Do not ask for confirmation between routine steps. Stop only when every item is done or you are blocked.\n\nChecklist so far:\n{s}]", .{todos_render});
}

/// Loop-LOCAL diff-gate state for the checklist copy in the /loop continuation
/// prompt (#318). Deliberately not an Agent field and never persisted: it
/// describes what THIS run has already handed the model, so a fresh run, a
/// user steer, a stop and a compaction all reset it.
pub const LoopListGate = struct {
    fp: u64 = 0,
    age: u32 = 0,
    rewrites_seen: u32 = 0,

    pub fn reset(self: *LoopListGate) void {
        self.* = .{};
    }

    /// This continuation turn's steering note, pasting the render only when the
    /// model has not just been handed the same list. A history rewrite
    /// (root.history_rewrites: compaction or emergency trim) kills every copy
    /// already pasted - including MID-turn, where mainloop's post-turn hook
    /// never fires because the meter is already back under the window - so the
    /// first continuation after one re-carries the list in full.
    pub fn note(self: *LoopListGate, arena: Allocator, root: *Agent) ![]const u8 {
        if (root.history_rewrites != self.rewrites_seen) {
            self.reset();
            self.rewrites_seen = root.history_rewrites;
        }
        const rendered = goal_state.renderCurrent(root);
        const gate = goal_state.steeringGate(rendered, self.fp, self.age, goal_state.refresh_turns);
        self.fp = gate.fp;
        self.age = gate.age;
        return continuationSteeringNote(arena, rendered, gate.inject);
    }
};

/// The goal-side effect of a /loop run that stopped as `accepted`: the loop
/// drove the objective to done, so it retires. Returns true when it flipped.
/// A standing --goal is the user's policy for the whole session and outlives
/// any single completion (#318); a paused or already-complete goal is not the
/// loop's to change either.
pub fn acceptLoopOutcome(root: *Agent) bool {
    if (root.goal) |*g| {
        if (g.status == .active and !g.standing) {
            g.status = .complete;
            return true;
        }
    }
    return false;
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
    root.goal_note_fp = 0;
    root.pending_goal_note = null;
    root.history_rewrites = 0;
    root.tool_calls_this_turn = 0;
    root.loop_deadline_ms = null;
    return root;
}

test "a --goal standing objective outlives the model's own completion (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    root.goal = standingGoalFromFlag("keep the tree green", null, root.todos.items, 7);
    try std.testing.expect(root.goal.?.standing);
    try std.testing.expectEqual(@as(u64, 1), root.goal.?.epoch); // never epoch 0: that bucket is the no-goal one

    // The completion CLAIM is double-checked exactly like a /goal objective:
    // an unearned "done" is worst in the flag's own headless sessions, where it
    // ended a /loop as accepted with open work. Only RETIREMENT is exempt.
    const r1 = try goal_state.completionGate(ar, &root);
    try std.testing.expect(r1 != null and std.mem.indexOf(u8, r1.?, "no checklist") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.?, "keeps steering") != null); // the refusal never promises a close
    goal_state.noteCompletionRefused(&root);
    try std.testing.expect((try goal_state.completionGate(ar, &root)) == null); // the promised second call is accepted...

    // ...and the accepted claim is recorded, but the objective stays active and
    // keeps steering. Before this, one attempt_completion left every later turn
    // of a headless/SDK session unsteered.
    root.completed = "shipped the first task";
    try std.testing.expect(!goal_state.retireOnCompletion(&root, 99));
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expect(root.completed != null);
    try std.testing.expect(goal_state.goalActive(&root));
    // The accepted claim CONSUMED the arm: a goal that never retires must not
    // ride one refusal forever, or every later claim passes unchecked.
    try std.testing.expect(!root.completion_gate_armed);

    // So the NEXT claim starts a fresh double-check cycle, no reset needed:
    // open work refuses with the standing consequence (the items stay active).
    try root.todos.append(ar, .{ .content = "an open item", .status = "pending", .epoch = 1 });
    const r2 = try goal_state.completionGate(ar, &root);
    try std.testing.expect(r2 != null and std.mem.indexOf(u8, r2.?, "stay active") != null);

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
    root.goal = standingGoalFromFlag("keep the tree green", null, root.todos.items, 7);
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
    root.goal = standingGoalFromFlag("keep the tree green", null, root.todos.items, 7);
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
    try std.testing.expect(std.mem.endsWith(u8, capped, "are dropped.]")); // the REPLACES warning survives the cut
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

test "continuationSteeringNote: checklist, generic, and the suppressed variant (#226/#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    const empty = try continuationSteeringNote(ar, "", true);
    try std.testing.expect(std.mem.indexOf(u8, empty, "Checklist so far") == null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "continuing autonomously") != null);
    const withlist = try continuationSteeringNote(ar, "[ ] add test", true);
    try std.testing.expect(std.mem.indexOf(u8, withlist, "Checklist so far:\n[ ] add test") != null);

    // Suppressed: the model is still told to work the checklist and where to
    // find it, but gets no second copy of a list it has not changed.
    const quiet = try continuationSteeringNote(ar, "[ ] add test", false);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "add test") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Checklist so far") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "keep working the current checklist (unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "todo_read") != null);
}

test "LoopListGate pastes the checklist once per change, not once per turn (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    root.goal = .{ .objective = "ship", .epoch = 1 };
    try root.todos.append(ar, .{ .content = "a", .status = "pending", .epoch = 1 });
    try root.todos.append(ar, .{ .content = "b", .status = "pending", .epoch = 1 });
    var gate: LoopListGate = .{};

    // Turn 1 of a run carries the list; the next turns do not, so a 25-turn
    // /loop no longer writes 25 near-identical copies into root.messages (all
    // autosaved, and all fed verbatim into the next compaction's summary).
    try std.testing.expect(std.mem.indexOf(u8, try gate.note(ar, &root), "[ ] a") != null);
    var i: usize = 0;
    while (i < 3) : (i += 1)
        try std.testing.expect(std.mem.indexOf(u8, try gate.note(ar, &root), "[ ] a") == null);
    // A real change to the list is carried immediately.
    root.todos.items[0].status = "completed";
    try std.testing.expect(std.mem.indexOf(u8, try gate.note(ar, &root), "[x] a") != null);
    // An unchanged list is re-stated after the refresh interval, in case it
    // aged out of the model's effective attention.
    i = 0;
    var restated = false;
    while (i < goal_state.refresh_turns) : (i += 1)
        restated = restated or std.mem.indexOf(u8, try gate.note(ar, &root), "[x] a") != null;
    try std.testing.expect(restated);
    // A history rewrite (compaction or emergency trim, possibly MID-turn where
    // no post-turn hook fires) destroyed every pasted copy: the next
    // continuation re-carries the list in full, then gates again.
    _ = try gate.note(ar, &root); // settle into suppression
    root.history_rewrites += 1;
    try std.testing.expect(std.mem.indexOf(u8, try gate.note(ar, &root), "[x] a") != null);
    try std.testing.expect(std.mem.indexOf(u8, try gate.note(ar, &root), "[x] a") == null);
    // reset() is what a fresh run, a user steer and a stop do: the very next
    // continuation carries the list in full again.
    gate.reset();
    try std.testing.expect(std.mem.indexOf(u8, try gate.note(ar, &root), "[x] a") != null);
}

test "re-applying --goal on resume keeps the same objective's own checklist (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = flowRoot(ar);
    // Run 1 of `graff -r sess --goal X` wrote a checklist under the standing
    // goal. Run 2 of the IDENTICAL command must find that work, not park it:
    // re-minting an epoch on every restart orphaned the objective's own list.
    root.goal = standingGoalFromFlag("keep the tree green", null, root.todos.items, 7);
    try root.todos.append(ar, .{ .content = "a", .status = "completed", .epoch = 1 });
    try root.todos.append(ar, .{ .content = "b", .status = "pending", .epoch = 1 });
    try std.testing.expect((try reapplyFlagGoal(ar, &root, "keep the tree green", 9)) == null);
    try std.testing.expectEqual(@as(u64, 1), root.goal.?.epoch);
    try std.testing.expectEqual(@as(i64, 7), root.goal.?.created_ms); // the restored goal, not a re-mint
    try std.testing.expectEqualStrings("[x] a\n[ ] b", goal_state.renderCurrent(&root));
    // A saved pause does not survive the flag: --goal typed TODAY means steer.
    // Restored verbatim, a paused standing goal produced no steering and no
    // completion gate at all, silently, in exactly the flag's headless flows.
    root.goal.?.status = .paused;
    try std.testing.expect((try reapplyFlagGoal(ar, &root, "keep the tree green", 10)) == null);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, root.goal.?.status);
    try std.testing.expectEqual(@as(u64, 1), root.goal.?.epoch); // still the same goal, not a re-mint
    try std.testing.expect(goal_state.goalActive(&root));

    // A DIFFERENT flag objective displaces a live restored /goal like any
    // supersession: new standing goal above every epoch, and the note reports
    // the parked work so the model does not silently continue it.
    root.goal = .{ .objective = "ship phase 2", .epoch = 1, .status = .active };
    root.completion_gate_armed = true; // a stale arm must not survive the boundary
    const note = try reapplyFlagGoal(ar, &root, "keep master green", 11);
    try std.testing.expect(note != null and std.mem.indexOf(u8, note.?, "ship phase 2") != null);
    try std.testing.expect(root.goal.?.standing);
    try std.testing.expectEqual(@as(u64, 2), root.goal.?.epoch);
    try std.testing.expect(!root.completion_gate_armed);
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, 2)); // b parked, never adopted

    // Displacing an already-complete goal queues nothing: its work already
    // parked when it retired, so there is no live boundary to announce.
    root.goal.?.standing = false;
    root.goal.?.status = .complete;
    try std.testing.expect((try reapplyFlagGoal(ar, &root, "keep the tree green", 12)) == null);
    try std.testing.expect(root.goal.?.standing and root.goal.?.status == .active);
}
