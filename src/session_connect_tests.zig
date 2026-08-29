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

test "connectCompanion yolo writes the companion receipt and does not addServer" {
    const main_mod = @import("main.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A plain file satisfies binOnPath's access() probe. A symlink to
    // /bin/false does not on every host: access() follows the link, and newer
    // macOS ships only /usr/bin/false.
    (try tmp.dir.createFile(io, "codedb-pro", .{})).close(io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const saved_path = main_mod.g_path_env;
    defer main_mod.g_path_env = saved_path;
    main_mod.g_path_env = path_buf[0..n];

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var registry = mcp.Registry.empty(std.testing.allocator, io);
    defer registry.deinit();

    try session_start.connectCompanion(io, arena_state.allocator(), &registry, .{ .yolo_flag = true }, &aw.writer, false, env);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "companion: codedb-pro (background)") != null);
    try std.testing.expectEqual(@as(usize, 0), registry.servers.len);
    try std.testing.expectEqual(@as(usize, 0), registry.tools.len);
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
