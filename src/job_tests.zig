//! Background-job and process-group tests, moved off jobs.zig (600-line cap).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const jobs = @import("jobs.zig");
const process_runner = @import("process_runner.zig");

const spawnJob = jobs.spawnJob;
const jobKill = jobs.jobKill;
const jobOutput = jobs.jobOutput;
const jobsReap = jobs.jobsReap;
const toolRunOptions = jobs.toolRunOptions;
const runCappedWithOptions = jobs.runCappedWithOptions;
const ranOk = process_runner.ranOk;

test "foreground tool subprocesses own their process group (#266, #198)" {
    const inherited = toolRunOptions(null);
    try std.testing.expect(inherited.kill_process_tree);
    try std.testing.expect(std.meta.activeTag(inherited.cwd) == .inherit);
    const pinned = toolRunOptions("/tmp/graff-worktree");
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
    const id = (try spawnJob(gpa, io, cmd)).id;
    defer jobsReap(gpa, io);
    const killed = try jobKill(gpa, io, id);
    gpa.free(killed.text);
    io.sleep(.fromMilliseconds(1_200), .awake) catch {};
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "marker", .{}));
}

test "isolated capped runs clean descendants after timeout and normal exit" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const timed = try runCappedWithOptions(
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

    const completed = try runCappedWithOptions(
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
    try std.testing.expect(ranOk(completed));
    io.sleep(.fromMilliseconds(1_000), .awake) catch {};
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "timeout-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "completed-marker", .{}));
}

test "bash_output wait_ms>0 waits for exit, not the next byte (ADR 0010)" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    jobs.g_jobs = .{};
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const id = (try spawnJob(gpa, io, "printf start; sleep 0.15; printf done; exit 7")).id;
    defer jobsReap(gpa, io);
    const snap = try jobOutput(gpa, io, id, 0);
    defer gpa.free(snap.text);
    const done = try jobOutput(gpa, io, id, 30_000);
    defer gpa.free(done.text);
    const text = if (std.mem.indexOf(u8, done.text, "exited with code 7") != null) done.text else snap.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "exited with code 7") != null);
}
