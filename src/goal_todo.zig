//! todo_write's write path: the epoch-scoped replace, plus the one rule that
//! stops a replace from destroying history - a current-epoch item that is
//! already COMPLETED survives being omitted.
//!
//! Replace semantics themselves stay (codex's update_plan and Claude Code's
//! TodoWrite are both full-replace, and an intentional re-plan must be able to
//! abandon open work), so an omitted PENDING or IN_PROGRESS item is still
//! dropped. A completed item is different in kind: it is a record of what
//! happened, not a plan. Keeping it can only help - openCount ignores completed
//! items, so a preserved one can never hold a completion back - while losing it
//! is durable damage, and the model rewriting the list from a summary after a
//! compaction is exactly how three finished items came back as pending (#318).
//! Forgecode's delta-writes are structurally wipe-proof; this takes that
//! property for the single item class where it is unambiguous. An incoming item
//! whose content matches a preserved one WINS, so "redo X, as pending" still
//! works and never leaves a duplicate behind.
//!
//! The preserve rule is per-ASK, not per-session (#394): retireFinishedForNewAsk
//! below expires it at the next user ask, so the record of done work survives
//! the ask that produced it without following every later prompt around.
//!
//! Split out of agent_tools.zig, which is at this repo's 600-line file cap.
//! Reached through the `test { _ = ... }` hook in main.zig - without that line
//! these tests silently compile to nothing and the suite still reports green.

const std = @import("std");
const Value = std.json.Value;
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;
const goal_state = @import("goal_state.zig");

/// Make room for a replacement checklist on `epoch`: remove that epoch's items,
/// EXCEPT completed ones whose content the incoming list does not mention.
/// Items from other (parked) epochs are never touched - the authoring goal is
/// rewriting its own list, nobody else's. Returns the number removed.
/// Callers must guarantee `incoming` is nonempty (applyTodoWrite rejects the
/// empty case): an empty replace here would leave only completed survivors,
/// an epoch that reads allDone off a write that did nothing (#318).
pub fn clearEpochForReplace(todos: *std.ArrayList(TodoItem), epoch: u64, incoming: []const []const u8) usize {
    var dropped_open: usize = 0;
    var i: usize = 0;
    while (i < todos.items.len) {
        const t = todos.items[i];
        const done = std.mem.eql(u8, t.status, "completed");
        const mentioned = mentions(incoming, t.content);
        if (t.epoch != epoch or (done and !mentioned)) {
            i += 1;
            continue;
        }
        // Open work the replacement did not mention is being ABANDONED. Count
        // it so the caller can say so: every user-driven drop reports a count
        // (/goal clear, /goal <new>), and only the model-driven one was silent.
        if (!done and !mentioned) dropped_open += 1;
        _ = todos.orderedRemove(i);
    }
    return dropped_open;
}

fn mentions(contents: []const []const u8, content: []const u8) bool {
    for (contents) |c| if (std.mem.eql(u8, c, content)) return true;
    return false;
}

/// A genuinely NEW user ask retires the checklist the PREVIOUS one finished
/// (#394). clearEpochForReplace keeps an omitted completed item because it is
/// the record of work done under THIS ask - but nothing ever expired that
/// parking, so five unrelated asks in one session accumulated: todo_read came
/// back with thirteen [x] entries spanning goals that had nothing to do with the
/// prompt in front of the model, and every new prompt inherited the pile.
/// The boundary is the cheapest honest one available in the loop: a user turn
/// (goal_state.beginTurn's `new_ask` - never a /loop continuation, which is the
/// same ask still running) whose current epoch is FULLY completed. An unfinished
/// checklist is live work and crosses the turn untouched, which is what the
/// compaction handoff and every cross-turn resume depend on.
/// Retirement is retention, like parking (#318): the items keep their content,
/// status and epoch, stay in root.todos and in the session JSON as the ask's
/// archive, and are merely skipped by the epoch-scoped queries in goal_state.
/// Subagents and /review turns share the Agent struct but not the user's ask,
/// so they never retire anything. Returns how many items retired.
pub fn retireFinishedForNewAsk(root: *Agent) usize {
    if (root.sub or root.review_mode) return 0;
    const epoch = goal_state.currentEpoch(root.goal);
    // allDone is false on an empty epoch (#226) and skips already-retired items,
    // so this is a no-op with no checklist, with open work, or run twice.
    if (!goal_state.allDone(root.todos.items, epoch)) return 0;
    var n: usize = 0;
    for (root.todos.items) |*t| {
        if (t.epoch != epoch or t.retired) continue;
        t.retired = true;
        n += 1;
    }
    return n;
}

pub const WriteResult = struct { text: []const u8, rejected: bool = false, dropped_open: usize = 0 };

/// The whole todo_write handler: replace the current epoch's checklist with
/// `list` (the tool call's "todos" argument, already parsed), preserving
/// omitted completed items, and return the rendered result the model sees.
/// A write with ZERO usable items (missing/typo'd "todos" key, empty array,
/// items without a content string) is REJECTED without touching anything:
/// under the preserve rule it would have left the epoch holding only
/// completed survivors - allDone true, todos_dirty true - so one malformed
/// call ended a /loop as accepted and retired the goal (#318, proven by the
/// round-4 verifier). It must also never count as completion evidence, so
/// noteTodoWrite runs only on the accepted path.
pub fn applyTodoWrite(root: *Agent, list: ?Value) !WriteResult {
    const epoch = goal_state.currentEpoch(root.goal); // items belong to the goal that authored them (#318)
    var incoming: std.ArrayList([]const u8) = .empty;
    defer incoming.deinit(root.gpa);
    if (asArray(list)) |items| {
        for (items) |item| if (contentOf(item)) |c| try incoming.append(root.gpa, c);
    }
    if (incoming.items.len == 0)
        return .{ .text = "todo_write had no usable items; the list is unchanged. Each item needs a content string and a status. Send your full remaining plan - completed items you omit are kept automatically.", .rejected = true };
    const dropped_open = clearEpochForReplace(&root.todos, epoch, incoming.items);
    goal_state.noteTodoWrite(root); // fresh evidence for the completion double-check, and this-process evidence for /loop (#318)
    if (asArray(list)) |items| {
        for (items) |item| {
            const content = contentOf(item) orelse continue;
            const status = if (item.object.get("status")) |st| (if (st == .string) st.string else "pending") else "pending";
            try root.todos.append(root.arena, .{
                .content = try root.arena.dupe(u8, content),
                .status = try root.arena.dupe(u8, status),
                .epoch = epoch,
            });
        }
    }
    const rendered = goal_state.renderTodos(root, epoch);
    if (dropped_open == 0) return .{ .text = rendered };
    // Name the abandonment. The model may well have meant it, but the user
    // reading the transcript needs the same count they get from /goal clear.
    return .{
        .text = try std.fmt.allocPrint(root.arena, "{s}\n({d} open item(s) you left out were dropped; re-list one to keep it)", .{ rendered, dropped_open }),
        .dropped_open = dropped_open,
    };
}

fn asArray(list: ?Value) ?[]const Value {
    const l = list orelse return null;
    if (l != .array) return null;
    return l.array.items;
}

fn contentOf(item: Value) ?[]const u8 {
    if (item != .object) return null;
    const c = item.object.get("content") orelse return null;
    if (c != .string) return null;
    return c.string;
}

/// A root agent in the shape the todo helpers read; no live turn behind it.
fn todoRoot(arena: std.mem.Allocator) Agent {
    var root: Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = arena;
    root.sub = false;
    root.review_mode = false;
    root.todos = .empty;
    root.goal = null;
    root.todos_dirty = false;
    root.completion_gate_armed = false;
    return root;
}

/// Parse a todo_write "todos" argument out of JSON, the way the dispatcher does.
fn todosArg(arena: std.mem.Allocator, json: []const u8) !?Value {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, json, .{ .allocate = .alloc_always });
    return parsed.object.get("todos");
}

test "a replace keeps omitted completed items and still drops omitted open ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };

    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"write the helper","status":"completed"},
        \\          {"content":"test it","status":"completed"},
        \\          {"content":"abandoned idea","status":"pending"},
        \\          {"content":"wire it up","status":"in_progress"}]}
    ));
    try std.testing.expectEqual(@as(usize, 4), root.todos.items.len);

    // The model re-plans and sends only the remaining work. Before this rule,
    // the two finished items were deleted outright - most often after a
    // compaction, where the list is rewritten from a summary (#318) - and the
    // goal's record of what it had already done was gone for good.
    const rendered = (try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"wire it up","status":"in_progress"}]}
    ))).text;
    // The list itself is unchanged; the abandonment is NAMED after it, because
    // a silent model-driven drop was the one deletion the user never saw.
    try std.testing.expect(std.mem.startsWith(u8, rendered, "[x] write the helper\n[x] test it\n[~] wire it up"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1 open item(s) you left out were dropped") != null);
    // The omitted OPEN item really is gone: a re-plan must be able to abandon work.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "abandoned idea") == null);
    try std.testing.expectEqual(@as(usize, 1), goal_state.openCount(root.todos.items, 1));

    // And preserving them cannot hold a completion back: openCount ignores
    // completed items, so finishing the last one still reads as done.
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"wire it up","status":"completed"}]}
    ));
    try std.testing.expect(goal_state.allDone(root.todos.items, 1));
    try std.testing.expect(goal_state.checklistFinished(&root));
}

test "an incoming item with the same content replaces the preserved one, never duplicates it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship phase 2", .epoch = 1 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"land the fix","status":"completed"}]}
    ));
    // "that one was not actually done, redo it" has to keep working: the
    // incoming item wins outright, so the list holds one entry, not two.
    const rendered = (try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"land the fix","status":"pending"},
        \\          {"content":"and verify","status":"pending"}]}
    ))).text;
    try std.testing.expectEqualStrings("[ ] land the fix\n[ ] and verify", rendered);
    try std.testing.expectEqual(@as(usize, 2), root.todos.items.len);
    try std.testing.expectEqual(@as(usize, 2), goal_state.openCount(root.todos.items, 1));
}

test "the replace stays epoch-scoped: parked work of any status is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    try root.todos.append(ar, .{ .content = "parked open", .status = "pending", .epoch = 3 });
    try root.todos.append(ar, .{ .content = "parked done", .status = "completed", .epoch = 3 });
    root.goal = .{ .objective = "phase B", .epoch = 4 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"B1","status":"pending"}]}
    ));
    const rendered = (try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"B2","status":"pending"}]}
    ))).text;
    try std.testing.expect(std.mem.startsWith(u8, rendered, "[ ] B2")); // B1 was open, so it dropped
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1 open item(s) you left out were dropped") != null);
    try std.testing.expectEqual(@as(usize, 3), root.todos.items.len);
    try std.testing.expectEqual(@as(u64, 3), root.todos.items[0].epoch);
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, 4));
}

test "a write with zero usable items is rejected untouched, never completion evidence (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship", .epoch = 1 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"done","status":"completed"},{"content":"open","status":"pending"}]}
    ));
    root.todos_dirty = false; // as after a resume: the list is persisted state, not evidence
    // The round-4 verifier's exact trace: under the preserve rule, an empty or
    // malformed write used to strip the open items and leave only completed
    // survivors - allDone true, todos_dirty true - so one typo'd call ended a
    // /loop as accepted and retired the goal. It is rejected outright instead.
    for ([_]?Value{ try todosArg(ar, "{\"todos\":[]}"), null, try todosArg(ar, "{\"todos\":[{\"status\":\"pending\"}]}") }) |bad| {
        const r = try applyTodoWrite(&root, bad);
        try std.testing.expect(r.rejected);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "unchanged") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), root.todos.items.len); // nothing removed
    try std.testing.expectEqual(@as(usize, 1), goal_state.openCount(root.todos.items, 1));
    try std.testing.expect(!root.todos_dirty); // and no fake this-process evidence
    try std.testing.expect(!goal_state.checklistFinished(&root));
}

test "preserved [x] items never make the NEXT goal born done (#318 guard holds)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "phase A", .epoch = 1 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"A1","status":"completed"}]}
    ));
    // A later replace omits A1 but it survives as history: the epoch reads all
    // done - precisely the state that used to make the next goal inherit a
    // "done" checklist. adoptTodos takes OPEN items only, so it adopts nothing.
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"A2","status":"completed"}]}
    ));
    try std.testing.expect(goal_state.allDone(root.todos.items, 1));

    const epoch_b = goal_state.nextEpoch(root.goal, root.todos.items);
    goal_state.adoptTodos(root.todos.items, goal_state.currentEpoch(root.goal), epoch_b);
    root.goal = .{ .objective = "phase B", .epoch = epoch_b };
    goal_state.resetCompletionGate(&root);
    try std.testing.expect(!goal_state.hasCurrent(root.todos.items, epoch_b));
    try std.testing.expect(!goal_state.checklistFinished(&root));
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "no checklist") != null);
    // A's record is still there, parked under its own epoch.
    try std.testing.expectEqualStrings("[x] A1\n[x] A2", goal_state.renderTodos(&root, 1));
}

test "a new user ask retires the finished checklist; the next list is that ask's own (#394)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar); // no /goal: the plain todo_write user #394 was filed by

    // Ask 1, finished.
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"rename the flag in config.zig","status":"completed"}]}
    ));
    try std.testing.expect(goal_state.allDone(root.todos.items, 0));
    try std.testing.expect(goal_state.checklistFinished(&root));

    // The user asks for something else. Before this, the [x] line rode along
    // into every later list - five asks deep it was a thirteen-item pile.
    try std.testing.expectEqual(@as(usize, 1), retireFinishedForNewAsk(&root));
    try std.testing.expectEqualStrings("(no todos)", goal_state.renderTodos(&root, 0));
    try std.testing.expectEqualStrings("", goal_state.renderCurrent(&root));
    try std.testing.expect(!goal_state.hasCurrent(root.todos.items, 0));
    try std.testing.expect(!goal_state.allDone(root.todos.items, 0)); // retired history is not a fresh completion
    try std.testing.expect(!goal_state.checklistFinished(&root));
    try std.testing.expectEqual(@as(usize, 0), goal_state.openCount(root.todos.items, 0));
    // Retirement RETAINS (#318): the archive keeps every field, it just stops being current.
    try std.testing.expectEqual(@as(usize, 1), root.todos.items.len);
    try std.testing.expect(root.todos.items[0].retired);
    try std.testing.expectEqualStrings("rename the flag in config.zig", root.todos.items[0].content);
    try std.testing.expectEqualStrings("completed", root.todos.items[0].status);
    try std.testing.expectEqual(@as(u64, 0), root.todos.items[0].epoch);

    // Ask 2's checklist is ask 2's work alone - no inherited [x] lines, and no
    // "1 open item(s) you left out were dropped" either: nothing open was left out.
    const rendered = (try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"draft the release notes","status":"in_progress"}]}
    ))).text;
    try std.testing.expectEqualStrings("[~] draft the release notes", rendered);
    // Mid-ask turns retire nothing: the list is open work.
    try std.testing.expectEqual(@as(usize, 0), retireFinishedForNewAsk(&root));
    try std.testing.expectEqualStrings("[~] draft the release notes", goal_state.renderCurrent(&root));

    // Ask 2 finishes; ask 3 retires ITS list and leaves the older archive alone.
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"draft the release notes","status":"completed"}]}
    ));
    try std.testing.expectEqual(@as(usize, 1), retireFinishedForNewAsk(&root));
    try std.testing.expectEqual(@as(usize, 0), retireFinishedForNewAsk(&root)); // idempotent
    try std.testing.expectEqualStrings("(no todos)", goal_state.renderTodos(&root, 0));
    try std.testing.expectEqual(@as(usize, 2), root.todos.items.len);
}

test "retirement is per-ASK: an unfinished checklist crosses the turn whole (#394 keeps 2896b32)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship the migration", .epoch = 1 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"migrate the schema","status":"completed"},
        \\          {"content":"backfill the rows","status":"pending"}]}
    ));
    // The user turn (or a compaction handoff) lands mid-ask: one item done, one
    // open. Retiring here would be the #318 bug again - the completed item is
    // this ask's own record and compaction-keeps-completed rides on it.
    try std.testing.expectEqual(@as(usize, 0), retireFinishedForNewAsk(&root));
    try std.testing.expectEqualStrings("[x] migrate the schema\n[ ] backfill the rows", goal_state.renderCurrent(&root));
    // And the omitted-completed preserve rule still holds inside the ask.
    const rendered = (try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"backfill the rows","status":"in_progress"}]}
    ))).text;
    try std.testing.expectEqualStrings("[x] migrate the schema\n[~] backfill the rows", rendered);
    try std.testing.expectEqual(@as(usize, 0), retireFinishedForNewAsk(&root));
    try std.testing.expect(!root.todos.items[0].retired);
}

test "retirement is epoch-scoped, root-only, and leaves no checklist to complete against (#394)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    try root.todos.append(ar, .{ .content = "parked open", .status = "pending", .epoch = 1 });
    try root.todos.append(ar, .{ .content = "parked done", .status = "completed", .epoch = 1 });
    root.goal = .{ .objective = "phase B", .epoch = 2 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"B1","status":"completed"}]}
    ));

    // Subagents and /review turns share the Agent struct but not the user's ask.
    root.sub = true;
    try std.testing.expectEqual(@as(usize, 0), retireFinishedForNewAsk(&root));
    root.sub = false;
    root.review_mode = true;
    try std.testing.expectEqual(@as(usize, 0), retireFinishedForNewAsk(&root));
    root.review_mode = false;

    try std.testing.expectEqual(@as(usize, 1), retireFinishedForNewAsk(&root)); // B1 only
    try std.testing.expect(!root.todos.items[0].retired and !root.todos.items[1].retired);
    try std.testing.expectEqualStrings("[ ] parked open\n[x] parked done", goal_state.renderTodos(&root, 1));
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, 2));
    // The retired epoch reads as "no checklist yet", not as a finished one: a
    // completion claim on the new ask is deferred rather than pre-accepted off
    // the previous ask's [x] lines (#318's born-done trap, one boundary over).
    const refusal = try goal_state.completionGate(ar, &root);
    try std.testing.expect(refusal != null and std.mem.indexOf(u8, refusal.?, "no checklist") != null);
}
