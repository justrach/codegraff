//! Capped subprocess execution with optional whole-process-tree ownership.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Agent = @import("agent.zig").Agent;

const posix_process_groups = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};
const GroupId = if (posix_process_groups) std.posix.pid_t else void;
const WindowsJobHandle = if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else void;

const WinJob = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const kill_on_close: windows.DWORD = 0x00002000;
    const extended_limit_information: c_int = 9;

    const BasicLimitInformation = extern struct {
        per_process_user_time_limit: windows.LARGE_INTEGER = 0,
        per_job_user_time_limit: windows.LARGE_INTEGER = 0,
        limit_flags: windows.DWORD = 0,
        minimum_working_set_size: windows.SIZE_T = 0,
        maximum_working_set_size: windows.SIZE_T = 0,
        active_process_limit: windows.DWORD = 0,
        affinity: windows.ULONG_PTR = 0,
        priority_class: windows.DWORD = 0,
        scheduling_class: windows.DWORD = 0,
    };
    const IoCounters = extern struct {
        read_operation_count: u64 = 0,
        write_operation_count: u64 = 0,
        other_operation_count: u64 = 0,
        read_transfer_count: u64 = 0,
        write_transfer_count: u64 = 0,
        other_transfer_count: u64 = 0,
    };
    const ExtendedLimitInformation = extern struct {
        basic_limit_information: BasicLimitInformation = .{},
        io_info: IoCounters = .{},
        process_memory_limit: windows.SIZE_T = 0,
        job_memory_limit: windows.SIZE_T = 0,
        peak_process_memory_used: windows.SIZE_T = 0,
        peak_job_memory_used: windows.SIZE_T = 0,
    };

    extern "kernel32" fn CreateJobObjectW(
        job_attributes: ?*windows.SECURITY_ATTRIBUTES,
        name: ?windows.LPCWSTR,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(
        job: windows.HANDLE,
        info_class: c_int,
        info: *const anyopaque,
        info_len: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(
        job: windows.HANDLE,
        process: windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;

    fn setup(child: *std.process.Child) !windows.HANDLE {
        const job = CreateJobObjectW(null, null) orelse return error.ProcessTreeSetupFailed;
        errdefer windows.CloseHandle(job);
        var limits: ExtendedLimitInformation = .{};
        limits.basic_limit_information.limit_flags = kill_on_close;
        if (!SetInformationJobObject(job, extended_limit_information, &limits, @sizeOf(ExtendedLimitInformation)).toBool())
            return error.ProcessTreeSetupFailed;
        if (!AssignProcessToJobObject(job, child.id.?).toBool()) return error.ProcessTreeSetupFailed;
        if (windows.ntdll.NtResumeThread(child.thread_handle, null) != .SUCCESS)
            return error.ProcessTreeSetupFailed;
        return job;
    }
} else struct {};

pub const CappedRun = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    timed_out: bool,
};

/// Supplying an explicit environment replaces (rather than augments) the
/// parent environment. `kill_process_tree` creates an owned process group/job
/// so descendants cannot outlive the orchestrated command.
pub const CappedRunOptions = struct {
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    kill_process_tree: bool = false,
};

fn setupWindowsJob(child: *std.process.Child, enabled: bool) !WindowsJobHandle {
    if (comptime builtin.os.tag == .windows) {
        return if (enabled) try WinJob.setup(child) else null;
    } else {
        return {};
    }
}

fn closeWindowsJob(job: *WindowsJobHandle) void {
    if (comptime builtin.os.tag == .windows) if (job.*) |handle| {
        std.os.windows.CloseHandle(handle);
        job.* = null;
    };
}

fn killProcessGroup(group_id: GroupId, enabled: bool) void {
    if (comptime posix_process_groups) {
        if (!enabled) return;
        std.posix.kill(-group_id, .KILL) catch {};
    }
}

fn terminateTree(child: *std.process.Child, io: Io, job: *WindowsJobHandle, group_id: GroupId, enabled: bool) void {
    closeWindowsJob(job);
    killProcessGroup(group_id, enabled);
    child.kill(io);
}

pub fn runCapped(gpa: Allocator, io: Io, argv: []const []const u8, stdout_cap: usize, stderr_cap: usize, deadline_ms: u64) !CappedRun {
    return runCappedWithOptions(gpa, io, argv, stdout_cap, stderr_cap, deadline_ms, .{});
}

pub fn runCappedWithOptions(gpa: Allocator, io: Io, argv: []const []const u8, stdout_cap: usize, stderr_cap: usize, deadline_ms: u64, options: CappedRunOptions) !CappedRun {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (posix_process_groups and options.kill_process_tree) 0 else null,
        .start_suspended = builtin.os.tag == .windows and options.kill_process_tree,
    });
    var setup_cleanup_needed = true;
    errdefer if (setup_cleanup_needed) child.kill(io);
    const group_id: GroupId = if (posix_process_groups) child.id.? else {};
    var windows_job = try setupWindowsJob(&child, options.kill_process_tree);
    setup_cleanup_needed = false;
    var cleanup_needed = true;
    defer if (cleanup_needed) terminateTree(&child, io, &windows_job, group_id, options.kill_process_tree);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const readers = [2]*Io.Reader{ multi_reader.reader(0), multi_reader.reader(1) };
    const caps = [2]usize{ stdout_cap, stderr_cap };
    var saved: [2]?[]u8 = .{ null, null };
    errdefer for (saved) |item| if (item) |bytes| gpa.free(bytes);

    var esc_killed = false;
    var timed_out = false;
    const started: Io.Timestamp = .now(io, .awake);
    loop: while (true) {
        multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break :loop,
            error.Timeout => {},
            else => |other| return other,
        };
        for (readers, caps, &saved) |reader, cap, *item| {
            const buffered = reader.buffered();
            if (item.* == null and buffered.len > cap) item.* = try gpa.dupe(u8, buffered[0..cap]);
            if (item.* != null) reader.toss(buffered.len);
        }
        if (Agent.esc_cancel.load(.acquire)) {
            esc_killed = true;
            terminateTree(&child, io, &windows_job, group_id, options.kill_process_tree);
            cleanup_needed = false;
            break :loop;
        }
        if (deadline_ms > 0 and started.untilNow(io, .awake).toMilliseconds() >= deadline_ms) {
            timed_out = true;
            terminateTree(&child, io, &windows_job, group_id, options.kill_process_tree);
            cleanup_needed = false;
            break :loop;
        }
    }
    if (!esc_killed and !timed_out) try multi_reader.checkAnyError();

    const term: std.process.Child.Term = if (esc_killed or timed_out) .{ .signal = .TERM } else try child.wait(io);
    const stdout = if (saved[0]) |bytes| bytes else try gpa.dupe(u8, readers[0].buffered());
    errdefer gpa.free(stdout);
    const stderr = if (saved[1]) |bytes| bytes else try gpa.dupe(u8, readers[1].buffered());
    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
        .stdout_truncated = saved[0] != null,
        .stderr_truncated = saved[1] != null,
        .timed_out = timed_out,
    };
}

pub fn ranOk(run: CappedRun) bool {
    return run.term == .exited and run.term.exited == 0;
}
