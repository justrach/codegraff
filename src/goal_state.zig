//! Goal-scoped todo epochs, steering-injection policy, and the completion gate
//! (#318). A standing /goal owns its checklist: todos are stamped with the
//! goal's epoch at write time, a replaced or cleared goal parks its unfinished
//! items instead of bequeathing them to the next objective, and the steering
//! note is diff-gated so unchanged state is never re-stated (a re-pasted note
//! on every turn is how compaction learned a dead goal's checklist by heart).
//! Pure logic — no Io — so every rule here is unit-tested.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;
const repl_glue = @import("repl_glue.zig");

/// Epoch for a goal that replaces `old` (0 is the no-goal/legacy epoch).
pub fn nextEpoch(old: ?agent_mod.Goal) u64 {
    return if (old) |g| g.epoch + 1 else 1;
}

/// Epoch new todos are stamped with: the standing goal's, else 0 (no goal).
pub fn currentEpoch(goal: ?agent_mod.Goal) u64 {
    return if (goal) |g| g.epoch else 0;
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

/// Remove every item not belonging to `keep_epoch`: a superseded goal's
/// checklist is parked, never inherited by the new objective. Returns how many
/// still-open items were parked so the caller can report them to the user.
pub fn parkSuperseded(todos: *std.ArrayList(TodoItem), keep_epoch: u64) usize {
    var parked_open: usize = 0;
    var i: usize = 0;
    while (i < todos.items.len) {
        const t = todos.items[i];
        if (t.epoch == keep_epoch) {
            i += 1;
            continue;
        }
        if (!std.mem.eql(u8, t.status, "completed")) parked_open += 1;
        _ = todos.orderedRemove(i);
    }
    return parked_open;
}

/// Close `epoch`'s checklist: remove all its items. A completed (or force-
/// closed) goal takes its list with it - the deferral text promises open items
/// are parked, and /goal status must never read "complete" with items open.
pub fn closeEpoch(todos: *std.ArrayList(TodoItem), epoch: u64) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < todos.items.len) {
        if (todos.items[i].epoch == epoch) {
            _ = todos.orderedRemove(i);
            removed += 1;
        } else i += 1;
    }
    return removed;
}

/// A fresh goal set while an unscoped (pre-goal) checklist exists adopts it:
/// the user just formalized the objective the plan was already serving.
pub fn adoptTodos(todos: []TodoItem, epoch: u64) void {
    for (todos) |*t| t.epoch = epoch;
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
/// to accept. The armed flag (set by the caller on refusal, reset each turn)
/// lets an explicit second call close the goal anyway.
pub fn completionGate(arena: Allocator, agent: *Agent) !?[]const u8 {
    if (!goalActive(agent)) return null;
    if (agent.completion_gate_armed) return null;
    const epoch = currentEpoch(agent.goal);
    const open = openCount(agent.todos.items, epoch);
    if (open > 0) return try completionRefusalText(arena, open, renderTodos(agent));
    if (!hasCurrent(agent.todos.items, epoch))
        return "completion deferred: the standing goal has no checklist yet, so there is no evidence the objective is done. If it truly is, call attempt_completion again to close the goal; otherwise write the remaining plan with todo_write and work it.";
    return null; // nonempty checklist, every item completed
}

/// The refusal text for completionGate's open-checklist arm.
pub fn completionRefusalText(arena: Allocator, open: usize, rendered: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "completion deferred: the standing goal still has {d} open checklist item(s):\n{s}\nFinish them, or call attempt_completion again to close the goal anyway (open items will be parked).", .{ open, rendered });
}

/// One-shot note for the turn after /goal replaced an active goal — ports
/// codex's objective_updated.md steering: the new objective supersedes, and
/// work that only served the old one must not silently continue.
pub fn supersededNote(arena: Allocator, old_objective: []const u8, parked_open: usize) ![]const u8 {
    if (parked_open > 0)
        return std.fmt.allocPrint(arena, "[goal update: the standing goal above supersedes the previous goal \"{s}\"; {d} unfinished checklist item(s) from it were parked. Avoid continuing work that only served the previous objective unless it also helps the new one. Start a fresh todo_write checklist for this objective.]", .{ old_objective, parked_open });
    return std.fmt.allocPrint(arena, "[goal update: the standing goal above supersedes the previous goal \"{s}\". Avoid continuing work that only served the previous objective unless it also helps the new one.]", .{old_objective});
}

/// One-shot note for the turn after /goal clear closed an unfinished checklist.
pub fn clearedNote(arena: Allocator, parked_open: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "[goal update: the standing goal was cleared and its checklist closed ({d} unfinished item(s) parked). Do not resume that work unless the user asks for it again.]", .{parked_open});
}

/// Render the checklist ("[x]/[~]/[ ] content" lines). Moved from agent.zig
/// (600-line cap); member-aliased so self.renderTodos() resolves unchanged.
pub fn renderTodos(self: *Agent) []const u8 {
    if (self.todos.items.len == 0) return "(no todos)";
    var aw: Io.Writer.Allocating = .init(self.arena);
    const w = &aw.writer;
    for (self.todos.items) |t| {
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

test "epochs: nextEpoch monotonic from the replaced goal; currentEpoch 0 without a goal" {
    try std.testing.expectEqual(@as(u64, 1), nextEpoch(null));
    try std.testing.expectEqual(@as(u64, 4), nextEpoch(.{ .objective = "a", .epoch = 3 }));
    try std.testing.expectEqual(@as(u64, 0), currentEpoch(null));
    try std.testing.expectEqual(@as(u64, 7), currentEpoch(.{ .objective = "a", .epoch = 7 }));
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

test "parkSuperseded drops other epochs, counts open ones, keeps the new epoch (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var todos: std.ArrayList(TodoItem) = .empty;
    try todos.append(ar, .{ .content = "phase3 audit", .status = "pending", .epoch = 1 });
    try todos.append(ar, .{ .content = "phase3 fix", .status = "completed", .epoch = 1 });
    try todos.append(ar, .{ .content = "phase2 test", .status = "in_progress", .epoch = 2 });
    const parked = parkSuperseded(&todos, 2);
    try std.testing.expectEqual(@as(usize, 1), parked); // only the OPEN phase3 item counts
    try std.testing.expectEqual(@as(usize, 1), todos.items.len);
    try std.testing.expectEqualStrings("phase2 test", todos.items[0].content);
    // Completing epoch 2 closes its checklist entirely (the parking promise).
    try std.testing.expectEqual(@as(usize, 1), closeEpoch(&todos, 2));
    try std.testing.expectEqual(@as(usize, 0), todos.items.len);
}

test "adoptTodos re-stamps a pre-goal checklist into the new goal's epoch" {
    var todos = [_]TodoItem{
        .{ .content = "a", .status = "pending", .epoch = 0 },
        .{ .content = "b", .status = "completed", .epoch = 0 },
    };
    adoptTodos(&todos, 5);
    try std.testing.expectEqual(@as(u64, 5), todos[0].epoch);
    try std.testing.expectEqual(@as(u64, 5), todos[1].epoch);
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
