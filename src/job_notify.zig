//! grok-build TaskCompleted / system-reminder for background bash (ADR 0010
//! follow-up). A finished job queues one notice. `deliver` injects a wake at
//! the next root step boundary; `takeWake` is the idle TUI auto-turn.

const std = @import("std");
const Io = std.Io;

const agent_mod = @import("agent.zig");
const engine_sink = @import("engine_sink.zig");
const Agent = agent_mod.Agent;

pub const Notice = struct {
    id: u32,
    exit_code: ?u8 = null,
    killed: bool = false,
    preview: [48]u8 = undefined,
    preview_len: u8 = 0,
};

const cap: usize = 16;
var mu: Io.Mutex = .init;
var ring: [cap]Notice = undefined;
var count: usize = 0;

fn clipCmd(cmd: []const u8) struct { buf: [48]u8, len: u8 } {
    const t = std.mem.trim(u8, cmd, " \t\r\n");
    const keep: u8 = @intCast(@min(t.len, 48));
    var buf: [48]u8 = @splat(0);
    @memcpy(buf[0..keep], t[0..keep]);
    return .{ .buf = buf, .len = keep };
}

/// One human/model line for a finished job.
pub fn line(buf: []u8, n: Notice) []const u8 {
    const cmd = n.preview[0..n.preview_len];
    if (n.killed) {
        return std.fmt.bufPrint(buf, "[job {d} killed: {s}]", .{ n.id, cmd }) catch buf[0..0];
    }
    if (n.exit_code) |c| {
        return std.fmt.bufPrint(buf, "[job {d} exited {d}: {s}]", .{ n.id, c, cmd }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "[job {d} ended: {s}]", .{ n.id, cmd }) catch buf[0..0];
}

fn wakeLine(buf: []u8, n: Notice) []const u8 {
    var head: [96]u8 = undefined;
    const h = line(&head, n);
    return std.fmt.bufPrint(buf, "{s} — unread output via bash_output; do not poll.", .{h}) catch h;
}

/// Pump thread: the job is done. Queues a reminder and, if a turn is live,
/// paints a TUI/REPL notice immediately.
pub fn record(io: Io, id: u32, exit_code: ?u8, killed: bool, cmd: []const u8) void {
    const clipped = clipCmd(cmd);
    const n = Notice{ .id = id, .exit_code = exit_code, .killed = killed, .preview = clipped.buf, .preview_len = clipped.len };
    mu.lockUncancelable(io);
    if (count == cap) {
        std.mem.copyForwards(Notice, ring[0 .. cap - 1], ring[1..cap]);
        count = cap - 1;
    }
    ring[count] = n;
    count += 1;
    mu.unlock(io);
    if (engine_sink.hostedSink()) |sink| {
        sink.emit(io, .{ .job_completed = .{ .id = id, .exit_code = exit_code, .killed = killed } });
    }
}

/// Drain queued notices into `buf`. Null when nothing finished.
pub fn takeWake(io: Io, buf: []u8) ?[]const u8 {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (count == 0) return null;
    var used: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var one: [160]u8 = undefined;
        const w = wakeLine(&one, ring[i]);
        if (used > 0) {
            if (used + 1 >= buf.len) break;
            buf[used] = '\n';
            used += 1;
        }
        const n = @min(w.len, buf.len - used);
        @memcpy(buf[used .. used + n], w[0..n]);
        used += n;
    }
    count = 0;
    if (used == 0) return null;
    return buf[0..used];
}

/// Root step-boundary inject (same moment as peer deliverInbound).
pub fn deliver(root: *Agent) void {
    if (root.sub) return;
    var buf: [512]u8 = undefined;
    const text = takeWake(root.io, &buf) orelse return;
    const owned = root.arena.dupe(u8, text) catch return;
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = owned }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
    engine_sink.forAgent(root).emit(root.io, .{ .session_notice = .{ .text = owned, .tone = .dim } });
}

test "line names exit, kill, and abnormal end" {
    const clipped = clipCmd("sleep 5");
    var n = Notice{ .id = 3, .exit_code = 0, .preview = clipped.buf, .preview_len = clipped.len };
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("[job 3 exited 0: sleep 5]", line(&buf, n));
    n.killed = true;
    try std.testing.expectEqualStrings("[job 3 killed: sleep 5]", line(&buf, n));
    n.killed = false;
    n.exit_code = null;
    try std.testing.expectEqualStrings("[job 3 ended: sleep 5]", line(&buf, n));
}

test "takeWake drains and formats the grok-build do-not-poll reminder" {
    const io = std.testing.io;
    count = 0;
    record(io, 1, 0, false, "true");
    record(io, 2, 1, false, "false");
    var buf: [256]u8 = undefined;
    const text = takeWake(io, &buf) orelse return error.Empty;
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 1 exited 0: true]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "do not poll") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[job 2 exited 1: false]") != null);
    try std.testing.expect(takeWake(io, &buf) == null);
}
