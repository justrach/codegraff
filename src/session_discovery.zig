//! Saved-session discovery across linked git worktrees, plus re-entering
//! that tree on resume (#1151). `$HOME` origin stays history-only (ADR 0059).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const main_mod = @import("main.zig");
const session_index = @import("session_index.zig");
const workspace_switch = @import("workspace_switch.zig");

const Agent = agent_mod.Agent;

pub const Located = struct {
    path: []const u8,
    workspace: []const u8,
    local: bool,
};

pub const EnterKind = enum { none, skipped, entered, failed };

pub const Entered = struct {
    workspace: []const u8 = "",
    kind: EnterKind = .none,
};

fn exists(io: Io, path: []const u8) bool {
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

fn cwdDisplay() []const u8 {
    return if (main_mod.g_cwd_display.len > 0) main_mod.g_cwd_display else ".";
}

fn absSession(arena: Allocator, workspace: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}{s}", .{ workspace, session_index.sessions_dir, name, session_index.session_ext });
}

/// Home-origin saves do not move file-tool cwd. Linked worktrees do (#1151).
pub fn shouldEnter(origin: []const u8, cwd: []const u8, home: []const u8) bool {
    if (origin.len == 0 or !std.fs.path.isAbsolute(origin)) return false;
    if (session_index.sameWorkspace(origin, cwd)) return false;
    if (home.len > 0 and session_index.sameWorkspace(origin, home)) return false;
    return true;
}

/// `extra` is additional workspace roots (tests pass fake trees; production
/// passes `git worktree list` paths). Cwd, then extras (newest wins on a
/// duplicate name), then `$HOME`.
pub fn locateIn(
    io: Io,
    arena: Allocator,
    name: []const u8,
    cwd: []const u8,
    home: []const u8,
    extra: []const []const u8,
) ?Located {
    if (!session_index.validSessionName(name)) return null;
    const local_rel = session_index.sessionPath(arena, name) catch return null;
    if (exists(io, local_rel)) return .{ .path = local_rel, .workspace = cwd, .local = true };
    const legacy = std.fmt.allocPrint(arena, "{s}{s}", .{ name, session_index.session_ext }) catch return null;
    if (exists(io, legacy)) return .{ .path = legacy, .workspace = cwd, .local = true };

    var best: ?Located = null;
    var best_ms: i64 = -1;
    for (extra) |workspace| {
        if (session_index.sameWorkspace(workspace, cwd)) continue;
        const path = absSession(arena, workspace, name) catch continue;
        if (!exists(io, path)) continue;
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch continue;
        const meta = session_index.sessionMetaFromBytes(arena, data);
        const ms = meta.updated_ms;
        if (best == null or ms > best_ms) {
            best = .{ .path = path, .workspace = meta.workspace orelse workspace, .local = false };
            best_ms = ms;
        }
    }
    if (best) |hit| return hit;

    if (home.len > 0 and !session_index.sameWorkspace(home, cwd)) {
        const home_path = session_index.homeSessionPath(arena, home, name) catch return null;
        if (exists(io, home_path)) return .{ .path = home_path, .workspace = home, .local = false };
    }
    return null;
}

fn extraWorktrees(root: *Agent, arena: Allocator) []const []const u8 {
    const trees = workspace_switch.listWorktrees(root.gpa, root.io, arena);
    var paths: std.ArrayList([]const u8) = .empty;
    for (trees) |t| {
        if (t.path.len == 0) continue;
        paths.append(arena, t.path) catch {};
    }
    return paths.items;
}

pub fn locate(root: *Agent, arena: Allocator, name: []const u8) ?Located {
    return locateIn(root.io, arena, name, cwdDisplay(), root.home, extraWorktrees(root, arena));
}

pub fn listAll(root: *Agent, arena: Allocator) std.ArrayList(session_index.SessionEntry) {
    var entries = session_index.listSavedSessions(root, arena);
    const cwd = cwdDisplay();
    for (extraWorktrees(root, arena)) |workspace| {
        if (session_index.sameWorkspace(workspace, cwd)) continue;
        session_index.appendWorkspaceSessions(root.io, arena, &entries, workspace, false);
    }
    const home = root.home;
    if (home.len > 0 and !session_index.sameWorkspace(home, cwd))
        session_index.appendWorkspaceSessions(root.io, arena, &entries, home, false);
    std.mem.sort(session_index.SessionEntry, entries.items, {}, struct {
        fn newer(_: void, a: session_index.SessionEntry, b: session_index.SessionEntry) bool {
            if (a.local != b.local) return a.local;
            return a.updated_ms > b.updated_ms;
        }
    }.newer);
    return entries;
}

pub fn enterOrigin(root: *Agent, arena: Allocator, name: []const u8) Entered {
    const found = locate(root, arena, name) orelse return .{};
    if (!shouldEnter(found.workspace, cwdDisplay(), root.home))
        return .{ .workspace = found.workspace, .kind = .skipped };
    if (builtin.os.tag == .windows)
        return .{ .workspace = found.workspace, .kind = .failed };
    const abs = workspace_switch.enterPath(root.gpa, root.io, arena, found.workspace) catch
        return .{ .workspace = found.workspace, .kind = .failed };
    return .{ .workspace = abs, .kind = .entered };
}

test "shouldEnter skips home and the current tree (#1151)" {
    try std.testing.expect(shouldEnter("/tmp/repo/.graff/worktrees/a", "/tmp/repo", "/Users/me"));
    try std.testing.expect(!shouldEnter("/Users/me", "/tmp/repo", "/Users/me"));
    try std.testing.expect(!shouldEnter("/tmp/repo", "/tmp/repo", "/Users/me"));
    try std.testing.expect(!shouldEnter("/tmp/repo/", "/tmp/repo", "/Users/me"));
    try std.testing.expect(!shouldEnter("relative", "/tmp/repo", "/Users/me"));
    try std.testing.expect(!shouldEnter("", "/tmp/repo", "/Users/me"));
}

test "locateIn prefers cwd then a linked worktree then home (#1151)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "cwd/.graff/sessions");
    try tmp.dir.createDirPath(io, "wt/.graff/sessions");
    try tmp.dir.createDirPath(io, "home/.graff/sessions");
    const cwd = try tmp.dir.realPathFileAlloc(io, "cwd", arena);
    const wt = try tmp.dir.realPathFileAlloc(io, "wt", arena);
    const home = try tmp.dir.realPathFileAlloc(io, "home", arena);

    try tmp.dir.writeFile(io, .{
        .sub_path = "cwd/.graff/sessions/here.session.json",
        .data = "{\"title\":\"Cwd\",\"updated_ms\":1,\"messages\":[]}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "wt/.graff/sessions/here.session.json",
        .data = "{\"title\":\"Tree\",\"updated_ms\":9,\"workspace\":\"unused\",\"messages\":[]}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "wt/.graff/sessions/isolated.session.json",
        .data = "{\"title\":\"Only tree\",\"updated_ms\":5,\"messages\":[]}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "home/.graff/sessions/notes.session.json",
        .data = "{\"title\":\"Home\",\"updated_ms\":3,\"messages\":[]}",
    });

    // locateIn cwd-relative paths are process-cwd, not tmp. Use absolute extras
    // and an empty relative cwd so local lookup misses, then extras/home hit.
    const isolated = locateIn(io, arena, "isolated", cwd, home, &.{wt}).?;
    try std.testing.expectEqualStrings(try absSession(arena, wt, "isolated"), isolated.path);
    try std.testing.expectEqualStrings(wt, isolated.workspace);
    try std.testing.expect(!isolated.local);

    const notes = locateIn(io, arena, "notes", cwd, home, &.{wt}).?;
    try std.testing.expect(session_index.sameWorkspace(notes.workspace, home));
    try std.testing.expect(!notes.local);
}

test "appendWorkspaceSessions skips names already listed (#1151)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "wt/.graff/sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "wt/.graff/sessions/shared.session.json",
        .data = "{\"title\":\"Tree\",\"updated_ms\":9,\"messages\":[]}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "wt/.graff/sessions/only.session.json",
        .data = "{\"title\":\"Only\",\"updated_ms\":2,\"messages\":[]}",
    });
    const wt = try tmp.dir.realPathFileAlloc(io, "wt", arena);

    var entries: std.ArrayList(session_index.SessionEntry) = .empty;
    try entries.append(arena, .{ .base = "shared", .title = "Cwd", .updated_ms = 1, .workspace = "/cwd", .local = true });
    session_index.appendWorkspaceSessions(io, arena, &entries, wt, false);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("shared", entries.items[0].base);
    try std.testing.expect(entries.items[0].local);
    try std.testing.expectEqualStrings("only", entries.items[1].base);
    try std.testing.expect(!entries.items[1].local);
}
