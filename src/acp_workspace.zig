//! ACP session workspace: adopt the client's `cwd` and report the Git
//! worktree the session runs in as `_meta["graff/worktree"]` (ADR 0202).
//!
//! ACP requires an absolute `cwd` on session/new and session/load and the
//! agent must use it regardless of where it was spawned. A process launched
//! with `-w <name>` or auto-isolated keeps its tree when the client names the
//! checkout that owns it; any other folder becomes the session's cwd.
//! Extensions ride `_meta` because ACP forbids custom top-level fields.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const proto = @import("acp_protocol.zig");
const runner = @import("process_runner.zig");
const session_index = @import("session_index.zig");
const util = @import("util.zig");
const workspace_switch = @import("workspace_switch.zig");
const worktree_base = @import("worktree_base.zig");

/// Present on the live CLI dispatch; embeds leave it null and report nothing.
pub const Env = struct { gpa: Allocator, io: Io };

pub const Info = struct {
    /// The `-w` / `graff worktree` name: branch minus `worktree-`, else the folder name.
    name: []const u8,
    path: []const u8,
    branch: []const u8,
    /// Landing branch recorded when graff created the tree; null when unknown.
    base: ?[]const u8 = null,
    baseSha: ?[]const u8 = null,
    /// The main checkout that owns this linked worktree.
    root: []const u8,
    /// Auto-isolated `session-*` tree; these are reaped once their process is gone.
    generated: bool,
};

/// Explicit null means "main checkout"; clients clear their worktree state on it.
pub const Meta = struct { @"graff/worktree": ?Info };

pub const AdoptError = error{ RelativeCwd, MissingCwd, ChdirFailed } || Allocator.Error;

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.RelativeCwd => "Session cwd must be an absolute path",
        error.MissingCwd => "Session cwd does not exist or is not a directory",
        else => "Session cwd could not be entered",
    };
}

fn git(env: Env, arena: Allocator, argv: []const []const u8) ?[]const u8 {
    const r = runner.runCapped(env.gpa, env.io, argv, 16 * 1024, 4096, 15_000) catch return null;
    defer env.gpa.free(r.stdout);
    defer env.gpa.free(r.stderr);
    if (!runner.ranOk(r)) return null;
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch null;
}

/// Pure half of `info`: `git rev-parse --path-format=absolute --show-toplevel
/// --git-dir --git-common-dir` output plus the short branch.
pub fn fromRevParse(arena: Allocator, rev_parse: []const u8, branch: []const u8) ?Info {
    var it = std.mem.tokenizeAny(u8, rev_parse, "\r\n");
    const top = it.next() orelse return null;
    const git_dir = std.mem.trimEnd(u8, it.next() orelse return null, "/");
    const common = std.mem.trimEnd(u8, it.next() orelse return null, "/");
    // The main checkout's git dir IS the common dir; only linked trees differ.
    if (std.mem.eql(u8, git_dir, common)) return null;
    if (!std.mem.endsWith(u8, common, "/.git")) return null; // bare repos have no checkout root
    const name = if (std.mem.startsWith(u8, branch, "worktree-") and branch.len > "worktree-".len)
        branch["worktree-".len..]
    else
        std.fs.path.basename(top);
    return .{
        .name = arena.dupe(u8, name) catch return null,
        .path = arena.dupe(u8, top) catch return null,
        .branch = arena.dupe(u8, branch) catch return null,
        .root = arena.dupe(u8, common[0 .. common.len - "/.git".len]) catch return null,
        .generated = std.mem.startsWith(u8, branch, "worktree-session-"),
    };
}

/// The linked worktree the process runs in, or null in a main checkout or outside Git.
pub fn info(env: Env, arena: Allocator) ?Info {
    const rev = git(env, arena, &.{ "git", "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" }) orelse return null;
    const branch = git(env, arena, &.{ "git", "symbolic-ref", "--short", "HEAD" }) orelse "";
    var out = fromRevParse(arena, rev, branch) orelse return null;
    const base = worktree_base.read(env.gpa, env.io, arena, out.root, branch);
    if (base.len > 0) {
        out.base = base;
        out.baseSha = git(env, arena, &.{ "git", "merge-base", "HEAD", base });
    }
    return out;
}

pub fn meta(env: Env, arena: Allocator) Meta {
    return .{ .@"graff/worktree" = info(env, arena) };
}

fn cwdParam(params: ?Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    return util.strFieldObj(p.object, "cwd");
}

/// Make the client's `cwd` the session's working directory. Keeps the current
/// tree when the client names it or the checkout that owns it (`-w`, auto-isolate).
pub fn adopt(env: Env, arena: Allocator, params: ?Value) AdoptError!void {
    const want = cwdParam(params) orelse return; // pre-v1 clients omit it
    if (!std.fs.path.isAbsolute(want)) return error.RelativeCwd;
    var dir = Io.Dir.cwd().openDir(env.io, want, .{}) catch return error.MissingCwd;
    dir.close(env.io);
    const active = workspace_switch.currentAbs(env.io, arena);
    if (workspace_switch.samePath(env.io, want, active)) return;
    if (info(env, arena)) |tree| if (workspace_switch.samePath(env.io, want, tree.root)) return;
    _ = workspace_switch.enterPath(env.gpa, env.io, arena, want) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ChdirFailed;
}

/// session/load from a main checkout: a save made inside one of its
/// `.graff/worktrees/<name>` trees. Enters that tree and returns true.
pub fn enterSavedTree(env: Env, arena: Allocator, session_id: []const u8) bool {
    if (info(env, arena) != null) return false; // already inside a linked tree
    const rel = session_index.sessionPath(arena, session_id) catch return false;
    var trees = Io.Dir.cwd().openDir(env.io, ".graff/worktrees", .{ .iterate = true }) catch return false;
    defer trees.close(env.io);
    var it = trees.iterate();
    while (it.next(env.io) catch return false) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = std.fmt.allocPrint(arena, ".graff/worktrees/{s}/{s}", .{ entry.name, rel }) catch return false;
        const stat = Io.Dir.cwd().statFile(env.io, candidate, .{}) catch continue;
        if (stat.kind != .file) continue;
        // enterPath verifies the chdir by resolving its argument afterwards,
        // so it must be absolute.
        const tree = std.fs.path.join(arena, &.{ workspace_switch.currentAbs(env.io, arena), ".graff/worktrees", entry.name }) catch return false;
        _ = workspace_switch.enterPath(env.gpa, env.io, arena, tree) catch return false;
        return true;
    }
    return false;
}

/// Taken before a prompt turn; compared by `emitChange` after it.
pub fn snapshot(env: ?Env, arena: Allocator) []const u8 {
    if (env == null) return "";
    return arena.dupe(u8, main_mod.g_cwd_display) catch "";
}

/// `/workspace use` and the `workspace` tool move the root session. Tell the
/// client with `session_info_update` so it can re-record the chat's tree.
pub fn emitChange(env: ?Env, arena: Allocator, w: *Io.Writer, session_id: []const u8, before: []const u8) !void {
    const e = env orelse return;
    if (std.mem.eql(u8, before, main_mod.g_cwd_display)) return;
    try proto.writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{ .sessionUpdate = "session_info_update", ._meta = meta(e, arena) },
    });
}

test "fromRevParse: a linked tree reports its name, branch, and owning checkout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rev = "/repo/.graff/worktrees/harness-abc\n/repo/.git/worktrees/harness-abc\n/repo/.git\n";
    const got = fromRevParse(a, rev, "worktree-harness-abc").?;
    try std.testing.expectEqualStrings("harness-abc", got.name);
    try std.testing.expectEqualStrings("/repo/.graff/worktrees/harness-abc", got.path);
    try std.testing.expectEqualStrings("/repo", got.root);
    try std.testing.expect(!got.generated);
    try std.testing.expect(fromRevParse(a, rev, "worktree-session-42-deadbeef").?.generated);
    // A hand-made tree on another branch is named after its folder.
    try std.testing.expectEqualStrings("harness-abc", fromRevParse(a, rev, "feature/x").?.name);
}

test "fromRevParse: the main checkout and bare repos report no worktree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(fromRevParse(a, "/repo\n/repo/.git\n/repo/.git\n", "main") == null);
    try std.testing.expect(fromRevParse(a, "/srv/x\n/srv/x.git/worktrees/y\n/srv/x.git\n", "main") == null);
    try std.testing.expect(fromRevParse(a, "", "main") == null);
}

test "Meta serializes an explicit null for the main checkout" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var s: std.json.Stringify = .{ .writer = &w };
    try s.write(Meta{ .@"graff/worktree" = null });
    try std.testing.expectEqualStrings("{\"graff/worktree\":null}", w.buffered());
}

test "errorText names the cwd problem" {
    try std.testing.expectEqualStrings("Session cwd must be an absolute path", errorText(error.RelativeCwd));
    try std.testing.expectEqualStrings("Session cwd does not exist or is not a directory", errorText(error.MissingCwd));
}
