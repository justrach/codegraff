//! The request half of a streaming POST (#1785): connection setup, the body
//! upload and the wait for the response head each get their own budget. One
//! flat head deadline over all three killed large bodies still draining to a
//! live peer, and the retry only re-sent the same upload into the same wall.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const Agent = @import("agent.zig").Agent;
const cancel_source = @import("cancel_source.zig");
const sendDeadlineMs = @import("agent_ws_signal.zig").sendDeadlineMs;

pub const Stage = enum(u8) { connect, upload, head };

/// Body bytes per socket write; each completed write is upload progress.
const chunk_len: usize = 16 * 1024;
/// Upload floor of 128 kbit/s: a peer accepting a byte at a time still ends.
const floor_bytes_per_s: usize = 16 * 1024;
/// The unfinished-event cap stream_read_progress uses for the read side.
const max_upload_ms: u64 = 15 * 60 * 1000;

pub const Budget = struct {
    connect_ms: u64,
    /// No body byte taken by the socket for this long is a stalled peer.
    upload_idle_ms: u64,
    upload_total_ms: u64,
    /// From the last body byte to the response head. Grows with the body as
    /// the WebSocket send deadline does: its tail can still sit in socket
    /// buffers, clamped to the read budget.
    head_ms: u64,

    pub fn init(body_len: usize, setup_ms: u64, head_ms: u64, stream_ms: u64) Budget {
        const floor_ms = @as(u64, @intCast(body_len / floor_bytes_per_s)) *| 1000;
        return .{
            .connect_ms = setup_ms,
            .upload_idle_ms = setup_ms,
            .upload_total_ms = @min(setup_ms +| floor_ms, @max(setup_ms, max_upload_ms)),
            .head_ms = sendDeadlineMs(body_len, head_ms, stream_ms),
        };
    }

    /// The configured budgets for one request. The loopback-inference head
    /// exception (http_stall.headBudgetMs) widens only the head wait.
    pub fn forRequest(body_len: usize, url: []const u8, model: []const u8) Budget {
        const policy = http_stall.streamPolicy(model, url, http.stream_stall_ms);
        return init(body_len, http.head_stall_ms, http_stall.headBudgetMs(url, http.head_stall_ms, policy), http.stream_stall_ms);
    }

    /// A transport that reports no upload progress (http-zig writes DATA
    /// internally) gets only the size-scaled total.
    pub fn blind(self: Budget) Budget {
        var b = self;
        b.upload_idle_ms = b.upload_total_ms;
        return b;
    }
};

/// `since_ms`: time in this stage; `idle_ms`: time since the last progress.
pub fn expired(b: Budget, stage: Stage, since_ms: u64, idle_ms: u64) bool {
    return switch (stage) {
        .connect => since_ms >= b.connect_ms,
        .upload => idle_ms >= b.upload_idle_ms or since_ms >= b.upload_total_ms,
        .head => since_ms >= b.head_ms,
    };
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn elapsed(from: i64, now: i64) u64 {
    return @intCast(@max(now - from, 0));
}

/// The request task advances the stage and notes progress; the watchdog arm
/// reads only these atomics.
pub const Watch = struct {
    io: Io,
    budget: Budget,
    stage: std.atomic.Value(Stage) = .init(.connect),
    stage_ms: std.atomic.Value(i64),
    last_ms: std.atomic.Value(i64),

    pub fn init(io: Io, budget: Budget) Watch {
        const now = nowMs(io);
        return .{ .io = io, .budget = budget, .stage_ms = .init(now), .last_ms = .init(now) };
    }

    pub fn enter(self: *Watch, stage: Stage) void {
        const now = nowMs(self.io);
        self.stage_ms.store(now, .monotonic);
        self.last_ms.store(now, .monotonic);
        self.stage.store(stage, .release);
    }

    pub fn note(self: *Watch) void {
        self.last_ms.store(nowMs(self.io), .monotonic);
    }

    /// Select arm: fires when the current stage's budget runs out, or on Esc.
    pub fn watch(self: *Watch, poll_stdin: bool) http.WatchdogFired {
        while (true) {
            const stage = self.stage.load(.acquire);
            const now = nowMs(self.io);
            if (expired(self.budget, stage, elapsed(self.stage_ms.load(.monotonic), now), elapsed(self.last_ms.load(.monotonic), now))) return .deadline;
            self.io.sleep(.fromMilliseconds(10), .awake) catch return .deadline; // canceled: the request finished
            if (poll_stdin and Agent.drainSteerStdin(true)) {
                cancel_source.cancelFromStdin();
                return .esc;
            }
            if (Agent.esc_cancel.load(.acquire)) return .esc;
        }
    }
};

/// Write the body in chunks; each one the connection took is progress.
pub fn sendBody(req: *std.http.Client.Request, body: []const u8, watch: *Watch) !void {
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    var off: usize = 0;
    while (off < body.len) {
        const n = @min(chunk_len, body.len - off);
        try bw.writer.writeAll(body[off..][0..n]);
        off += n;
        watch.note();
    }
    try bw.end();
    try req.connection.?.flush();
}

/// HTTP/1.1 request state the task fills and the caller owns. `req` stays
/// null until the connection is up, so the caller knows what to tear down.
pub const H1 = struct {
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    body: []const u8,
    req: ?std.http.Client.Request = null,
    response: std.http.Client.Response = undefined,
};

fn h1Task(h: *H1, w: *Watch) anyerror!void {
    h.req = try h.client.request(.POST, h.uri, h.options);
    w.enter(.upload);
    try sendBody(&h.req.?, h.body, w);
    w.enter(.head);
    h.response = try h.req.?.receiveHead(&.{});
}

/// Connect, upload and receive the head against the staged watchdog. A
/// deadline is HungRequest (retryable), Esc is Interrupted.
pub fn raceH1(io: Io, h: *H1, poll_stdin: bool, budget: Budget) !void {
    var w: Watch = .init(io, budget);
    const Done = union(enum) { sent: anyerror!void, stall: http.WatchdogFired };
    var buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &buf);
    // #56 Fix-B: no slot for the request means no watchdog either. Nothing
    // is on the wire, so fail retryable instead of blocking the turn.
    sel.concurrent(.sent, h1Task, .{ h, &w }) catch return error.HungRequest;
    sel.concurrent(.stall, Watch.watch, .{ &w, poll_stdin }) catch {
        const r = sel.await() catch |e| {
            sel.cancelDiscard();
            return e;
        };
        sel.cancelDiscard();
        return r.sent;
    };
    const first = sel.await() catch |e| {
        sel.cancelDiscard();
        return e;
    };
    sel.cancelDiscard();
    switch (first) {
        .sent => |s| return s,
        .stall => |f| return http.watchdogError(f, error.HungRequest),
    }
}

test "staged budgets: defaults, body scaling and their caps (#1785)" {
    const small = Budget.init(4 * 1024, 30_000, 30_000, 120_000);
    try std.testing.expectEqual(@as(u64, 30_000), small.connect_ms);
    try std.testing.expectEqual(@as(u64, 30_000), small.upload_idle_ms);
    try std.testing.expectEqual(@as(u64, 30_000), small.upload_total_ms);
    try std.testing.expectEqual(@as(u64, 30_000), small.head_ms);
    // 1 MiB: 64 s of floor-rate upload, 16 s of queued tail for the head.
    const mib = Budget.init(1024 * 1024, 30_000, 30_000, 120_000);
    try std.testing.expectEqual(@as(u64, 30_000), mib.upload_idle_ms);
    try std.testing.expectEqual(@as(u64, 94_000), mib.upload_total_ms);
    try std.testing.expectEqual(@as(u64, 46_000), mib.head_ms);
    const huge = Budget.init(std.math.maxInt(usize), 30_000, 30_000, 120_000);
    try std.testing.expectEqual(max_upload_ms, huge.upload_total_ms);
    try std.testing.expectEqual(@as(u64, 120_000), huge.head_ms);
    // A widened loopback head wait is kept, not clamped to the read budget.
    try std.testing.expectEqual(@as(u64, 600_000), Budget.init(1024 * 1024, 30_000, 600_000, 120_000).head_ms);
    try std.testing.expectEqual(mib.upload_total_ms, mib.blind().upload_idle_ms);
}

test "staged expiry: upload ends on silence or its total, never on the head deadline (#1785)" {
    const b = Budget.init(1024 * 1024, 30_000, 30_000, 120_000);
    try std.testing.expect(!expired(b, .connect, 29_999, 29_999));
    try std.testing.expect(expired(b, .connect, 30_000, 0));
    // Still draining well past the head deadline: alive.
    try std.testing.expect(!expired(b, .upload, 80_000, 50));
    try std.testing.expect(expired(b, .upload, 1_000, 30_000));
    try std.testing.expect(expired(b, .upload, 94_000, 50));
    try std.testing.expect(!expired(b, .head, 45_999, 45_999));
    try std.testing.expect(expired(b, .head, 46_000, 0));
}
