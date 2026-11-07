//! `graff mcp status | reconnect | enable | disable`: the CLI the desktop app's
//! MCP servers page and the fullscreen client's `/mcp` run (with `--json`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp_config = @import("mcp_config.zig");
const mcp_state = @import("mcp_state.zig");
const mcp_status = @import("mcp_status.zig");

pub fn verb(arg: []const u8) bool {
    const verbs = [_][]const u8{ "status", "reconnect", "enable", "disable" };
    for (verbs) |v| if (std.mem.eql(u8, arg, v)) return true;
    return false;
}

pub fn run(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, merged: mcp_config.Merged, args: []const []const u8, out: *Io.Writer, environ_map: anytype) !void {
    var json = false;
    var all = false;
    var names: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--all")) all = true else try names.append(arena, arg);
    }
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "enable") or std.mem.eql(u8, cmd, "disable")) {
        if (names.items.len != 1) return usage(out, "graff mcp enable|disable <name>");
        const name = names.items[0];
        if (merged.servers.get(name) == null) std.process.fatal("mcp {s}: server '{s}' is not configured (see `graff mcp status`)", .{ cmd, name });
        try mcp_state.set(io, arena, home, name, cmd[0] == 'e');
        return report(try only(try mcp_status.offline(io, arena, home, merged, environ_map), names.items), json, out);
    }
    if (std.mem.eql(u8, cmd, "reconnect")) {
        if (names.items.len == 0 and !all) return usage(out, "graff mcp reconnect <name>... | --all [--json]");
        for (names.items) |n| if (merged.servers.get(n) == null) std.process.fatal("mcp reconnect: server '{s}' is not configured (see `graff mcp status`)", .{n});
        @import("mcp_rpc.zig").applyHandshakeTimeoutEnv(environ_map);
        const rows = try @import("mcp_reconnect.zig").probe(io, gpa, arena, home, merged, if (all) null else names.items, environ_map);
        return report(rows, json, out);
    }
    const rows = try mcp_status.offline(io, arena, home, merged, environ_map);
    return report(if (names.items.len > 0) try only(rows, names.items) else rows, json, out);
}

fn only(rows: []mcp_status.Row, names: []const []const u8) ![]mcp_status.Row {
    var n: usize = 0;
    for (rows) |row| for (names) |want| if (std.mem.eql(u8, row.name, want)) {
        rows[n] = row;
        n += 1;
        break;
    };
    return rows[0..n];
}

fn usage(out: *Io.Writer, text: []const u8) !void {
    try out.print("usage: {s}\n", .{text});
    try out.flush();
}

fn report(rows: []const mcp_status.Row, json: bool, out: *Io.Writer) !void {
    if (json) {
        try mcp_status.writeJson(rows, out);
    } else if (rows.len == 0) {
        try out.writeAll("no MCP servers configured.\n");
    } else for (rows) |row| {
        try out.print("  {s}  {s}", .{ row.name, mcp_status.label(row) });
        if (row.toolCount > 0) try out.print(" · {d} tool(s)", .{row.toolCount});
        if (row.@"error") |e| try out.print(" — {s} ({s})", .{ e, row.errorCode orelse "?" });
        try out.print("  ({s}{s}{s})\n", .{ row.source, if (row.origin.len > 0) ", " else "", row.origin });
    }
    try out.flush();
}
