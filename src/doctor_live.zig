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
const job_registry = @import("job_registry.zig");
const worktree_lease = @import("worktree_lease.zig");
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");
const posix_groups = builtin.os.tag != .windows and builtin.os.tag != .wasi;

pub const JobView = struct {
    id: u64 = 0,
    done: bool = false,
    shares_root_pgid: bool = false,
};

pub const LeaseView = struct {
    pid: i32 = 0,
    session_id: []const u8 = "",
    verdict: worktree_lease.OwnerVerdict = .self,
};

pub const OwnedJobView = struct {
    pid: i32 = 0,
    state: job_registry.State = .gone,
    owner_alive: bool = false,
    pinned: bool = false,
    retained: bool = false,
};

pub const Live = struct {
    jobs: []const JobView = &.{},
    leases: []const LeaseView = &.{},
    owned_jobs: []const OwnedJobView = &.{},
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

pub fn selfPid() i32 {
    return thisPid();
}

pub fn captureLeases(arena: Allocator, io: Io, home: []const u8, my_identity: []const u8, my_pid: i32) Allocator.Error![]const LeaseView {
    if (home.len == 0 or my_identity.len == 0) return &.{};
    const dir_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, presence.registry_subdir });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var out: std.ArrayList(LeaseView) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (out.items.len >= 32) break;
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(4096)) catch continue;
        const rec = presence.parseRecord(arena, text) orelse continue;
        const probe = proc_identity.probe(io, rec.pid);
        try out.append(arena, .{
            .pid = rec.pid,
            .session_id = rec.session_id,
            .verdict = worktree_lease.ownerVerdict(rec, my_identity, my_pid, probe),
        });
    }
    return out.toOwnedSlice(arena);
}

pub fn captureOwnedJobs(arena: Allocator, io: Io, home: []const u8) Allocator.Error![]const OwnedJobView {
    if (home.len == 0) return &.{};
    const recs = job_registry.list(io, arena, home);
    var out: std.ArrayList(OwnedJobView) = .empty;
    for (recs) |rec| {
        try out.append(arena, .{
            .pid = rec.pid,
            .state = job_registry.state(io, rec),
            .owner_alive = job_registry.ownerAlive(io, rec),
            .pinned = rec.pinned,
            .retained = rec.retained,
        });
    }
    return out.toOwnedSlice(arena);
}

pub fn append(arena: Allocator, out: *std.ArrayList(Check), live: Live) Allocator.Error!void {
    if (try duplicateWorktreeOwner(arena, live.leases)) |c| try out.append(arena, c);
    if (try staleSessionLease(arena, live.leases)) |c| try out.append(arena, c);
    try out.append(arena, try jobStateLine(arena, live.jobs));
    if (try jobSharesRoot(arena, live.jobs)) |c| try out.append(arena, c);
    if (try orphanedOwnedJob(arena, live.owned_jobs)) |c| try out.append(arena, c);
    try out.append(arena, try budgetStateLine(arena, live.budget_max, live.budget_used));
    if (try budgetFinding(arena, live.budget_max, live.budget_used)) |c| try out.append(arena, c);
}

fn duplicateWorktreeOwner(arena: Allocator, leases: []const LeaseView) Allocator.Error!?Check {
    var n: usize = 0;
    var first_pid: i32 = 0;
    var first_session: []const u8 = "";
    for (leases) |l| {
        if (l.verdict != .live_foreign and l.verdict != .live_unverified) continue;
        if (n == 0) {
            first_pid = l.pid;
            first_session = if (l.session_id.len > 0) l.session_id else "unknown";
        }
        n += 1;
    }
    if (n == 0) return null;
    return .{
        .id = "DUPLICATE_WORKTREE_OWNER",
        .severity = .warn,
        .title = "another live graff session owns this worktree",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} foreign session(s) share this canonical Git worktree (first pid {d}, session \"{s}\"). Restart with `graff -w` for an isolated worktree.",
            .{ n, first_pid, first_session },
        ),
    };
}

fn staleSessionLease(arena: Allocator, leases: []const LeaseView) Allocator.Error!?Check {
    var n: usize = 0;
    var first_pid: i32 = 0;
    for (leases) |l| {
        if (l.verdict != .stale_dead and l.verdict != .stale_unverifiable) continue;
        if (n == 0) first_pid = l.pid;
        n += 1;
    }
    if (n == 0) return null;
    return .{
        .id = "STALE_SESSION_LEASE",
        .severity = .warn,
        .title = "stale session lease in ~/.graff/live",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} lease record(s) have a dead or recycled PID/start identity (first pid {d}). Presence scans reap dead records automatically on next peer check.",
            .{ n, first_pid },
        ),
    };
}

fn orphanedOwnedJob(arena: Allocator, jobs: []const OwnedJobView) Allocator.Error!?Check {
    var n: usize = 0;
    var first_pid: i32 = 0;
    for (jobs) |j| {
        if (j.state != .running or j.owner_alive or j.pinned or j.retained) continue;
        if (n == 0) first_pid = j.pid;
        n += 1;
    }
    if (n == 0) return null;
    return .{
        .id = "ORPHANED_OWNED_JOB",
        .severity = .warn,
        .title = "an unretained background job outlived its owning session",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} owned job(s) remain running after their launcher session exited (first pid {d}). Inspect with `graff servers` or stop with `graff servers stop {d}`.",
            .{ n, first_pid, first_pid },
        ),
    };
}

pub fn cliCommand(gpa: Allocator, io: Io, arena: Allocator, home: []const u8, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};
    const want_json = @import("main.zig").json_mode or (args.len > 0 and (std.mem.eql(u8, args[0], "--json") or std.mem.eql(u8, args[0], "json")));
    const id = worktree_lease.currentIdentity(gpa, io, arena).id;
    const st: doctor.State = .{
        .now_ms = @import("util.zig").unixMs(io),
        .jobs = try captureJobs(arena, io),
        .leases = try captureLeases(arena, io, home, id, thisPid()),
        .owned_jobs = try captureOwnedJobs(arena, io, home),
        .listener_findings = try @import("server_diagnostics.zig").capture(arena, io),
    };
    const checks = try doctor.run(arena, st);
    if (want_json) {
        try out.print("{s}\n", .{try doctor.toJson(arena, checks)});
    } else {
        try out.writeAll(try doctor.render(arena, checks));
    }
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
    var first: u64 = 0;
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

test "doctor live: DUPLICATE_WORKTREE_OWNER, STALE_SESSION_LEASE, and ORPHANED_OWNED_JOB (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const leases = [_]LeaseView{
        .{ .pid = 4100, .session_id = "peer-a", .verdict = .live_foreign },
        .{ .pid = 4200, .session_id = "dead-b", .verdict = .stale_dead },
    };
    const owned = [_]OwnedJobView{
        .{ .pid = 5100, .state = .running, .owner_alive = false, .pinned = false, .retained = false },
        .{ .pid = 5200, .state = .running, .owner_alive = false, .pinned = true, .retained = true },
    };
    var out: std.ArrayList(Check) = .empty;
    try append(ar, &out, .{ .leases = &leases, .owned_jobs = &owned });
    const dup = find(out.items, "DUPLICATE_WORKTREE_OWNER") orelse return error.TestExpectedDuplicateOwner;
    try std.testing.expectEqual(Severity.warn, dup.severity);
    try std.testing.expect(std.mem.indexOf(u8, dup.detail, "4100") != null);
    const stale = find(out.items, "STALE_SESSION_LEASE") orelse return error.TestExpectedStaleLease;
    try std.testing.expectEqual(Severity.warn, stale.severity);
    try std.testing.expect(std.mem.indexOf(u8, stale.detail, "4200") != null);
    const orphan = find(out.items, "ORPHANED_OWNED_JOB") orelse return error.TestExpectedOrphanJob;
    try std.testing.expectEqual(Severity.warn, orphan.severity);
    try std.testing.expect(std.mem.indexOf(u8, orphan.detail, "5100") != null);
    try std.testing.expect(std.mem.indexOf(u8, orphan.detail, "5200") == null);
}
