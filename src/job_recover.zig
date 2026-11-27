//! Resume re-attaches durable background jobs (ADR 0218). A graff that died
//! mid-task left its finite background jobs running with their output in
//! `.graff/job-output/<id>/` (job_capture.zig). Loading that session puts
//! each one back in the job pool under its old id: a job still running is
//! watched to its end, one that ended while graff was down is reported, and
//! either way `bash_output` and `bash_kill` reach it again. Captures of other
//! sessions are left for their own resume, and swept once stale and over.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");
const Job = jobs.Job;
const g_jobs = &jobs.g_jobs;
const job_capture = @import("job_capture.zig");
const Meta = job_capture.Meta;
const job_registry = @import("job_registry.zig");
const proc_identity = @import("proc_identity.zig");
const util = @import("util.zig");

/// Another session's capture is swept once this old and over.
const stale_ms: i64 = 7 * std.time.ms_per_day;

pub const Seen = struct {
    meta: ?Meta,
    reported: bool = false,
    owner_alive: bool = false,
    over: bool = false, // an exit receipt, or its leader is gone
    age_ms: i64 = 0,
};

pub const Verdict = enum { adopt, remove, skip };

/// What resume does with one capture directory.
pub fn verdict(seen: Seen, session: []const u8) Verdict {
    const meta = seen.meta orelse return if (seen.age_ms > stale_ms) .remove else .skip;
    if (seen.owner_alive) return .skip; // a live graff still watches it
    if (seen.reported) return .remove; // its exit already reached the model
    if (std.mem.eql(u8, meta.session, session)) return .adopt;
    return if (seen.over and seen.age_ms > stale_ms) .remove else .skip;
}

/// session.loadSession: recover from the workspace's capture root.
pub fn onLoad(gpa: Allocator, io: Io, session: []const u8) void {
    if (comptime !job_capture.enabled) return;
    if (builtin.is_test or session.len == 0) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = job_capture.rootPath(io, &buf) orelse return;
    _ = recoverIn(gpa, io, root, session);
}

/// Returns how many jobs went back into the pool.
pub fn recoverIn(gpa: Allocator, io: Io, root: []const u8, session: []const u8) usize {
    if (comptime !job_capture.enabled) return 0;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            _ = std.fmt.parseInt(u64, entry.name, 10) catch continue;
            names.append(arena, arena.dupe(u8, entry.name) catch continue) catch continue;
        }
    }
    const now = util.unixMs(io);
    var adopted: usize = 0;
    for (names.items) |name| { // acted on after the listing: no deletes mid-iteration
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, name }) catch continue;
        const seen = look(io, arena, path, now);
        switch (verdict(seen, session)) {
            .skip => {},
            .remove => Io.Dir.cwd().deleteTree(io, path) catch {},
            .adopt => if (adopt(gpa, io, path, seen.meta.?)) {
                adopted += 1;
            } else |_| {},
        }
    }
    return adopted;
}

fn look(io: Io, arena: Allocator, path: []const u8, now: i64) Seen {
    const meta = job_capture.readMeta(io, arena, path) orelse {
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .meta = null };
        const mtime_ms: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
        return .{ .meta = null, .age_ms = now - mtime_ms };
    };
    const owner: proc_identity.Probe = if (meta.owner_pid > 0) proc_identity.probe(io, meta.owner_pid) else .gone;
    const leader = proc_identity.probe(io, meta.pid);
    return .{
        .meta = meta,
        .reported = job_capture.reported(io, path),
        .owner_alive = job_registry.stateOf(meta.owner_start_id, owner) != .gone,
        .over = job_capture.exitStatus(io, path) != null or job_registry.stateOf(meta.start_id, leader) == .gone,
        .age_ms = now - meta.started_ms,
    };
}

/// Back into the pool under its old id, watched by the durable pump.
fn adopt(gpa: Allocator, io: Io, path: []const u8, meta: Meta) !void {
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        if (g_jobs.find(meta.id) != null) return error.AlreadyTracked;
    }
    const capture = try gpa.create(job_capture.Capture);
    errdefer gpa.destroy(capture);
    capture.* = .{ .dir = try gpa.dupe(u8, path), .adopted = true, .start_id = meta.start_id };
    errdefer gpa.free(capture.dir);
    const cmd = try gpa.dupe(u8, meta.cmd);
    errdefer gpa.free(cmd);
    const cwd: ?[]u8 = if (meta.cwd.len > 0) try gpa.dupe(u8, meta.cwd) else null;
    errdefer if (cwd) |c| gpa.free(c);
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{
        .id = meta.id,
        .cmd = cmd,
        // Not graff's child: nothing may wait on or signal it through `child`.
        .child = .{ .id = null, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false },
        .cwd = cwd,
        .started_ms = meta.started_ms,
        .start_id = meta.start_id,
        .last_active_ms = jobs.nowMs(io),
        .group_pid = meta.pid,
        .capture = capture,
    };
    // This graff watches it now: another resume of the session leaves it be.
    // Both records land before the pump, which forgets the registry one.
    var owned = meta;
    owned.owner_pid = proc_identity.selfPid();
    owned.owner_start_id = proc_identity.selfStartId(io);
    job_capture.writeMeta(io, capture, owned);
    if (meta.pid > 0) job_registry.write(io, job_registry.home, @import("jobs_admin.zig").recordOf(io, job));
    errdefer if (meta.pid > 0) job_registry.forget(io, job_registry.home, meta.pid);
    {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        try g_jobs.list.append(gpa, job);
    }
    job.future = io.concurrent(@import("job_durable.zig").pump, .{ job, gpa, io }) catch |e| {
        g_jobs.mutex.lockUncancelable(io);
        defer g_jobs.mutex.unlock(io);
        for (g_jobs.list.items, 0..) |j, i| {
            if (j == job) {
                _ = g_jobs.list.swapRemove(i);
                break;
            }
        }
        return e;
    };
}

test "resume adopts its own session's jobs and leaves live owners and other sessions alone" {
    const own: Meta = .{ .id = 1, .session = "mine", .cmd = "make" };
    const other: Meta = .{ .id = 2, .session = "theirs", .cmd = "make" };
    try std.testing.expectEqual(Verdict.adopt, verdict(.{ .meta = own }, "mine"));
    try std.testing.expectEqual(Verdict.skip, verdict(.{ .meta = own, .owner_alive = true }, "mine"));
    try std.testing.expectEqual(Verdict.remove, verdict(.{ .meta = own, .reported = true }, "mine"));
    try std.testing.expectEqual(Verdict.skip, verdict(.{ .meta = own, .reported = true, .owner_alive = true }, "mine"));
    try std.testing.expectEqual(Verdict.skip, verdict(.{ .meta = other, .over = true }, "mine"));
    try std.testing.expectEqual(Verdict.skip, verdict(.{ .meta = other, .age_ms = stale_ms + 1 }, "mine"));
    try std.testing.expectEqual(Verdict.remove, verdict(.{ .meta = other, .over = true, .age_ms = stale_ms + 1 }, "mine"));
    try std.testing.expectEqual(Verdict.skip, verdict(.{ .meta = null }, "mine"));
    try std.testing.expectEqual(Verdict.remove, verdict(.{ .meta = null, .age_ms = stale_ms + 1 }, "mine"));
}

/// A capture as a graff that then died would leave it: the job spawned with
/// its receipt, its record naming an owner that no longer exists.
fn orphan(io: Io, root: []const u8, id: u64, cmd: []const u8, session: []const u8) !std.process.Child {
    const gpa = std.testing.allocator;
    var setup = try job_capture.create(io, gpa, root, id, cmd);
    const child = std.process.spawn(io, .{ .argv = &setup.argv, .stdin = .ignore, .stdout = .{ .file = setup.out }, .stderr = .{ .file = setup.err }, .pgid = 0 }) catch |e| {
        setup.abandon(gpa, io);
        return e;
    };
    const pid = child.id.?;
    const capture = setup.capture;
    setup.spawned(gpa, io);
    job_capture.writeMeta(io, capture, .{
        .id = id,
        .session = session,
        .cmd = cmd,
        .pid = pid,
        .start_id = switch (proc_identity.probe(io, pid)) {
            .id => |v| v,
            else => 0,
        },
        .owner_pid = 0,
        .started_ms = util.unixMs(io),
    });
    job_capture.release(gpa, io, capture, false);
    return child;
}

test "a job that outlived graff is re-attached on resume and reports its real exit once" {
    if (!job_capture.enabled) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const job_notify = @import("job_notify.zig");
    jobs.g_jobs = .{};
    job_notify.resetForTest(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp.dir.realPath(io, &rbuf)];

    // One finished while graff was down, one is still running at resume, and
    // one belongs to another session.
    var done = try orphan(io, root, 7001, "printf early; exit 3", "s-resume");
    _ = try done.wait(io);
    var late = try orphan(io, root, 7002, "sleep 0.3; printf late", "s-resume");
    defer if (late.wait(io)) |_| {} else |_| {};
    var other = try orphan(io, root, 7003, "exit 0", "s-other");
    _ = try other.wait(io);

    try std.testing.expectEqual(@as(usize, 2), recoverIn(gpa, io, root, "s-resume"));
    defer jobs.jobsReap(gpa, io);
    const early = try jobs.jobOutput(gpa, io, 7001, 5000);
    defer gpa.free(early.text);
    try std.testing.expect(std.mem.indexOf(u8, early.text, "exited with code 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, early.text, "early") != null);
    const running = try jobs.jobOutput(gpa, io, 7002, 5000);
    defer gpa.free(running.text);
    try std.testing.expect(std.mem.indexOf(u8, running.text, "exited with code 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, running.text, "late") != null);
    // Both exits reached the model; the other session's capture is untouched.
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(job_capture.reported(io, try std.fmt.bufPrint(&pbuf, "{s}/7001", .{root})));
    try std.testing.expect(job_capture.reported(io, try std.fmt.bufPrint(&pbuf, "{s}/7002", .{root})));
    try std.testing.expect(!job_capture.reported(io, try std.fmt.bufPrint(&pbuf, "{s}/7003", .{root})));
    // A second resume while this process owns them adopts nothing.
    try std.testing.expectEqual(@as(usize, 0), recoverIn(gpa, io, root, "s-resume"));
}

test "a resumed job's completion notice marks it reported" {
    if (!job_capture.enabled) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const job_notify = @import("job_notify.zig");
    jobs.g_jobs = .{};
    job_notify.resetForTest(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = rbuf[0..try tmp.dir.realPath(io, &rbuf)];
    var done = try orphan(io, root, 7101, "printf gone; exit 5", "s-notice");
    _ = try done.wait(io);

    try std.testing.expectEqual(@as(usize, 1), recoverIn(gpa, io, root, "s-notice"));
    defer jobs.jobsReap(gpa, io);
    var buf: [4096]u8 = undefined;
    var text: []const u8 = "";
    for (0..200) |_| {
        text = job_notify.takeWake(io, &buf) orelse {
            try io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
        break;
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 7101 exited 5: printf gone; exit 5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gone") != null);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(job_capture.reported(io, try std.fmt.bufPrint(&pbuf, "{s}/7101", .{root})));
}
