//! #1654: saveSession writes no size limit, but every reader used to cap a
//! session file at 8 MiB. One opaque provider compaction item can exceed that
//! alone, so a long session saved fine and then could not be listed or loaded.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const session_index = @import("session_index.zig");

/// A save past the old 8 MiB cap: one large opaque message before the tail.
fn writeLargeSave(gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) !void {
    const blob = try gpa.alloc(u8, 9 * 1024 * 1024);
    defer gpa.free(blob);
    @memset(blob, 'a');
    const data = try std.fmt.allocPrint(gpa, "{{\"provider\":\"anthropic\",\"model\":\"sonnet\",\"title\":\"Long chat\",\"updated_ms\":7,\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}},{{\"role\":\"user\",\"content\":\"remember 1654\"}}]}}", .{blob});
    defer gpa.free(data);
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

test "#1654 a session save larger than 8 MiB still lists and loads" {
    const session = @import("session.zig");
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];
    try tmp.dir.createDirPath(io, ".graff/sessions");
    try writeLargeSave(gpa, tmp.dir, ".graff/sessions/large-1654.session.json");

    var sessions = try tmp.dir.openDir(io, ".graff/sessions", .{ .iterate = true });
    defer sessions.close(io);
    const listed = session_index.listFromDir(io, arena, sessions, home, false);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("Long chat", listed.items[0].title.?);

    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
        if (!std.mem.eql(u8, spec.id, "anthropic")) continue;
        value.* = "launch-key";
        source.* = .environment;
    }
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = .init(arena),
        .sub = false,
        .label = "root",
        .out = null,
        .home = home,
        .stored_keys_loaded = true,
    };
    try session.loadSession(&root, &keys, arena, "large-1654");
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);

    // Past the shared limit the save is reported as too large, not as missing.
    const saved_limit = session_index.max_session_bytes;
    defer session_index.max_session_bytes = saved_limit;
    session_index.max_session_bytes = 1024 * 1024;
    try std.testing.expectError(error.SessionTooLarge, session.loadSession(&root, &keys, arena, "large-1654"));
}

test "#1848 listFromDir and locateIn inspect bounded headers without retaining session bodies in the listing arena" {
    const discovery = @import("session_discovery.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "wt/.graff/sessions");
    try writeLargeSave(gpa, tmp.dir, "wt/.graff/sessions/one-9mb.session.json");
    try writeLargeSave(gpa, tmp.dir, "wt/.graff/sessions/two-9mb.session.json");

    var sessions = try tmp.dir.openDir(io, "wt/.graff/sessions", .{ .iterate = true });
    defer sessions.close(io);

    // An 8 KiB FixedBufferAllocator cannot hold even 0.1% of one 9 MiB save,
    // proving neither listFromDir nor locateIn reads or retains message bodies
    // in the caller's arena.
    var backing: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const tiny_arena = fba.allocator();

    const wt = try tmp.dir.realPathFileAlloc(io, "wt", tiny_arena);
    const listed = session_index.listFromDir(io, tiny_arena, sessions, wt, true);
    try std.testing.expectEqual(@as(usize, 2), listed.items.len);
    try std.testing.expectEqualStrings("Long chat", listed.items[0].title.?);
    try std.testing.expectEqualStrings("Long chat", listed.items[1].title.?);

    const located = discovery.locateIn(io, tiny_arena, "one-9mb", "/nonexistent-cwd", "", &.{wt}).?;
    try std.testing.expectEqualStrings(wt, located.workspace);
    try std.testing.expect(fba.end_index < 2048);
}
