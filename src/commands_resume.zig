//! `/resume` and clone-on-write `/resume SOURCE --branch DEST`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const session = @import("session.zig");
const session_branch = @import("session_branch.zig");
const main_mod = @import("main.zig");
const pickers = @import("pickers.zig");
const presence = @import("presence.zig");

const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const PickItem = pickers.PickItem;

fn pickSource(root: *Agent, arena: Allocator, out: *Io.Writer) ?session.SessionEntry {
    var entries = session.listSavedSessionsAll(root, arena);
    defer entries.deinit(arena);
    if (entries.items.len == 0) {
        out.writeAll("(no saved sessions on this device — /save creates one in cwd)\n") catch {};
        out.flush() catch {};
        return null;
    }
    var choices: std.ArrayList(PickItem) = .empty;
    defer choices.deinit(arena);
    for (entries.items) |e| {
        const age = session.sessionAge(arena, root.io, e.updated_ms);
        const where = if (e.local) "" else session.displayWorkspace(arena, e.workspace, root.home);
        const desc = blk: {
            if (!e.local and where.len > 0) {
                if (age.len > 0) break :blk std.fmt.allocPrint(arena, "{s} · {s} · {s}", .{ age, e.base, where }) catch e.base;
                break :blk std.fmt.allocPrint(arena, "{s} · {s}", .{ e.base, where }) catch e.base;
            }
            if (e.title == null) break :blk age;
            if (age.len > 0) break :blk std.fmt.allocPrint(arena, "{s} · {s}", .{ age, e.base }) catch e.base;
            break :blk e.base;
        };
        choices.append(arena, .{ .name = e.title orelse e.base, .desc = desc }) catch return null;
    }
    const idx = pickers.listPicker(root, arena, out, "Resume session ›", choices.items) orelse return null;
    return entries.items[idx];
}

fn reject(out: *Io.Writer, comptime fmt: []const u8, args: anytype) !bool {
    try out.print(fmt, args);
    try out.flush();
    return true;
}

pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.startsWith(u8, line, "/resume") or (line.len > 7 and line[7] != ' ' and line[7] != '\t')) return false;
    const parsed = session_branch.parseSpec(line["/resume".len..]) orelse return reject(out, "usage: /resume SOURCE [--branch DEST]\n", .{});
    var source = parsed.source;
    var picked_remote: ?[]const u8 = null;
    if (source.len == 0) {
        if (!(main_mod.use_color and root.in != null)) return reject(out, "usage: /resume SOURCE [--branch DEST]\n", .{});
        const picked = pickSource(root, arena, out) orelse return true;
        source = try arena.dupe(u8, picked.base);
        if (!picked.local and picked.workspace.len > 0) picked_remote = try arena.dupe(u8, picked.workspace);
    }

    const resumed = session_branch.restore(root, keys, arena, source, parsed.branch) catch |err| return switch (err) {
        error.FileNotFound => reject(out, "no session named '{s}' ({s}{s} not found in cwd or ~/{s}) — /sessions lists saved ones\n", .{ source, source, session.session_ext, session.sessions_dir }),
        error.InvalidSessionName => reject(out, "resume failed: invalid source or branch name\n", .{}),
        error.BranchMatchesSource => reject(out, "branch failed: destination must differ from source\n", .{}),
        error.BranchAlreadyExists => reject(out, "branch failed: destination already exists\n", .{}),
        else => reject(out, "resume failed: {t}\n", .{err}),
    };
    presence.noteLabelsFrom(root.io, root.gpa, arena, root.session_title, root.session_name);
    if (picked_remote) |ws| {
        try out.print("this save is from {s} — history restored here; read_file/edit_file/bash stay in {s}\n", .{ session.displayWorkspace(arena, ws, root.home), main_mod.g_cwd_display });
    }
    if (resumed.branched) {
        try out.print("branched {s}{s} → {s}{s} — {d} message(s), {s} via {s}{s}\n", .{ resumed.source, session.session_ext, resumed.target, session.session_ext, root.messages.items.len, root.provider.model, root.provider.id, if (root.strict) " (strict)" else "" });
    } else {
        try out.print("resumed {s}{s} — {d} message(s), {s} via {s}{s}\n", .{ source, session.session_ext, root.messages.items.len, root.provider.model, root.provider.id, if (root.strict) " (strict)" else "" });
    }
    try out.flush();
    return true;
}

test "resume argument parser separates an explicit branch" {
    const plain = session_branch.parseSpec(" baseline ").?;
    try std.testing.expectEqualStrings("baseline", plain.source);
    try std.testing.expect(plain.branch == null);
    const forked = session_branch.parseSpec("baseline --branch branch-a").?;
    try std.testing.expectEqualStrings("baseline", forked.source);
    try std.testing.expectEqualStrings("branch-a", forked.branch.?);
    try std.testing.expect(session_branch.parseSpec("baseline --branch ") == null);
}
