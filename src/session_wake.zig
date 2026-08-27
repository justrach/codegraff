//! One-line user-role inject used by job_notify, schedule, and channel
//! workers. Same shape as a finished-job wake: history + session_notice.

const std = @import("std");

const agent_mod = @import("agent.zig");
const engine_sink = @import("engine_sink.zig");
const Agent = agent_mod.Agent;

pub fn inject(root: *Agent, text: []const u8) void {
    if (root.sub or text.len == 0) return;
    const owned = root.arena.dupe(u8, text) catch return;
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = owned }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
    engine_sink.forAgent(root).emit(root.io, .{ .session_notice = .{ .text = owned, .tone = .dim } });
}

test "inject is a no-op on subagents" {
    var root: Agent = undefined;
    root.sub = true;
    root.messages = .empty;
    inject(&root, "hi");
    try std.testing.expectEqual(@as(usize, 0), root.messages.items.len);
}

test "inject appends a user-role line on the root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const drop = struct {
        fn emit(_: *anyopaque, _: engine_sink.Stamped) void {}
    };
    const vt = engine_sink.VTable{ .emit = drop.emit, .durable = false };
    var root: Agent = undefined;
    root.sub = false;
    root.arena = arena_state.allocator();
    root.messages = std.json.Array.init(arena_state.allocator());
    root.sink = .{ .ctx = undefined, .vt = &vt };
    inject(&root, "wake up");
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try std.testing.expectEqualStrings("user", root.messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("wake up", root.messages.items[0].object.get("content").?.string);
}
