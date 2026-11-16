//! REPL `/unharnessed` and `--json` `set_unharnessed` handlers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const unharnessed = @import("unharnessed_mode.zig");
const python_repl = @import("python_repl.zig");
const no_local_tools = @import("no_local_tools.zig");

pub fn handle(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/unharnessed") and !std.mem.startsWith(u8, line, "/unharnessed ")) return false;
    const arg = std.mem.trim(u8, line["/unharnessed".len..], " \t\r\n");
    if (arg.len == 0 or std.ascii.eqlIgnoreCase(arg, "status")) {
        if (no_local_tools.enabled) {
            try out.writeAll("unharnessed: off (disabled by --no-local-tools)\n");
        } else {
            try out.print("unharnessed: {s} (use /unharnessed on|off|reset)\n", .{unharnessed.label()});
        }
        try out.flush();
        return true;
    }
    if (std.ascii.eqlIgnoreCase(arg, "reset")) {
        python_repl.resetSession(root.io);
        try out.writeAll("python_repl: namespace reset\n");
        try out.flush();
        return true;
    }
    const on = unharnessed.parse(arg) orelse {
        try out.writeAll("usage: /unharnessed [on|off|reset|status]\n");
        try out.flush();
        return true;
    };
    if (on and no_local_tools.enabled) {
        try out.writeAll("unharnessed: unavailable in --no-local-tools mode\n");
        try out.flush();
        return true;
    }
    const saved = try unharnessed.applyLive(root, arena, on, true);
    const suffix: []const u8 = if (saved) "" else " (not persisted)";
    try out.print("unharnessed: {s}{s}\n", .{ unharnessed.label(), suffix });
    try out.flush();
    return true;
}

pub fn handleJson(root: *Agent, arena: Allocator, obj: std.json.ObjectMap) void {
    const mode_val = obj.get("mode");
    if (mode_val) |mv| if (mv == .string and std.ascii.eqlIgnoreCase(std.mem.trim(u8, mv.string, " \t\r\n"), "reset")) {
        python_repl.resetSession(root.io);
        root.emit(.{ .type = "unharnessed", .ok = true, .on = unharnessed.enabled(), .reset = true });
        return;
    };
    const on: ?bool = if (obj.get("on")) |v|
        (if (v == .bool) v.bool else if (v == .string) unharnessed.parse(v.string) else null)
    else if (mode_val) |mv|
        (if (mv == .string) unharnessed.parse(mv.string) else null)
    else
        null;
    const next = on orelse {
        root.emit(.{ .type = "error", .message = "set_unharnessed needs {\"on\": true|false} or {\"mode\": \"on\"|\"off\"|\"reset\"}" });
        return;
    };
    if (next and no_local_tools.enabled) {
        root.emit(.{ .type = "error", .message = "unharnessed mode is disabled by --no-local-tools" });
        return;
    }
    _ = unharnessed.applyLive(root, arena, next, true) catch |err| {
        root.emit(.{ .type = "error", .message = @errorName(err) });
        return;
    };
    root.emit(.{ .type = "unharnessed", .ok = true, .on = unharnessed.enabled() });
}
