//! Job-pool tests. Split out of jobs.zig so waitForeground (#620) fits under
//! the 600-line ceiling. Imported from jobs.zig's `test {}` so they stay in
//! the suite.

const std = @import("std");
const builtin = @import("builtin");
const jobs = @import("jobs.zig");
const job_idle = @import("job_idle.zig");
const job_registry = @import("job_registry.zig");
const proc_identity = @import("proc_identity.zig");

test {
    _ = @import("jobs_completion_tests.zig");
}

test "foreground tool subprocesses own their process group (#266, #198)" {
    const inherited = jobs.toolRunOptions(null);
    try std.testing.expect(inherited.kill_process_tree);
    try std.testing.expect(std.meta.activeTag(inherited.cwd) == .inherit);
    const pinned = jobs.toolRunOptions("/tmp/graff-worktree");
    try std.testing.expect(pinned.kill_process_tree);
    try std.testing.expectEqualStrings("/tmp/graff-worktree", pinned.cwd.path);
}

test "killing a background job takes its grandchildren with it (#198)" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The job inherits this process's cwd, the one tmpDir resolved .zig-cache
    // against, so the marker path is reachable from the shell. The grandchild
    // detaches from the job's pipes or the pump never sees EOF; `sh` execs the
    // trailing sleep, so a bare child kill orphans the marker subshell.
    const cmd = try std.fmt.allocPrint(gpa, "(sleep 0.8; printf survived > .zig-cache/tmp/{s}/marker) >/dev/null 2>&1 & sleep 30", .{&tmp.sub_path});
    defer gpa.free(cmd);
    const id = (try jobs.spawnJob(gpa, io, cmd)).id;
    defer jobs.jobsReap(gpa, io);
    const killed = try jobs.jobKill(gpa, io, id);
    gpa.free(killed.text);
    io.sleep(.fromMilliseconds(1_200), .awake) catch {};
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "marker", .{}));
}

test "isolated capped runs clean descendants after timeout and normal exit" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const timed = try jobs.runCappedWithOptions(
        std.testing.allocator,
        io,
        &.{ "/bin/sh", "-c", "(sleep 0.8; printf survived > timeout-marker) >/dev/null 2>&1 & sleep 30" },
        1024,
        1024,
        50,
        .{ .cwd = .{ .dir = tmp.dir }, .kill_process_tree = true },
    );
    defer {
        std.testing.allocator.free(timed.stdout);
        std.testing.allocator.free(timed.stderr);
    }
    try std.testing.expect(timed.timed_out);

    const completed = try jobs.runCappedWithOptions(
        std.testing.allocator,
        io,
        &.{ "/bin/sh", "-c", "(sleep 0.8; printf survived > completed-marker) >/dev/null 2>&1 & exit 0" },
        1024,
        1024,
        2_000,
        .{ .cwd = .{ .dir = tmp.dir }, .kill_process_tree = true },
    );
    defer {
        std.testing.allocator.free(completed.stdout);
        std.testing.allocator.free(completed.stderr);
    }
    try std.testing.expect(jobs.ranOk(completed));
    io.sleep(.fromMilliseconds(1_000), .awake) catch {};
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "timeout-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "completed-marker", .{}));
}

test "bash_output wait_ms>0 waits for exit, not the next byte (ADR 0010)" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const id = (try jobs.spawnJob(gpa, io, "printf start; sleep 0.15; printf done; exit 7")).id;
    defer jobs.jobsReap(gpa, io);
    const snap = try jobs.jobOutput(gpa, io, id, 0);
    defer gpa.free(snap.text);
    const done = try jobs.jobOutput(gpa, io, id, 30_000);
    defer gpa.free(done.text);
    const text = if (std.mem.indexOf(u8, done.text, "exited with code 7") != null) done.text else snap.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "exited with code 7") != null);
}

test "#620: a still-running foreground wait promotes instead of killing" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const id = (try jobs.spawnJob(gpa, io, "sleep 2; printf never")).id;
    defer jobs.jobsReap(gpa, io);
    const waited = try jobs.waitForeground(gpa, io, id, 200);
    defer switch (waited) {
        .running => |r| gpa.free(r.output),
        .done => |d| gpa.free(d.output),
        .cancelled => |c| gpa.free(c.output),
    };
    try std.testing.expect(waited == .running);
    try std.testing.expectEqual(id, waited.running.id);
    const snap = try jobs.jobOutput(gpa, io, id, 0);
    defer gpa.free(snap.text);
    try std.testing.expect(std.mem.indexOf(u8, snap.text, "running") != null);
}

test "#620: a short foreground command finishes as done, not a job" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const id = (try jobs.spawnJob(gpa, io, "printf hi; exit 0")).id;
    defer jobs.jobsReap(gpa, io);
    const waited = try jobs.waitForeground(gpa, io, id, 2_000);
    defer switch (waited) {
        .running => |r| gpa.free(r.output),
        .done => |d| gpa.free(d.output),
        .cancelled => |c| gpa.free(c.output),
    };
    try std.testing.expect(waited == .done);
    try std.testing.expectEqual(@as(?u8, 0), waited.done.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, waited.done.output, "hi") != null);
}

test "#199: a silent, unread job is stopped after the idle budget and can be restarted" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const saved = job_idle.policy;
    defer job_idle.policy = saved;
    job_idle.policy = .{ .warn_ms = 100, .stop_ms = 400 };
    const id = (try jobs.spawnJob(gpa, io, "sleep 30")).id;
    defer jobs.jobsReap(gpa, io);
    io.sleep(.fromMilliseconds(1_500), .awake) catch {};
    const snap = try jobs.jobOutput(gpa, io, id, 0);
    defer gpa.free(snap.text);
    try std.testing.expect(std.mem.indexOf(u8, snap.text, "stopped after") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap.text, "/jobs keep") != null);
    // The command survives: a restart is a new job, running, in the same place.
    const again = try jobs.restartJob(gpa, io, id);
    try std.testing.expect(again.id != id);
    const snap2 = try jobs.jobOutput(gpa, io, again.id, 0);
    defer gpa.free(snap2.text);
    try std.testing.expect(std.mem.indexOf(u8, snap2.text, "running") != null);
    try std.testing.expectError(error.StillRunning, jobs.restartJob(gpa, io, again.id));
    try std.testing.expectError(error.NoSuchJob, jobs.restartJob(gpa, io, 9999));
}

test "#199: output keeps a job alive past the budget; a pinned job is never idle-stopped" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const saved = job_idle.policy;
    defer job_idle.policy = saved;
    job_idle.policy = .{ .warn_ms = 100, .stop_ms = 300 };
    const chatty = (try jobs.spawnJob(gpa, io, "i=0; while [ $i -lt 15 ]; do echo tick; sleep 0.1; i=$((i+1)); done")).id;
    const pinned = (try jobs.spawnJob(gpa, io, "sleep 4")).id;
    defer jobs.jobsReap(gpa, io);
    try std.testing.expectEqual(@as(?bool, true), jobs.setPinned(io, pinned, true));
    try std.testing.expectEqual(@as(?bool, null), jobs.setPinned(io, 9999, true));
    io.sleep(.fromMilliseconds(1_000), .awake) catch {};
    for ([_]u32{ chatty, pinned }) |id| {
        const snap = try jobs.jobOutput(gpa, io, id, 0);
        defer gpa.free(snap.text);
        try std.testing.expect(std.mem.indexOf(u8, snap.text, "running") != null);
    }
    _ = jobs.setPinned(io, pinned, false); // so the reap below kills it instead of retaining it
}

test "#199: a spawn writes an ownership record with the leader's identity; reaping removes it" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const saved_home = job_registry.home;
    defer job_registry.home = saved_home;
    job_registry.home = buf[0..n];

    const job = try jobs.spawnJob(gpa, io, "sleep 5");
    const pid = job.child.id.?;
    const recs = job_registry.list(io, arena, job_registry.home);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    try std.testing.expectEqual(pid, recs[0].pid);
    try std.testing.expectEqualStrings("sleep 5", recs[0].cmd);
    try std.testing.expectEqual(proc_identity.selfPid(), recs[0].owner_pid);
    try std.testing.expect(job_registry.ownerAlive(io, recs[0]));
    try std.testing.expectEqual(job_registry.State.running, job_registry.state(io, recs[0]));
    jobs.jobsReap(gpa, io);
    try std.testing.expectEqual(@as(usize, 0), job_registry.list(io, arena, job_registry.home).len);
}

test "#199: a pinned job is retained at session end — record kept, tree alive, then stoppable by pid" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const saved_home = job_registry.home;
    defer job_registry.home = saved_home;
    job_registry.home = buf[0..n];

    const job = try jobs.spawnJob(gpa, io, "sleep 30");
    const pid = job.child.id.?;
    try std.testing.expectEqual(@as(?bool, true), jobs.setPinned(io, job.id, true));
    jobs.jobsReap(gpa, io); // session end: pinned → retained, not killed
    const recs = job_registry.list(io, arena, job_registry.home);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    try std.testing.expect(recs[0].retained);
    try std.testing.expectEqual(pid, recs[0].pid);
    try std.testing.expectEqual(job_registry.State.running, job_registry.state(io, recs[0]));
    // A later `graff servers stop <pid>`: verified, then the whole group goes.
    try std.testing.expectEqual(job_registry.StopResult.stopped, job_registry.stopTree(io, recs[0]));
    job_registry.forget(io, job_registry.home, pid);
    try std.testing.expectEqual(@as(usize, 0), job_registry.list(io, arena, job_registry.home).len);
}
