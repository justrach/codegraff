//! Companion-connect opt-in: Smolify is not added unless GRAFF_SMOLIFY is set.

const std = @import("std");
const Io = std.Io;

const args = @import("args.zig");
const mcp = @import("mcp.zig");
const session_start = @import("session_start.zig");
const tool_surface = @import("tool_surface.zig");

test "connectCompanion does not add Smolify tools unless the opt-in env is present" {
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

    try env.put("GRAFF_SMOLIFY", "1");
    var with_opt = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer with_opt.deinit();
    try session_start.connectCompanion(std.testing.io, arena, &with_opt, flags, &aw.writer, true, env);
    try std.testing.expect(with_opt.tools.len > 0);
    try std.testing.expectEqualStrings("smolify", with_opt.servers[0].name);
    for (with_opt.tools) |t| {
        try std.testing.expect(std.mem.startsWith(u8, t.qualified_name, "mcp__smolify__"));
    }
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
