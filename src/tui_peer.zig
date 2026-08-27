//! Host side of TUI `/tell` / `/peek`: the pager is a thin client; this
//! calls the existing mailbox (`tellCommand` / `peekCommand`) on the live
//! agent. Wired from `tui_launch` as `engine.PeerFn`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const peer_channel = @import("peer_channel.zig");
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");
const repl_glue = @import("repl_glue.zig");

const Agent = agent_mod.Agent;

/// Run a `/tell` or `/peek` line against `root`. Caller frees the returned
/// text. Null only when the line is not a peer slash or allocation failed.
pub fn runSlash(root: *Agent, gpa: Allocator, line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const is_tell = std.mem.startsWith(u8, trimmed, "/tell") and
        (trimmed.len == 5 or trimmed[5] == ' ' or trimmed[5] == '\t');
    const is_peek = std.mem.startsWith(u8, trimmed, "/peek") and
        (trimmed.len == 5 or trimmed[5] == ' ' or trimmed[5] == '\t');
    if (!is_tell and !is_peek) return null;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const ok = if (is_tell)
        peer_channel.tellCommand(root, arena_state.allocator(), trimmed, &w)
    else
        peer_channel.peekCommand(root, arena_state.allocator(), trimmed, &w);
    _ = ok catch return gpa.dupe(u8, "peer talk failed") catch null;
    return gpa.dupe(u8, w.buffered()) catch null;
}

/// `engine.PeerFn` — reads the live agent off `ReplCtx.root`.
pub fn peerCb(ctx: ?*anyopaque, gpa: Allocator, line: []const u8) ?[]const u8 {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return null));
    const root = c.root orelse return gpa.dupe(u8, "peer talk needs a live session") catch null;
    return runSlash(root, gpa, line);
}

test "TUI /tell all appends a device-room line the other session would hear" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{std.mem.sliceTo(&tmp.sub_path, 0)});
    defer gpa.free(dir_path);

    presence.bindForTest(dir_path, "/repo/.git", "s-tui", proc_identity.selfRecord(io));
    defer presence.unbindForTest();

    var root: Agent = undefined;
    root.io = io;
    const text = runSlash(&root, gpa, "/tell all hold the tree from the pager") orelse
        return error.ExpectedPosted;
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "posted") != null);

    const room = tmp.dir.readFileAlloc(io, presence.device_room, gpa, .limited(4096)) catch
        return error.ExpectedRoomFile;
    defer gpa.free(room);
    try std.testing.expect(std.mem.indexOf(u8, room, "hold the tree from the pager") != null);
    try std.testing.expect(std.mem.indexOf(u8, room, "\"from_user\":true") != null);
}
