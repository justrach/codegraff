//! Host-specific MCP surfaces selected by plugin manifest variants.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const layout = @import("plugin_layout.zig");
const codex_node_repl = @import("codex_node_repl.zig");

/// Merge each plugin MCP declaration, replacing Codex's raw Computer Use
/// client with its signed node_repl content variant when available (#618).
pub fn merge(io: Io, arena: Allocator, home: []const u8, cwd: []const u8, plugs: anytype, servers: *std.json.ObjectMap, found: *bool) void {
    var node_repl_plugin: ?[]const u8 = null;
    for (plugs) |p| {
        if (!p.mcp) continue;
        if (@import("builtin").os.tag == .macos and
            std.ascii.eqlIgnoreCase(p.name, "computer-use") and
            layout.usesNodeRepl(io, arena, p.path))
        {
            node_repl_plugin = p.path;
            continue;
        }
        layout.mergeMcp(io, arena, p.path, cwd, servers, found);
    }
    if (node_repl_plugin) |path| {
        const bridged = codex_node_repl.merge(io, arena, home, cwd, servers, found);
        // Custom/non-Codex builds may make the plugin client callable. Keep
        // that declared fallback only when no signed bridge was available.
        if (!bridged) layout.mergeMcp(io, arena, path, cwd, servers, found);
    }
}
