//! Native UI extension transport, shared by CLI and frontend bridges.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const runtime = @import("extension_runtime.zig");

pub fn list(io: Io, a: Allocator) !Value {
    var panels = std.json.Array.init(a);
    for (try runtime.load(io, a)) |p| {
        if (!runtime.handles(p, "ui")) continue;
        if (@import("hard_policy.zig").check(io, a, "plugin.use", p.id) != null) continue;
        const response = try runtime.invoke(io, a, p, "ui", .null);
        const panel = response.object.get("panel") orelse continue;
        if (panel == .null) continue;
        try runtime.validatePanel(panel);
        var row = panel.object;
        try row.put(a, "plugin", .{ .string = p.id });
        try panels.append(.{ .object = row });
    }
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "version", .{ .integer = 1 });
    try out.put(a, "panels", .{ .array = panels });
    return .{ .object = out };
}
fn containsAction(node: Value, action_name: []const u8) bool {
    if (node != .object) return false;
    if (node.object.get("action")) |v| if (v == .string and std.mem.eql(u8, v.string, action_name)) return true;
    if (node.object.get("children")) |v| if (v == .array) {
        for (v.array.items) |child| if (containsAction(child, action_name)) return true;
    };
    return false;
}
pub fn action(io: Io, a: Allocator, id: []const u8, name: []const u8) !Value {
    if (!runtime.identifier(id) or !runtime.identifier(name)) return error.InvalidExtensionAction;
    for (try runtime.load(io, a)) |p| {
        if (!std.mem.eql(u8, p.id, id)) continue;
        if (!runtime.handles(p, "ui") or !runtime.handles(p, "action")) return error.UnsupportedExtensionEvent;
        const current = try runtime.invoke(io, a, p, "ui", .null);
        const panel = current.object.get("panel") orelse return error.InvalidExtensionPanel;
        try runtime.validatePanel(panel);
        if (!containsAction(panel.object.get("root").?, name)) return error.InvalidExtensionAction;
        var data: std.json.ObjectMap = .empty;
        try data.put(a, "action", .{ .string = name });
        const response = try runtime.invoke(io, a, p, "action", .{ .object = data });
        if (response.object.get("panel")) |updated| try runtime.validatePanel(updated);
        return response;
    }
    return error.ExtensionNotFound;
}
pub fn runCli(io: Io, a: Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !bool {
    @import("plugins.zig").applyEnv(environ);
    @import("tool_env.zig").init(a, environ);
    var buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &buffer);
    try command(io, a, args, &output.interface);
    return true;
}

pub fn command(io: Io, a: Allocator, args: []const []const u8, out: *Io.Writer) !void {
    const result = if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "list")) or
        (args.len == 2 and std.mem.eql(u8, args[0], "list") and std.mem.eql(u8, args[1], "--json")))
        try list(io, a)
    else if (args.len == 3 and std.mem.eql(u8, args[0], "invoke"))
        try action(io, a, args[1], args[2])
    else
        return error.InvalidExtensionCommand;
    try out.print("{s}\n", .{try std.json.Stringify.valueAlloc(a, result, .{})});
    try out.flush();
}

test "native extension actions must be declared by the validated panel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"kind":"column","children":[{"kind":"button","label":"Refresh","action":"refresh"}]}
    , .{});
    try std.testing.expect(containsAction(v, "refresh"));
    try std.testing.expect(!containsAction(v, "shell"));
}
