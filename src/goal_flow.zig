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
const Agent = agent_mod.Agent;
const TodoItem = agent_mod.TodoItem;

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
    return root;
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
