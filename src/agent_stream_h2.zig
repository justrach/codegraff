//! HTTPS SSE over http-zig. Returns null to keep the std.http/1.1 path, but
//! only while the request provably never reached the server: the dial or the
//! send failed, the server did not pick h2 via ALPN, or it answered GOAWAY /
//! REFUSED_STREAM for our stream (RFC 9113 §8.7). Once the request is on the
//! wire any other failure is an error for request()'s retry loop -- falling
//! back would POST the same prompt twice and bill two generations.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const http = @import("http.zig");
const http_headers = @import("http_headers.zig");
const http_stall = @import("http_stall.zig");
const http2_pool = @import("http2_pool.zig");
const engine_sink = @import("engine_sink.zig");
const http_zig = @import("http_zig");
const WatchdogFired = http.WatchdogFired;
const watchdogError = http.watchdogError;
const deadlineStallTask = http.deadlineStallTask;
const headStallTask = http.headStallTask;

const ssePayload = Agent.ssePayload;
const escPressed = Agent.escPressed;
const openaiComplete = @import("agent_stream.zig").openaiComplete;
const isStreamEnd = @import("agent_stream.zig").isStreamEnd;

/// After the provider's terminal event, how long to wait for a trailing
/// END_STREAM (servers often send it as its own empty DATA frame) before
/// giving up on reusing the connection.
const trailing_end_ms: u64 = 500;

/// `poll_stdin`: the root REPL has stdin in raw non-blocking mode (set up by
/// agent_stream.postStream before either transport runs), so Esc and steering
/// keystrokes are polled here exactly as on the HTTP/1.1 path.
pub fn postStream(self: *Agent, body: []const u8, poll_stdin: bool) !?[]u8 {
    if (!http2_pool.want(self.provider.url)) return null;
    const origin = http2_pool.parseOrigin(self.provider.url) catch return null;
    if (http2_pool.knownH1(self.io, origin.host, origin.port)) return null;
    const gpa = self.gpa;
    const provider = self.provider;
    const bearer = switch (provider.auth) {
        .x_api_key, .goog_api_key => "",
        .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
    };
    defer if (bearer.len > 0) gpa.free(bearer);
    var headers_buf: [12]std.http.Header = undefined;
    var conv_buf: [96]u8 = undefined;
    const conv = http_headers.requestCacheKey(self.io, self.label, self, provider.id, &conv_buf);
    const extra = http_headers.providerHeadersWithConv(self.io, provider, bearer, &headers_buf, conv);

    var name_store: [16][64]u8 = undefined;
    var extras: [20]http_zig.Header = undefined;
    var n: usize = 0;
    extras[n] = .{ .name = "content-type", .value = "application/json" };
    n += 1;
    if (std.mem.eql(u8, provider.id, "kimi")) {
        extras[n] = .{ .name = "user-agent", .value = main_mod.kimi_user_agent };
        n += 1;
    }
    for (extra, 0..) |h, i| {
        if (i >= name_store.len or n >= extras.len) break;
        extras[n] = .{ .name = std.ascii.lowerString(&name_store[i], h.name), .value = h.value };
        n += 1;
    }

    var head: Head = .{
        .gpa = gpa,
        .io = self.io,
        .origin = origin,
        .openai = std.mem.startsWith(u8, provider.id, "openai"),
        .req = .{
            .method = "POST",
            .scheme = "https",
            .authority = origin.host,
            .path = origin.path,
            .extra = extras[0..n],
            .body = body,
        },
    };
    var keep = false;
    defer head.deinit(keep);

    // Dial, send and time-to-first-HEADERS race the head-stall watchdog, as
    // the HTTP/1.1 send + receiveHead do (issue #54): a half-open socket or a
    // server that accepts the stream and goes silent must not hang the turn.
    switch (try raceHead(self.io, &head, poll_stdin)) {
        .ok => {},
        .fallback => return null,
    }
    if (head.status == 429) return error.RateLimited;
    if (head.status >= 500) return error.ServerError;
    if (head.status == 404 and head.openai) return error.OpenAiFlaky404;
    // Esc pressed while connecting / waiting for headers? Stop before the body.
    if (poll_stdin and escPressed(true)) return error.Interrupted;
    const lines = &head.lines.?;

    // Any other status streams its body like the HTTP/1.1 path does: a 4xx
    // error envelope is what request()'s parser classifies.
    const sink = engine_sink.forAgent(self);
    var full: Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var loop_guard: @import("agent_model_loop.zig").Stream = .{};
    var got_body = false;
    var saw_done = false;

    while (true) {
        const stall_budget = http_stall.interFrameBudgetMs(http.stream_stall_ms, got_body, self.partial_text.items.len != 0, self.stall.widen);
        const got = raceLine(self.io, lines, &line, gpa, poll_stdin, stall_budget) orelse {
            // #56 Fix-B: no spare concurrency for the read. Fail safe.
            if (saw_done) break;
            self.stall.tripped_ms = stall_budget;
            sink.emit(self.io, .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = false } });
            return error.StreamStalled;
        };
        switch (got) {
            .line => |r| {
                const more = r catch |e| {
                    if (e == error.Canceled) return e;
                    if (saw_done) break;
                    if (got_body) {
                        sink.emit(self.io, .{ .stream_aborted = .dropped });
                        return error.StreamDropped;
                    }
                    return e;
                };
                if (!more) {
                    keep = lines.ended;
                    break;
                }
            },
            .stall => |w| {
                if (w == .deadline and saw_done) break;
                if (w == .deadline) self.stall.tripped_ms = stall_budget;
                if (w == .deadline) sink.emit(self.io, .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = false } }) else sink.emit(self.io, .{ .stream_aborted = .interrupted });
                return watchdogError(w, error.StreamStalled);
            },
        }
        if (ssePayload(line.items)) |payload|
            try loop_guard.event(self, payload, true);
        try full.writer.writeAll(line.items);
        try full.writer.writeByte('\n');
        got_body = true;
        self.printDelta(line.items);
        if (main_mod.g_thinking_fold_request) {
            main_mod.g_thinking_fold_request = false;
            sink.emit(self.io, .thinking_fold_toggle);
        }
        if (self.provider.kind == .openai and openaiComplete(line.items)) saw_done = true;
        if (isStreamEnd(self.scratchAlloc(), self.provider.kind, line.items)) {
            saw_done = true;
            keep = settleAfterEnd(self.io, lines, gpa);
            break;
        }
        if ((poll_stdin and escPressed(true)) or (self.sub and Agent.esc_cancel.load(.acquire))) {
            sink.emit(self.io, .{ .stream_aborted = .interrupted });
            return error.Interrupted;
        }
    }
    // A connection the peer is draining (GOAWAY) takes no new streams.
    keep = keep and head.lease.?.session.reusable();
    sink.emit(self.io, .{ .stream_complete = .{ .streamed_text = self.streamed_text } });
    return try full.toOwnedSlice();
}

/// Where the head task got to. Only failures before the request is complete
/// on the wire (or that the server proves it never processed) may fall back.
const Phase = enum { dial, send, wait };

/// State the head task fills and postStream owns. Select.cancelDiscard waits
/// for the task, so deinit always sees a settled lease/lines pair, whether the
/// task succeeded, failed or was cancelled by the watchdog.
const Head = struct {
    gpa: std.mem.Allocator,
    io: Io,
    origin: http2_pool.Origin,
    openai: bool,
    req: http_zig.Request,
    phase: Phase = .dial,
    lease: ?http2_pool.Lease = null,
    lines: ?http_zig.LineStream = null,
    status: u16 = 0,

    fn deinit(self: *Head, keep: bool) void {
        if (self.lines) |*l| l.deinit();
        if (self.lease) |l| l.release(keep);
    }
};

const HeadResult = enum { ok, fallback };

fn raceHead(io: Io, head: *Head, poll_stdin: bool) !HeadResult {
    const HeadDone = union(enum) { done: anyerror!void, stall: WatchdogFired };
    var hd_buf: [2]HeadDone = undefined;
    var hsel: Io.Select(HeadDone) = .init(io, &hd_buf);
    // #56 Fix-B: no slot for the task means no watchdog either. Nothing has
    // been sent, so fail retryable instead of blocking the turn.
    hsel.concurrent(.done, headTask, .{head}) catch return error.HungRequest;
    hsel.concurrent(.stall, headStallTask, .{ io, poll_stdin }) catch {};
    const first = hsel.await() catch |e| {
        hsel.cancelDiscard();
        return e;
    };
    hsel.cancelDiscard();
    switch (first) {
        .stall => |w| return watchdogError(w, error.HungRequest),
        .done => |r| {
            r catch |e| {
                if (e == error.Canceled) return e;
                if (head.lease) |l| if (l.session.h1_only) http2_pool.noteH1(io, head.origin.host, head.origin.port);
                if (mayResendOnH1(head.phase, e)) return .fallback;
                return e;
            };
            return .ok;
        },
    }
}

/// Falling back to HTTP/1.1 re-sends the POST, so it is allowed only when
/// the server cannot have acted on it: the body never fully left (dial or
/// send failed), or it said so -- GOAWAY above our stream id, REFUSED_STREAM.
fn mayResendOnH1(phase: Phase, err: anyerror) bool {
    if (err == error.Canceled) return false;
    if (phase != .wait) return true;
    return err == error.GoAway or err == error.StreamRefused;
}

test "HTTP/1.1 fallback only when the request provably never reached the server" {
    try std.testing.expect(mayResendOnH1(.dial, error.ConnectionRefused));
    try std.testing.expect(mayResendOnH1(.dial, error.H1NoStream));
    try std.testing.expect(mayResendOnH1(.send, error.WriteFailed));
    try std.testing.expect(mayResendOnH1(.wait, error.GoAway));
    try std.testing.expect(mayResendOnH1(.wait, error.StreamRefused));
    // Sent and possibly generating: retry via request(), never a silent re-POST.
    try std.testing.expect(!mayResendOnH1(.wait, error.EndOfStream));
    try std.testing.expect(!mayResendOnH1(.wait, error.RstStream));
    try std.testing.expect(!mayResendOnH1(.wait, error.ReadFailed));
    // A cancel is never turned into a replacement request.
    try std.testing.expect(!mayResendOnH1(.dial, error.Canceled));
    try std.testing.expect(!mayResendOnH1(.send, error.Canceled));
}

fn headTask(head: *Head) anyerror!void {
    head.phase = .dial;
    head.lease = try http2_pool.acquire(head.gpa, head.io, head.origin.host, head.origin.port);
    const sess = head.lease.?.session;
    if (sess.h1_only) return error.H1NoStream;
    head.phase = .send;
    head.lines = try sess.startLines(head.req);
    head.phase = .wait;
    const lines = &head.lines.?;
    head.status = try lines.waitStatus();
    // Error bodies are read here, still under the head watchdog: request()
    // classifies quota/overflow from the snippet and honours Retry-After.
    const throttled = head.status == 429 or head.status >= 500;
    if (throttled) main_mod.g_retry_after_ms = http.retryAfterMs(lines.header("retry-after"), lines.header("retry-after-ms"));
    if (throttled or (head.status == 404 and head.openai)) captureErrorBody(head.gpa, lines);
}

/// Same contract as http.capture5xxBodyStream: up to g_5xx_body_buf.len bytes
/// of the body, lines joined without their newlines; best effort.
fn captureErrorBody(gpa: std.mem.Allocator, lines: *http_zig.LineStream) void {
    main_mod.g_5xx_body_len = 0;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    while (main_mod.g_5xx_body_len < main_mod.g_5xx_body_buf.len) {
        const more = lines.readLine(&line) catch break;
        if (!more) break;
        const n = @min(line.items.len, main_mod.g_5xx_body_buf.len - main_mod.g_5xx_body_len);
        @memcpy(main_mod.g_5xx_body_buf[main_mod.g_5xx_body_len..][0..n], line.items[0..n]);
        main_mod.g_5xx_body_len += n;
    }
}

const ReadDone = union(enum) { line: anyerror!bool, stall: WatchdogFired };

/// One readLine raced against the between-lines watchdog. Null when there is
/// no concurrency slot for the read at all.
fn raceLine(io: Io, lines: *http_zig.LineStream, line: *std.ArrayList(u8), gpa: std.mem.Allocator, poll_stdin: bool, budget_ms: u64) ?ReadDone {
    var rd_buf: [2]ReadDone = undefined;
    var rsel: Io.Select(ReadDone) = .init(io, &rd_buf);
    rsel.concurrent(.line, lineTask, .{ lines, line, gpa }) catch return null;
    rsel.concurrent(.stall, deadlineStallTask, .{ io, poll_stdin, budget_ms }) catch {};
    const first = rsel.await() catch |e| {
        rsel.cancelDiscard();
        return .{ .line = e };
    };
    rsel.cancelDiscard();
    return first;
}

/// The terminal event landed. Reuse the connection only if END_STREAM
/// follows promptly; a server that holds the stream open costs one dial.
fn settleAfterEnd(io: Io, lines: *http_zig.LineStream, gpa: std.mem.Allocator) bool {
    var junk: std.ArrayList(u8) = .empty;
    defer junk.deinit(gpa);
    while (true) {
        if (lines.ended) {
            while (lines.readLine(&junk) catch return false) {}
            return true;
        }
        const got = raceLine(io, lines, &junk, gpa, false, trailing_end_ms) orelse return false;
        switch (got) {
            .line => |r| if (!(r catch return false)) return lines.ended,
            .stall => return false,
        }
    }
}

fn lineTask(ls: *http_zig.LineStream, dest: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
    _ = gpa;
    return ls.readLine(dest);
}
