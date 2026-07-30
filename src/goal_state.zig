//! Goal-scoped todo epochs, steering-injection policy, and the completion gate
//! (#318). A standing /goal owns its checklist: todos are stamped with the
//! goal's epoch at write time, a replaced or cleared goal parks its unfinished
//! items instead of bequeathing them to the next objective, and the steering
//! note is diff-gated so unchanged state is never re-stated (a re-pasted note
//! on every turn is how compaction learned a dead goal's checklist by heart).
//! Parking is RETENTION, never deletion (#318): a parked item keeps its epoch,
//! stays in root.todos and in the session JSON, and merely stops being current.
//! Every query and render here is epoch-scoped instead - the old destructive
//! parkSuperseded/closeEpoch pair is gone, because a mistyped /goal must not be
//! able to erase the user's checklist.
//! Pure logic — no Io — so every rule here is unit-tested.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;
const repl_glue = @import("repl_glue.zig");

/// Epoch for a goal that replaces `old`, above every epoch already present in
/// `todos` (0 is the no-goal/legacy epoch, so the first goal gets 1). Deriving
/// it from the live goal alone was not enough (#318): /goal clear nulls the goal
/// while its items keep their epoch, so the NEXT goal was born on epoch 1 again
/// and silently adopted the cleared goal's parked checklist - born done when
/// that list was finished, steering someone else's open items when it was not.
/// Parked epochs are the high-water mark, so a new objective always lands above
/// them. The same collision is reachable across a resume (goal null on disk,
/// parked items restored), which is why this reads the todos and not a counter.
pub fn nextEpoch(old: ?agent_mod.Goal, todos: []const TodoItem) u64 {
    var top: u64 = if (old) |g| g.epoch else 0;
    for (todos) |t| top = @max(top, t.epoch);
    return top + 1;
}

/// Epoch new todos are stamped with: the standing goal's while it still owns the
/// work, else 0 (no goal). A COMPLETE goal is not the stamping authority - its
/// checklist parks with it, later writes are unscoped again, and /goal status can
/// never read "complete" with items open. Paused/blocked goals keep their epoch:
/// they are alive, just not steering.
pub fn currentEpoch(goal: ?agent_mod.Goal) u64 {
    const g = goal orelse return 0;
    return if (g.status == .complete) 0 else g.epoch;
}

/// Not-yet-completed items belonging to `epoch`.
pub fn openCount(todos: []const TodoItem, epoch: u64) usize {
    var n: usize = 0;
    for (todos) |t| {
        if (t.epoch == epoch and !std.mem.eql(u8, t.status, "completed")) n += 1;
    }
    return n;
}

/// True only when `epoch` has a nonempty checklist and every item is completed
/// (#226 — an empty list is "no plan yet", never "done").
pub fn allDone(todos: []const TodoItem, epoch: u64) bool {
    var seen = false;
    for (todos) |t| {
        if (t.epoch != epoch) continue;
        if (!std.mem.eql(u8, t.status, "completed")) return false;
        seen = true;
    }
    return seen;
}

/// Still-open items that do NOT belong to `keep_epoch` - the work a supersession
/// parks. Nothing is removed: parked items stay in the list (and in session
/// JSON) under their own epoch, they just stop being current. Callers report the
/// count so the user knows what stopped steering.
pub fn parkedOpenCount(todos: []const TodoItem, keep_epoch: u64) usize {
    var parked: usize = 0;
    for (todos) |t| {
        if (t.epoch == keep_epoch) continue;
        if (!std.mem.eql(u8, t.status, "completed")) parked += 1;
    }
    return parked;
}

/// A fresh goal set while a current (unscoped, or post-completion) checklist
/// exists adopts it: the user just formalized the objective the plan was already
/// serving. Only `from_epoch` items move - work parked by a finished or
/// superseded goal stays parked and is never resurrected into the new objective.
/// Only OPEN items are adopted: a completed item is finished work, and carrying
/// it into the new epoch made the fresh goal born "done" - openCount 0 with a
/// checklist present, so the completion gate's confirm-once arm was skipped and
/// the goal was completable before any of its work happened (#318). Completed
/// items keep their old epoch, i.e. they park.
pub fn adoptTodos(todos: []TodoItem, from_epoch: u64, to_epoch: u64) void {
    for (todos) |*t| {
        if (t.epoch != from_epoch or std.mem.eql(u8, t.status, "completed")) continue;
        t.epoch = to_epoch;
    }
}

/// Per-turn reset of the completion gate's turn-scoped flags. `completion_gate_armed`
/// is deliberately NOT reset here (#318): a model emits at most one
/// attempt_completion per turn, so clearing the arm at the turn boundary made
/// every refusal unresolvable - refuse, turn ends, flag clears, refuse again,
/// forever, with nothing the user could type to break out.
pub fn beginTurn(root: *Agent) void {
    root.completion_refused = false;
}

/// The caller's half of a refusal: arm the double-check so the model's promised
/// second attempt_completion closes the goal (this turn or any later one), and
/// record that the turn did work - a refused call is exempt from the tool
/// counter, so without this the /loop reads the turn as silence (#318).
pub fn noteCompletionRefused(root: *Agent) void {
    root.completion_gate_armed = true;
    root.completion_refused = true;
}

/// Did the checklist finish in THIS process? `allDone` alone is not evidence:
/// todos persist, so a checklist completed in a PREVIOUS session made the next
/// /loop stop at iteration 1 as `accepted` and flipped the restored goal to
/// complete with zero work done (#318). The freshness flag also covers the
/// goal == null case, where an all-completed epoch-0 leftover satisfies allDone
/// on a bare /loop. Only todo_write sets it; loadSession, /clear and /new clear it.
pub fn checklistFinished(root: *const Agent) bool {
    if (!root.todos_dirty) return false;
    return allDone(root.todos.items, currentEpoch(root.goal));
}

/// todo_write just rewrote the current epoch's checklist: the completion
/// double-check gets fresh evidence to check against, and the list becomes
/// this-process evidence for /loop termination (#318).
pub fn noteTodoWrite(root: *Agent) void {
    resetCompletionGate(root);
    root.todos_dirty = true;
}

/// Load-time reconciliation (#318): a session that finished its checklist but
/// quit without calling attempt_completion persists {goal .active, all-[x]
/// list} - models routinely finish work without that call. Restoring it verbatim
/// re-steers the resumed session at work already done, which is #318's literal
/// complaint surviving the resume boundary. Retire the goal instead. Returns
/// true when it reconciled so the caller can note it. `allDone` is false on an
/// empty epoch (#226), so a goal that never wrote a checklist is left alone.
pub fn reconcileRestored(root: *Agent) bool {
    const g = root.goal orelse return false;
    if (g.standing) return false; // --goal is the user's policy for the session; a finished checklist is not their permission to drop it (#318)
    if (g.status != .active or !allDone(root.todos.items, g.epoch)) return false;
    root.goal.?.status = .complete;
    return true;
}

/// An accepted attempt_completion retires the goal - unless it is standing.
/// Returns true when it retired, so the caller can print/trace the difference;
/// the completion itself is recorded either way. A --goal objective is the
/// user's policy for the whole session (--json/-p/SDK included), so the model
/// finishing one task must not end the steering; only /goal clear|pause|<new>
/// can (#318). Pure (no Io) so the rule is unit-tested; the caller passes the
/// clock reading.
pub fn retireOnCompletion(root: *Agent, now_ms: i64) bool {
    // ANY accepted claim consumes the double-check arm: the refusal it answered
    // is spent whether the goal retires, stands, or sits paused. A goal that
    // lives on (standing, or paused-then-resumed) must not ride one refusal
    // forever, or every later claim passes unchecked - the unearned accepted,
    // displaced by one cycle (#318).
    resetCompletionGate(root);
    if (!goalActive(root) or root.goal.?.standing) return false;
    root.goal.?.status = .complete;
    root.goal.?.updated_ms = now_ms;
    return true;
}

/// Reset the completion double-check because the evidence changed: todo_write
/// wrote a new current-epoch checklist, or /goal set|replace|clear moved the
/// objective. Clearing the arm makes the NEXT attempt_completion get checked
/// against the new state instead of riding a refusal the model already answered.
pub fn resetCompletionGate(root: *Agent) void {
    root.completion_gate_armed = false;
}

/// Re-state an unchanged active note after this many suppressed turns, in case
/// the last statement aged out of the model's effective attention.
pub const refresh_turns: u32 = 8;

pub const SteeringGate = struct { inject: bool, fp: u64, age: u32 };

/// Diff-gate for the standing-goal note: inject when the note text changed or
/// the refresh interval lapsed; suppress verbatim repeats. Codex renders all
/// standing context as a diff against a snapshot for the same reason.
pub fn steeringGate(note: []const u8, last_fp: u64, age: u32, refresh_every: u32) SteeringGate {
    if (note.len == 0) return .{ .inject = false, .fp = 0, .age = 0 };
    const fp = std.hash.Wyhash.hash(0, note);
    if (fp != last_fp or age + 1 >= refresh_every) return .{ .inject = true, .fp = fp, .age = 0 };
    return .{ .inject = false, .fp = fp, .age = age + 1 };
}

/// Assemble this turn's goal steering onto `base`: the diff-gated standing
/// note plus any one-shot supersession note (consumed here). Review turns are
/// isolated and get neither.
pub fn applyGoalSteering(arena: Allocator, root: *Agent, base: []const u8) ![]const u8 {
    if (root.review_mode) return base;
    var msg = base;
    const note = try repl_glue.goalSteeringNote(arena, root.goal);
    const gate = steeringGate(note, root.goal_note_fp, root.goal_note_age, refresh_turns);
    root.goal_note_fp = gate.fp;
    root.goal_note_age = gate.age;
    if (gate.inject) msg = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ msg, note });
    if (root.pending_goal_note) |one_shot| {
        msg = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ msg, one_shot });
        root.pending_goal_note = null;
    }
    return msg;
}

/// Root-only, non-review: does this agent carry an active standing goal?
/// Review turns and subagents share the root Agent struct but not its goal,
/// so they must never gate on it or complete it.
pub fn goalActive(agent: *Agent) bool {
    return !agent.sub and !agent.review_mode and agent.goal != null and agent.goal.?.status == .active;
}

/// True when any todo belongs to `epoch` (the goal has a checklist at all).
pub fn hasCurrent(todos: []const TodoItem, epoch: u64) bool {
    for (todos) |t| if (t.epoch == epoch) return true;
    return false;
}

/// Goal gate for attempt_completion (Cline-style double-check): returns refusal
/// text when completion must be deferred - the checklist has open items, or the
/// goal has no checklist at all so there is no evidence it is done - and null
/// to accept. The armed flag (set by the caller on refusal) persists until the
/// checklist or the goal changes, so the promised "call it again" is honored
/// even when the model makes that call on a LATER turn - which is the only way it
/// ever can, since one attempt_completion per turn is all a model emits.
/// A standing --goal is gated like any other goal (#318: an unearned "done" is
/// exactly what the flag's headless sessions need double-checked - exempting
/// them here let one premature claim end a /loop as accepted with open work);
/// standing only exempts RETIREMENT (retireOnCompletion), so a confirmed claim
/// is recorded and the objective keeps steering.
pub fn completionGate(arena: Allocator, agent: *Agent) !?[]const u8 {
    if (!goalActive(agent)) return null;
    if (agent.completion_gate_armed) return null;
    const standing = agent.goal.?.standing;
    const epoch = currentEpoch(agent.goal);
    const open = openCount(agent.todos.items, epoch);
    if (open > 0) return try completionRefusalText(arena, open, renderTodos(agent, epoch), standing);
    if (!hasCurrent(agent.todos.items, epoch)) {
        if (standing) return "completion deferred: the standing goal has no checklist yet, so there is no evidence this task is done. If it truly is, call attempt_completion again - now or on a later turn - to record it (the standing objective keeps steering either way); otherwise write the remaining plan with todo_write and work it.";
        return "completion deferred: the standing goal has no checklist yet, so there is no evidence the objective is done. If it truly is, call attempt_completion again - now or on a later turn - to close the goal; otherwise write the remaining plan with todo_write and work it.";
    }
    return null; // nonempty checklist, every item completed
}

/// The refusal text for completionGate's open-checklist arm. The second-call
/// consequence differs (#318): a /goal objective closes and parks its open
/// items; a standing --goal records the completion and stays active.
pub fn completionRefusalText(arena: Allocator, open: usize, rendered: []const u8, standing: bool) ![]const u8 {
    const consequence = if (standing)
        "to record completion anyway; the standing objective and its open items stay active"
    else
        "to close the goal anyway; the open items are then parked (kept in the session, no longer steering)";
    return std.fmt.allocPrint(arena, "completion deferred: the standing goal still has {d} open checklist item(s):\n{s}\nFinish them, or call attempt_completion again - now or on a later turn - {s}.", .{ open, rendered, consequence });
}

/// One-shot note for the turn after /goal replaced an active goal — ports
/// codex's objective_updated.md steering: the new objective supersedes, and
/// work that only served the old one must not silently continue.
pub fn supersededNote(arena: Allocator, old_objective: []const u8, parked_open: usize) ![]const u8 {
    if (parked_open > 0)
        return std.fmt.allocPrint(arena, "[goal update: the standing goal above supersedes the previous goal \"{s}\"; {d} unfinished checklist item(s) from it were parked. Avoid continuing work that only served the previous objective unless it also helps the new one. Start a fresh todo_write checklist for this objective.]", .{ old_objective, parked_open });
    return std.fmt.allocPrint(arena, "[goal update: the standing goal above supersedes the previous goal \"{s}\". Avoid continuing work that only served the previous objective unless it also helps the new one.]", .{old_objective});
}

/// One-shot note for the turn after /goal clear parked an unfinished checklist.
pub fn clearedNote(arena: Allocator, parked_open: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "[goal update: the standing goal was cleared and its checklist parked ({d} unfinished item(s), kept in the session but no longer current). Do not resume that work unless the user asks for it again.]", .{parked_open});
}

/// Render `epoch`'s checklist ("[x]/[~]/[ ] content" lines). Epoch-scoped (#318):
/// items parked by an earlier goal are retained but never rendered as if they
/// were current work. Moved from agent.zig (600-line cap); member-aliased so
/// self.renderTodos(epoch) resolves unchanged.
pub fn renderTodos(self: *Agent, epoch: u64) []const u8 {
    if (!hasCurrent(self.todos.items, epoch)) return "(no todos)";
    var aw: Io.Writer.Allocating = .init(self.arena);
    const w = &aw.writer;
    for (self.todos.items) |t| {
        if (t.epoch != epoch) continue;
        const mark = if (std.mem.eql(u8, t.status, "completed"))
            "[x]"
        else if (std.mem.eql(u8, t.status, "in_progress"))
            "[~]"
        else
            "[ ]";
        w.print("{s} {s}\n", .{ mark, t.content }) catch break;
    }
    return std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
}

/// The current epoch's checklist, or "" when it has no items - callers that
/// carry the list into steering pick their checklist-free variant on "".
pub fn renderCurrent(root: *Agent) []const u8 {
    const epoch = currentEpoch(root.goal);
    if (!hasCurrent(root.todos.items, epoch)) return "";
    return renderTodos(root, epoch);
}

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
    // The goal == null variant: a bare /loop must not stop at iteration 1 just
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
    beginTurn(&root);
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
    // Refresh interval lapse re-states an unchanged note.
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
