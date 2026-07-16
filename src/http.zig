//! HTTP transport for model calls: per-provider auth headers, the raw POST,
//! the 5xx-body capture, and the Esc/deadline watchdogs that race the
//! send/receive/stream select-arms so a stalled request can't hang a turn.
//! Split out of main.zig (600-line goal). Back-imports main for Provider, the
//! Agent Esc-cancel signal + steer-stdin drain, the anthropic/kimi UA consts,
//! and the shared g_5xx error-body buffer (which stays in main).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const provider_mod = @import("provider.zig");
const agent_mod = @import("agent.zig");
const Provider = provider_mod.Provider;
const Agent = agent_mod.Agent;
const anthropic_version = root.anthropic_version;
const kimi_user_agent = root.kimi_user_agent;

/// Launch-scoped gate installed while the shared client's CA bundle warms in
/// the background. Null in unit tests and standalone pre-client subcommands.
pub var g_client_ready: ?*Io.Event = null;

pub fn waitForClientReady(io: Io) void {
    if (g_client_ready) |ready| ready.waitUncancelable(io);
}

pub fn providerUserAgent(provider: Provider) std.http.Client.Request.Headers.Value {
    if (std.mem.eql(u8, provider.id, "kimi")) {
        return .{ .override = kimi_user_agent };
    }
    return .default;
}
pub fn providerHeaders(provider: Provider, bearer: []const u8, buf: *[6]std.http.Header) []const std.http.Header {
    var n: usize = 0;
    switch (provider.auth) {
        .x_api_key => {
            buf[n] = .{ .name = "x-api-key", .value = provider.api_key };
            n += 1;
        },
        .bearer => {
            buf[n] = .{ .name = "authorization", .value = bearer };
            n += 1;
        },
    }
    // Anthropic-format endpoints also get the anthropic-version header
    // (harmless extra for compatible providers).
    if (provider.kind == .anthropic) {
        buf[n] = .{ .name = "anthropic-version", .value = anthropic_version };
        n += 1;
    }
    // Codex / ChatGPT backend: identify as the codex client and carry the
    // ChatGPT account id + Responses beta opt-in.
    if (provider.kind == .responses) {
        buf[n] = .{ .name = "chatgpt-account-id", .value = provider.account };
        n += 1;
        buf[n] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
        n += 1;
        buf[n] = .{ .name = "originator", .value = "codex_cli_rs" };
        n += 1;
        buf[n] = .{ .name = "session_id", .value = "00000000-0000-0000-0000-000000000001" };
        n += 1;
    }
    return buf[0..n];
}

/// Copy up to root.g_5xx_body_buf.len bytes of an error response body into the
/// global buffer so request()'s retry message can surface the gateway's
/// diagnostic (e.g. "upstream timeout connecting to anthropic") instead of a
/// bare "server error (5xx)".
fn capture5xxBody(src: []const u8) void {
    const n = @min(src.len, root.g_5xx_body_buf.len);
    if (n > 0) @memcpy(root.g_5xx_body_buf[0..n], src[0..n]);
    root.g_5xx_body_len = n;
}

/// Same, but drains from a streaming Response whose head has been received but
/// whose body hasn't been read yet. Best-effort: a read failure just leaves
/// root.g_5xx_body_len at 0.
pub fn capture5xxBodyStream(gpa: Allocator, response: *std.http.Client.Response) void {
    root.g_5xx_body_len = 0;
    const dbuf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len) catch return,
        .deflate, .gzip => gpa.alloc(u8, std.compress.flate.max_window_len) catch return,
        .compress => return,
    };
    defer if (dbuf.len > 0) gpa.free(dbuf);
    var tbuf: [64]u8 = undefined;
    var dec: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&tbuf, &dec, dbuf);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    while (root.g_5xx_body_len < root.g_5xx_body_buf.len) {
        _ = reader.streamDelimiterEnding(&aw.writer, '\n') catch break;
        const chunk = aw.writer.buffered();
        if (chunk.len == 0) break;
        const n = @min(chunk.len, root.g_5xx_body_buf.len - root.g_5xx_body_len);
        @memcpy(root.g_5xx_body_buf[root.g_5xx_body_len..][0..n], chunk[0..n]);
        root.g_5xx_body_len += n;
        aw.clearRetainingCapacity();
    }
}

/// Max backoff we honor from a provider's Retry-After (429/503), mirroring
/// opencode's default cap. A larger server value is clamped to this.
pub const retry_after_cap_ms: u64 = 30_000;

/// Pure: resolve Retry-After headers to a backoff in ms (0 = none/unparseable).
/// Prefers the millisecond form (`retry-after-ms`, which Anthropic/OpenAI send on
/// 429s); `retry-after` is integer seconds — the HTTP-date form is ignored (0),
/// falling back to our own exponential backoff. Capped at retry_after_cap_ms.
pub fn retryAfterMs(retry_after: ?[]const u8, retry_after_ms: ?[]const u8) u64 {
    if (retry_after_ms) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |ms| return @min(ms, retry_after_cap_ms) else |_| {}
    }
    if (retry_after) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| return @min(secs *| 1000, retry_after_cap_ms) else |_| {}
    }
    return 0;
}

/// Capture a 429/503 response's Retry-After into g_retry_after_ms so request()'s
/// throttle backoff waits exactly as long as the server asked (#retry-after).
pub fn captureRetryAfter(response: *std.http.Client.Response) void {
    var ra: ?[]const u8 = null;
    var ra_ms: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            ra = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "retry-after-ms")) {
            ra_ms = h.value;
        }
    }
    root.g_retry_after_ms = retryAfterMs(ra, ra_ms);
}

test "retryAfterMs: seconds, ms preferred, cap, HTTP-date/none -> 0 (#retry-after)" {
    try std.testing.expectEqual(@as(u64, 5000), retryAfterMs("5", null)); // integer seconds
    try std.testing.expectEqual(@as(u64, 1500), retryAfterMs(null, "1500")); // millisecond form
    try std.testing.expectEqual(@as(u64, 1500), retryAfterMs("60", "1500")); // ms preferred over seconds
    try std.testing.expectEqual(@as(u64, retry_after_cap_ms), retryAfterMs("120", null)); // 120s clamped to 30s
    try std.testing.expectEqual(@as(u64, 3000), retryAfterMs(" 3 ", null)); // whitespace-trimmed
    try std.testing.expectEqual(@as(u64, 0), retryAfterMs(null, null)); // no header -> our backoff
    try std.testing.expectEqual(@as(u64, 0), retryAfterMs("Wed, 21 Oct 2025 07:28:00 GMT", null)); // HTTP-date form ignored
}

/// POST the request body; returns the raw response body (caller frees).
/// Built on client.request, NOT client.fetch: fetch never exposes the
/// Request, so a failed body send could not be poisoned — std re-pooled the
/// dead connection (a failed SEND leaves reader.state == .ready, which
/// Request.deinit reads as "still clean") and findConnection handed the same
/// corpse to every retry and every later same-host request, so one
/// WriteFailed became a whole-session storm across compaction, [title], and
/// subagents (#177). Mirrors postStream's errdefer poison (agent_stream.zig).
/// The client and its connection pool stay shared across pool threads —
/// client.request is what fetch wraps and is equally thread-safe.
fn post(gpa: Allocator, client: *std.http.Client, provider: Provider, body: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    const bearer = switch (provider.auth) {
        .x_api_key => "",
        .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
    };
    defer if (bearer.len > 0) gpa.free(bearer);

    var headers_buf: [6]std.http.Header = undefined;
    const extra = providerHeaders(provider, bearer, &headers_buf);

    var req = try client.request(.POST, try std.Uri.parse(provider.url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = providerUserAgent(provider),
        },
        .extra_headers = extra,
    });
    defer req.deinit();
    // The #177 poison: on ANY error make deinit discard this connection
    // instead of returning it to the keep-alive pool, so the retry (and
    // every later request to this host) dials fresh.
    errdefer if (req.connection) |conn| {
        conn.closing = true;
    };

    var response: std.http.Client.Response = undefined;
    try sendHeadTask(&req, body, &response);

    const code = @intFromEnum(response.head.status);
    if (code == 429 or code >= 500) {
        // Drain a snippet of the error body for the retry message, then
        // poison: the connection still holds unread body bytes.
        captureRetryAfter(&response); // #retry-after: honor the provider's requested backoff
        capture5xxBodyStream(gpa, &response);
        if (req.connection) |conn| conn.closing = true;
        return if (code == 429) error.RateLimited else error.ServerError;
    }

    // #opencode-parity: OpenAI proper spuriously 404s models that are actually
    // available — treat a 404 from an openai-* provider as a retryable server blip
    // (poison the connection so the retry dials fresh), like a 5xx.
    if (code == 404 and std.mem.startsWith(u8, provider.id, "openai")) {
        capture5xxBodyStream(gpa, &response);
        if (req.connection) |conn| conn.closing = true;
        return error.OpenAiFlaky404;
    }

    // Any other status (200 or a 4xx API error envelope): return the body —
    // request() parses error envelopes out of non-2xx JSON itself.
    const dbuf: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (dbuf.len > 0) gpa.free(dbuf);
    var tbuf: [64]u8 = undefined;
    var dec: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&tbuf, &dec, dbuf);
    _ = try reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

/// Hard ceiling on one non-streaming request. The legitimate worst case
/// observed (a 160k-token subagent context) completed in ~134s; anything
/// past this is a hung response, not a slow one.
const post_deadline_ms: u64 = 5 * 60 * 1000;

pub const WatchdogFired = enum { esc, deadline };

/// Classify a fired stream/head watchdog into an error. A user Esc is a
/// deliberate cancel — error.Interrupted, which request()'s retry loop never
/// retries and mainloop records as a user interruption. A `.deadline` is a
/// dead/idle connection, NOT the user: the caller passes the error it wants
/// for that case (HungRequest to retry the head, StreamStalled to end the
/// turn). This is the seam that keeps a stall from being mislabeled as an
/// Esc — the root cause of #134.
pub fn watchdogError(w: WatchdogFired, on_deadline: anyerror) anyerror {
    return if (w == .esc) error.Interrupted else on_deadline;
}

test "watchdogError (#134): Esc -> Interrupted; a deadline is the caller's error, never Interrupted" {
    // A real user Esc is always a deliberate interrupt, whatever the caller's deadline error.
    try std.testing.expect(watchdogError(.esc, error.HungRequest) == error.Interrupted);
    try std.testing.expect(watchdogError(.esc, error.StreamStalled) == error.Interrupted);
    // A deadline (idle/dead connection) surfaces as whatever the caller chose:
    // HungRequest for the head (retry), StreamStalled for a mid-stream stall (end turn).
    try std.testing.expect(watchdogError(.deadline, error.HungRequest) == error.HungRequest);
    try std.testing.expect(watchdogError(.deadline, error.StreamStalled) == error.StreamStalled);
    // The #134 regression guard: a stall must NEVER be reported as a user Esc.
    try std.testing.expect(watchdogError(.deadline, error.StreamStalled) != error.Interrupted);
}

/// Watchdog arm for postWatched: ticks every 200ms so a user Esc aborts a
/// stuck subagent request promptly; otherwise fires at the hard deadline.
fn postWatchdog(io: Io) WatchdogFired {
    var waited: u64 = 0;
    while (waited < post_deadline_ms) {
        io.sleep(.fromMilliseconds(200), .awake) catch return .deadline; // canceled: loser arm, result discarded
        waited += 200;
        if (Agent.esc_cancel.load(.acquire)) return .esc;
    }
    return .deadline;
}

// A streaming response idle THIS LONG between SSE events (not total response
// time — streamStallTask resets its clock on every line, so it measures the
// gap between tokens/keep-alives/reasoning deltas) is treated as a dead or
// hung connection and given up on, so a turn can't wait forever. Generous, so
// a legit reasoning pause between tokens doesn't trip it; a model that streams
// — even slowly — never does, since each event resets the clock. Only TOTAL
// silence trips it. Tunable via GRAFF_STREAM_STALL_SECS (wired in
// session_run.setupSkillsAndTheme) for providers that buffer a long reasoning
// phase in complete silence. Giving up here is error.StreamStalled — a
// harness stall, NEVER a user Esc interruption (#134).
pub var stream_stall_ms: u64 = 120 * 1000;

/// A response head (HTTP status line + headers) idle this long means the
/// server accepted the connection but isn't responding — common right
/// after a keep-alive drop that caused an HttpConnectionClosing retry.
/// Shorter than stream_stall_ms because the head should arrive in
/// milliseconds; any delay past this is a stall, not a slow model.
const head_stall_ms: u64 = 30 * 1000;

/// Retry policy for request() after a failed attempt. Transport flakes
/// (HttpConnectionClosing / WriteFailed / reset / truncated TLS) are now far
/// more patient: a real network blip (wifi hiccup, gateway redeploy) outlasts
/// the old 3-try / ~1.75s window and was wrongly giving up the whole turn. The
/// connection is poisoned + re-dialed fresh on each retry (postStream's and
/// post()'s errdefer — the latter since #177; this comment used to claim a
/// postWatched poison that was never implemented, which is exactly how one
/// dead pooled connection could fail all 6 tries). 429/5xx throttles keep their longer
/// server-directed waits.
pub const RetryPlan = struct {
    /// Total attempts before the turn gives up.
    pub fn maxAttempts(throttled: bool) usize {
        return if (throttled) 5 else 6;
    }
    /// Backoff (ms) before the attempt following `attempt` (0-based).
    /// throttle: 1Â·2Â·4Â·8Â·8 s. flake: .25Â·.5Â·1Â·2Â·4Â·4 s (~7.75s total).
    pub fn delayMs(throttled: bool, attempt: usize) u64 {
        return if (throttled)
            @min(@as(u64, 1000) << @intCast(@min(attempt, 3)), 8000)
        else
            @min(@as(u64, 250) << @intCast(@min(attempt, 4)), 4000);
    }
};

test "retry policy: transport flakes get 6 patient tries, throttles keep 5 (network give-up fix)" {
    // The WriteFailed/HttpConnectionClosing give-up bailed at 3 tries (~1.75s) —
    // too short for a transient blip. Now 6 tries spanning ~7.75s.
    try std.testing.expectEqual(@as(usize, 6), RetryPlan.maxAttempts(false));
    const flake = [_]u64{ 250, 500, 1000, 2000, 4000 }; // backoff before tries 2..6
    for (flake, 0..) |want, a| try std.testing.expectEqual(want, RetryPlan.delayMs(false, a));
    // 429/5xx throttles unchanged: 5 tries, 1-2-4-8-8 s.
    try std.testing.expectEqual(@as(usize, 5), RetryPlan.maxAttempts(true));
    const throttle = [_]u64{ 1000, 2000, 4000, 8000 };
    for (throttle, 0..) |want, a| try std.testing.expectEqual(want, RetryPlan.delayMs(true, a));
}

/// Select-arm wrapper: send the request body and receive the response head.
/// Stores the response in `out` for the main thread to use after the select.
pub fn sendHeadTask(req: *std.http.Client.Request, body: []const u8, out: *std.http.Client.Response) anyerror!void {
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
    out.* = try req.receiveHead(&.{});
}

/// Select-arm wrapper: read one '\n'-delimited SSE line into `w`.
pub fn streamLineTask(reader: *Io.Reader, w: *Io.Writer) anyerror!usize {
    return reader.streamDelimiterEnding(w, '\n');
}

/// Select-arm wrapper: fires after stream_stall_ms of no line (idle stall), or
/// early on Esc — resets each line, so it measures the gap between lines.
pub fn streamStallTask(io: Io, poll_stdin: bool) WatchdogFired {
    var waited: u64 = 0;
    while (waited < stream_stall_ms) {
        io.sleep(.fromMilliseconds(50), .awake) catch return .deadline; // canceled: a line arrived
        waited += 50;
        if (poll_stdin and Agent.drainSteerStdin(true)) {
            Agent.esc_cancel.store(true, .release);
            return .esc;
        }
        if (Agent.esc_cancel.load(.acquire)) return .esc;
    }
    return .deadline;
}

/// Select-arm wrapper: fires after head_stall_ms (head receive stall), or
/// early on Esc. Races postStream's send + receiveHead so a freshly-redialed
/// connection that the server accepts but never answers can't hang the turn
/// (the root cause of the "retrying (1/3)" → "thinking… forever" bug).
pub fn headStallTask(io: Io, poll_stdin: bool) WatchdogFired {
    var waited: u64 = 0;
    while (waited < head_stall_ms) {
        io.sleep(.fromMilliseconds(50), .awake) catch return .deadline;
        waited += 50;
        if (poll_stdin and Agent.drainSteerStdin(true)) {
            Agent.esc_cancel.store(true, .release);
            return .esc;
        }
        if (Agent.esc_cancel.load(.acquire)) return .esc;
    }
    return .deadline;
}

/// Select-arm wrapper for `post` (pins the member type to anyerror![]u8).
fn postTask(gpa: Allocator, client: *std.http.Client, provider: Provider, body: []const u8) anyerror![]u8 {
    return post(gpa, client, provider, body);
}

/// Cancel the remaining select arms, freeing a late-arriving response body
/// (cancelDiscard would leak it — see Io.Select.cancel docs).
fn drainPostSelect(gpa: Allocator, sel: anytype) void {
    while (sel.cancel()) |late| switch (late) {
        .posted => |p| {
            if (p) |b| gpa.free(b) else |_| {}
        },
        .watchdog => {},
    };
}

/// Non-streaming POST raced against a watchdog. A bare `post` can block
/// forever on a stalled response — a hung subagent request once wedged an
/// entire workflow await, with no Esc path into the child's HTTP call.
/// Esc surfaces as error.Interrupted (no retry); the deadline as
/// error.HungRequest, which request()'s retry loop treats as a transport
/// flake. Falls back to a bare post when no spare concurrency exists.
pub fn postWatched(gpa: Allocator, io: Io, client: *std.http.Client, provider: Provider, body: []const u8) ![]u8 {
    const Done = union(enum) { posted: anyerror![]u8, watchdog: WatchdogFired };
    var done_buf: [2]Done = undefined;
    var sel: Io.Select(Done) = .init(io, &done_buf);
    sel.concurrent(.posted, postTask, .{ gpa, client, provider, body }) catch
        return error.HungRequest; // #56 Fix-B: pool exhausted — don't fall back to a bare blocking post() that can hang a subagent turn with no Esc path; return retryable so request() retries + backs off
    sel.concurrent(.watchdog, postWatchdog, .{io}) catch {
        const r = sel.await() catch |e| { // posted is the only arm
            sel.cancelDiscard();
            return e;
        };
        sel.cancelDiscard();
        return r.posted;
    };
    const first = sel.await() catch |e| {
        drainPostSelect(gpa, &sel);
        return e;
    };
    drainPostSelect(gpa, &sel);
    return switch (first) {
        .posted => |p| p,
        .watchdog => |w| watchdogError(w, error.HungRequest),
    };
}

// #177 regression: a POST whose body SEND fails must NOT return its dead
// connection to the keep-alive pool. Before the fix (post() built on
// client.fetch), std re-pooled it — a failed send leaves reader.state ==
// .ready, which Request.deinit reads as "still clean" — and findConnection
// handed the same corpse to every retry and every later same-host request
// (compaction, [title], subagents): WriteFailed forever after. Real loopback
// server: connection 1 is accepted and closed unread, so the large body send
// hits a reset mid-flight; only a poisoned pool makes request 2 dial a fresh
// connection 2 and reach the 200.
test "post (#177): a send-failed connection is not re-pooled — the next request dials fresh" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Windows loopback RST timing is non-deterministic: a forced send failure
    // can surface as LOCAL_DISCONNECT (or defer to the head read) and flake.
    // The poison logic is validated deterministically on POSIX.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const Srv = struct {
        fn run(io_: Io, server: *std.Io.net.Server) void {
            // conn 1: close before reading anything. The client's
            // multi-megabyte body overruns the socket buffers, the kernel
            // resets data arriving on the closed socket, and the send fails
            // mid-write — the same shape as the codex backend killing an
            // over-cap request at write time (#163).
            const c1 = server.accept(io_) catch return;
            c1.close(io_);

            // conn 2 only ever arrives on a fresh dial: drain the (tiny)
            // request, then serve a minimal 200.
            const c2 = server.accept(io_) catch return;
            defer c2.close(io_);
            var rbuf: [4096]u8 = undefined;
            var sr = std.Io.net.Stream.Reader.init(c2, io_, &rbuf);
            while (true) {
                const line = (sr.interface.takeDelimiter('\n') catch break) orelse break;
                if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break; // end of headers
            }
            _ = sr.interface.take(2) catch {}; // the 2-byte "{}" body
            var wbuf: [256]u8 = undefined;
            var sw = std.Io.net.Stream.Writer.init(c2, io_, &wbuf);
            sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok") catch {};
            sw.interface.flush() catch {};
        }
    };

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    var fut = io.async(Srv.run, .{ io, &server });
    defer fut.await(io);
    defer server.deinit(io);

    var bound = server.socket.address;
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/x", .{bound.getPort()});
    const provider: Provider = .{
        .id = "test",
        .kind = .openai,
        .auth = .x_api_key,
        .url = url,
        .api_key = "k",
        .model = "m",
        .context = 0,
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // Large enough that the send cannot complete inside socket buffers, so
    // the closed conn 1 fails the WRITE (the #177 signature) rather than
    // buffering silently and failing later at the head read.
    const big = try gpa.alloc(u8, 8 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    // The send to a closed peer MUST fail — a success is the only wrong outcome.
    // The specific error is platform-dependent: on POSIX the 8 MB body overruns
    // the socket buffers so the reset fails the WRITE (error.WriteFailed, the
    // #177 signature); on Windows the body buffers and the reset instead
    // surfaces as a read-side error at receiveHead. Either way post()'s errdefer
    // poisoned the connection, and the real assertion is that the NEXT request
    // recovers (below). Only an unexpected success needs the throwaway dial, to
    // release the server's still-pending second accept() so await can't hang.
    if (post(gpa, &client, provider, big)) |resp| {
        gpa.free(resp);
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return error.TestExpectedError;
    } else |_| {}

    // The regression: without the poison this pulls dead conn 1 back out of
    // the pool (no fresh dial) and fails with WriteFailed instead of
    // reaching conn 2's 200.
    const second = post(gpa, &client, provider, "{}");
    if (second) |resp| {
        defer gpa.free(resp);
        try std.testing.expectEqualStrings("ok", resp);
    } else |err| {
        // Regression path: conn 2 never arrived, so the server task is still
        // blocked in accept — release it with a throwaway dial before
        // failing, or the deferred await would hang the test binary.
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return err;
    }
}

// post's 429/5xx branch: an oversized error body is partial-drained
// (capture5xxBodyStream stops at the 600-byte g_5xx_body_buf), the request
// surfaces as error.ServerError, and the session recovers on the next request.
// This is the dominant real-world failure (gateway throttles / 500s), and
// before this test the whole 5xx branch was uncovered. NOTE: unlike the
// send-failed case above, std will NOT re-pool a partially-read response
// connection on its own, so post's explicit 5xx poison is defensive; this test
// exercises the path end-to-end rather than isolating that poison. The
// load-bearing poison regression — a failed SEND that leaves the reader
// deceptively .ready so std DOES re-pool the corpse — is the test above.
test "post (#177 5xx path): an oversized 5xx surfaces as ServerError and the session recovers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Windows loopback RST timing is non-deterministic: a forced connection
    // reset can surface as LOCAL_DISCONNECT mid-recovery, flaking this timing
    // test. The poison logic is validated deterministically on POSIX.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    // A 5xx body well over the 600-byte capture buffer, with newlines so
    // capture5xxBodyStream grabs a snippet and stops, leaving the rest unread.
    var body500: [4096]u8 = undefined;
    {
        const line = "upstream gateway error (simulated 5xx)\n";
        for (&body500, 0..) |*b, i| b.* = line[i % line.len];
    }

    const Srv = struct {
        fn readReq(sr: *std.Io.net.Stream.Reader) void {
            while (true) {
                const l = (sr.interface.takeDelimiter('\n') catch return) orelse return;
                if (l.len == 0 or (l.len == 1 and l[0] == '\r')) break; // end of headers
            }
            _ = sr.interface.take(2) catch {}; // the 2-byte "{}" body
        }
        fn run(io_: Io, server: *std.Io.net.Server, body: []const u8) void {
            // conn 1: keep-alive 500 (no `connection: close`) with an oversized
            // body — without the poison std would re-pool this half-read corpse.
            const c1 = server.accept(io_) catch return;
            {
                defer c1.close(io_);
                var rbuf: [4096]u8 = undefined;
                var sr = std.Io.net.Stream.Reader.init(c1, io_, &rbuf);
                readReq(&sr);
                var hbuf: [96]u8 = undefined;
                const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 500 Internal Server Error\r\ncontent-length: {d}\r\n\r\n", .{body.len}) catch return;
                var wbuf: [1024]u8 = undefined;
                var sw = std.Io.net.Stream.Writer.init(c1, io_, &wbuf);
                sw.interface.writeAll(head) catch {};
                sw.interface.writeAll(body) catch {};
                sw.interface.flush() catch {};
            }
            // conn 2 only ever arrives on a fresh dial (the poison worked).
            const c2 = server.accept(io_) catch return;
            defer c2.close(io_);
            var rbuf: [4096]u8 = undefined;
            var sr = std.Io.net.Stream.Reader.init(c2, io_, &rbuf);
            readReq(&sr);
            var wbuf: [256]u8 = undefined;
            var sw = std.Io.net.Stream.Writer.init(c2, io_, &wbuf);
            sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok") catch {};
            sw.interface.flush() catch {};
        }
    };

    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    var fut = io.async(Srv.run, .{ io, &server, @as([]const u8, &body500) });
    defer fut.await(io);
    defer server.deinit(io);

    var bound = server.socket.address;
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/x", .{bound.getPort()});
    const provider: Provider = .{
        .id = "test",
        .kind = .openai,
        .auth = .x_api_key,
        .url = url,
        .api_key = "k",
        .model = "m",
        .context = 0,
    };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // The 5xx surfaces as error.ServerError and poisons conn 1. Guard the
    // assertion the same way as the send-failed test: on any other outcome,
    // release the server's still-pending second accept() before failing.
    if (post(gpa, &client, provider, "{}")) |resp| {
        gpa.free(resp);
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return error.TestExpectedError; // a 500 must surface as ServerError
    } else |err| if (err != error.ServerError) {
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return err;
    }

    // Recovery: the next request reaches conn 2's 200. (Unlike the send-failed
    // case above, std does not re-pool a partially-read connection on its own,
    // so this asserts end-to-end recovery, not that the 5xx poison is required.)
    const second = post(gpa, &client, provider, "{}");
    if (second) |resp| {
        defer gpa.free(resp);
        try std.testing.expectEqualStrings("ok", resp);
    } else |err| {
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return err;
    }
}
