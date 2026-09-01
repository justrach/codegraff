//! `/sessions` listing: cwd saves, then device-wide home saves (#712).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const session = @import("session.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;

const Agent = agent_mod.Agent;

pub fn writeSaved(root: *Agent, arena: Allocator, out: *Io.Writer) !void {
    var entries = session.listSavedSessionsAll(root, arena);
    defer entries.deinit(arena);
    var local_n: usize = 0;
    var remote_n: usize = 0;
    for (entries.items) |e| {
        if (e.local) local_n += 1 else remote_n += 1;
    }
    if (local_n > 0) {
        try out.writeAll("saved here\n");
        try writeRows(root, arena, out, entries.items, true);
    }
    if (remote_n > 0) {
        try out.writeAll("saved elsewhere on this device\n");
        try writeRows(root, arena, out, entries.items, false);
    }
    if (entries.items.len == 0) {
        try out.writeAll("(no saved sessions on this device — /save creates one in cwd)\n");
    } else if (local_n == 0) {
        try out.print("(no saved sessions in cwd — {d} elsewhere; bare /resume lists them)\n", .{remote_n});
    }
}

fn writeRows(root: *Agent, arena: Allocator, out: *Io.Writer, entries: []const session.SessionEntry, local: bool) !void {
    for (entries) |e| {
        if (e.local != local) continue;
        const age = session.sessionAge(arena, root.io, e.updated_ms);
        const cur = if (std.mem.eql(u8, e.base, root.session_name)) "  ← current" else "";
        const parent = if (e.parent) |p| std.fmt.allocPrint(arena, " ← {s}", .{p}) catch "" else "";
        const where = if (local) "" else std.fmt.allocPrint(arena, "  · {s}", .{session.displayWorkspace(arena, e.workspace, root.home)}) catch "";
        if (e.title) |t| {
            try out.print("  {s}  {s}{s}{s}{s}{s}{s}{s}{s}\n", .{ t, style.dim, e.base, parent, if (age.len > 0) " · " else "", age, where, style.reset, cur });
        } else {
            try out.print("  {s}{s}{s}{s}{s}{s}{s}{s}\n", .{ e.base, parent, style.dim, if (age.len > 0) "  " else "", age, where, style.reset, cur });
        }
    }
}

test "displayWorkspace tilde-shorts a home path (#712)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("~", session.displayWorkspace(a, "/Users/me", "/Users/me"));
    try std.testing.expectEqualStrings("~/code", session.displayWorkspace(a, "/Users/me/code", "/Users/me"));
    try std.testing.expectEqualStrings("/tmp/proj", session.displayWorkspace(a, "/tmp/proj", "/Users/me"));
}
