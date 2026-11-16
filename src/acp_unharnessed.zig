//! Live ACP `unharnessed` selector (`off` | `on`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const no_local_tools = @import("no_local_tools.zig");
const unharnessed = @import("unharnessed_mode.zig");

const choices = [_]engine.ConfigValue{
    .{ .value = "off", .name = "Off" },
    .{ .value = "on", .name = "On" },
};

pub fn option(ctx: *anyopaque, _: Allocator) anyerror!?engine.ConfigOption {
    _ = ctx;
    if (no_local_tools.enabled) return null;
    return .{
        .id = "unharnessed",
        .name = "Unharnessed",
        .category = "mode",
        .currentValue = unharnessed.label(),
        .options = &choices,
    };
}

pub fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
    if (no_local_tools.enabled) return false;
    const on = unharnessed.parse(value) orelse return false;
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    var arena_state = std.heap.ArenaAllocator.init(root.gpa);
    defer arena_state.deinit();
    _ = try unharnessed.applyLive(root, arena_state.allocator(), on, true);
    return true;
}
