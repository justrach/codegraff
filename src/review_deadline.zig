//! Opt-in review deadline. The watcher belongs to one turn and is joined before
//! its storage or the turn's cancellation state can be reused.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const cancel = @import("cancel_source.zig");
const A = std.mem.Allocator;
const State = struct {
    io: std.Io,
    until_ns: i128,
    done: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),

    fn watch(self: *State) void {
        while (!self.done.load(.acquire)) {
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= self.until_ns) {
                if (self.done.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                    self.expired.store(true, .release);
                    cancel.cancelIfIdle(.review_deadline);
                }
                return;
            }
            self.io.sleep(.fromMilliseconds(20), .awake) catch return;
        }
    }
};

pub const Watch = struct {
    state: ?*State = null,
    thread: ?std.Thread = null,
    allocator: A = undefined,
    expired: bool = false,

    pub fn stop(self: *Watch) void {
        const state = self.state orelse return;
        state.done.store(true, .release);
        self.thread.?.join();
        self.expired = state.expired.load(.acquire);
        self.allocator.destroy(state);
        self.state = null;
    }

    pub fn finish(self: *Watch, text: []const u8) ![]const u8 {
        self.stop();
        if (self.expired) return error.Interrupted;
        return text;
    }
};

fn startMs(a: A, io: std.Io, ms: u64) !Watch {
    if (ms == 0) return .{};
    const state = try a.create(State);
    errdefer a.destroy(state);
    state.* = .{ .io = io, .until_ns = @as(i128, std.Io.Timestamp.now(io, .awake).nanoseconds) + @as(i128, ms) * std.time.ns_per_ms };
    return .{ .state = state, .thread = try std.Thread.spawn(.{}, State.watch, .{state}), .allocator = a };
}

pub fn parseSeconds(raw: []const u8) !u64 {
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t"), 10) catch return error.InvalidReviewTimeLimit;
    if (n > 86400) return error.InvalidReviewTimeLimit;
    return n;
}

pub fn start(agent: *Agent) !Watch {
    if (!agent.review_mode or agent.sub) return .{};
    const raw = std.c.getenv("GRAFF_REVIEW_MAX_SECONDS") orelse return .{};
    const seconds = try parseSeconds(std.mem.span(raw));
    if (seconds != 0) if (agent.tracer) |tr| tr.note("review_deadline", "explicit wall-time limit armed");
    return startMs(agent.gpa, agent.io, seconds * 1000);
}

test "review deadline rejects malformed limits and permits explicit unlimited" {
    try std.testing.expectEqual(@as(u64, 0), try parseSeconds("0"));
    try std.testing.expectEqual(@as(u64, 30), try parseSeconds(" 30 "));
    for ([_][]const u8{ "", "-1", "later", "86401" }) |raw|
        try std.testing.expectError(error.InvalidReviewTimeLimit, parseSeconds(raw));
}

test "review watcher is joined and cannot cancel a later turn" {
    cancel.clear();
    defer cancel.clear();
    var watch = try startMs(std.testing.allocator, std.testing.io, 20);
    watch.stop();
    try std.testing.io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
    watch.stop();
}

test "review deadline cancels with harness provenance and preserves a user cancellation" {
    cancel.clear();
    defer cancel.clear();
    var watch = try startMs(std.testing.allocator, std.testing.io, 1);
    defer watch.stop();
    try waitForExpiration(&watch);
    watch.stop();
    try std.testing.expect(Agent.esc_cancel.load(.acquire));
    try std.testing.expectEqual(cancel.Source.review_deadline, cancel.take(null));
    cancel.clear();
    cancel.cancel(.json_cancel);
    var second = try startMs(std.testing.allocator, std.testing.io, 1);
    defer second.stop();
    try waitForExpiration(&second);
    second.stop();
    try std.testing.expectEqual(cancel.Source.json_cancel, cancel.take(null));
}

test "a result arriving after the review deadline cannot become successful completion" {
    cancel.clear();
    defer cancel.clear();
    var watch = try startMs(std.testing.allocator, std.testing.io, 1);
    defer watch.stop();
    try waitForExpiration(&watch);
    try std.testing.expectError(error.Interrupted, watch.finish("late findings"));
    try std.testing.expect(!cancel.byUser(.review_deadline));
    try std.testing.expect(std.mem.indexOf(u8, cancel.marker(.review_deadline), "incomplete") != null);
}

fn waitForExpiration(watch: *Watch) !void {
    const until = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds + 5 * std.time.ns_per_s;
    while (!watch.state.?.expired.load(.acquire)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds >= until) return error.DeadlineDidNotFire;
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }
}
