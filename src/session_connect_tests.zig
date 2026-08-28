//! Companion-connect: codedb-pro/muonry only. Smolify is not a bundled server.

const std = @import("std");
const Io = std.Io;

const args = @import("args.zig");
const mcp = @import("mcp.zig");
const companion_boot = @import("companion_boot.zig");
const session_start = @import("session_start.zig");
const tool_surface = @import("tool_surface.zig");

test "connectCompanion never injects a bundled Smolify server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const flags: args.Flags = .{};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var registry = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    try session_start.connectCompanion(std.testing.io, arena, &registry, flags, &aw.writer, true, env);
    try std.testing.expectEqual(@as(usize, 0), registry.tools.len);
    try std.testing.expectEqual(@as(usize, 0), registry.servers.len);

    // Former opt-in env vars are ignored: there is no reserved core server.
    try env.put("GRAFF_SMOLIFY", "1");
    try env.put("GRAFF_SMOLIFY_ACCESS", "full");
    var with_opt = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer with_opt.deinit();
    try session_start.connectCompanion(std.testing.io, arena, &with_opt, flags, &aw.writer, true, env);
    try std.testing.expectEqual(@as(usize, 0), with_opt.tools.len);
    try std.testing.expectEqual(@as(usize, 0), with_opt.servers.len);
}

test "connectCompanion on interactive yolo queues instead of addServer" {
    try std.testing.expect(companion_boot.deferCompanion(.{ .yolo_flag = true }, false));
    const src = @embedFile("companion_boot.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "queueStdio") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "addServer") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "companion: {s} (background)") != null);
}

test "skipOptionalServer keeps deepwiki/mobbin out of the default catalog" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(tool_surface.skipOptionalServer("deepwiki", env));
    try std.testing.expect(tool_surface.skipOptionalServer("mobbin", env));
    try env.put("GRAFF_DEEPWIKI", "1");
    try std.testing.expect(!tool_surface.skipOptionalServer("deepwiki", env));
    try std.testing.expect(tool_surface.skipOptionalServer("mobbin", env));
}
