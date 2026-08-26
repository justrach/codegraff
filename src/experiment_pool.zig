//! #629 first slice: a pre-minted worktree pool for one experiment.
//! Lives on `release/v0.0.279` only (not merged to main). Fan-out seats
//! children in already-created trees so the first tool is not `git worktree add`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const cap: u8 = 16;

const Slot = struct { path: []const u8, branch: []const u8 };

var g_n: u8 = 0;
var g_next: u8 = 0;
var g_id: []const u8 = "";
var g_slots: [cap]Slot = @splat(.{ .path = "", .branch = "" });

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
    g_slots = @splat(.{ .path = "", .branch = "" });
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
    if (g_next >= g_n) return null;
    const i = g_next;
    g_next += 1;
    return g_slots[i].path;
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

fn mintOne(gpa: Allocator, io: Io, arena: Allocator, id: []const u8, i: u8) !Slot {
    var pbuf: [256]u8 = undefined;
    var bbuf: [256]u8 = undefined;
    const rel = slotPath(&pbuf, id, i);
    const branch = try arena.dupe(u8, slotBranch(&bbuf, id, i));
    if (dirExists(io, rel)) return .{ .path = try absOrRel(io, arena, rel), .branch = branch };
    const add = runCapped(gpa, io, &.{ "git", "worktree", "add", rel, "-b", branch }, 8192, 8192, 60_000) catch return error.CreateFailed;
    defer {
        gpa.free(add.stdout);
        gpa.free(add.stderr);
    }
    if (!ranOk(add) and !dirExists(io, rel)) return error.CreateFailed;
    return .{ .path = try absOrRel(io, arena, rel), .branch = branch };
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
    return n;
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
