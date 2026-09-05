//! Ownership records for background jobs (#199): `~/.codegraff/jobs/<pid>.json`,
//! one per live job, written at spawn and removed when the pump reaps it.
//! The record is what outlives a graff that died without running its defers
//! (SIGKILL, a closed terminal): the process tree may still be alive, and
//! `graff servers` reads these to find it, show its ports, and stop it — only
//! ever a tree graff itself started, checked against the leader's pid AND
//! start identity (#413) so a recycled pid never gets an unrelated process
//! killed. A pinned job the session keeps on exit stays here, `retained`.
//!
//! Ports are not stored: a server is not listening yet when it is spawned.
//! They are read live (`lsof` by process group) when someone looks.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc_identity = @import("proc_identity.zig");
const process_runner = @import("process_runner.zig");

const posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// The process $HOME, pinned at startup beside oauth.initHome. "" (tests, no
/// HOME) means no on-disk record; the in-session pool is unaffected.
pub var home: []const u8 = "";

pub const Record = struct {
    pid: i32,
    start_id: u64 = 0,
    owner_pid: i32 = 0,
    owner_start_id: u64 = 0,
    cmd: []const u8,
    cwd: []const u8 = "",
    started_ms: i64 = 0,
    pinned: bool = false,
    retained: bool = false,
};

pub fn dirPath(buf: []u8, base: []const u8) ?[]const u8 {
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.codegraff/jobs", .{base}) catch null;
}

fn recordPath(buf: []u8, base: []const u8, pid: i32) ?[]const u8 {
    if (base.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.codegraff/jobs/{d}.json", .{ base, pid }) catch null;
}

/// Write (or rewrite) one record. Best-effort: no HOME or an unwritable dir
/// costs the cross-session view, never the job.
pub fn write(io: Io, base: []const u8, rec: Record) void {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dbuf, base) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch return;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = recordPath(&pbuf, base, rec.pid) orelse return;
    var jbuf: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&jbuf);
    var s: std.json.Stringify = .{ .writer = &w };
    s.write(rec) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() }) catch return;
}

pub fn forget(io: Io, base: []const u8, pid: i32) void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = recordPath(&pbuf, base, pid) orelse return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn earlier(_: void, a: Record, b: Record) bool {
    return a.started_ms < b.started_ms;
}

/// Every record on disk, oldest first, arena-owned.
pub fn list(io: Io, arena: Allocator, base: []const u8) []const Record {
    var out: std.ArrayList(Record) = .empty;
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dirPath(&dbuf, base) orelse return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const data = dir.readFileAlloc(io, entry.name, arena, .limited(64 * 1024)) catch continue;
        const rec = std.json.parseFromSliceLeaky(Record, arena, data, .{ .ignore_unknown_fields = true }) catch continue;
        out.append(arena, rec) catch break;
    }
    std.mem.sort(Record, out.items, {}, earlier);
    return out.items;
}

pub const State = enum { running, gone, unverifiable };

/// Is the recorded leader still the process we started? A live pid with a
/// different start identity is a recycled pid: gone, and never signalled.
pub fn state(io: Io, rec: Record) State {
    return stateOf(rec.start_id, proc_identity.probe(io, rec.pid));
}

pub fn stateOf(start_id: u64, live: proc_identity.Probe) State {
    return switch (live) {
        .gone => .gone,
        .unknown => .unverifiable,
        .id => |v| if (start_id == 0 or v == start_id) .running else .gone,
    };
}

/// Is the graff session that started it still alive?
pub fn ownerAlive(io: Io, rec: Record) bool {
    if (rec.owner_pid <= 0) return false;
    return stateOf(rec.owner_start_id, proc_identity.probe(io, rec.owner_pid)) != .gone;
}

/// Listening TCP sockets of the job's process group, `127.0.0.1:3002, *:3003`
/// style, or "" (Windows, no lsof, nothing listening). The leader was spawned
/// as its own group, so the group id is its pid.
pub fn listenPorts(gpa: Allocator, io: Io, arena: Allocator, pid: i32) []const u8 {
    if (!posix) return "";
    var pidbuf: [16]u8 = undefined;
    const pid_s = std.fmt.bufPrint(&pidbuf, "{d}", .{pid}) catch return "";
    const run = process_runner.runCapped(gpa, io, &.{ "lsof", "-a", "-P", "-n", "-iTCP", "-sTCP:LISTEN", "-g", pid_s, "-Fn" }, 64 * 1024, 4096, 5_000) catch return "";
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    return parseLsofPorts(arena, run.stdout);
}

/// `lsof -Fn`: one `n<addr>` line per socket (`n127.0.0.1:3002`, `n*:3003`)
/// between `p<pid>` / `f<fd>` lines. Deduped, joined with ", ".
pub fn parseLsofPorts(arena: Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len < 2 or line[0] != 'n') continue;
        const addr = line[1..];
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, addr)) dup = true;
        }
        if (dup) continue;
        seen.append(arena, addr) catch break;
        if (out.items.len > 0) out.appendSlice(arena, ", ") catch break;
        out.appendSlice(arena, addr) catch break;
    }
    return out.items;
}

pub const StopResult = enum { stopped, gone, unverifiable, unsupported };

/// TERM the whole group, give it 2s, then KILL — only when the leader still
/// carries the recorded start identity.
pub fn stopTree(io: Io, rec: Record) StopResult {
    if (!posix) return .unsupported;
    switch (state(io, rec)) {
        .gone => return .gone,
        .unverifiable => return .unverifiable,
        .running => {},
    }
    std.posix.kill(-rec.pid, .TERM) catch return .gone;
    var waited: u64 = 0;
    while (waited < 2000) : (waited += 100) {
        io.sleep(.fromMilliseconds(100), .awake) catch break;
        if (proc_identity.probe(io, rec.pid) == .gone) return .stopped;
    }
    std.posix.kill(-rec.pid, .KILL) catch {};
    return .stopped;
}

/// Session end for a pinned job: hand each of its pipes to a detached
/// `cat >/dev/null` so the server never sees EPIPE once graff's read ends
/// close with the process (a Node dev server dies on its next log line
/// otherwise), then rewrite the record as retained. False when a drainer
/// could not start — the caller kills the job rather than leak a
/// half-detached one.
pub fn retain(io: Io, base: []const u8, rec: Record, stdout: ?Io.File, stderr: ?Io.File) bool {
    if (!posix) return false;
    for ([_]?Io.File{ stdout, stderr }) |maybe| {
        const f = maybe orelse continue;
        _ = std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", "exec cat >/dev/null 2>&1" },
            .stdin = .{ .file = f },
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch return false;
    }
    var kept = rec;
    kept.pinned = true;
    kept.retained = true;
    write(io, base, kept);
    return true;
}

test "parseLsofPorts: n lines only, deduped, joined" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "p4242\nf12\nn127.0.0.1:3002\nf13\nn127.0.0.1:3002\np4250\nf5\nn*:3003\n";
    try std.testing.expectEqualStrings("127.0.0.1:3002, *:3003", parseLsofPorts(arena, text));
    try std.testing.expectEqualStrings("", parseLsofPorts(arena, ""));
    try std.testing.expectEqualStrings("", parseLsofPorts(arena, "p1\nf2\n"));
}

test "stateOf: a recycled pid is gone, an opaque one is unverifiable, legacy 0 trusts the pid" {
    try std.testing.expectEqual(State.running, stateOf(77, .{ .id = 77 }));
    try std.testing.expectEqual(State.gone, stateOf(77, .{ .id = 78 }));
    try std.testing.expectEqual(State.running, stateOf(0, .{ .id = 78 }));
    try std.testing.expectEqual(State.gone, stateOf(77, .gone));
    try std.testing.expectEqual(State.unverifiable, stateOf(77, .unknown));
}

test "records: write, list oldest-first, forget; no HOME means no record" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = try arena.dupe(u8, buf[0..n]);

    write(io, base, .{ .pid = 200, .start_id = 5, .cmd = "next dev", .cwd = "/srv/site", .started_ms = 2_000 });
    write(io, base, .{ .pid = 100, .start_id = 4, .owner_pid = 9, .cmd = "sleep 30", .started_ms = 1_000, .pinned = true });
    const recs = list(io, arena, base);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    try std.testing.expectEqual(@as(i32, 100), recs[0].pid);
    try std.testing.expect(recs[0].pinned);
    try std.testing.expectEqual(@as(i32, 9), recs[0].owner_pid);
    try std.testing.expectEqualStrings("next dev", recs[1].cmd);
    try std.testing.expectEqualStrings("/srv/site", recs[1].cwd);
    try std.testing.expectEqual(@as(u64, 5), recs[1].start_id);
    forget(io, base, 200);
    try std.testing.expectEqual(@as(usize, 1), list(io, arena, base).len);
    write(io, "", .{ .pid = 300, .cmd = "nowhere" });
    try std.testing.expectEqual(@as(usize, 0), list(io, arena, "").len);
}

test "stopTree never signals a pid whose start identity is not ours" {
    if (!posix) return error.SkipZigTest;
    const io = std.testing.io;
    const me = proc_identity.selfRecord(io);
    if (me.start_id == 0) return error.SkipZigTest; // no identity source here
    // Our own pid with a wrong start id reads as a recycled pid: gone, no kill.
    const forged: Record = .{ .pid = me.pid, .start_id = me.start_id +% 1, .cmd = "not us" };
    try std.testing.expectEqual(State.gone, state(io, forged));
    try std.testing.expectEqual(StopResult.gone, stopTree(io, forged));
    const real: Record = .{ .pid = me.pid, .start_id = me.start_id, .cmd = "us" };
    try std.testing.expectEqual(State.running, state(io, real));
}
