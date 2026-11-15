//! REPL `/orchestrator` and `--json` `set_orchestrator` handlers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const orchestrator = @import("orchestrator_mode.zig");

pub fn handle(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/orchestrator") and !std.mem.startsWith(u8, line, "/orchestrator ")) return false;
    const arg = std.mem.trim(u8, line["/orchestrator".len..], " \t\r\n");
    const exec_p = orchestrator.resolveExecutor(root.provider, root.reasoning);
    if (arg.len == 0 or std.ascii.eqlIgnoreCase(arg, "status")) {
        if (exec_p) |ep| {
            try out.print("orchestrator: {s} (executor for {s}: {s}; use /orchestrator off|auto|on)\n", .{
                orchestrator.g_mode.label(), root.provider.model, ep.model,
            });
        } else {
            try out.print("orchestrator: {s} (unsupported on {s}; use /orchestrator off|auto|on)\n", .{
                orchestrator.g_mode.label(), root.provider.model,
            });
        }
        try out.flush();
        return true;
    }
    const mode = orchestrator.Mode.parse(arg) orelse {
        try out.writeAll("usage: /orchestrator [off|auto|on|status]\n");
        try out.flush();
        return true;
    };
    const saved = if (orchestrator.saveSettings(root.io, arena, mode)) |_| true else |_| blk: {
        orchestrator.g_mode = mode;
        break :blk false;
    };
    const suffix: []const u8 = if (saved) "" else " (not persisted)";
    if (exec_p) |ep| {
        try out.print("orchestrator: {s} (executor: {s}){s}\n", .{ mode.label(), ep.model, suffix });
    } else {
        try out.print("orchestrator: {s} (unsupported on {s}){s}\n", .{ mode.label(), root.provider.model, suffix });
    }
    try out.flush();
    return true;
}

pub fn handleJson(root: *Agent, arena: Allocator, obj: std.json.ObjectMap) void {
    const raw = if (obj.get("mode")) |v| (if (v == .string) v.string else "") else "";
    const mode = orchestrator.Mode.parse(raw) orelse {
        root.emit(.{ .type = "error", .message = "set_orchestrator needs mode 'off', 'auto', or 'on'" });
        return;
    };
    _ = orchestrator.saveSettings(root.io, arena, mode) catch {
        orchestrator.g_mode = mode;
    };
    const exec_p = orchestrator.resolveExecutor(root.provider, root.reasoning);
    root.emit(.{
        .type = "orchestrator",
        .ok = true,
        .mode = mode.label(),
        .supported = exec_p != null,
        .executor_model = if (exec_p) |ep| ep.model else @as(?[]const u8, null),
    });
}
