//! Tests for commands_session.zig's conversation-reset helper. They live in a
//! sibling because commands_session.zig sits at the 600-line cap (AGENTS.md)
//! and #445 needed room in it for the transcript-line reset call sites.
//! Reachability is wired in test_hooks.zig — an unreferenced module's tests
//! compile to nothing and the suite still reports green.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const resetConversationSteering = @import("commands_session.zig").resetConversationSteering;

test "/clear + /new reset conversation steering — goal and ultracode_mode don't survive (#178)" {
    var root: Agent = undefined;
    root.io = std.testing.io;
    root.goal = .{ .objective = "ultracode: index the statutes" };
    root.ultracode_mode = true;
    root.goal_flag = null; // no --goal: the conversation's goal dies with it
    root.todos = .empty;
    resetConversationSteering(&root);
    try std.testing.expect(root.goal == null);
    try std.testing.expect(!root.ultracode_mode);
}

test "/clear keeps a --goal standing objective standing (#318 through the /clear door)" {
    var root: Agent = undefined;
    root.io = std.testing.io;
    root.ultracode_mode = false;
    root.todos = .empty;
    root.goal_flag = "keep the tree green"; // the user passed --goal
    root.goal = .{ .objective = "keep the tree green", .standing = true, .epoch = 1 };
    resetConversationSteering(&root);
    // Before this, /clear dropped it, the user typed a fresh /goal, got a
    // RETIRABLE one, and the next attempt_completion ended their steering.
    const g = root.goal orelse return error.TestExpectedNonNull;
    try std.testing.expect(g.standing);
    try std.testing.expectEqualStrings("keep the tree green", g.objective);
}

test "/clear drops persisted rlm binds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const rlm_spec = @import("rlm_spec.zig");
    try rlm_spec.commitBinds(gpa, io, &.{.{ .name = "prev", .text = "keep" }});
    defer rlm_spec.resetBinds(gpa, io);
    var root: Agent = undefined;
    root.io = io;
    root.goal = null;
    root.ultracode_mode = false;
    root.goal_flag = null;
    root.todos = .empty;
    resetConversationSteering(&root);
    var seeded: std.ArrayList(rlm_spec.Binding) = .empty;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try rlm_spec.seedBinds(gpa, io, arena_state.allocator(), &seeded);
    try std.testing.expectEqual(@as(usize, 0), seeded.items.len);
}
