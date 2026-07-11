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

/// POST the request body; returns the raw response body (caller frees).
/// std.http.Client.fetch is thread-safe, so subagents on pool threads share
/// this client (and its connection pool).
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

    const res = try client.fetch(.{
        .location = .{ .url = provider.url },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = providerUserAgent(provider),
        },
        .extra_headers = extra,
    });
    const code = @intFromEnum(res.status);
    if (code == 429 or code >= 500) {
        capture5xxBody(aw.writer.buffered());
        return if (code == 429) error.RateLimited else error.ServerError;
    }
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
/// connection is poisoned + re-dialed fresh on each retry (postStream/postWatched
/// errdefer), so these tries hit new sockets. 429/5xx throttles keep their longer
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
