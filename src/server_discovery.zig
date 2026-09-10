//! Untrusted orphan hints, never ownership. No adoption or signalling API.
const std = @import("std");
const builtin = @import("builtin");
const runner = @import("process_runner.zig");
const A = std.mem.Allocator;
pub const Candidate = struct { pid: i32, listener: i32 };
pub const Result = struct { candidates: []const Candidate = &.{}, incomplete: bool = false };
pub const Process = struct { pid: i32, ppid: i32, pgid: i32, uid: u32 };

pub fn parseProcess(line: []const u8) ?Process {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    const pid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const ppid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const pgid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const uid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or pid <= 1 or ppid < 0 or pgid <= 1) return null;
    return .{ .pid = pid, .ppid = ppid, .pgid = pgid, .uid = uid };
}

pub fn marker(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\x00");
    while (it.next()) |word| {
        // Environment is spoofable (and ps may include argv). This is a hint ONLY.
        if (!std.mem.startsWith(u8, word, "GRAFF_")) continue;
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse continue;
        if (eq > 6 and eq + 1 < word.len) return true;
    }
    return false;
}

fn lookup(procs: []const Process, pid: i32) ?Process {
    for (procs) |p| if (p.pid == pid) return p;
    return null;
}

pub fn orphanLeader(procs: []const Process, listener: i32, uid: u32) ?Process {
    const p = lookup(procs, listener) orelse return null;
    const leader = lookup(procs, p.pgid) orelse return null;
    if (p.uid != uid or leader.uid != uid or leader.pid != leader.pgid or leader.ppid != 1) return null;
    return leader;
}

pub fn descendant(procs: []const Process, child: Process, leader: Process) bool {
    var p = child;
    for (0..procs.len) |_| {
        if (p.uid != leader.uid or p.pgid != leader.pid) return false;
        if (p.pid == leader.pid) return true;
        p = lookup(procs, p.ppid) orelse return false;
    }
    return false;
}

fn capture(gpa: A, io: std.Io, arena: A, argv: []const []const u8, empty_ok: bool) ![]const u8 {
    const r = try runner.runCapped(gpa, io, argv, 1024 * 1024, 4096, 500);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.timed_out or r.stdout_truncated or r.stderr_truncated or r.cancelled) return error.DiscoveryIncomplete;
    switch (r.term) {
        .exited => |code| if (code != 0 and !(empty_ok and code == 1 and r.stdout.len == 0 and r.stderr.len == 0)) return error.DiscoveryCommandFailed,
        else => return error.DiscoveryCommandFailed,
    }
    if (r.stderr.len != 0) return error.DiscoveryCommandFailed;
    return try arena.dupe(u8, r.stdout);
}

/// At most 35 short subprocesses, capped output, at most 4096 processes and
/// 32 environment inspections. Failures/limits remain visible, not healthy.
pub fn scan(gpa: A, io: std.Io, arena: A) !Result {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.DiscoveryUnsupported;
    const uid_text = try capture(gpa, io, arena, &.{ "id", "-u" }, false);
    const uid = std.fmt.parseInt(u32, std.mem.trim(u8, uid_text, " \r\n"), 10) catch return error.DiscoveryMalformed;
    const table = try capture(gpa, io, arena, &.{ "ps", "-axo", "pid=,ppid=,pgid=,uid=" }, false);
    var procs: std.array_list.Managed(Process) = .init(arena);
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (procs.items.len >= 4096) return error.DiscoveryLimit;
        if (parseProcess(line)) |p| try procs.append(p);
    }
    if (procs.items.len == 0) return error.DiscoveryMalformed;
    var ubuf: [16]u8 = undefined;
    const uid_s = try std.fmt.bufPrint(&ubuf, "{d}", .{uid});
    const sockets = try capture(gpa, io, arena, &.{ "lsof", "-a", "-nP", "-u", uid_s, "-iTCP", "-sTCP:LISTEN", "-Fp" }, true);
    var result: Result = .{};
    var candidates: std.array_list.Managed(Candidate) = .init(arena);
    var checked: std.array_list.Managed(i32) = .init(arena);
    var inspections: usize = 0;
    lines = std.mem.splitScalar(u8, sockets, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != 'p') continue;
        const listener = std.fmt.parseInt(i32, line[1..], 10) catch return error.DiscoveryMalformed;
        const leader = orphanLeader(procs.items, listener, uid) orelse continue;
        if (std.mem.indexOfScalar(i32, checked.items, leader.pid) != null) continue;
        try checked.append(leader.pid);
        for (procs.items) |p| {
            if (!descendant(procs.items, p, leader)) continue;
            if (inspections >= 32) {
                result.incomplete = true;
                break;
            }
            inspections += 1;
            var pbuf: [16]u8 = undefined;
            const pid_s = try std.fmt.bufPrint(&pbuf, "{d}", .{p.pid});
            const env = capture(gpa, io, arena, &.{ "ps", "eww", "-p", pid_s, "-o", "command=" }, false) catch {
                result.incomplete = true;
                continue;
            };
            if (marker(env)) {
                try candidates.append(.{ .pid = leader.pid, .listener = listener });
                break;
            }
        }
    }
    result.candidates = candidates.items;
    return result;
}

test "discovery process parser rejects malformed and unsafe IDs" {
    try std.testing.expectEqual(@as(i32, 20), parseProcess("20 1 20 501").?.pid);
    try std.testing.expect(parseProcess("20 1 20 nope") == null);
    try std.testing.expect(parseProcess("1 0 1 501") == null);
    try std.testing.expect(parseProcess("20 1 20 501 extra") == null);
}

test "discovery markers are token bounded and nonempty hints" {
    try std.testing.expect(marker("node GRAFF_SESSION=x"));
    try std.testing.expect(marker("X=a\x00GRAFF_JOB_ID=2\x00"));
    try std.testing.expect(!marker("NOT_GRAFF_SESSION=x GRAFF_SESSION="));
}

test "discovery requires same-user orphan group leader and descendant chain" {
    const procs = [_]Process{
        .{ .pid = 20, .ppid = 1, .pgid = 20, .uid = 501 },
        .{ .pid = 21, .ppid = 20, .pgid = 20, .uid = 501 },
        .{ .pid = 22, .ppid = 21, .pgid = 20, .uid = 501 },
        .{ .pid = 23, .ppid = 1, .pgid = 20, .uid = 502 },
        .{ .pid = 24, .ppid = 24, .pgid = 20, .uid = 501 },
    };
    try std.testing.expect(orphanLeader(&procs, 22, 501) != null);
    try std.testing.expect(orphanLeader(&procs, 23, 501) == null);
    try std.testing.expect(orphanLeader(&procs, 22, 502) == null);
    try std.testing.expect(descendant(&procs, procs[2], procs[0]));
    try std.testing.expect(!descendant(&procs, procs[3], procs[0]));
    try std.testing.expect(!descendant(&procs, procs[4], procs[0]));
}
