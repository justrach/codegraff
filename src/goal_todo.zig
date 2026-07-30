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
/// This is goal_state.clearEpoch plus the preserve rule; clearEpoch itself
/// stays for the callers that really do mean "drop the whole epoch".
pub fn clearEpochForReplace(todos: *std.ArrayList(TodoItem), epoch: u64, incoming: []const []const u8) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < todos.items.len) {
        const t = todos.items[i];
        const preserve = std.mem.eql(u8, t.status, "completed") and !mentions(incoming, t.content);
        if (t.epoch != epoch or preserve) {
            i += 1;
            continue;
        }
        _ = todos.orderedRemove(i);
        removed += 1;
    }
    return removed;
}

fn mentions(contents: []const []const u8, content: []const u8) bool {
    for (contents) |c| if (std.mem.eql(u8, c, content)) return true;
    return false;
}

/// The whole todo_write handler: replace the current epoch's checklist with
/// `list` (the tool call's "todos" argument, already parsed), preserving
/// omitted completed items, and return the rendered result the model sees.
/// `list` is null or a non-array when the model sent nothing usable, which is a
/// legitimate way to clear the open items of a checklist.
pub fn applyTodoWrite(root: *Agent, list: ?Value) ![]const u8 {
    const epoch = goal_state.currentEpoch(root.goal); // items belong to the goal that authored them (#318)
    var incoming: std.ArrayList([]const u8) = .empty;
    defer incoming.deinit(root.gpa);
    if (asArray(list)) |items| {
        for (items) |item| if (contentOf(item)) |c| try incoming.append(root.gpa, c);
    }
    _ = clearEpochForReplace(&root.todos, epoch, incoming.items);
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
    return goal_state.renderTodos(root, epoch);
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
    const rendered = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"wire it up","status":"in_progress"}]}
    ));
    try std.testing.expectEqualStrings("[x] write the helper\n[x] test it\n[~] wire it up", rendered);
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
    const rendered = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"land the fix","status":"pending"},
        \\          {"content":"and verify","status":"pending"}]}
    ));
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
    const rendered = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"B2","status":"pending"}]}
    ));
    try std.testing.expectEqualStrings("[ ] B2", rendered); // B1 was open, so it dropped
    try std.testing.expectEqual(@as(usize, 3), root.todos.items.len);
    try std.testing.expectEqual(@as(u64, 3), root.todos.items[0].epoch);
    try std.testing.expectEqual(@as(usize, 1), goal_state.parkedOpenCount(root.todos.items, 4));
}

test "an empty or missing todos argument clears the open items but not the record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root = todoRoot(ar);
    root.goal = .{ .objective = "ship", .epoch = 1 };
    _ = try applyTodoWrite(&root, try todosArg(ar,
        \\{"todos":[{"content":"done","status":"completed"},{"content":"open","status":"pending"}]}
    ));
    try std.testing.expectEqualStrings("[x] done", try applyTodoWrite(&root, try todosArg(ar, "{\"todos\":[]}")));
    // A malformed call (no "todos" at all) takes the same path rather than crashing.
    try std.testing.expectEqualStrings("[x] done", try applyTodoWrite(&root, null));
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
    // A replace that mentions nothing leaves A's finished item standing - which
    // is precisely the state that used to make the next goal inherit a "done"
    // checklist. adoptTodos takes OPEN items only, so it adopts nothing.
    _ = try applyTodoWrite(&root, try todosArg(ar, "{\"todos\":[]}"));
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
    try std.testing.expectEqualStrings("[x] A1", goal_state.renderTodos(&root, 1));
}
