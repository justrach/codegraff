//! Optional runtime catalog entry: absent when no server was trusted at boot.
const std = @import("std");
const schema = @import("schema.zig");
const config = @import("lsp_config.zig");
pub const specs = [_]schema.ToolSpec{@import("lsp.zig").spec};
pub fn extras(registry: config.Registry) []const schema.ToolSpec {
    return if (registry.enabled() and !@import("no_local_tools.zig").enabled) &specs else &.{};
}
pub fn rootExtras() []const schema.ToolSpec {
    return if (config.root_enabled and !@import("no_local_tools.zig").enabled) &specs else &.{};
}
pub fn append(a: std.mem.Allocator, kind: @import("provider.zig").Provider.Kind, base: []const u8, registry: config.Registry) []const u8 {
    if (extras(registry).len == 0) return base;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var writer: std.json.Stringify = .{ .writer = &output.writer };
    writer.beginArray() catch return base;
    const tool = specs[0];
    if (kind == .responses)
        schema.writeEagerResponsesEntry(&writer, tool.name, tool.desc, .{ .raw = tool.schema }) catch return base
    else
        schema.writeToolEntry(&writer, kind, tool.name, tool.desc, .{ .raw = tool.schema }) catch return base;
    writer.endArray() catch return base;
    const extra = output.writer.buffered();
    const head = std.mem.trimEnd(u8, base, " \t\r\n");
    if (head.len < 2 or head[head.len - 1] != ']') return base;
    if (std.mem.trim(u8, head[1 .. head.len - 1], " \t\r\n").len == 0) return a.dupe(u8, extra) catch base;
    return std.fmt.allocPrint(a, "{s},{s}]", .{ head[0 .. head.len - 1], extra[1 .. extra.len - 1] }) catch base;
}
