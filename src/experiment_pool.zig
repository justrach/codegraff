//! #629 experiment worktree pool: mint N trees first, seat children in them,
//! force the root to spawn, list/deliver-back without deleting the pool.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const cap: u8 = 16;

pub const Seat = struct { path: []const u8 = "", branch: []const u8 = "", base: []const u8 = "" };

/// Standing line injected into the root system prompt while a pool is armed.
pub const directive_marker = "Experiment pool `";

var g_n: u8 = 0;
var g_next: u8 = 0;
var g_id: []const u8 = "";
var g_directive: []const u8 = "";
var g_slots: [cap]Seat = @splat(.{});

pub fn enabled() bool {
    return g_n > 0;
}

pub fn size() u8 {
    return g_n;
}

pub fn remaining() u8 {
    if (g_next >= g_n) return 0;
    return g_n - g_next;
}

pub fn reset() void {
    g_n = 0;
    g_next = 0;
    g_id = "";
    g_directive = "";
    g_slots = @splat(.{});
}

pub fn sanitizeId(buf: []u8, id: []const u8) []const u8 {
    const n = @min(id.len, buf.len);
    for (id[0..n], 0..) |c, i| {
        buf[i] = if (c == '/' or c == '\\' or c == ' ') '-' else c;
    }
    return buf[0..n];
}

pub fn slotPath(buf: []u8, id: []const u8, i: u8) []const u8 {
    return std.fmt.bufPrint(buf, ".graff/worktrees/exp-{s}/{d}", .{ id, i }) catch buf[0..0];
}

pub fn slotBranch(buf: []u8, id: []const u8, i: u8) []const u8 {
    return std.fmt.bufPrint(buf, "graff/exp/{s}/{d}", .{ id, i }) catch buf[0..0];
}

/// Next unused seat, or null when the pool is empty/exhausted.
pub fn claim() ?[]const u8 {
    const seat = claimSeat() orelse return null;
    return seat.path;
}

/// Path + branch + creation HEAD so finish can report keep-reason without
/// deleting the tree (ADR 0037: pool trees are not auto-deleted).
pub fn claimSeat() ?Seat {
    if (g_next >= g_n) return null;
    const i = g_next;
    g_next += 1;
    return g_slots[i];
}

/// Root must spawn, not edit. Null when the pool is off.
pub fn directive() ?[]const u8 {
    if (g_n == 0 or g_directive.len == 0) return null;
    return g_directive;
}

/// `graff worktree list` tag: minted pool trees, even after this process resets.
pub fn isExperimentTree(path: []const u8, branch: []const u8) bool {
    if (std.mem.indexOf(u8, path, ".graff/worktrees/exp-") != null) return true;
    const b = if (std.mem.startsWith(u8, branch, "refs/heads/")) branch["refs/heads/".len..] else branch;
    return std.mem.startsWith(u8, b, "graff/exp/");
}

pub fn statusLine(buf: []u8) []const u8 {
    if (g_n == 0) return "experiment pool off";
    return std.fmt.bufPrint(buf, "experiment {s}: {d}/{d} seats left", .{ g_id, remaining(), g_n }) catch "experiment pool";
}

fn dirExists(io: Io, path: []const u8) bool {
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

fn absOrRel(io: Io, arena: Allocator, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return arena.dupe(u8, path);
    return arena.dupe(u8, buf[0..n]);
}

fn readHead(gpa: Allocator, io: Io, arena: Allocator, path: []const u8) []const u8 {
    const r = runCapped(gpa, io, &.{ "git", "-C", path, "rev-parse", "HEAD" }, 4096, 4096, 15_000) catch return "";
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return "";
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch "";
}

fn mintOne(gpa: Allocator, io: Io, arena: Allocator, id: []const u8, i: u8) !Seat {
    var pbuf: [256]u8 = undefined;
    var bbuf: [256]u8 = undefined;
    const rel = slotPath(&pbuf, id, i);
    const branch = try arena.dupe(u8, slotBranch(&bbuf, id, i));
    if (!dirExists(io, rel)) {
        const add = runCapped(gpa, io, &.{ "git", "worktree", "add", rel, "-b", branch }, 8192, 8192, 60_000) catch return error.CreateFailed;
        defer {
            gpa.free(add.stdout);
            gpa.free(add.stderr);
        }
        if (!ranOk(add) and !dirExists(io, rel)) return error.CreateFailed;
    }
    const path = try absOrRel(io, arena, rel);
    return .{ .path = path, .branch = branch, .base = readHead(gpa, io, arena, path) };
}

/// Create or reuse N trees under `.graff/worktrees/exp-{id}/`. Idempotent
/// on an already-armed pool of the same size.
pub fn arm(gpa: Allocator, io: Io, arena: Allocator, id: []const u8, n: u8) !u8 {
    if (n == 0 or n > cap) return error.BadPoolSize;
    const probe = runCapped(gpa, io, &.{ "git", "rev-parse", "--is-inside-work-tree" }, 4096, 4096, 15_000) catch return error.NotAGitRepo;
    defer {
        gpa.free(probe.stdout);
        gpa.free(probe.stderr);
    }
    if (!ranOk(probe)) return error.NotAGitRepo;

    reset();
    var idbuf: [64]u8 = undefined;
    g_id = try arena.dupe(u8, sanitizeId(&idbuf, id));
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        g_slots[i] = try mintOne(gpa, io, arena, g_id, i);
    }
    g_n = n;
    g_next = 0;
    g_directive = try std.fmt.allocPrint(arena, "{s}{s}` is armed with {d} pre-minted worktrees under `.graff/worktrees/exp-{s}/` (branches `graff/exp/{s}/0` …). You MUST call the subagent tool once per independent task or A/B arm so each child claims a seat. Do not edit files in this caller tree. After children return, synthesize — do not redo their work here.", .{
        directive_marker, g_id, n, g_id, g_id,
    });
    return n;
}

/// Report path / branch / keep-reason / diffstat. Never removes the tree.
pub fn deliverNote(gpa: Allocator, io: Io, seat: Seat) []const u8 {
    const keep = @import("agent_worktree.zig");
    const st = runCapped(gpa, io, &.{ "git", "-C", seat.path, "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch
        return std.fmt.allocPrint(gpa, "\n\n[experiment seat kept (could not verify) — path: {s}, branch: {s}]", .{ seat.path, seat.branch }) catch "";
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }
    var head_buf: [64]u8 = undefined;
    const head = blk: {
        const r = runCapped(gpa, io, &.{ "git", "-C", seat.path, "rev-parse", "HEAD" }, 4096, 4096, 15_000) catch break :blk "";
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (!ranOk(r)) break :blk "";
        const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
        const n = @min(trimmed.len, head_buf.len);
        @memcpy(head_buf[0..n], trimmed[0..n]);
        break :blk head_buf[0..n];
    };
    const reason = keep.worktreeKeepReason(ranOk(st), st.stdout, seat.base, head);
    const why: []const u8 = if (reason == .removed) "clean, left in the pool" else keep.keepReasonText(reason);
    var stat: []const u8 = "";
    if (seat.base.len > 0) {
        if (runCapped(gpa, io, &.{ "git", "-C", seat.path, "diff", "--stat", seat.base }, 4096, 2048, 15_000)) |r| {
            defer {
                gpa.free(r.stdout);
                gpa.free(r.stderr);
            }
            if (ranOk(r)) {
                const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
                if (trimmed.len > 0) stat = std.fmt.allocPrint(gpa, "; {s}", .{trimmed}) catch "";
            }
        } else |_| {}
    }
    defer if (stat.len > 0) gpa.free(stat);
    return std.fmt.allocPrint(gpa, "\n\n[experiment seat kept ({s}) — path: {s}, branch: {s}{s}]", .{
        why, seat.path, seat.branch, stat,
    }) catch "";
}

test "slot names are stable and claim walks the pool" {
    var pbuf: [64]u8 = undefined;
    var bbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(".graff/worktrees/exp-live/0", slotPath(&pbuf, "live", 0));
    try std.testing.expectEqualStrings("graff/exp/live/2", slotBranch(&bbuf, "live", 2));
    var sbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a-b", sanitizeId(&sbuf, "a/b"));

    reset();
    g_id = "live";
    g_n = 2;
    g_slots[0] = .{ .path = "a", .branch = "ba" };
    g_slots[1] = .{ .path = "b", .branch = "bb" };
    try std.testing.expectEqualStrings("a", claim().?);
    try std.testing.expectEqual(@as(u8, 1), remaining());
    try std.testing.expectEqualStrings("b", claim().?);
    try std.testing.expect(claim() == null);
    try std.testing.expectEqual(@as(u8, 0), remaining());
}

test "statusLine names the id and remaining seats" {
    reset();
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("experiment pool off", statusLine(&buf));
    g_id = "q";
    g_n = 3;
    g_next = 1;
    try std.testing.expectEqualStrings("experiment q: 2/3 seats left", statusLine(&buf));
}

test "arm rejects empty and oversized pools before git" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.BadPoolSize, arm(std.testing.allocator, std.testing.io, a, "live", 0));
    try std.testing.expectError(error.BadPoolSize, arm(std.testing.allocator, std.testing.io, a, "live", 17));
}

test "isExperimentTree matches pool paths and graff/exp branches" {
    try std.testing.expect(isExperimentTree("/tmp/repo/.graff/worktrees/exp-live/0", "refs/heads/graff/exp/live/0"));
    try std.testing.expect(isExperimentTree("/other", "graff/exp/q/1"));
    try std.testing.expect(!isExperimentTree("/tmp/repo/.graff/worktrees/agent-sa-1", "refs/heads/graff/agents/sa-1"));
    try std.testing.expect(!isExperimentTree("/tmp/repo", "main"));
}

test "directive is off until arm writes the spawn mandate" {
    reset();
    defer reset();
    try std.testing.expect(directive() == null);
}

fn fixtureGit(gpa: Allocator, io: Io, argv: []const []const u8) !void {
    const r = runCapped(gpa, io, argv, 1 << 16, 1 << 16, 60_000) catch return error.SkipZigTest;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!ranOk(r)) return error.FixtureCommandFailed;
}

test "arm mints then reuses real git worktrees; deliver-back never deletes (#629)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer _ = std.posix.system.fchdir(orig_dir.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "work.txt", .data = "one\n" });
    try fixtureGit(gpa, io, &.{ "git", "init", "-q" });
    try fixtureGit(gpa, io, &.{ "git", "add", "-A" });
    try fixtureGit(gpa, io, &.{ "git", "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "fixture" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    reset();
    defer reset();

    try std.testing.expectEqual(@as(u8, 2), try arm(gpa, io, arena, "live", 2));
    try std.testing.expect(dirExists(io, ".graff/worktrees/exp-live/0"));
    try std.testing.expect(dirExists(io, ".graff/worktrees/exp-live/1"));
    try std.testing.expect(std.mem.indexOf(u8, directive().?, "MUST") != null);
    try std.testing.expect(std.mem.indexOf(u8, directive().?, "Do not edit files in this caller tree") != null);

    const first0 = g_slots[0].path;
    try std.testing.expectEqual(@as(u8, 2), try arm(gpa, io, arena, "live", 2));
    try std.testing.expectEqualStrings(first0, g_slots[0].path);
    try std.testing.expect(g_slots[0].base.len > 0);

    const seat = claimSeat().?;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ".graff/worktrees/exp-live/0/dirty.txt", .data = "edit\n" });

    const note = deliverNote(gpa, io, seat);
    defer if (note.len > 0) gpa.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "experiment seat kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, seat.branch) != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "has changes") != null);
    try std.testing.expect(dirExists(io, ".graff/worktrees/exp-live/0"));
}
