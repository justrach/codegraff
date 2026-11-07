//! `graff mcp list --json`: the merged MCP set as data, for clients (Harness's
//! MCP settings) that show and edit what graff will connect. Each server says
//! where it comes from (`project`, `global`, or `imported` from another tool's
//! config) and whether an off-list switched it off. Env and header VALUES are
//! never printed, only their names: they are often tokens.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_config = @import("mcp_config.zig");

const Server = struct {
    name: []const u8,
    source: mcp_config.Merged.Source,
    enabled: bool,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    url: ?[]const u8 = null,
    envKeys: []const []const u8 = &.{},
    headerKeys: []const []const u8 = &.{},
};

fn keysOf(arena: Allocator, cfg: std.json.ObjectMap, field: []const u8) []const []const u8 {
    const obj = cfg.get(field) orelse return &.{};
    if (obj != .object) return &.{};
    return arena.dupe([]const u8, obj.object.keys()) catch &.{};
}

fn server(arena: Allocator, merged: mcp_config.Merged, name: []const u8, cfg: Value, enabled: bool) Server {
    var out: Server = .{ .name = name, .source = merged.source(name), .enabled = enabled };
    if (cfg != .object) return out;
    const o = cfg.object;
    if (o.get("command")) |c| if (c == .string) {
        out.command = c.string;
    };
    if (o.get("url")) |u| if (u == .string) {
        out.url = u.string;
    };
    if (o.get("args")) |a| if (a == .array) {
        var args: std.ArrayList([]const u8) = .empty;
        for (a.array.items) |item| if (item == .string) args.append(arena, item.string) catch {};
        out.args = args.items;
    };
    out.envKeys = keysOf(arena, o, "env");
    out.headerKeys = keysOf(arena, o, "headers");
    return out;
}

pub fn write(arena: Allocator, merged: mcp_config.Merged, project_path: []const u8, global_path: ?[]const u8, w: *Io.Writer) !void {
    var servers: std.ArrayList(Server) = .empty;
    var it = merged.servers.iterator();
    while (it.next()) |e| try servers.append(arena, server(arena, merged, e.key_ptr.*, e.value_ptr.*, true));
    var off = merged.disabled.iterator();
    while (off.next()) |e| try servers.append(arena, server(arena, merged, e.key_ptr.*, e.value_ptr.*, false));
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(.{
        .globalPath = global_path,
        .projectPath = project_path,
        .invalidGlobal = merged.invalid_global,
        .invalidProject = merged.invalid_project,
        .servers = servers.items,
    });
    try w.writeByte('\n');
}

test "the JSON listing tags sources, carries off-listed servers, and never prints values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "global.json", .data =
        \\{"mcpServers":{"docs":{"url":"https://g/mcp","headers":{"Authorization":"Bearer secret"}}},
        \\ "disabledMcpServers":{"parked":{"command":"/bin/parked","args":["-v"],"env":{"TOKEN":"hidden"}}}}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".mcp.json", .data =
        \\{"mcpServers":{"local":{"command":"./srv","args":["--root","."]}}}
    });
    const merged = mcp_config.load(std.testing.io, arena, tmp.dir, ".mcp.json", "global.json", "", false);
    var aw: Io.Writer.Allocating = .init(arena);
    try write(arena, merged, ".mcp.json", "global.json", &aw.writer);
    const text = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hidden") == null);

    const parsed = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const list = parsed.object.get("servers").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    const find = struct {
        fn by(items: []const Value, name: []const u8) std.json.ObjectMap {
            for (items) |item| if (std.mem.eql(u8, item.object.get("name").?.string, name)) return item.object;
            unreachable;
        }
    }.by;
    try std.testing.expectEqualStrings("global", find(list, "docs").get("source").?.string);
    try std.testing.expectEqualStrings("Authorization", find(list, "docs").get("headerKeys").?.array.items[0].string);
    try std.testing.expectEqualStrings("project", find(list, "local").get("source").?.string);
    try std.testing.expectEqualStrings(".", find(list, "local").get("args").?.array.items[1].string);
    try std.testing.expect(!find(list, "parked").get("enabled").?.bool);
    try std.testing.expectEqualStrings("TOKEN", find(list, "parked").get("envKeys").?.array.items[0].string);
}
