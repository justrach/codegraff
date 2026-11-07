//! What todo_write tells the model (ADR 0233). The model just sent the list,
//! so echoing it back cost its tokens a second time, then again on every
//! later request that carried the result; the replies ran nearly twice the
//! size of the calls. The reply is the counts, any item
//! graff kept that the call left out (a finished item, open verification),
//! and the notes about dropped or kept work. The full list still goes to the
//! UI through `todo_list_updated`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TodoItem = @import("agent.zig").TodoItem;

pub fn text(arena: Allocator, todos: []const TodoItem, epoch: u64, incoming: []const []const u8, dropped_open: usize, kept_verify: usize) ![]const u8 {
    var done: usize = 0;
    var doing: usize = 0;
    var open: usize = 0;
    var cancelled: usize = 0;
    var dropped: usize = 0;
    for (todos) |t| {
        if (t.epoch != epoch or t.retired) continue;
        if (std.mem.eql(u8, t.status, "completed")) {
            done += 1;
        } else if (std.mem.eql(u8, t.status, "in_progress")) {
            doing += 1;
        } else if (std.mem.eql(u8, t.status, "cancelled")) {
            cancelled += 1; // scope changed, not pending work (#1545)
        } else if (@import("goal_state.zig").isDropped(t.status)) {
            dropped += 1;
        } else {
            open += 1;
        }
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("Todo list saved: {d} done, {d} in progress, {d} pending", .{ done, doing, open });
    if (cancelled > 0) try w.print(", {d} cancelled", .{cancelled});
    try w.writeAll(".");
    if (dropped > 0) try w.print(" {d} dropped (abandoned by user order; no longer blocks completion).", .{dropped});
    var kept_header = false;
    for (todos) |t| {
        if (t.epoch != epoch or t.retired or mentions(incoming, t.content)) continue;
        if (!kept_header) try w.writeAll("\nKept from before (not in your list):");
        kept_header = true;
        try w.print("\n{s} {s}", .{ mark(t.status), t.content });
        if (t.reason.len > 0) try w.print(" (cancelled: {s})", .{t.reason}); // #1520
    }
    if (kept_verify > 0) try w.print("\n({d} verification item(s) you left out were kept as unresolved acceptance requirements)", .{kept_verify});
    if (dropped_open > 0) try w.print("\n({d} open item(s) you left out were dropped; re-list one to keep it)", .{dropped_open});
    return aw.writer.buffered();
}

fn mark(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "completed")) return "[x]";
    if (std.mem.eql(u8, status, "in_progress")) return "[~]";
    if (std.mem.eql(u8, status, "cancelled") or @import("goal_state.zig").isDropped(status)) return "[-]";
    return "[ ]";
}

fn mentions(contents: []const []const u8, content: []const u8) bool {
    for (contents) |c| if (std.mem.eql(u8, c, content)) return true;
    return false;
}

test "todo_write reply: counts only when graff kept nothing the call left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const todos = [_]TodoItem{
        .{ .content = "write the helper", .status = "completed", .epoch = 1 },
        .{ .content = "wire it up", .status = "in_progress", .epoch = 1 },
        .{ .content = "ship it", .status = "pending", .epoch = 1 },
        .{ .content = "another goal's item", .status = "pending", .epoch = 2 },
    };
    const sent = [_][]const u8{ "write the helper", "wire it up", "ship it" };
    const got = try text(arena_state.allocator(), &todos, 1, &sent, 0, 0);
    try std.testing.expectEqualStrings("Todo list saved: 1 done, 1 in progress, 1 pending.", got);
}

test "todo_write reply: names what graff kept and what the call dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const todos = [_]TodoItem{
        .{ .content = "write the helper", .status = "completed", .epoch = 1 },
        .{ .content = "verify the fix", .status = "pending", .epoch = 1 },
        .{ .content = "wire it up", .status = "in_progress", .epoch = 1 },
        .{ .content = "retired", .status = "completed", .epoch = 1, .retired = true },
    };
    const sent = [_][]const u8{"wire it up"};
    const got = try text(arena_state.allocator(), &todos, 1, &sent, 2, 1);
    try std.testing.expectEqualStrings(
        \\Todo list saved: 1 done, 1 in progress, 1 pending.
        \\Kept from before (not in your list):
        \\[x] write the helper
        \\[ ] verify the fix
        \\(1 verification item(s) you left out were kept as unresolved acceptance requirements)
        \\(2 open item(s) you left out were dropped; re-list one to keep it)
    , got);
}

test "#1545 todo reply distinguishes cancelled and dropped records from pending work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const todos = [_]TodoItem{
        .{ .content = "finished", .status = "completed", .epoch = 1 },
        .{ .content = "scope changed", .status = "cancelled", .epoch = 1, .reason = "delegated to another session" },
        .{ .content = "abandoned", .status = "dropped", .epoch = 1 },
        .{ .content = "remaining", .status = "pending", .epoch = 1 },
    };
    const got = try text(arena_state.allocator(), &todos, 1, &.{ "finished", "remaining" }, 0, 0);
    try std.testing.expectEqualStrings(
        \\Todo list saved: 1 done, 0 in progress, 1 pending, 1 cancelled. 1 dropped (abandoned by user order; no longer blocks completion).
        \\Kept from before (not in your list):
        \\[-] scope changed (cancelled: delegated to another session)
        \\[-] abandoned
    , got);
}
