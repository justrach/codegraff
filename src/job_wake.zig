//! Idle job auto-wake (ADR 0010 follow-up, ADR 0013).
//!
//! `bash_output(wait_ms>0)` waits in-turn. This module is the between-turns
//! half: when a background job the harness already saw running later finishes,
//! or a `monitor` watch grows new complete lines, the next `popSteer` (REPL)
//! or `session/prompt` (ACP) prepends one harness note. It does not interrupt
//! a blocked readline — that needs a wake pipe on the input loop.
//!
//! Line watches must not advance `job.cursor`: that belongs to `bash_output`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");

const gpa = std.heap.page_allocator;

pub const max_lines_per_wake: u32 = 40;
pub const max_lines_lifetime: u32 = 200;

const Watch = struct {
    id: u32,
    description: []u8,
    line_cursor: usize,
    lines_seen: u32,
};

var seen_running: std.AutoHashMapUnmanaged(u32, void) = .empty;
var woken: std.AutoHashMapUnmanaged(u32, void) = .empty;
var pending: std.ArrayListUnmanaged(u8) = .empty;
var watches: std.ArrayListUnmanaged(Watch) = .empty;

pub fn resetForTest() void {
    seen_running.deinit(gpa);
    seen_running = .empty;
    woken.deinit(gpa);
    woken = .empty;
    pending.deinit(gpa);
    pending = .empty;
    for (watches.items) |w| gpa.free(w.description);
    watches.deinit(gpa);
    watches = .empty;
}

pub fn registerWatch(id: u32, description: []const u8) void {
    const desc = gpa.dupe(u8, description) catch return;
    watches.append(gpa, .{
        .id = id,
        .description = desc,
        .line_cursor = 0,
        .lines_seen = 0,
    }) catch gpa.free(desc);
}

fn appendPending(text: []const u8) void {
    if (pending.items.len > 0) pending.append(gpa, '\n') catch {};
    pending.appendSlice(gpa, text) catch {};
}

const Drain = struct {
    kill_ids: [8]u32 = undefined,
    kill_n: usize = 0,
};

fn onJob(ctx: *anyopaque, view: jobs.JobView) void {
    const d: *Drain = @ptrCast(@alignCast(ctx));
    if (!view.done) _ = seen_running.put(gpa, view.id, {}) catch {};
    drainWatch(d, view);
    if (!view.done) return;
    if (!seen_running.contains(view.id) or woken.contains(view.id)) return;
    _ = woken.put(gpa, view.id, {}) catch {};
    var status_buf: [32]u8 = undefined;
    const status = if (view.killed)
        "killed"
    else if (view.exit_code) |c|
        std.fmt.bufPrint(&status_buf, "exit {d}", .{c}) catch "done"
    else
        "done";
    const cmd = if (view.cmd.len > 80) view.cmd[0..80] else view.cmd;
    var line: [160]u8 = undefined;
    const note = std.fmt.bufPrint(&line, "[harness] Background job {d} finished ({s}): {s}", .{ view.id, status, cmd }) catch return;
    appendPending(note);
}

fn drainWatch(d: *Drain, view: jobs.JobView) void {
    for (watches.items) |*w| {
        if (w.id != view.id) continue;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer lines.deinit(gpa);
        var i = w.line_cursor;
        while (i < view.buf.len) {
            if (std.mem.indexOfScalar(u8, view.buf[i..], '\n')) |rel| {
                lines.append(gpa, view.buf[i .. i + rel]) catch {};
                i += rel + 1;
            } else {
                if (view.done) {
                    lines.append(gpa, view.buf[i..]) catch {};
                    i = view.buf.len;
                }
                break;
            }
        }
        w.line_cursor = i;
        const fresh: u32 = @intCast(@min(lines.items.len, std.math.maxInt(u32)));
        w.lines_seen += fresh;
        if (fresh > 0) {
            var aw: Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            aw.writer.print("[harness] monitor job {d} ({s}): {d} new line(s)", .{ view.id, w.description, fresh }) catch {};
            const start = if (fresh > max_lines_per_wake) lines.items.len - max_lines_per_wake else 0;
            for (lines.items[start..]) |ln| {
                aw.writer.writeAll("\n") catch {};
                aw.writer.writeAll(ln) catch {};
            }
            appendPending(aw.writer.buffered());
        }
        if (w.lines_seen >= max_lines_lifetime and d.kill_n < d.kill_ids.len) {
            d.kill_ids[d.kill_n] = view.id;
            d.kill_n += 1;
            appendPending("[harness] monitor stopped: volume cap");
        }
    }
}

pub fn drain(io: Io) void {
    var d: Drain = .{};
    jobs.visitJobs(io, &d, onJob);
    for (d.kill_ids[0..d.kill_n]) |id| {
        const out = jobs.jobKill(gpa, io, id) catch continue;
        gpa.free(out.text);
    }
}

/// page_allocator-owned text for the REPL steer queue; caller frees.
pub fn popWakeText() ?[]const u8 {
    if (jobs.g_jobs_io) |io| drain(io);
    if (pending.items.len == 0) return null;
    const text = gpa.dupe(u8, pending.items) catch return null;
    pending.clearRetainingCapacity();
    return text;
}

/// Arena-owned note for ACP to prepend on the next `session/prompt`.
pub fn takeNote(arena: Allocator) []const u8 {
    if (jobs.g_jobs_io) |io| drain(io);
    if (pending.items.len == 0) return "";
    const text = arena.dupe(u8, pending.items) catch return "";
    pending.clearRetainingCapacity();
    return text;
}

const testing = std.testing;

test "a job that finishes after we saw it running wakes once" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    resetForTest();
    defer resetForTest();
    jobs.g_jobs = .{};
    const io = testing.io;
    const id = (try jobs.spawnJob(testing.allocator, io, "sleep 0.25; exit 3")).id;
    defer jobs.jobsReap(testing.allocator, io);
    drain(io);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("", takeNote(arena_state.allocator()));
    io.sleep(.fromMilliseconds(500), .awake) catch {};
    drain(io);
    const note = takeNote(arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, note, "Background job") != null);
    try testing.expect(std.mem.indexOf(u8, note, "exit 3") != null);
    var buf: [16]u8 = undefined;
    const id_s = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, note, id_s) != null);
    drain(io);
    try testing.expectEqualStrings("", takeNote(arena_state.allocator()));
}

test "a job that is already done on first drain does not wake" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    resetForTest();
    defer resetForTest();
    jobs.g_jobs = .{};
    const io = testing.io;
    _ = (try jobs.spawnJob(testing.allocator, io, "exit 0")).id;
    defer jobs.jobsReap(testing.allocator, io);
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    drain(io);
    try testing.expectEqualStrings("", takeNote(arena_state.allocator()));
}

test "monitor lines do not advance bash_output's cursor" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    resetForTest();
    defer resetForTest();
    jobs.g_jobs = .{};
    const io = testing.io;
    const id = (try jobs.spawnJob(testing.allocator, io, "printf 'alpha\\nbeta\\ngamma\\n'")).id;
    defer jobs.jobsReap(testing.allocator, io);
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    registerWatch(id, "lines");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    drain(io);
    const note = takeNote(arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, note, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, note, "beta") != null);
    const S = struct {
        cursor: usize = 0,
        fn cb(ctx: *anyopaque, view: jobs.JobView) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.cursor = view.cursor;
        }
    };
    var s: S = .{};
    jobs.visitJobs(io, &s, S.cb);
    try testing.expectEqual(@as(usize, 0), s.cursor);
}

test "monitor volume cap asks the job to stop" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    resetForTest();
    defer resetForTest();
    jobs.g_jobs = .{};
    const io = testing.io;
    const id = (try jobs.spawnJob(testing.allocator, io, "i=0; while [ $i -lt 220 ]; do echo line$i; i=$((i+1)); done")).id;
    defer jobs.jobsReap(testing.allocator, io);
    io.sleep(.fromMilliseconds(400), .awake) catch {};
    registerWatch(id, "vol");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    drain(io);
    const note = takeNote(arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, note, "volume cap") != null);
}
