//! Live process-table half of /doctor (#321).
//!
//! Goal/todo checks stay in doctor.zig. These read the in-memory job pool and
//! RunBudget — harness-owned state that already exists. They do NOT invent a
//! durable session-lease or listener registry; those still have nothing to
//! read, so they stay absent rather than reporting "healthy" from thin air.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const doctor = @import("doctor.zig");
const Check = doctor.Check;
const Severity = doctor.Severity;
const jobs_mod = @import("jobs.zig");
const posix_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi;

pub const JobView = struct {
    id: u32 = 0,
    done: bool = false,
    shares_root_pgid: bool = false,
};

pub const Live = struct {
    jobs: []const JobView = &.{},
    budget_max: u64 = 0,
    budget_used: u64 = 0,
};

/// Copy the live job table. `shares_root_pgid` is measured here (getpgid)
/// so `append` stays a pure function of the snapshot.
pub fn captureJobs(arena: Allocator, io: Io) Allocator.Error![]const JobView {
    jobs_mod.g_jobs.mutex.lockUncancelable(io);
    defer jobs_mod.g_jobs.mutex.unlock(io);
    const self_pid = thisPid();
    var out: std.ArrayList(JobView) = .empty;
    for (jobs_mod.g_jobs.list.items) |job| {
        // Windows `Child.id` is a HANDLE (`*anyopaque`), not a pid. Same
        // comptime gate jobs.zig uses when it group-kills.
        const shares = if (comptime posix_groups)
            !job.done and sharesRootPgid(job.child.id orelse 0, self_pid)
        else
            false;
        try out.append(arena, .{
            .id = job.id,
            .done = job.done,
            .shares_root_pgid = shares,
        });
    }
    return out.toOwnedSlice(arena);
}

fn thisPid() i32 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return 0;
    return @intCast(std.posix.system.getpid());
}

fn sharesRootPgid(pid: std.posix.pid_t, self_pid: i32) bool {
    if (builtin.os.tag != .linux) return false;
    if (self_pid <= 0) return false;
    const rc = std.os.linux.getpgid(pid);
    if (@as(isize, @bitCast(rc)) < 0) return false;
    const pg: i32 = @intCast(@as(u32, @truncate(rc)));
    return pg == self_pid;
}

pub fn append(arena: Allocator, out: *std.ArrayList(Check), live: Live) Allocator.Error!void {
    try out.append(arena, try jobStateLine(arena, live.jobs));
    if (try jobSharesRoot(arena, live.jobs)) |c| try out.append(arena, c);
    try out.append(arena, try budgetStateLine(arena, live.budget_max, live.budget_used));
    if (try budgetFinding(arena, live.budget_max, live.budget_used)) |c| try out.append(arena, c);
}

fn jobStateLine(arena: Allocator, jobs: []const JobView) Allocator.Error!Check {
    if (jobs.len == 0) return .{
        .id = "JOB_STATE",
        .severity = .info,
        .title = "no background jobs",
        .detail = "the in-process job table is empty. Forgotten localhost trees started outside bash are not visible here.",
    };
    var running: usize = 0;
    var done: usize = 0;
    for (jobs) |j| {
        if (j.done) done += 1 else running += 1;
    }
    return .{
        .id = "JOB_STATE",
        .severity = .info,
        .title = "background jobs in this process",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} job(s) in the table ({d} running, {d} done). This is the live pool, not a durable registry across restarts.",
            .{ jobs.len, running, done },
        ),
    };
}

fn jobSharesRoot(arena: Allocator, jobs: []const JobView) Allocator.Error!?Check {
    var n: usize = 0;
    var first: u32 = 0;
    for (jobs) |j| {
        if (!j.shares_root_pgid) continue;
        if (n == 0) first = j.id;
        n += 1;
    }
    if (n == 0) return null;
    return .{
        .id = "JOB_SHARES_ROOT_PGID",
        .severity = .warn,
        .title = "a background job shares graff's process group",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} live job(s) share the root PGID (first id {d}). A group kill would take graff down with them.",
            .{ n, first },
        ),
    };
}

fn budgetStateLine(arena: Allocator, max: u64, used: u64) Allocator.Error!Check {
    if (max == 0) return .{
        .id = "BUDGET_STATE",
        .severity = .info,
        .title = "model-call budget is unlimited",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} model call(s) this invocation; --max-model-calls is unset so the doctor will not warn on spend.",
            .{used},
        ),
    };
    return .{
        .id = "BUDGET_STATE",
        .severity = .info,
        .title = "model-call budget",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} of {d} model call(s) used ({d} remaining).",
            .{ used, max, max -| used },
        ),
    };
}

fn budgetFinding(arena: Allocator, max: u64, used: u64) Allocator.Error!?Check {
    if (max == 0) return null;
    if (used >= max) return .{
        .id = "BUDGET_EXCEEDED",
        .severity = .@"error",
        .title = "model-call budget is exhausted",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} of {d} calls used. Further model work is refused until the process exits.",
            .{ used, max },
        ),
    };
    if (used * 5 >= max * 4) return .{
        .id = "BUDGET_NEAR_LIMIT",
        .severity = .warn,
        .title = "model-call budget is nearly spent",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} of {d} calls used ({d} remaining).",
            .{ used, max, max - used },
        ),
    };
    return null;
}

fn find(checks: []const Check, id: []const u8) ?Check {
    for (checks) |c| {
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

test "doctor live: empty jobs and unlimited budget are info only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var out: std.ArrayList(Check) = .empty;
    try append(ar, &out, .{});
    try std.testing.expect(find(out.items, "JOB_STATE") != null);
    try std.testing.expectEqual(Severity.info, find(out.items, "JOB_STATE").?.severity);
    try std.testing.expect(find(out.items, "JOB_SHARES_ROOT_PGID") == null);
    try std.testing.expect(find(out.items, "BUDGET_STATE") != null);
    try std.testing.expect(find(out.items, "BUDGET_NEAR_LIMIT") == null);
    try std.testing.expect(find(out.items, "BUDGET_EXCEEDED") == null);
}

test "doctor live: JOB_SHARES_ROOT_PGID and budget ladder (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const jobs = [_]JobView{
        .{ .id = 3, .done = false, .shares_root_pgid = true },
        .{ .id = 4, .done = true, .shares_root_pgid = false },
    };
    var out: std.ArrayList(Check) = .empty;
    try append(ar, &out, .{ .jobs = &jobs, .budget_max = 10, .budget_used = 8 });
    const share = find(out.items, "JOB_SHARES_ROOT_PGID") orelse return error.TestExpectedShare;
    try std.testing.expectEqual(Severity.warn, share.severity);
    try std.testing.expect(std.mem.indexOf(u8, share.detail, "id 3") != null);
    try std.testing.expectEqual(Severity.warn, find(out.items, "BUDGET_NEAR_LIMIT").?.severity);

    out.clearRetainingCapacity();
    try append(ar, &out, .{ .budget_max = 4, .budget_used = 4 });
    try std.testing.expectEqual(Severity.@"error", find(out.items, "BUDGET_EXCEEDED").?.severity);
    try std.testing.expect(find(out.items, "BUDGET_NEAR_LIMIT") == null);
}
