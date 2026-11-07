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
//! RETIREMENT (#394) is the same retention one axis over: an item a LATER user
//! ask retired keeps its epoch and its place in root.todos and the session JSON,
//! and is simply skipped by every query and render below - so a finished
//! checklist stops following the session around without anything being deleted.
//! goal_todo.retireFinishedForNewAsk owns when that happens.
//! Pure logic — no Io — so every rule here is unit-tested.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;
const goal_todo = @import("goal_todo.zig");
const repl_glue = @import("repl_glue.zig");

/// Dropped = abandoned by user order, not finished (#1545): kept as the
/// record, invisible to every epoch-scoped query, never nagged for.
pub fn isDropped(status: []const u8) bool {
    return std.mem.eql(u8, status, "dropped");
}

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

/// Open items in `epoch` (retired, cancelled and dropped never count, #1545).
pub fn openCount(todos: []const TodoItem, epoch: u64) usize {
    var n: usize = 0;
    for (todos) |t| {
        if (t.epoch == epoch and !t.retired and !t.closed() and !isDropped(t.status)) n += 1;
    }
    return n;
}

/// True when `epoch` has a nonempty checklist and every live item is closed.
/// Dropped items are retained history, not completion evidence (#1545).
/// (#226 — an empty list is "no plan yet", never "done"). An epoch left holding
/// only RETIRED items is empty by this rule, so retiring a finished checklist
/// can never read as a fresh completion (#394).
pub fn allDone(todos: []const TodoItem, epoch: u64) bool {
    var seen = false;
    for (todos) |t| {
        if (t.epoch != epoch or t.retired or isDropped(t.status)) continue;
        if (!t.closed()) return false; // cancelled closes scope, but never verifies (goal_verify)
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
        if (t.epoch == keep_epoch or t.retired or isDropped(t.status)) continue;
        if (!t.closed()) parked += 1;
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
        if (t.epoch != from_epoch or t.retired or t.closed() or isDropped(t.status)) continue;
        t.epoch = to_epoch;
    }
}

/// Per-turn reset of the completion gate's turn-scoped flags. `completion_gate_armed`
/// is deliberately NOT reset here (#318): a model emits at most one
/// attempt_completion per turn, so clearing the arm at the turn boundary made
/// every refusal unresolvable - refuse, turn ends, flag clears, refuse again,
/// forever, with nothing the user could type to break out.
/// `new_ask` marks a turn the USER started (false for a run's continuation,
/// which is the same ask still running): that is the boundary where a finished
/// checklist retires instead of following the session forever (#394).
pub fn beginTurn(root: *Agent, new_ask: bool) void {
    root.completion_refused = false;
    if (new_ask) _ = goal_todo.retireFinishedForNewAsk(root);
}

/// The caller's half of a refusal: arm the double-check so the model's promised
/// second attempt_completion closes the goal (this turn or any later one), and
/// record that the turn did work - a refused call is exempt from the tool
/// counter, so without this the run reads the turn as silence (#318).
pub fn noteCompletionRefused(root: *Agent) void {
    root.completion_gate_armed = true;
    root.completion_refused = true;
}

/// Did the checklist finish in THIS process? `allDone` alone is not evidence:
/// todos persist, so a checklist completed in a PREVIOUS session made the next
/// run stop at iteration 1 as `accepted` and flipped the restored goal to
/// complete with zero work done (#318). The freshness flag also covers the
/// goal == null case, where an all-completed epoch-0 leftover satisfies allDone
/// on a goal-less run. Only todo_write sets it; loadSession, /clear and /new clear it.
pub fn checklistFinished(root: *const Agent) bool {
    if (!root.todos_dirty) return false;
    return allDone(root.todos.items, currentEpoch(root.goal));
}

/// todo_write just rewrote the current epoch's checklist: the completion
/// double-check gets fresh evidence to check against, and the list becomes
/// this-process evidence for run termination (#318).
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
/// LoopListGate: re-paste an unchanged run checklist after this many quiet turns.
pub const refresh_turns: u32 = 8;
/// Standing-goal essay. 0 = never; the objective lives in the prefix (ADR 0005).
pub const essay_refresh_turns: u32 = 0;

pub const SteeringGate = struct { inject: bool, fp: u64, age: u32 };

/// Diff-gate for the standing-goal note: inject when the note text changed or
/// the refresh interval lapsed; suppress verbatim repeats. Codex renders all
/// standing context as a diff against a snapshot for the same reason.
pub fn steeringGate(note: []const u8, last_fp: u64, age: u32, refresh_every: u32) SteeringGate {
    if (note.len == 0) return .{ .inject = false, .fp = 0, .age = 0 };
    const fp = std.hash.Wyhash.hash(0, note);
    if (fp != last_fp) return .{ .inject = true, .fp = fp, .age = 0 };
    if (refresh_every > 0 and age + 1 >= refresh_every) return .{ .inject = true, .fp = fp, .age = 0 };
    return .{ .inject = false, .fp = fp, .age = age + 1 };
}

/// Assemble this turn's goal steering onto `base`: the diff-gated standing
/// note plus any one-shot supersession note (consumed here). Review turns are
/// isolated and get neither.
pub fn applyGoalSteering(arena: Allocator, root: *Agent, base: []const u8) ![]const u8 {
    if (root.review_mode) return base;
    var msg = base;
    const note = try repl_glue.goalSteeringNote(arena, root.goal);
    const gate = steeringGate(note, root.goal_note_fp, root.goal_note_age, essay_refresh_turns);
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

/// True when any LIVE todo belongs to `epoch` (the goal has a checklist at all).
/// Retired items do not qualify (#394): an epoch holding only retired history
/// has no evidence of its own, so the completion gate asks for a plan instead of
/// accepting "checklist present, 0 open" - the #318 born-done trap.
pub fn hasCurrent(todos: []const TodoItem, epoch: u64) bool {
    for (todos) |t| if (t.epoch == epoch and !t.retired) return true;
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
/// them here let one premature claim end a run as accepted with open work);
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
        if (t.epoch != epoch or t.retired) continue; // #394: a previous ask's finished list is archive, not this ask's plan
        const mark = if (std.mem.eql(u8, t.status, "completed"))
            "[x]"
        else if (std.mem.eql(u8, t.status, "in_progress"))
            "[~]"
        else if (std.mem.eql(u8, t.status, "cancelled") or isDropped(t.status))
            "[-]"
        else
            "[ ]";
        w.print("{s} {s}", .{ mark, t.content }) catch break;
        if (t.reason.len > 0) w.print(" (cancelled: {s})", .{t.reason}) catch break; // #1520: a cancel shows why
        w.writeByte('\n') catch break;
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
