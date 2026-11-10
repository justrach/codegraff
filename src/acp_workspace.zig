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

/// Explicit null on `graff/worktree` means "main checkout" (clients clear their
/// worktree state on it); `graff/cwd` always carries the active absolute cwd (#1737).
pub const Meta = struct { @"graff/worktree": ?Info, @"graff/cwd": []const u8 };

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

var base_cache_key: [512]u8 = undefined;
var base_cache_key_len: usize = 0;
var base_cache_sha: [64]u8 = undefined;
var base_cache_sha_len: usize = 0;

fn resolveWorktreeInProcess(env: Env, arena: Allocator) union(enum) { not_linked, linked: Info, fallback } {
    const cwd = workspace_switch.currentAbs(env.io, arena);
    if (!std.fs.path.isAbsolute(cwd)) return .fallback;
    var cur: []const u8 = if (cwd.len > 1) std.mem.trimEnd(u8, cwd, "/") else cwd;
    while (true) {
        const dot_git = std.fs.path.join(arena, &.{ cur, ".git" }) catch return .fallback;
        if (Io.Dir.cwd().statFile(env.io, dot_git, .{}) catch null) |st| {
            if (st.kind == .directory) return .not_linked;
            if (st.kind != .file) return .fallback;
            const dot_bytes = Io.Dir.cwd().readFileAlloc(env.io, dot_git, arena, .limited(4096)) catch return .fallback;
            const trimmed = std.mem.trim(u8, dot_bytes, " \t\r\n");
            if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return .fallback;
            const raw_gitdir = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
            const git_dir = (if (std.fs.path.isAbsolute(raw_gitdir))
                arena.dupe(u8, raw_gitdir)
            else
                std.fs.path.resolve(arena, &.{ cur, raw_gitdir })) catch return .fallback;
            const commondir_path = std.fs.path.join(arena, &.{ git_dir, "commondir" }) catch return .fallback;
            const common_bytes = Io.Dir.cwd().readFileAlloc(env.io, commondir_path, arena, .limited(4096)) catch return .fallback;
            const raw_common = std.mem.trim(u8, common_bytes, " \t\r\n");
            const common_dir = (if (std.fs.path.isAbsolute(raw_common))
                arena.dupe(u8, raw_common)
            else
                std.fs.path.resolve(arena, &.{ git_dir, raw_common })) catch return .fallback;
            const head_path = std.fs.path.join(arena, &.{ git_dir, "HEAD" }) catch return .fallback;
            const head_bytes = Io.Dir.cwd().readFileAlloc(env.io, head_path, arena, .limited(4096)) catch return .fallback;
            const head_trimmed = std.mem.trim(u8, head_bytes, " \t\r\n");
            const branch: []const u8 = if (std.mem.startsWith(u8, head_trimmed, "ref: refs/heads/"))
                head_trimmed["ref: refs/heads/".len..]
            else if (std.mem.startsWith(u8, head_trimmed, "ref:"))
                return .fallback
            else
                "";
            const rev = std.fmt.allocPrint(arena, "{s}\n{s}\n{s}\n", .{ cur, git_dir, common_dir }) catch return .fallback;
            return if (fromRevParse(arena, rev, branch)) |out| .{ .linked = out } else .not_linked;
        }
        const parent = std.fs.path.dirname(cur) orelse return .not_linked;
        if (std.mem.eql(u8, parent, cur)) return .not_linked;
        cur = parent;
    }
}

fn cachedMergeBase(env: Env, arena: Allocator, top: []const u8, root: []const u8, branch: []const u8, base: []const u8) ?[]const u8 {
    const head_ref_path = if (branch.len > 0)
        std.fs.path.join(arena, &.{ root, ".git", "refs", "heads", branch }) catch null
    else
        null;
    const head_oid = if (head_ref_path) |p|
        std.mem.trim(u8, Io.Dir.cwd().readFileAlloc(env.io, p, arena, .limited(128)) catch "", " \t\r\n")
    else
        "";
    const key = if (head_oid.len > 0)
        std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}\x00{s}", .{ top, branch, base, head_oid }) catch null
    else
        null;
    if (key) |k| {
        if (k.len <= base_cache_key.len and std.mem.eql(u8, base_cache_key[0..base_cache_key_len], k) and base_cache_sha_len > 0) {
            return arena.dupe(u8, base_cache_sha[0..base_cache_sha_len]) catch null;
        }
    }
    const sha = git(env, arena, &.{ "git", "merge-base", "HEAD", base }) orelse return null;
    if (key) |k| {
        if (k.len <= base_cache_key.len and sha.len <= base_cache_sha.len) {
            @memcpy(base_cache_key[0..k.len], k);
            base_cache_key_len = k.len;
            @memcpy(base_cache_sha[0..sha.len], sha);
            base_cache_sha_len = sha.len;
        }
    }
    return sha;
}

/// The linked worktree the process runs in, or null in a main checkout or outside Git.
pub fn info(env: Env, arena: Allocator) ?Info {
    var out: Info = switch (resolveWorktreeInProcess(env, arena)) {
        .not_linked => return null,
        .linked => |resolved| resolved,
        .fallback => blk: {
            const rev = git(env, arena, &.{ "git", "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" }) orelse return null;
            if (fromRevParse(arena, rev, "") == null) return null;
            const branch = git(env, arena, &.{ "git", "symbolic-ref", "--short", "HEAD" }) orelse "";
            break :blk fromRevParse(arena, rev, branch) orelse return null;
        },
    };
    const base = worktree_base.read(env.gpa, env.io, arena, out.root, out.branch);
    if (base.len > 0) {
        out.base = base;
        out.baseSha = cachedMergeBase(env, arena, out.path, out.root, out.branch, base);
    }
    return out;
}

pub fn meta(env: Env, arena: Allocator) Meta {
    return .{
        .@"graff/worktree" = info(env, arena),
        .@"graff/cwd" = workspace_switch.currentAbs(env.io, arena),
    };
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
    if (workspace_switch.samePath(env.io, want, active)) {
        if (!std.fs.path.isAbsolute(main_mod.g_cwd_display) and std.fs.path.isAbsolute(active))
            @import("workspace_display.zig").adopt(env.gpa, active);
        return;
    }
    if (@import("acp_t3.zig").keepsIsolatedTree()) if (info(env, arena)) |tree| if (workspace_switch.samePath(env.io, want, tree.root)) return;
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

/// `session_info_update` meta: same shape as handshake `Meta` (`graff/worktree`
/// plus `graff/cwd`) so clients can re-root cwd-relative work (image attachment,
/// files panel) even when switching to a main checkout or non-graff tree (#1737).
pub const ChangeMeta = Meta;

/// The live session's env and the cwd the client was last told about. The
/// event stream reads them to report a mid-turn switch (`emitMoved`) without
/// threading the dispatch through it. Embeds and the REPL leave env null.
var live_env: ?Env = null;
var reported_buf: [std.fs.max_path_bytes]u8 = undefined;
var reported_len: usize = 0;

fn remember(cwd: []const u8) void {
    reported_len = @min(cwd.len, reported_buf.len);
    @memcpy(reported_buf[0..reported_len], cwd[0..reported_len]);
}

/// Taken before a prompt turn: the client already knows this cwd.
pub fn snapshot(env: ?Env) void {
    live_env = env orelse return;
    remember(main_mod.g_cwd_display);
}

fn emitIfMoved(e: Env, arena: Allocator, w: *Io.Writer, session_id: []const u8) !void {
    const cwd = main_mod.g_cwd_display;
    if (std.mem.eql(u8, reported_buf[0..reported_len], cwd)) return;
    try proto.writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{ .sessionUpdate = "session_info_update", ._meta = ChangeMeta{
            .@"graff/worktree" = info(e, arena),
            .@"graff/cwd" = cwd,
        } },
    });
    remember(cwd);
}

/// `/workspace use` and the `workspace` tool move the root session. Tell the
/// client with `session_info_update` so it can re-record the chat's tree.
/// Silent when `emitMoved` already reported the switch during the turn.
pub fn emitChange(env: ?Env, arena: Allocator, w: *Io.Writer, session_id: []const u8) !void {
    try emitIfMoved(env orelse return, arena, w, session_id);
}

/// After a root tool result: report a switch the moment it happens, before
/// the model's next call. Waiting for the turn to end left the client
/// resolving tools it serves (show_image) against the old tree (#1737).
pub fn emitMoved(w: *Io.Writer, session_id: []const u8) !void {
    const e = live_env orelse return;
    if (std.mem.eql(u8, reported_buf[0..reported_len], main_mod.g_cwd_display)) return;
    var arena_state = std.heap.ArenaAllocator.init(e.gpa);
    defer arena_state.deinit();
    try emitIfMoved(e, arena_state.allocator(), w, session_id);
}

pub fn resetForTest() void {
    live_env = null;
    reported_len = 0;
    base_cache_key_len = 0;
    base_cache_sha_len = 0;
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

test "Meta serializes an explicit null for the main checkout alongside graff/cwd" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var s: std.json.Stringify = .{ .writer = &w };
    try s.write(Meta{ .@"graff/worktree" = null, .@"graff/cwd" = "/repo" });
    try std.testing.expectEqualStrings("{\"graff/worktree\":null,\"graff/cwd\":\"/repo\"}", w.buffered());
}

test "#1737: a mid-turn workspace switch reaches the client with the tool result, once" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const saved = main_mod.g_cwd_display;
    defer main_mod.g_cwd_display = saved;
    defer resetForTest();
    const stream = @import("acp_stream.zig");
    const ev = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"type":"tool_result","id":"call-7","name":"workspace","text":"now at /trees/other","is_error":false}
    , .{});
    var id_buf: [64]u8 = @splat(0);
    var next: u32 = 0;
    var buf: [8192]u8 = undefined;

    // Without a live ACP session (REPL, embeds) nothing extra is written.
    main_mod.g_cwd_display = "/trees/launch";
    var quiet: Io.Writer = .fixed(&buf);
    _ = try stream.translateEvent(&quiet, "s1", ev, &id_buf, &next);
    try std.testing.expect(std.mem.indexOf(u8, quiet.buffered(), "session_info_update") == null);

    // Live session: the switch is reported right after the tool's own update.
    snapshot(.{ .gpa = a, .io = std.testing.io });
    main_mod.g_cwd_display = "/trees/other";
    var w: Io.Writer = .fixed(&buf);
    _ = try stream.translateEvent(&w, "s1", ev, &id_buf, &next);
    const out = w.buffered();
    const done = std.mem.indexOf(u8, out, "call-7") orelse return error.TestExpectedToolUpdate;
    const info_at = std.mem.indexOf(u8, out, "\"session_info_update\"") orelse return error.TestExpectedInfoUpdate;
    try std.testing.expect(done < info_at);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"graff/cwd\":\"/trees/other\"") != null);

    // Already told: neither the next tool result nor turn end repeats it.
    var again: Io.Writer = .fixed(&buf);
    _ = try stream.translateEvent(&again, "s1", ev, &id_buf, &next);
    try emitChange(.{ .gpa = a, .io = std.testing.io }, arena.allocator(), &again, "s1");
    try std.testing.expect(std.mem.indexOf(u8, again.buffered(), "session_info_update") == null);

    // A slash switch (no tool result) is still reported at turn end.
    main_mod.g_cwd_display = "/trees/third";
    var end: Io.Writer = .fixed(&buf);
    try emitChange(.{ .gpa = a, .io = std.testing.io }, arena.allocator(), &end, "s1");
    try std.testing.expect(std.mem.indexOf(u8, end.buffered(), "\"graff/cwd\":\"/trees/third\"") != null);
}

test "errorText names the cwd problem" {
    try std.testing.expectEqualStrings("Session cwd must be an absolute path", errorText(error.RelativeCwd));
    try std.testing.expectEqualStrings("Session cwd does not exist or is not a directory", errorText(error.MissingCwd));
}

test "resolveWorktreeInProcess resolves main checkouts and linked worktrees without spawning git" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git/worktrees/wt-fast");
    try tmp.dir.createDirPath(io, "repo/.graff/worktrees/wt-fast");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/worktrees/wt-fast/commondir", .data = "../..\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/worktrees/wt-fast/HEAD", .data = "ref: refs/heads/worktree-wt-fast\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.graff/worktrees/wt-fast/.git", .data = "gitdir: ../../../.git/worktrees/wt-fast\n" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved_cwd = workspace_switch.currentAbs(io, a);
    const saved_display = main_mod.g_cwd_display;
    defer {
        _ = workspace_switch.enterPath(a, io, a, saved_cwd) catch {};
        main_mod.g_cwd_display = saved_display;
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root_abs = try std.fs.path.join(a, &.{ buf[0..n], "repo" });
    const wt_abs = try std.fs.path.join(a, &.{ root_abs, ".graff/worktrees/wt-fast" });
    const env: Env = .{ .gpa = std.testing.allocator, .io = io };

    _ = try workspace_switch.enterPath(a, io, a, root_abs);
    try std.testing.expect(resolveWorktreeInProcess(env, a) == .not_linked);
    try std.testing.expect(info(env, a) == null);

    _ = try workspace_switch.enterPath(a, io, a, wt_abs);
    const resolved = resolveWorktreeInProcess(env, a);
    try std.testing.expect(resolved == .linked);
    try std.testing.expectEqualStrings("wt-fast", resolved.linked.name);
    try std.testing.expectEqualStrings("worktree-wt-fast", resolved.linked.branch);
    try std.testing.expectEqualStrings(root_abs, resolved.linked.root);
}
