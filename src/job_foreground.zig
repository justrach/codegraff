//! Root foreground bash wait (#620 / grok-build auto-background), split out
//! of jobs.zig (600-line cap): wait for the job, or promote it to the
//! background at the bound, or kill it on Esc.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");
const Job = jobs.Job;
const g_jobs = &jobs.g_jobs;
const nowMs = jobs.nowMs;
const jobKill = jobs.jobKill;
const job_wait = @import("job_wait.zig");
const job_notify = @import("job_notify.zig");
const browser_guard = @import("job_browser_guard.zig");
const tool_pulse = @import("tool_pulse.zig");
const Agent = @import("agent.zig").Agent;

/// Outcome of a root foreground wait (#620 / grok-build auto-background).
pub const FgDone = struct { exit_code: ?u8, killed: bool, output: []u8, dropped: bool };
pub const FgPartial = struct { id: u64, output: []u8, dropped: bool };
pub const FgWait = union(enum) { done: FgDone, running: FgPartial, cancelled: FgPartial };

fn takeUnread(gpa: Allocator, job: *Job) error{OutOfMemory}!struct { []u8, bool } {
    job.stream = null;
    job.stream_ctx = null;
    const out = try gpa.dupe(u8, job.buf.items[job.cursor..]);
    @import("job_ring.zig").consumeUnread(gpa, &job.buf, &job.cursor);
    const dropped = job.dropped;
    job.dropped = false;
    return .{ out, dropped };
}

pub fn waitForeground(gpa: Allocator, io: Io, id: u64, wait_ms: u64) !FgWait {
    const deadline = if (wait_ms == 0) job_wait.wait_cap_ms else @min(wait_ms, job_wait.wait_cap_ms);
    var waited: u64 = 0;
    var still = tool_pulse.Pulse{};
    while (true) {
        g_jobs.mutex.lockUncancelable(io);
        const job = g_jobs.find(id) orelse {
            g_jobs.mutex.unlock(io);
            return error.NoSuchJob;
        };
        browser_guard.touch(job, nowMs(io)); // the foreground wait is activity (#199)
        if (job.done) {
            const pair = takeUnread(gpa, job) catch {
                g_jobs.mutex.unlock(io);
                return error.OutOfMemory;
            };
            job_notify.dismiss(io, id);
            const result: FgWait = .{ .done = .{ .exit_code = job.exit_code, .killed = job.killed, .output = pair[0], .dropped = pair[1] } };
            g_jobs.mutex.unlock(io);
            return result;
        }
        if (job_wait.shouldPromote(waited >= deadline, job_wait.followup_pending.load(.acquire))) {
            const pair = takeUnread(gpa, job) catch {
                g_jobs.mutex.unlock(io);
                return error.OutOfMemory;
            };
            job.quiet = false; // completion should now notify (#620)
            const result: FgWait = .{ .running = .{ .id = id, .output = pair[0], .dropped = pair[1] } };
            g_jobs.mutex.unlock(io);
            return result;
        }
        g_jobs.mutex.unlock(io);
        if (Agent.esc_cancel.load(.acquire)) {
            if (jobKill(gpa, io, id)) |out| gpa.free(out.text) else |_| {}
            g_jobs.mutex.lockUncancelable(io);
            if (g_jobs.find(id)) |j| {
                const pair = takeUnread(gpa, j) catch {
                    g_jobs.mutex.unlock(io);
                    return error.OutOfMemory;
                };
                g_jobs.mutex.unlock(io);
                return .{ .cancelled = .{ .id = id, .output = pair[0], .dropped = pair[1] } };
            }
            g_jobs.mutex.unlock(io);
            return .{ .cancelled = .{ .id = id, .output = try gpa.dupe(u8, ""), .dropped = false } };
        }
        io.sleep(.fromMilliseconds(100), .awake) catch {
            waited = deadline;
            continue;
        };
        waited += 100;
        if (still.due(waited)) {
            var ebuf: [16]u8 = undefined;
            tool_pulse.emitNotice(io, "· bash still running · {s}", .{tool_pulse.formatElapsed(&ebuf, waited)});
        }
    }
}
