//! Device-local saved-workspace index. One file per root avoids shared RMW races.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const index = @import("session_index.zig");

const subdir = ".graff/session-workspaces";

pub fn remember(io: Io, _: Allocator, home: []const u8, workspace: []const u8) void {
    if (home.len == 0 or !std.fs.path.isAbsolute(workspace)) return;
    var tmp = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp.deinit();
    const arena = tmp.allocator();
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, subdir }) catch return;
    Io.Dir.cwd().createDirPath(io, path) catch return;
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return;
    defer dir.close(io);
    const name = std.fmt.allocPrint(arena, "{x}.json", .{std.hash.Wyhash.hash(0, workspace)}) catch return;
    // Unchanged roots need no write on subsequent autosaves.
    if (dir.readFileAlloc(io, name, arena, .limited(64 * 1024)) catch null) |old| {
        const parsed = std.json.parseFromSliceLeaky([]const u8, arena, old, .{}) catch null;
        if (parsed) |p| if (std.mem.eql(u8, p, workspace)) return;
    }
    var out: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(workspace, .{}, &out.writer) catch return;
    dir.writeFile(io, .{ .sub_path = name, .data = out.written() }) catch {};
}

pub fn list(io: Io, arena: Allocator, home: []const u8) []const []const u8 {
    if (home.len == 0) return &.{};
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, subdir }) catch return &.{};
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var roots: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(64 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky([]const u8, arena, text, .{ .allocate = .alloc_always }) catch continue;
        if (!std.fs.path.isAbsolute(root)) continue;
        roots.append(arena, root) catch {};
    }
    return roots.items;
}

pub const Target = struct { workspace: []const u8, base: []const u8 };

/// An absolute session-file path is an explicit workspace-qualified selection.
pub fn parseTarget(raw: []const u8) ?Target {
    if (!std.fs.path.isAbsolute(raw) or !std.mem.endsWith(u8, raw, index.session_ext)) return null;
    const marker = "/" ++ index.sessions_dir ++ "/";
    const at = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    const base = raw[at + marker.len .. raw.len - index.session_ext.len];
    if (!index.validSessionName(base)) return null;
    return .{ .workspace = if (at == 0) "/" else raw[0..at], .base = base };
}

pub fn target(arena: Allocator, entry: index.SessionEntry) ![]const u8 {
    if (entry.local or !std.fs.path.isAbsolute(entry.workspace)) return entry.base;
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}{s}", .{ std.mem.trimEnd(u8, entry.workspace, "/"), index.sessions_dir, entry.base, index.session_ext });
}

/// Presence identities are git directories, or cwd for non-git projects.
pub fn fromIdentity(io: Io, arena: Allocator, identity: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(identity)) return null;
    if (std.mem.endsWith(u8, identity, "/.git")) return identity[0 .. identity.len - 5];
    const gitdir = std.fmt.allocPrint(arena, "{s}/gitdir", .{identity}) catch return null;
    if (Io.Dir.cwd().readFileAlloc(io, gitdir, arena, .limited(64 * 1024)) catch null) |data| {
        const path = std.mem.trim(u8, data, " \t\r\n");
        if (std.fs.path.isAbsolute(path) and std.mem.endsWith(u8, path, "/.git")) return path[0 .. path.len - 5];
    }
    return identity;
}

test "session workspace index survives process state and disambiguates qualified targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const home = try tmp.dir.realPathFileAlloc(io, ".", arena);
    remember(io, arena, home, "/projects/one");
    remember(io, arena, home, "/projects/two");
    remember(io, arena, home, "/projects/one");
    const roots = list(io, arena, home);
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    const path = try target(arena, .{ .base = "same", .workspace = "/projects/two", .local = false });
    const parsed = parseTarget(path).?;
    try std.testing.expectEqualStrings("/projects/two", parsed.workspace);
    try std.testing.expectEqualStrings("same", parsed.base);
    try std.testing.expect(parseTarget("../same.session.json") == null);
    try std.testing.expect(parseTarget("/projects/two/.graff/sessions/../same.session.json") == null);
}
