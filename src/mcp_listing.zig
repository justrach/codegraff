//! The session's `/mcp` lines for servers that are not connected, and
//! `/mcp reconnect <name>`. Each server not connected says why (failed with
//! its cause, switched off, optional, still connecting, or never started
//! because startup consent was declined), so the `/mcp trust` hint appears
//! only when trust is actually the reason.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_status = @import("mcp_status.zig");
const style = &@import("ansi.zig").style;

const NoEnv = struct {
    pub fn get(_: NoEnv, _: []const u8) ?[]const u8 {
        return null;
    }
};

fn merged(reg: *mcp.Registry, arena: Allocator, config_path: []const u8) mcp_config.Merged {
    return mcp_config.load(reg.io, arena, Io.Dir.cwd(), config_path, reg.global_config_path, reg.home, reg.global_is_override);
}

/// After the connected servers: one line per configured server that is not.
pub fn notConnected(reg: *mcp.Registry, arena: Allocator, out: *Io.Writer, config_path: []const u8) !void {
    const m = merged(reg, arena, config_path);
    const rows = try mcp_status.live(reg, arena, m, NoEnv{});
    var untrusted: usize = 0;
    var failed = false;
    for (rows) |row| switch (row.state) {
        .ready, .on_demand => {},
        .not_started => untrusted += 1,
        else => {
            failed = failed or row.state == .failed or row.state == .needs_login;
            try out.print("  {s}{s}  {s}{s}{s}{s}\n", .{ style.dim, row.name, mcp_status.label(row), if (row.@"error" != null) " — " else "", row.@"error" orelse "", style.reset });
        },
    };
    if (@import("nanocua_default.zig").missingStatusNote(reg.io, arena, reg.home, m, reg.global_is_override, @import("builtin").os.tag == .macos)) |note| {
        try out.print("{s}{s}{s}", .{ style.dim, note, style.reset });
    }
    if (failed) try out.print("  {s}/mcp reconnect <name> tries a failed server again; graff mcp login <name> signs in{s}\n", .{ style.dim, style.reset });
    if (untrusted > 0) try out.print("  {s}{d} configured server(s) not started — /mcp trust to connect them{s}\n", .{ style.dim, untrusted, style.reset });
}

/// `/mcp reconnect <name>`. True when the registry changed and the caller
/// must re-render its catalog.
pub fn reconnect(reg: *mcp.Registry, arena: Allocator, out: *Io.Writer, config_path: []const u8, name: []const u8) !bool {
    defer out.flush() catch {};
    if (name.len == 0) {
        try out.writeAll("usage: /mcp reconnect <name>\n");
        return false;
    }
    const m = merged(reg, arena, config_path);
    switch (@import("mcp_reconnect.zig").live(reg, m, name)) {
        .reconnected => |n| try out.print("{s}✓{s} reconnected {s}{s}{s} — {d} tool(s)\n", .{ style.green, style.reset, style.accent, name, style.reset, n }),
        .connected => |n| try out.print("{s}✓{s} connected {s}{s}{s} — {d} tool(s)\n", .{ style.green, style.reset, style.accent, name, style.reset, n }),
        .still_connecting => {
            try out.print("{s} is still connecting; /mcp shows when it is ready.\n", .{name});
            return false;
        },
        .switched_off => {
            try out.print("{s} is switched off — graff mcp enable {s}, then start a new session.\n", .{ name, name });
            return false;
        },
        .not_configured => {
            if (std.mem.eql(u8, name, @import("nanocua_default.zig").server_name) and
                @import("nanocua_default.zig").missingStatusNote(reg.io, arena, reg.home, m, reg.global_is_override, @import("builtin").os.tag == .macos) != null)
            {
                try out.writeAll("nanocua isn't installed — run `graff computer install` (or `graff update`) to install ~/Applications/nanocua.app, then `/mcp reconnect nanocua`.\n");
                return false;
            }
            try out.print("no MCP server named {s} — /mcp lists them.\n", .{name});
            return false;
        },
        .failed => |err| {
            try out.print("{s}✗ {s} did not connect: {s} ({t}){s}\n", .{ style.red, name, mcp_status.errorText(err), err, style.reset });
            return false;
        },
    }
    return true;
}
