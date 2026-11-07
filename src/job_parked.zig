//! #1486: a foreground command parked in the background stays on pipes (ADR
//! 0218: its `cmd &` idioms depend on pipe EOF), so it cannot outlive the
//! graff that owns it. Its handle could: a resumed or restarted session that
//! asked for it found no owner and could only answer "unknown outcome".
//!
//! A parked job now leaves a small record, `.graff/job-parked/<id>.json`,
//! written when it parks and rewritten with its final state (exit code and the
//! unread output tail, or how session end treated it) when the pool frees it.
//! A later process answers that handle from the record instead of losing it.
//! A record whose owner is still alive is answered as owned elsewhere; one
//! whose owner died without a final state says exactly that.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc_identity = @import("proc_identity.zig");

pub const dir_rel = ".graff/job-parked";
const tail_cap = 16 * 1024;
const max_age_ns: i96 = 7 * std.time.ns_per_day;

pub const State = enum { running, exited, killed, stopped_at_exit, left_running };

pub const Record = struct {
    id: u64,
    cmd: []const u8,
    owner_pid: i32 = 0,
    owner_start: proc_identity.StartId = 0,
    state: State = .running,
    exit_code: ?u8 = null,
    output: []const u8 = "",
    reported: bool = false,
};

/// Tests point this at a tmp dir; production writes under the process cwd.
pub var base_override: ?Io.Dir = null;

fn base() Io.Dir {
    return base_override orelse Io.Dir.cwd();
}

fn path(buf: []u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{d}.json", .{ dir_rel, id }) catch unreachable;
}

/// Write `rec`. Best effort: a failed write leaves the earlier record.
pub fn write(io: Io, rec: Record) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = std.json.Stringify.valueAlloc(arena, rec, .{}) catch return;
    base().createDirPath(io, dir_rel) catch return;
    var buf: [96]u8 = undefined;
    const final = path(&buf, rec.id);
    const tmp = std.fmt.allocPrint(arena, "{s}.tmp", .{final}) catch return;
    base().writeFile(io, .{ .sub_path = tmp, .data = body }) catch return;
    base().rename(tmp, base(), final, io) catch base().deleteFile(io, tmp) catch {};
}

/// The job just parked: record it as running under this process.
pub fn begin(io: Io, id: u64, cmd: []const u8) void {
    sweep(io);
    write(io, .{ .id = id, .cmd = cmd, .owner_pid = proc_identity.selfPid(), .owner_start = proc_identity.selfStartId(io) });
}

/// What the pool knew about the job when it freed it.
pub const Final = struct {
    exit_code: ?u8,
    done: bool,
    killed: bool,
    session_end: bool,
    unread: []const u8,
};

pub fn finish(io: Io, id: u64, cmd: []const u8, f: Final) void {
    const state: State = if (!f.done)
        .left_running
    else if (f.killed and f.session_end)
        .stopped_at_exit
    else if (f.killed)
        .killed
    else
        .exited;
    const tail = f.unread[f.unread.len -| tail_cap..];
    write(io, .{
        .id = id,
        .cmd = cmd,
        .state = state,
        .exit_code = f.exit_code,
        .output = tail,
        .reported = f.done and f.unread.len == 0,
    });
}

/// The answer for a handle this process does not own, or null when no parked
/// job ever recorded it.
pub fn describe(gpa: Allocator, io: Io, id: u64) ?Answer {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [96]u8 = undefined;
    const bytes = base().readFileAlloc(io, path(&buf, id), arena, .limited(tail_cap + 8 * 1024)) catch return null;
    const rec = std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (rec.id != id) return null;
    return render(gpa, io, rec) catch null;
}

pub const Answer = struct { text: []u8, is_error: bool };

fn render(gpa: Allocator, io: Io, rec: Record) !Answer {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    var is_error = true;
    switch (rec.state) {
        .running => {
            const owner = proc_identity.stateOf(io, .{ .pid = rec.owner_pid, .start_id = rec.owner_start });
            if (owner == .held and rec.owner_pid != proc_identity.selfPid()) {
                try w.print("job {d} ({s}) belongs to another running graff (pid {d}); read it from that session", .{ rec.id, rec.cmd, rec.owner_pid });
            } else {
                try w.print("job {d} ({s}) was a parked foreground command whose graff ended without recording an outcome; its output pipes closed with that graff, so the command most likely stopped then. Its output and exit status were not kept; do not assume it finished", .{ rec.id, rec.cmd });
            }
        },
        .exited => {
            is_error = (rec.exit_code orelse 1) != 0;
            if (rec.exit_code) |c|
                try w.print("job {d} ({s}) finished before this continuation: exited with code {d}", .{ rec.id, rec.cmd, c })
            else
                try w.print("job {d} ({s}) finished before this continuation: terminated abnormally", .{ rec.id, rec.cmd });
        },
        .killed => try w.print("job {d} ({s}) was killed before this continuation", .{ rec.id, rec.cmd }),
        .stopped_at_exit => try w.print("job {d} ({s}) was stopped when its graff session ended; it did not finish", .{ rec.id, rec.cmd }),
        .left_running => try w.print("job {d} ({s}) was left running when its graff session ended; its output is no longer captured — /jobs or `graff servers` show what still runs", .{ rec.id, rec.cmd }),
    }
    if (rec.output.len > 0) {
        try w.writeAll("\nunread output:\n");
        try w.writeAll(rec.output);
    } else if (rec.reported) {
        try w.writeAll("\n(its output was already read)");
    }
    return .{ .text = try aw.toOwnedSlice(), .is_error = is_error };
}

/// Drop records older than a week. Cheap: one directory pass per park.
fn sweep(io: Io) void {
    var dir = base().openDir(io, dir_rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const now = Io.Clock.real.now(io).nanoseconds;
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        if (now - st.mtime.nanoseconds > max_age_ns) dir.deleteFile(io, entry.name) catch {};
    }
}

test "#1486 a parked job's record answers its handle after its graff is gone" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    base_override = tmp.dir;
    defer base_override = null;

    try std.testing.expect(describe(gpa, io, 7) == null);
    // Parked by a graff that died before the pool could record an outcome.
    write(io, .{ .id = 7, .cmd = "make test", .owner_pid = 0 });
    const lost = describe(gpa, io, 7).?;
    defer gpa.free(lost.text);
    try std.testing.expect(lost.is_error);
    try std.testing.expect(std.mem.indexOf(u8, lost.text, "without recording an outcome") != null);

    finish(io, 7, "make test", .{ .exit_code = 0, .done = true, .killed = false, .session_end = true, .unread = "all green\n" });
    const done = describe(gpa, io, 7).?;
    defer gpa.free(done.text);
    try std.testing.expect(!done.is_error);
    try std.testing.expect(std.mem.indexOf(u8, done.text, "exited with code 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, done.text, "all green") != null);

    finish(io, 7, "make test", .{ .exit_code = null, .done = true, .killed = true, .session_end = true, .unread = "" });
    const stopped = describe(gpa, io, 7).?;
    defer gpa.free(stopped.text);
    try std.testing.expect(std.mem.indexOf(u8, stopped.text, "stopped when its graff session ended") != null);
}

test "#1486 a parked job's handle still answers after the pool that owned it is gone" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const Agent = @import("agent.zig").Agent;
    const jobs = @import("jobs.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    base_override = tmp.dir;
    defer base_override = null;
    jobs.g_jobs = .{};
    Agent.esc_cancel.store(false, .release);
    const id = (try jobs.spawnJob(gpa, io, "printf parked-out; exit 3")).id;
    jobs.markParked(io, id); // what the foreground wait does when it parks a command
    while (true) {
        jobs.g_jobs.mutex.lockUncancelable(io);
        const done = jobs.g_jobs.find(id).?.done;
        jobs.g_jobs.mutex.unlock(io);
        if (done) break;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    jobs.jobsReap(gpa, io); // the owning session ends; a continuation asks next
    const out = try jobs.jobOutput(gpa, io, id, 0);
    defer gpa.free(out.text);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "no live owner") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "exited with code 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "parked-out") != null);
    try std.testing.expect(out.is_error);
}
