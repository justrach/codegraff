//! Live ACP `orchestrator` selector (`off` | `auto` | `on`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("acp_engine.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const orchestrator = @import("orchestrator_mode.zig");

const choices = [_]engine.ConfigValue{
    .{ .value = "off", .name = "Off" },
    .{ .value = "auto", .name = "Auto" },
    .{ .value = "on", .name = "On" },
};

pub fn option(ctx: *anyopaque, _: Allocator) anyerror!?engine.ConfigOption {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    if (orchestrator.resolveExecutor(root.provider, root.reasoning) == null) return null;
    return .{
        .id = "orchestrator",
        .name = "Orchestrator",
        .category = "mode",
        .currentValue = orchestrator.g_mode.label(),
        .options = &choices,
    };
}

pub fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    if (orchestrator.resolveExecutor(root.provider, root.reasoning) == null) return false;
    const mode: orchestrator.Mode = if (std.mem.eql(u8, value, "off"))
        .off
    else if (std.mem.eql(u8, value, "auto"))
        .auto
    else if (std.mem.eql(u8, value, "on"))
        .on
    else
        return false;
    var arena_state = std.heap.ArenaAllocator.init(root.gpa);
    defer arena_state.deinit();
    _ = orchestrator.saveSettings(root.io, arena_state.allocator(), mode) catch {
        orchestrator.g_mode = mode;
    };
    return true;
}
