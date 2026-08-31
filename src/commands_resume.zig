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

const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const PickItem = pickers.PickItem;

fn pickSource(root: *Agent, arena: Allocator, out: *Io.Writer) ?[]const u8 {
    var entries = session.listSavedSessions(root, arena);
    defer entries.deinit(arena);
    if (entries.items.len == 0) {
        out.writeAll("(no saved sessions in cwd — /save creates one)\n") catch {};
        out.flush() catch {};
        return null;
    }
    var choices: std.ArrayList(PickItem) = .empty;
    defer choices.deinit(arena);
    for (entries.items) |e| {
        const age = session.sessionAge(arena, root.io, e.updated_ms);
        const desc = if (e.title == null)
            age
        else if (age.len > 0)
            std.fmt.allocPrint(arena, "{s} · {s}", .{ age, e.base }) catch e.base
        else
            e.base;
        choices.append(arena, .{ .name = e.title orelse e.base, .desc = desc }) catch return null;
    }
    const idx = pickers.listPicker(root, arena, out, "Resume session ›", choices.items) orelse return null;
    return entries.items[idx].base;
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
    if (source.len == 0) {
        if (!(main_mod.use_color and root.in != null)) return reject(out, "usage: /resume SOURCE [--branch DEST]\n", .{});
        source = pickSource(root, arena, out) orelse return true;
    }

    const resumed = session_branch.restore(root, keys, arena, source, parsed.branch) catch |err| return switch (err) {
        error.FileNotFound => reject(out, "no session named '{s}' ({s}{s} not found in cwd) — /sessions lists saved ones\n", .{ source, source, session.session_ext }),
        error.InvalidSessionName => reject(out, "resume failed: invalid source or branch name\n", .{}),
        error.BranchMatchesSource => reject(out, "branch failed: destination must differ from source\n", .{}),
        error.BranchAlreadyExists => reject(out, "branch failed: destination already exists\n", .{}),
        else => reject(out, "resume failed: {t}\n", .{err}),
    };
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
