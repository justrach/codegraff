//! session_start.initRegistryConsent and the plugins switch, kept apart from
//! session_start.zig (600-line ceiling).
const std = @import("std");
const Io = std.Io;
const session_start = @import("session_start.zig");

test "initRegistryConsent applies GRAFF_NO_PLUGINS before it reads any MCP config" {
    const plugins = @import("plugins.zig");
    const saved = plugins.disabled;
    defer plugins.disabled = saved;
    plugins.disabled = false;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A home whose Claude config names a server: with plugins off it must not
    // be merged, so there is nothing to connect.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".claude.json", .data = "{\"mcpServers\":{\"leak\":{\"command\":\"/nonexistent/leak-mcp\"}}}" });
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(std.testing.io, &home_buf);
    const home = home_buf[0..home_len];
    const Env = struct {
        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "GRAFF_NO_PLUGINS")) "1" else null;
        }
    };
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var in: Io.Reader = .fixed("");
    const project = try std.fs.path.join(arena, &.{ home, ".mcp.json" });
    var registry = try session_start.initRegistryConsent(std.testing.io, std.testing.allocator, arena, &out, &in, .{ .yolo_flag = true }, project, home, false, true, Env{});
    defer registry.deinit();
    try std.testing.expect(plugins.disabled);
    for (registry.servers) |server| try std.testing.expect(!std.mem.eql(u8, server.name, "leak"));
}
