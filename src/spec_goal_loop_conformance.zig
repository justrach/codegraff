//! Impl half of the GoalLoop kernel: every cell in spec/kernels/goal_loop.json
//! must match goal_state.completionGate / checklistFinished / retireOnCompletion.

const std = @import("std");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const goal_state = @import("goal_state.zig");
const goal_todo = @import("goal_todo.zig");

const fixtures_json = @embedFile("spec_goal_loop");

fn verdictOf(text: ?[]const u8) []const u8 {
    const t = text orelse return "accept";
    if (std.mem.indexOf(u8, t, "open checklist") != null) return "refuse_open";
    if (std.mem.indexOf(u8, t, "no checklist") != null) return "refuse_no_plan";
    return "unknown";
}

fn loadAgent(arena: std.mem.Allocator, st: std.json.ObjectMap) !Agent {
    var root: Agent = undefined;
    const seat = st.get("seat").?.string;
    root.sub = std.mem.eql(u8, seat, "sub");
    root.review_mode = std.mem.eql(u8, seat, "review");
    root.arena = arena;
    root.gpa = std.testing.allocator;
    root.todos = .empty;
    root.completion_gate_armed = st.get("armed").?.bool;
    root.todos_dirty = st.get("dirty").?.bool;
    root.completed = null;

    const gname = st.get("goal").?.string;
    const standing = st.get("standing").?.bool;
    if (std.mem.eql(u8, gname, "none")) {
        root.goal = null;
    } else {
        const status: agent_mod.GoalStatus = if (std.mem.eql(u8, gname, "active"))
            .active
        else if (std.mem.eql(u8, gname, "paused"))
            .paused
        else if (std.mem.eql(u8, gname, "blocked"))
            .blocked
        else
            .complete;
        root.goal = .{ .objective = "ship", .epoch = 1, .standing = standing, .status = status };
    }

    const stamp: u64 = if (root.goal == null or (root.goal != null and root.goal.?.status == .complete)) 0 else 1;
    const list = st.get("checklist").?.string;
    if (std.mem.eql(u8, list, "open")) {
        try root.todos.append(arena, .{ .content = "a", .status = "pending", .epoch = stamp });
    } else if (std.mem.eql(u8, list, "all_completed")) {
        try root.todos.append(arena, .{ .content = "a", .status = "completed", .epoch = stamp });
    }
    return root;
}

test "spec/goal_loop: completionGate matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 360), cases.len);

    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root = try loadAgent(arena, case.get("state").?.object);

        const want_gate = case.get("completion_gate").?.string;
        const got_text = try goal_state.completionGate(arena, &root);
        const got_gate = verdictOf(got_text);
        if (!std.mem.eql(u8, want_gate, got_gate)) {
            std.debug.print("\ncounterexample {s}: gate want={s} got={s}\n", .{ id, want_gate, got_gate });
            return error.CatalogMismatch;
        }

        const want_fin = case.get("checklist_finished").?.bool;
        const got_fin = goal_state.checklistFinished(&root);
        if (want_fin != got_fin) {
            std.debug.print("\ncounterexample {s}: finished want={} got={}\n", .{ id, want_fin, got_fin });
            return error.CatalogMismatch;
        }

        const want_ret = case.get("retires_on_accept").?.bool;
        const got_ret = goal_state.retireOnCompletion(&root, 0);
        if (want_ret != got_ret) {
            std.debug.print("\ncounterexample {s}: retire want={} got={}\n", .{ id, want_ret, got_ret });
            return error.CatalogMismatch;
        }
    }
}

test "spec/goal_loop: empty todo_write is rejected and is not done" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var root: Agent = undefined;
    root.gpa = std.testing.allocator;
    root.arena = ar;
    root.sub = false;
    root.review_mode = false;
    root.todos = .empty;
    root.goal = .{ .objective = "ship", .epoch = 1 };
    root.completion_gate_armed = false;
    root.todos_dirty = false;

    const empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "[]", .{});
    defer empty.deinit();
    const out = try goal_todo.applyTodoWrite(&root, empty.value);
    try std.testing.expect(out.rejected);
    try std.testing.expect(!goal_state.checklistFinished(&root));
    try std.testing.expect(!goal_state.allDone(root.todos.items, 1));
}

test "spec/goal_loop: replace keeps omitted completed and drops omitted open" {
    var todos: std.ArrayList(agent_mod.TodoItem) = .empty;
    defer todos.deinit(std.testing.allocator);
    try todos.append(std.testing.allocator, .{ .content = "keep", .status = "completed", .epoch = 1 });
    try todos.append(std.testing.allocator, .{ .content = "drop", .status = "pending", .epoch = 1 });
    try todos.append(std.testing.allocator, .{ .content = "parked", .status = "pending", .epoch = 2 });
    const incoming = [_][]const u8{"new"};
    const dropped = goal_todo.clearEpochForReplace(&todos, 1, &incoming);
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqual(@as(usize, 2), todos.items.len);
    try std.testing.expectEqualStrings("keep", todos.items[0].content);
    try std.testing.expectEqualStrings("parked", todos.items[1].content);
}
