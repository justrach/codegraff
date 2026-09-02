//! Mid-session workspace switch: list git worktrees and chdir the root
//! session so read_file/edit_file/bash follow the new tree.
//!
//! A skill cannot do this. File tools resolve against process cwd (or a
//! subagent's isolated agent_cwd). `cd` inside bash does not move them.
//! `graff -w` creates a scratch tree at startup; this module switches among
//! trees that already exist (Claude worktrees, `git worktree add`, -w tabs).
//!
//! Surfaces:
//!   - workspace tool: action=list | use (folded; agent-thread only)
//!   - /workspace [list|use <name>]: the human's own switch
//!   - bundled `workspace` skill: when to load the tool, not the actuator

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const main_mod = @import("main.zig");
const jobs = @import("jobs.zig");
const presence = @import("presence.zig");
const tool_spill = @import("tool_spill.zig");

const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;

pub const tool_name = "workspace";
pub const tool_desc = "List this repo's git worktrees or switch the session into one. action=list (default) or use. path is a worktree path, its last folder, or a unique name fragment. File tools and bash follow the new cwd. Root session only — a subagent stays in its assigned tree. Do not bash-cd to switch.";
pub const tool_schema =
    \\{"type": "object", "properties": {"action": {"type": "string", "enum": ["list", "use"], "description": "list (default): the repo's git worktrees. use: chdir this session into one."}, "path": {"type": "string", "description": "worktree path, last folder, or unique fragment (required for use)"}}}
;

pub const Entry = struct {
    path: []const u8,
    head: []const u8 = "",
    branch: []const u8 = "",
};

pub const Resolve = union(enum) {
    one: Entry,
    already: Entry,
    none,
    ambiguous: []const Entry,
};

var g_cwd_owned: ?[]u8 = null;

pub fn deinitDisplay(gpa: Allocator) void {
    if (g_cwd_owned) |old| gpa.free(old);
    g_cwd_owned = null;
}

fn adoptDisplay(gpa: Allocator, path: []const u8) void {
    const owned = gpa.dupe(u8, path) catch return;
    if (g_cwd_owned) |old| gpa.free(old);
    g_cwd_owned = owned;
    main_mod.g_cwd_display = owned;
}

fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| return trimmed[i + 1 ..];
    return trimmed;
}

fn branchShort(ref: []const u8) []const u8 {
    const prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref, prefix)) return ref[prefix.len..];
    return ref;
}

/// Copy `s` into the arena so a row does not alias the caller's buffer. An
/// empty result on OOM drops the row rather than smuggling a dangling slice out.
fn own(arena: Allocator, s: []const u8) []const u8 {
    return arena.dupe(u8, s) catch "";
}

/// Parse `git worktree list --porcelain`. Ignores bare/detached/locked extras.
///
/// Every row OWNS its bytes. `listEntries` frees git's stdout as soon as it
/// returns, so borrowing out of `text` left each path and branch pointing at
/// released memory (#715): reused pages read back as NUL, which printed blank
/// rows for `action=list` and made `action=use` match neither the name nor the
/// exact path of a worktree git itself listed fine.
pub fn parsePorcelain(arena: Allocator, text: []const u8) []Entry {
    var list: std.ArrayList(Entry) = .empty;
    var cur: Entry = .{ .path = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            if (cur.path.len > 0) list.append(arena, cur) catch {};
            cur = .{ .path = "" };
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (cur.path.len > 0) list.append(arena, cur) catch {};
            cur = .{ .path = own(arena, std.mem.trim(u8, line["worktree ".len..], " \t")) };
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            cur.head = own(arena, std.mem.trim(u8, line["HEAD ".len..], " \t"));
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            cur.branch = own(arena, branchShort(std.mem.trim(u8, line["branch ".len..], " \t")));
        }
    }
    if (cur.path.len > 0) list.append(arena, cur) catch {};
    return list.items;
}

fn zpath(path: []const u8, z: *[std.fs.max_path_bytes + 1]u8) ?[:0]const u8 {
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return z[0..path.len :0];
}

fn realpathOs(path: []const u8, out: []u8) ?[]const u8 {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src = zpath(path, &z) orelse return null;
    const p = std.c.realpath(src, out.ptr) orelse return null;
    return std.mem.sliceTo(p, 0);
}

fn samePath(a: []const u8, b: []const u8) bool {
    const left = std.mem.trimEnd(u8, a, "/");
    const right = std.mem.trimEnd(u8, b, "/");
    if (std.mem.eql(u8, left, right)) return true;
    if (left.len == 0 or right.len == 0) return false;
    // Porcelain paths and getcwd disagree on macOS (/tmp vs /private/tmp) and
    // on any worktree added through a symlink. Star / already / enter must
    // compare the resolved directories, not the strings git printed (#721).
    var ab: [std.fs.max_path_bytes]u8 = undefined;
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const ar = realpathOs(left, &ab) orelse return false;
    const br = realpathOs(right, &bb) orelse return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, ar, "/"), std.mem.trimEnd(u8, br, "/"));
}

const Rank = enum(u8) { substring = 1, exact_branch, exact_base, exact_path };

fn matchRank(entry: Entry, want: []const u8) ?Rank {
    if (samePath(entry.path, want)) return .exact_path;
    if (std.mem.eql(u8, basename(entry.path), want)) return .exact_base;
    if (std.mem.eql(u8, entry.branch, want)) return .exact_branch;
    if (std.mem.indexOf(u8, entry.path, want) != null or std.mem.indexOf(u8, entry.branch, want) != null)
        return .substring;
    return null;
}

pub fn resolve(arena: Allocator, entries: []const Entry, want: []const u8, current: []const u8) Resolve {
    const needle = std.mem.trim(u8, want, " \t");
    if (needle.len == 0 or entries.len == 0) return .none;
    var best: ?Rank = null;
    var hits: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        const rank = matchRank(e, needle) orelse continue;
        if (best == null or @intFromEnum(rank) > @intFromEnum(best.?)) {
            best = rank;
            hits.clearRetainingCapacity();
            hits.append(arena, e) catch {};
        } else if (rank == best.?) {
            hits.append(arena, e) catch {};
        }
    }
    if (hits.items.len == 0) return .none;
    if (hits.items.len == 1) {
        if (current.len > 0 and samePath(hits.items[0].path, current)) return .{ .already = hits.items[0] };
        return .{ .one = hits.items[0] };
    }
    return .{ .ambiguous = hits.items };
}

pub fn formatList(arena: Allocator, entries: []const Entry, current: []const u8) []const u8 {
    if (entries.len == 0) return "no git worktrees here — this cwd is not a repository, or git worktree list failed";
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "git worktrees (star = this session). workspace action=use path=<folder or fragment> to switch.\n") catch {};
    for (entries) |e| {
        const star: []const u8 = if (current.len > 0 and samePath(e.path, current)) "* " else "  ";
        const br = if (e.branch.len > 0) e.branch else "(detached)";
        const line = std.fmt.allocPrint(arena, "{s}{s}  {s}\n", .{ star, e.path, br }) catch continue;
        buf.appendSlice(arena, line) catch {};
    }
    return buf.items;
}

fn currentAbs(io: Io, arena: Allocator) []const u8 {
    _ = io;
    // OS getcwd, not Io.Dir.cwd().realPath: Threaded Io can keep a stale Dir
    // across posix.chdir, so the listing starred one tree while bash still
    // ran in another, and `use` of the starred tree returned .already
    // without chdir'ing (#721).
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ptr = std.c.getcwd(&buf, buf.len) orelse return main_mod.g_cwd_display;
    return arena.dupe(u8, std.mem.sliceTo(ptr, 0)) catch main_mod.g_cwd_display;
}

fn listEntries(gpa: Allocator, io: Io, arena: Allocator) []Entry {
    const listed = jobs.runCapped(gpa, io, &.{ "git", "worktree", "list", "--porcelain" }, 64 * 1024, 4096, 15_000) catch return &.{};
    defer {
        gpa.free(listed.stdout);
        gpa.free(listed.stderr);
    }
    if (listed.term != .exited or listed.term.exited != 0) return &.{};
    return parsePorcelain(arena, listed.stdout);
}

fn enterPath(gpa: Allocator, io: Io, arena: Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const z = try arena.dupeSentinel(u8, path, 0);
    if (std.posix.system.chdir(z.ptr) != 0) return error.ChdirFailed;
    const abs = currentAbs(io, arena);
    if (!samePath(abs, path)) return error.ChdirFailed;
    adoptDisplay(gpa, abs);
    main_mod.g_worktree_branch = null;
    tool_spill.enable(.{ .io = io, .dir = .cwd(), .base_abs = main_mod.g_cwd_display });
    presence.rebind(io, gpa, arena);
    return abs;
}

fn run(gpa: Allocator, io: Io, arena: Allocator, from_sub: bool, action: []const u8, path: []const u8) ExecResult {
    if (from_sub) return .{
        .text = "workspace switch is root-session only — a subagent stays in its assigned tree",
        .is_error = true,
    };
    const current = currentAbs(io, arena);
    if (std.mem.eql(u8, action, "list") or action.len == 0) {
        return .{ .text = formatList(arena, listEntries(gpa, io, arena), current), .is_error = false };
    }
    if (!std.mem.eql(u8, action, "use")) return .{
        .text = "workspace action must be list or use",
        .is_error = true,
    };
    if (path.len == 0) return .{
        .text = "workspace use needs path — a worktree folder or unique fragment. action=list to see them.",
        .is_error = true,
    };
    const entries = listEntries(gpa, io, arena);
    return switch (resolve(arena, entries, path, current)) {
        .none => .{
            .text = tryText(arena, "no worktree matches \"{s}\" — action=list to see them", .{path}),
            .is_error = true,
        },
        .ambiguous => |hits| .{
            .text = tryText(arena, "more than one worktree matches \"{s}\":\n{s}", .{ path, formatList(arena, hits, current) }),
            .is_error = true,
        },
        .already => |e| .{
            .text = tryText(arena, "already at {s} ({s})", .{ e.path, if (e.branch.len > 0) e.branch else "detached" }),
            .is_error = false,
        },
        .one => |e| blk: {
            const abs = enterPath(gpa, io, arena, e.path) catch |err| break :blk .{
                .text = tryText(arena, "could not enter {s}: {t}", .{ e.path, err }),
                .is_error = true,
            };
            break :blk .{
                .text = tryText(arena, "now at {s} ({s}) — read_file, edit_file, and bash use this tree. Project instructions stay the ones from session start until /clear.", .{ abs, if (e.branch.len > 0) e.branch else "detached" }),
                .is_error = false,
            };
        },
    };
}

fn tryText(arena: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "workspace: out of memory";
}

pub fn handle(self: *Agent, call: ToolCall) !ExecResult {
    const obj = tools_mod.json_args.object(call.input);
    const action = if (obj) |o| (tools_mod.json_args.str(o, "action") orelse "list") else "list";
    const path = if (obj) |o| (tools_mod.json_args.str(o, "path") orelse "") else "";
    return run(self.gpa, self.io, self.arena, self.sub or self.agent_cwd != null, action, path);
}

fn isSlash(line: []const u8) bool {
    return std.mem.eql(u8, line, "/workspace") or std.mem.eql(u8, line, "/ws") or
        std.mem.startsWith(u8, line, "/workspace ") or std.mem.startsWith(u8, line, "/ws ");
}

/// /workspace [list|use <name>]. Bare lists.
pub fn slashCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!isSlash(line)) return false;
    const rest = if (std.mem.startsWith(u8, line, "/workspace"))
        std.mem.trim(u8, line["/workspace".len..], " \t")
    else
        std.mem.trim(u8, line["/ws".len..], " \t");
    var action: []const u8 = "list";
    var path: []const u8 = "";
    if (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "use ") or std.mem.startsWith(u8, rest, "cd ")) {
            action = "use";
            path = std.mem.trim(u8, rest[3..], " \t");
        } else if (std.mem.eql(u8, rest, "use") or std.mem.eql(u8, rest, "cd")) {
            action = "use";
        } else if (std.mem.eql(u8, rest, "list") or std.mem.eql(u8, rest, "ls")) {
            action = "list";
        } else {
            action = "use";
            path = rest;
        }
    }
    const result = run(root.gpa, root.io, arena, false, action, path);
    try out.writeAll(result.text);
    if (result.text.len == 0 or result.text[result.text.len - 1] != '\n') try out.writeAll("\n");
    try out.flush();
    return true;
}

const sample_porcelain =
    \\worktree /Users/rach/codegraff
    \\HEAD abcdef0123456789
    \\branch refs/heads/main
    \\
    \\worktree /Users/rach/codegraff/.claude/worktrees/cursor-peer-pull-554f
    \\HEAD d93214eb7fb782c3
    \\branch refs/heads/cursor/peer-pull-554f
    \\
    \\worktree /Users/rach/codegraff/.graff/worktrees/agent1
    \\HEAD 1111111111111111
    \\branch refs/heads/worktree-agent1
    \\
;

test "parsePorcelain: path, short branch, ignores extras" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const extra =
        \\worktree /tmp/repo
        \\HEAD deadbeef
        \\detached
        \\
    ;
    const rows = parsePorcelain(a, extra);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("/tmp/repo", rows[0].path);
    try std.testing.expectEqualStrings("", rows[0].branch);
    const all = parsePorcelain(a, sample_porcelain);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("cursor/peer-pull-554f", all[1].branch);
    try std.testing.expectEqualStrings("cursor-peer-pull-554f", basename(all[1].path));
}

test "#715: rows outlive the git output they were parsed from" {
    // `listEntries` frees git's stdout the moment it returns. While rows
    // borrowed their bytes out of that buffer, every path and branch pointed at
    // released memory: reused pages read back as NUL, so `action=list` printed
    // blank rows and `action=use` matched neither the name nor the exact path
    // of a worktree that git itself listed fine (#715). Zeroing the source here
    // is what that reuse looks like, without the undefined read.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const from_git = try std.testing.allocator.dupe(u8, sample_porcelain);
    defer std.testing.allocator.free(from_git);
    const rows = parsePorcelain(a, from_git);
    @memset(from_git, 0);

    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("cursor/peer-pull-554f", rows[1].branch);
    try std.testing.expectEqualStrings(
        "/Users/rach/codegraff/.claude/worktrees/cursor-peer-pull-554f",
        rows[1].path,
    );
    // ...and a freshly added tree stays selectable by fragment and by full path.
    switch (resolve(a, rows, "cursor-peer-pull-554f", "/Users/rach/codegraff")) {
        .one => |e| try std.testing.expectEqualStrings(rows[1].path, e.path),
        else => return error.TestExpectedWorktreeMatch,
    }
    switch (resolve(a, rows, "/Users/rach/codegraff/.graff/worktrees/agent1", "/Users/rach/codegraff")) {
        .one => |e| try std.testing.expectEqualStrings("worktree-agent1", e.branch),
        else => return error.TestExpectedWorktreeMatch,
    }
}

test "#715: real git rows survive listEntries freeing git's stdout" {
    // Every other test here parses a comptime literal, which lives in .rodata
    // and can never be freed — which is exactly why the dangling rows in #715
    // went unnoticed. This one walks the production path: spawn git, parse,
    // free stdout, then read. Skips where git or a repo is absent.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const rows = listEntries(gpa, std.testing.io, a);
    if (rows.len == 0) return error.SkipZigTest; // not a git worktree here

    for (rows) |e| {
        try std.testing.expect(e.path.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, e.path, 0) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, e.branch, 0) == null);
        // ...and every row git listed is one `action=use` can actually select.
        switch (resolve(a, rows, e.path, "")) {
            .one, .already => {},
            else => return error.TestExpectedWorktreeMatch,
        }
    }
}

test "resolve: unique fragment, basename, branch, already, none, ambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = parsePorcelain(a, sample_porcelain);
    const here = rows[0].path;
    switch (resolve(a, rows, "cursor-peer-pull-554f", here)) {
        .one => |e| try std.testing.expectEqualStrings(rows[1].path, e.path),
        else => return error.TestUnexpectedResult,
    }
    switch (resolve(a, rows, "cursor/peer-pull-554f", here)) {
        .one => |e| try std.testing.expectEqualStrings(rows[1].path, e.path),
        else => return error.TestUnexpectedResult,
    }
    switch (resolve(a, rows, here, here)) {
        .already => |e| try std.testing.expectEqualStrings(here, e.path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(resolve(a, rows, "no-such-tree", here) == .none);
    switch (resolve(a, rows, "codegraff", here)) {
        .already => |e| try std.testing.expectEqualStrings(here, e.path),
        else => return error.TestUnexpectedResult,
    }
    switch (resolve(a, rows, "worktrees", here)) {
        .ambiguous => |hits| try std.testing.expectEqual(@as(usize, 2), hits.len),
        else => return error.TestUnexpectedResult,
    }
}

test "formatList: stars the current tree and stays pull (no dump of bodies)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rows = parsePorcelain(a, sample_porcelain);
    const text = formatList(a, rows, rows[1].path);
    try std.testing.expect(std.mem.indexOf(u8, text, "* /Users/rach/codegraff/.claude/worktrees/cursor-peer-pull-554f") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "action=use") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, formatList(a, &.{}, ""), "*"));
}

test "run: subagent is refused; bad action and empty use name the fix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const sub = run(gpa, io, a, true, "list", "");
    try std.testing.expect(sub.is_error);
    try std.testing.expect(std.mem.indexOf(u8, sub.text, "root-session only") != null);
    const bad = run(gpa, io, a, false, "send", "");
    try std.testing.expect(bad.is_error);
    const empty = run(gpa, io, a, false, "use", "");
    try std.testing.expect(empty.is_error);
    try std.testing.expect(std.mem.indexOf(u8, empty.text, "action=list") != null);
}

test "enterPath: chdir then restore; display follows the new tree" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPath(io, &path_buf) catch return error.SkipZigTest;
    const dest = try a.dupe(u8, path_buf[0..n]);
    _ = std.posix.system.fchdir(orig.handle);
    const saved = main_mod.g_cwd_display;
    const saved_branch = main_mod.g_worktree_branch;
    defer {
        main_mod.g_cwd_display = saved;
        main_mod.g_worktree_branch = saved_branch;
        deinitDisplay(gpa);
        tool_spill.resetForTest();
    }
    const abs = try enterPath(gpa, io, a, dest);
    try std.testing.expect(samePath(dest, abs));
    try std.testing.expect(samePath(dest, main_mod.g_cwd_display));
}

test "#721: round-trip switch keeps posix cwd, display, and list star in lockstep" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir_a = std.testing.tmpDir(.{});
    defer dir_a.cleanup();
    var dir_b = std.testing.tmpDir(.{});
    defer dir_b.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.posix.system.fchdir(dir_a.dir.handle) != 0) return error.ChdirFailed;
    const path_a = try a.dupe(u8, std.mem.sliceTo(std.c.getcwd(&buf, buf.len) orelse return error.SkipZigTest, 0));
    if (std.posix.system.fchdir(dir_b.dir.handle) != 0) return error.ChdirFailed;
    const path_b = try a.dupe(u8, std.mem.sliceTo(std.c.getcwd(&buf, buf.len) orelse return error.SkipZigTest, 0));
    _ = std.posix.system.fchdir(orig.handle);
    const saved = main_mod.g_cwd_display;
    const saved_branch = main_mod.g_worktree_branch;
    defer {
        main_mod.g_cwd_display = saved;
        main_mod.g_worktree_branch = saved_branch;
        deinitDisplay(gpa);
        tool_spill.resetForTest();
    }
    _ = try enterPath(gpa, io, a, path_a);
    try std.testing.expect(samePath(std.mem.sliceTo(std.c.getcwd(&buf, buf.len) orelse "", 0), path_a));
    try std.testing.expect(samePath(main_mod.g_cwd_display, path_a));
    _ = try enterPath(gpa, io, a, path_b);
    try std.testing.expect(samePath(std.mem.sliceTo(std.c.getcwd(&buf, buf.len) orelse "", 0), path_b));
    try std.testing.expect(samePath(main_mod.g_cwd_display, path_b));
    const rows = [_]Entry{ .{ .path = path_a, .branch = "a" }, .{ .path = path_b, .branch = "b" } };
    const listed = formatList(a, &rows, currentAbs(io, a));
    try std.testing.expect(std.mem.indexOf(u8, listed, "* ") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, path_b) != null);
    // The #721 failure: report primary, posix still secondary.
    _ = try enterPath(gpa, io, a, path_a);
    try std.testing.expect(samePath(std.mem.sliceTo(std.c.getcwd(&buf, buf.len) orelse "", 0), path_a));
    try std.testing.expect(samePath(main_mod.g_cwd_display, path_a));
    switch (resolve(a, &rows, path_a, currentAbs(io, a))) {
        .already => {},
        else => return error.TestExpectedAlready,
    }
    switch (resolve(a, &rows, path_b, currentAbs(io, a))) {
        .one => {},
        else => return error.TestExpectedSwitch,
    }
}
