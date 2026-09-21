//! Step-boundary inbox: peer mail, jobs, schedule, channel workers, and
//! REPL steer. One call from `Agent.runTurn` so a follow-up typed during
//! tools lands as the next user message in the same turn (not the next
//! prompt after `runTurn` returns). Force-steers stay queued for the
//! interrupt path. TUI follow-ups still drain after the job.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const repl_glue = @import("repl_glue.zig");
const session_wake = @import("session_wake.zig");
const main_mod = @import("main.zig");

pub fn deliver(self: *Agent) !void {
    @import("peer_wake.zig").noteTurnStart(self.messages.items);
    @import("peer_channel.zig").deliverInbound(self);
    try @import("subagent_feedback.zig").deliverToAgent(self);
    @import("job_notify.zig").deliver(self);
    @import("schedule.zig").deliver(self);
    @import("channel_worker.zig").deliver(self);
    deliverSteer(self);
}

/// Soft steer only: `force` stays at the head of `g_steer_queue` so the
/// REPL interrupt path still sees it after this turn unwinds.
fn popSteerSoft() ?repl_glue.SteerEntry {
    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    const q = &main_mod.g_steer_queue;
    if (q.items.len == 0) return null;
    if (q.items[0].force) return null;
    return q.orderedRemove(0);
}

fn deliverSteer(self: *Agent) void {
    if (self.sub) return;
    const entry = popSteerSoft() orelse return;
    defer std.heap.page_allocator.free(entry.text);
    session_wake.inject(self, entry.text);
}

test "deliverSteer injects one non-force line and leaves force queued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const drop = struct {
        fn emit(_: *anyopaque, _: @import("engine_sink.zig").Stamped) void {}
    };
    const vt = @import("engine_sink.zig").VTable{ .emit = drop.emit, .durable = false };
    var root: Agent = undefined;
    root.sub = false;
    root.arena = arena_state.allocator();
    root.messages = std.json.Array.init(arena_state.allocator());
    root.sink = .{ .ctx = undefined, .vt = &vt };

    const page = std.heap.page_allocator;
    const soft = try page.dupe(u8, "also run the tests");
    const force = try page.dupe(u8, "stop");
    repl_glue.steerLock();
    for (main_mod.g_steer_queue.items) |e| page.free(e.text);
    main_mod.g_steer_queue.clearRetainingCapacity();
    try main_mod.g_steer_queue.append(page, .{ .text = soft, .force = false });
    try main_mod.g_steer_queue.append(page, .{ .text = force, .force = true });
    repl_glue.steerUnlock();
    defer {
        repl_glue.steerLock();
        for (main_mod.g_steer_queue.items) |e| page.free(e.text);
        main_mod.g_steer_queue.clearRetainingCapacity();
        repl_glue.steerUnlock();
    }

    deliverSteer(&root);
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try std.testing.expectEqualStrings("also run the tests", root.messages.items[0].object.get("content").?.string);

    repl_glue.steerLock();
    defer repl_glue.steerUnlock();
    try std.testing.expectEqual(@as(usize, 1), main_mod.g_steer_queue.items.len);
    try std.testing.expect(main_mod.g_steer_queue.items[0].force);
}

test "deliverSteer is a no-op on subagents" {
    var root: Agent = undefined;
    root.sub = true;
    deliverSteer(&root);
}

test "popSteerSoft leaves an empty queue alone" {
    repl_glue.steerLock();
    for (main_mod.g_steer_queue.items) |e| std.heap.page_allocator.free(e.text);
    main_mod.g_steer_queue.clearRetainingCapacity();
    repl_glue.steerUnlock();
    try std.testing.expect(popSteerSoft() == null);
}
