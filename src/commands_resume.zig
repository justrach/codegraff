//! `/resume`, clone-on-write `/resume SOURCE --branch DEST`, and `/fork`.

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

/// `/fork [NAME]`: branch the current conversation and continue in the branch.
fn tryFork(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.startsWith(u8, line, "/fork") or (line.len > 5 and line[5] != ' ' and line[5] != '\t')) return false;
    const arg = std.mem.trim(u8, line["/fork".len..], " \t");
    if (std.mem.indexOfAny(u8, arg, " \t") != null) return reject(out, "usage: /fork [NAME]\n", .{});
    const forked = @import("session_fork.zig").forkCurrent(root, keys, arena, if (arg.len == 0) null else arg, null) catch |err| return switch (err) {
        error.NothingToFork => reject(out, "fork failed: this conversation has nothing to fork yet\n", .{}),
        error.InvalidSessionName => reject(out, "fork failed: invalid session or branch name\n", .{}),
        error.BranchMatchesSource => reject(out, "fork failed: the branch name must differ from the current session\n", .{}),
        error.BranchAlreadyExists => reject(out, "fork failed: a session named {s} already exists\n", .{arg}),
        else => reject(out, "fork failed: {t}\n", .{err}),
    };
    presence.noteLabelsFrom(root.io, root.gpa, arena, root.session_title, root.session_name);
    try out.print("forked {s} into {s} ({d} messages); you are on the branch, /resume {s} returns to the original\n", .{ forked.source, forked.target, root.messages.items.len, forked.source });
    try out.flush();
    return true;
}

pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (try tryFork(root, keys, arena, line, out)) return true;
    if (!std.mem.startsWith(u8, line, "/resume") or (line.len > 7 and line[7] != ' ' and line[7] != '\t')) return false;
    const parsed = session_branch.parseSpec(line["/resume".len..]) orelse return reject(out, "usage: /resume SOURCE [--branch DEST]\n", .{});
    var source = parsed.source;
    var picked_remote: ?[]const u8 = null;
    if (source.len == 0) {
        if (!(main_mod.use_color and root.in != null)) return reject(out, "usage: /resume SOURCE [--branch DEST]\n", .{});
        const picked = pickSource(root, arena, out) orelse return true;
        source = try @import("session_workspaces.zig").target(arena, picked);
        if (!picked.local and picked.workspace.len > 0) picked_remote = try arena.dupe(u8, picked.workspace);
    }

    const resumed = session_branch.restore(root, keys, arena, source, parsed.branch, null) catch |err| return switch (err) {
        error.FileNotFound => reject(out, "{s}\n", .{try missingMessage(root, arena, source)}),
        error.WorkspaceUnavailable => reject(out, "resume stopped: the selected workspace could not be entered; use /workspace use with its directory, then retry /resume\n", .{}),
        error.InvalidSessionName => reject(out, "resume failed: invalid source or branch name\n", .{}),
        error.BranchMatchesSource => reject(out, "branch failed: destination must differ from source\n", .{}),
        error.BranchAlreadyExists => reject(out, "branch failed: destination already exists\n", .{}),
        else => reject(out, "resume failed: {t}\n", .{err}),
    };
    presence.noteLabelsFrom(root.io, root.gpa, arena, root.session_title, root.session_name);
    if (resumed.entered) {
        try out.print("now at {s} — read_file/edit_file/bash use this tree\n", .{session.displayWorkspace(arena, resumed.workspace, root.home)});
    } else if (resumed.enter_failed) {
        try out.print("could not enter {s} — history restored here; read_file/edit_file/bash stay in {s}\n", .{ session.displayWorkspace(arena, resumed.workspace, root.home), main_mod.g_cwd_display });
    } else if (picked_remote) |ws| {
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

pub fn missingMessage(root: *Agent, arena: Allocator, source: []const u8) ![]const u8 {
    const entries = session.listSavedSessionsAll(root, arena);
    for (entries.items) |entry| {
        if (entry.title) |title| if (std.mem.eql(u8, title, source))
            return std.fmt.allocPrint(arena, "'{s}' is a saved-session title; use /resume {s}", .{ source, try @import("session_workspaces.zig").target(arena, entry) });
    }
    return missingLiveMessage(arena, source, presence.liveAllPeers(root.io, arena));
}

fn missingLiveMessage(arena: Allocator, source: []const u8, peers: []const @import("worktree_lease.zig").Owner) ![]const u8 {
    for (peers) |peer| {
        const pid = std.fmt.parseInt(i32, source, 10) catch 0;
        if (!std.mem.eql(u8, source, peer.title) and !std.mem.eql(u8, source, peer.session_id) and
            !std.mem.eql(u8, source, peer.session_base) and (pid == 0 or pid != peer.pid)) continue;
        const key = if (peer.session_base.len > 0) peer.session_base else peer.session_id;
        return std.fmt.allocPrint(arena, "'{s}' matches a live session, but no reachable save has that key. /resume takes a saved key, not a title, PID or live ID. In the originating workspace, /save {s}; then select it with bare /resume. Live workspace identity: {s}", .{ source, key, peer.identity });
    }
    return std.fmt.allocPrint(arena, "no reachable saved session named '{s}'. Searched cwd, linked worktrees, remembered workspaces and ~/.graff/sessions. /resume takes a saved key (not a title or PID), or an absolute .graff/sessions/KEY.session.json path. Use bare /resume to select a save; /sessions also lists live processes, which may have no save yet.", .{source});
}

test "resume missing diagnostic distinguishes live identifiers from saved keys" {
    const a = std.testing.allocator;
    const peers = [_]@import("worktree_lease.zig").Owner{.{ .pid = 42, .session_id = "live-id", .title = "Visible title", .session_base = "saved-key", .identity = "/project/.git" }};
    const live = try missingLiveMessage(a, "42", &peers);
    defer a.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "matches a live session") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "/save saved-key") != null);
    const absent = try missingLiveMessage(a, "missing", &peers);
    defer a.free(absent);
    try std.testing.expect(std.mem.indexOf(u8, absent, "no reachable saved session") != null);
    try std.testing.expect(std.mem.indexOf(u8, absent, "remembered workspaces") != null);
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
