//! Gateway-artifact retry policy + retry trace attribution (#gateway-artifact).
//!
//! Split out of agent_request.zig / agent_request_policy.zig for the 600-line
//! ceiling (AGENTS.md). Two concerns live here:
//!
//! 1. A 4xx body-parse rejection ("Body must be valid JSON") arriving right
//!    after consecutive transport timeouts indicts the gateway, not the
//!    request — the body bytes do not change between attempts — so it is
//!    retried bounded instead of killing the turn. Without the timeout
//!    history it stays a fail-fast 400, exactly as before.
//! 2. Retry trace notes carry the agent label, so a 5xx can be attributed to
//!    the subagent that drew it without ms-arithmetic across api spans.
//! 3. A short generic `api_error` / "Internal Server Error" / empty envelope
//!    (the DeepSeek flash `-j 6` follow-up flake) is retried bounded. The
//!    same 110-byte / ~450ms follow-up also arrives as `invalid_request_error`
//!    / "Body must be valid JSON" (our stringify just succeeded on call 1).
//!    That phrase is a flake; auth / quota / a real invalid prompt stay
//!    fail-fast.
//! 4. The transient-server ladder (overloaded / server_error, and xAI's
//!    mid-stream "Internal error during token parsing" — ADR 0148): a 5xx that
//!    surfaced in-band is retried 3× with 1·2·4 s (+jitter) backoff, never treated as
//!    context overflow. Moved here from agent_request_policy.zig (600-line cap).

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const RetryPlan = http.RetryPlan;
const jitter = @import("retry_jitter.zig");
const util = @import("util.zig");
const policy = @import("agent_request_policy.zig");
const telemetry = @import("telemetry.zig");
const main_mod = @import("main.zig");

/// Per-request gateway-retry state; a fresh value lives for one request()
/// call, so concurrent agents never share counters.
pub const GatewayRetryState = struct {
    transport_timeouts: usize = 0,
    parse_retries: usize = 0,
};

pub const min_timeout_history_for_parse_retry: usize = 2; // a lone timeout is not a pattern
pub const max_gateway_parse_retries: usize = 2; // then surface the provider's message

/// A 4xx whose body rejects the REQUEST BODY as unparseable JSON ("Body must
/// be valid JSON", "Malformed JSON in request body", ...) is a real client bug
/// — unless the same attempt-sequence just endured consecutive transport
/// timeouts. Matched from the message so any vendor phrasing of the same
/// rejection classifies alike.
pub fn isBodyParseRejection(msg: []const u8) bool {
    const pairs = [_][2][]const u8{
        .{ "json", "body" },
        .{ "json", "parse" },
        .{ "json", "parsing" },
        .{ "parse", "request" },
    };
    for (pairs) |pair| {
        if (util.indexOfIgnoreCase(msg, pair[0]) != null and
            util.indexOfIgnoreCase(msg, pair[1]) != null) return true;
    }
    return false;
}

/// Gate (pure, testable): a body-parse rejection is retried only when THIS
/// request already hit enough transport timeouts to indict the gateway and the
/// bounded retry budget is not spent.
pub fn shouldRetryBodyParseAfterTimeouts(msg: []const u8, transport_timeouts: usize, retries: usize) bool {
    if (transport_timeouts < min_timeout_history_for_parse_retry) return false;
    if (retries >= max_gateway_parse_retries) return false;
    return isBodyParseRejection(msg);
}

/// The trace-attributed retry note (was agent_request.zig's retryNote): tag
/// the agent label into the detail. REPL lines stay unchanged; the record is
/// serialized synchronously inside note(), so arena scratch is safe.
pub fn noteRetry(self: *Agent, what: []const u8) void {
    const tr = self.tracer orelse return;
    const detail = std.fmt.allocPrint(self.arena, "{s} [{s}]", .{ what, self.label }) catch what;
    tr.note("retry", detail);
}

/// Transport-flake branch: attribute the note AND remember Timeout hits so the
/// gateway-artifact gate can recognize a blip pattern later in this request.
pub fn noteFlake(self: *Agent, state: *GatewayRetryState, err: anyerror) void {
    noteRetry(self, @errorName(err));
    if (err == error.Timeout) state.transport_timeouts += 1;
}

/// One gate for the envelope-fatal paths: transient server error first (3-step
/// ladder below), then a short Codegraff follow-up flake (ADR 0053 DeepSeek
/// `-j 6` 110-byte / ~450ms `api_error`), then the timeout-gated body-parse retry.
pub fn afterServerErrorOrParseReject(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, server_retries: *usize, state: *GatewayRetryState) !bool {
    // A structured terminal code outranks transient wording in the message.
    // In particular, do not retry a model the gateway cannot serve even if
    // its diagnostic also mentions capacity or a request-body parse error.
    if (isModelUnavailable(code)) return false;
    if (try retryTransientServerError(self, etype, code, msg, server_retries)) return true;
    if (try retryShortGatewayFlake(self, etype, code, msg, server_retries)) return true;
    return retryBodyParseAfterTimeouts(self, msg, state);
}

pub const max_short_flake_retries: usize = 2;

fn isModelUnavailable(code: ?[]const u8) bool {
    return if (code) |c| std.mem.eql(u8, c, "model_unavailable") else false;
}

/// Tiny / generic envelopes that are not a real client bug. The DeepSeek
/// SWE `-j 6` follow-up was ~110 bytes, ~450 ms, `is_error`, no
/// "overloaded" / "server_error" needle — isolated serial retry passed.
/// Do not treat invalid_request / auth / quota as a flake.
pub fn isShortGatewayFlake(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    // Gateway 110-byte follow-up. etype is often invalid_request_error, which
    // would otherwise hard-fail on the "invalid" needle. Auth/quota still die.
    if (isModelUnavailable(code)) return false;
    if (isBodyParseRejection(msg)) return true;
    const hard = [_][]const u8{ "invalid", "authentication", "unauthorized", "insufficient", "quota", "permission", "tool_choice", "not found" };
    for (hard) |n| {
        if (util.indexOfIgnoreCase(etype, n) != null) return false;
        if (util.indexOfIgnoreCase(msg, n) != null) return false;
        if (code) |c| if (util.indexOfIgnoreCase(c, n) != null) return false;
    }
    const flakes = [_][]const u8{ "internal", "try again", "temporarily", "unavailable", "bad gateway", "upstream", "capacity", "unknown error", "something went wrong", "an error occurred" };
    for (flakes) |n| {
        if (util.indexOfIgnoreCase(etype, n) != null) return true;
        if (util.indexOfIgnoreCase(msg, n) != null) return true;
        if (code) |c| if (util.indexOfIgnoreCase(c, n) != null) return true;
    }
    const generic = etype.len == 0 or std.mem.eql(u8, etype, "error") or std.mem.eql(u8, etype, "api_error");
    return generic and std.mem.trim(u8, msg, " \t\r\n").len == 0;
}

/// An explicit streamed error (not a truncated JSON body). Must not be
/// classified as a gateway flake — invalid_request is deterministic (#748).
pub fn sseLooksLikeError(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "event: error") != null) return true;
    if (std.mem.indexOf(u8, body, "event:error") != null) return true;
    if (std.mem.indexOf(u8, body, "\"error\"") != null and
        std.mem.indexOf(u8, body, "\"choices\"") == null)
        return true;
    return false;
}

/// Unparseable body that is keep-alive comments or a tiny truncated
/// payload (the 110-byte follow-up). Bounded. Real JSON error envelopes
/// do not reach this — they go through `afterServerErrorOrParseReject`.
pub fn retryDegenerateBody(self: *Agent, body: []const u8, retries: *usize) !bool {
    if (sseLooksLikeError(body)) return false;
    const tiny = body.len > 0 and body.len <= 256;
    if (!policy.sseKeepAliveOnly(body) and !tiny) return false;
    if (retries.* >= max_short_flake_retries) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity();
    const delay_ms = jitter.ms(self.io, RetryPlan.delayMs(true, retries.* - 1));
    const what: []const u8 = if (policy.sseKeepAliveOnly(body)) "keep-alive only, no tokens" else "truncated gateway body";
    try self.say("[provider queued the request ({s}) — retrying in {d}s ({d}/{d})]\n", .{ what, delay_ms / 1000, retries.*, max_short_flake_retries });
    if (self.tracer) |tr| tr.note("retry", what);
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
}

fn retryShortGatewayFlake(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, retries: *usize) !bool {
    if (!isShortGatewayFlake(etype, code, msg)) return false;
    if (retries.* >= max_short_flake_retries) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity();
    const delay_ms = jitter.ms(self.io, RetryPlan.delayMs(true, retries.* - 1));
    try self.say("[gateway flake — retrying in {d}s ({d}/{d})]\n", .{ delay_ms / 1000, retries.*, max_short_flake_retries });
    if (self.tracer) |tr| tr.note("retry", "short gateway flake");
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
}

pub const max_server_retries: usize = 3; // #opencode-parity: bounded retries for a transient in-stream server error

/// #opencode-parity: an in-band error event (an SSE {"type":"error"} or a JSON
/// error envelope) naming a TRANSIENT server condition — Anthropic overloaded_error,
/// OpenAI server_error / server_is_overloaded, plain "overloaded", or xAI's
/// mid-stream "Internal error during token parsing" (ADR 0148) — is a 5xx that
/// surfaced mid-stream and should be retried, not hard-failed. Billing / quota /
/// invalid-input errors are NOT transient and fall through to a hard fail.
pub fn isTransientServerError(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    if (isModelUnavailable(code)) return false;
    const needles = [_][]const u8{ "overloaded", "server_error", "server_is_overloaded", "token parsing" };
    for (needles) |n| {
        if (util.indexOfIgnoreCase(etype, n) != null) return true;
        if (util.indexOfIgnoreCase(msg, n) != null) return true;
        if (code) |c| if (util.indexOfIgnoreCase(c, n) != null) return true;
    }
    return false;
}

/// The user-facing name for the wait. xAI's token-parse 500 arrives after
/// output began and is not an overload; calling it one misled #1019.
fn transientServerLabel(msg: []const u8) []const u8 {
    return if (util.indexOfIgnoreCase(msg, "token parsing") != null) "provider error mid-response" else "server overloaded";
}

/// A streamed error frame has no Retry-After header. Honor "try again in N" /
/// "retry after N seconds" from the message when it names 1..60 s; otherwise
/// the local 1·2·4 s ladder. Larger waits (rate-limit days) stay display-only.
fn parseRetryAfterSeconds(msg: []const u8) ?u64 {
    const needles = [_][]const u8{ "try again in ", "retry after " };
    for (needles) |n| {
        const pos = util.indexOfIgnoreCase(msg, n) orelse continue;
        var i = pos + n.len;
        while (i < msg.len and msg[i] == ' ') i += 1;
        var j = i;
        while (j < msg.len and std.ascii.isDigit(msg[j])) j += 1;
        if (j == i) continue;
        return std.fmt.parseInt(u64, msg[i..j], 10) catch continue;
    }
    return null;
}

fn serverRetryDelayMs(msg: []const u8) ?u64 {
    const secs = parseRetryAfterSeconds(msg) orelse return null;
    if (secs == 0 or secs > 60) return null;
    return secs * 1000;
}

/// REPL: say(). TUI: session_notice on the bound sink (ADR 0041). ACP/--json:
/// a `text` event, which EventSink already turns into agent_message_chunk.
fn announceTransientRetry(self: *Agent, label: []const u8, delay_ms: u64, attempt: usize) !void {
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{s} — retrying in {d}s ({d}/{d})]", .{
        label, delay_ms / 1000, attempt, max_server_retries,
    }) catch {
        try self.say("[{s} — retrying in {d}s ({d}/{d})]\n", .{ label, delay_ms / 1000, attempt, max_server_retries });
        return;
    };
    try self.say("{s}\n", .{line});
    if (self.sink) |s| s.emit(self.io, .{ .session_notice = .{ .text = line, .tone = .dim } });
    if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "text", .text = line });
}

/// If an in-stream error names a transient server condition, back off and retry
/// the request (bounded), like a 5xx — returns true to signal the caller to
/// `continue`. Partial text is cleared so the re-stream starts clean; the WS arm
/// has already retired its socket on the terminal error frame, so the rebuild
/// reconnects with full input. Esc during the backoff propagates as
/// error.Interrupted. #opencode-parity.
pub fn retryTransientServerError(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, retries: *usize) !bool {
    if (!isTransientServerError(etype, code, msg)) return false;
    if (retries.* >= max_server_retries) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity(); // fresh re-stream after the retry, no concat
    const delay_ms = jitter.ms(self.io, serverRetryDelayMs(msg) orelse RetryPlan.delayMs(true, retries.* - 1)); // 1·2·4s, or the provider's wait; +jitter (#1274)
    const label = transientServerLabel(msg);
    try announceTransientRetry(self, label, delay_ms, retries.*);
    if (self.tracer) |tr| tr.note("retry", label);
    if (telemetry.g_telem) |t| t.errorEvent("server_overloaded", if (msg.len > 0) msg else etype);
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
}

/// The gate on the Agent: announce, trace, back off (1·2s — the gateway just
/// answered, give it a beat), clear partial text for a fresh re-stream, and
/// tell the caller to `continue`. Esc during the backoff still propagates.
fn retryBodyParseAfterTimeouts(self: *Agent, msg: []const u8, state: *GatewayRetryState) !bool {
    if (!shouldRetryBodyParseAfterTimeouts(msg, state.transport_timeouts, state.parse_retries)) return false;
    state.parse_retries += 1;
    self.partial_text.clearRetainingCapacity(); // fresh re-stream after the retry, no concat
    const delay_ms = jitter.ms(self.io, RetryPlan.delayMs(true, state.parse_retries - 1)); // 1·2s
    try self.say("[gateway answered after {d} timeouts with a body-parse rejection — retrying in {d}s ({d}/{d})]\n", .{ state.transport_timeouts, delay_ms / 1000, state.parse_retries, max_gateway_parse_retries });
    if (self.tracer) |tr| tr.note("retry", "body-parse rejection after transport timeouts (gateway artifact?)");
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
}

test "isBodyParseRejection (#gateway-artifact): body-parse phrasings match, unrelated 400s do not" {
    try std.testing.expect(isBodyParseRejection("Body must be valid JSON"));
    try std.testing.expect(isBodyParseRejection("Malformed JSON in request body"));
    try std.testing.expect(isBodyParseRejection("We could not parse the JSON body of your request."));
    try std.testing.expect(isBodyParseRejection("failed to parse the request"));
    // not a body-parse rejection: model-capability / billing / content errors
    try std.testing.expect(!isBodyParseRejection("response_format json_schema is not supported by this model"));
    try std.testing.expect(!isBodyParseRejection("messages: text content blocks must be non-empty"));
    try std.testing.expect(!isBodyParseRejection("Your credit balance is too low to use this model"));
    try std.testing.expect(!isBodyParseRejection(""));
}

test "shouldRetryBodyParseAfterTimeouts (#gateway-artifact): timeout history gates it, budget bounds it" {
    // a lone timeout (or none) before the 400 -> real client bug, fail fast
    try std.testing.expect(!shouldRetryBodyParseAfterTimeouts("Body must be valid JSON", 0, 0));
    try std.testing.expect(!shouldRetryBodyParseAfterTimeouts("Body must be valid JSON", 1, 0));
    // 3 timeouts then the rejection (the 2026-08-29 glm/codegraff incident shape) -> retry
    try std.testing.expect(shouldRetryBodyParseAfterTimeouts("Body must be valid JSON", 3, 0));
    // budget spent -> surface the provider's message instead of looping
    try std.testing.expect(!shouldRetryBodyParseAfterTimeouts("Body must be valid JSON", 3, max_gateway_parse_retries));
    // an unrelated message never retries, however many timeouts preceded it
    try std.testing.expect(!shouldRetryBodyParseAfterTimeouts("quota exceeded", 5, 0));
}

test "isShortGatewayFlake: internal/empty api_error retry; invalid/auth/quota do not" {
    try std.testing.expect(isShortGatewayFlake("api_error", null, "Internal Server Error"));
    try std.testing.expect(isShortGatewayFlake("api_error", null, ""));
    try std.testing.expect(isShortGatewayFlake("error", null, "   "));
    try std.testing.expect(isShortGatewayFlake("", null, "unknown error"));
    try std.testing.expect(isShortGatewayFlake("", null, "upstream connect error"));
    try std.testing.expect(!isShortGatewayFlake("invalid_request_error", null, "invalid prompt"));
    try std.testing.expect(!isShortGatewayFlake("api_error", null, "invalid tool_choice"));
    try std.testing.expect(!isShortGatewayFlake("authentication_error", null, "invalid api key"));
    try std.testing.expect(!isShortGatewayFlake("insufficient_quota", null, "You exceeded your current quota"));
    try std.testing.expect(!isShortGatewayFlake("api_error", null, "model not found"));
    try std.testing.expect(!isShortGatewayFlake("service_unavailable", "model_unavailable", "Codegraff cannot serve this model right now"));
    try std.testing.expect(!isShortGatewayFlake("service_unavailable", "model_unavailable", "Malformed JSON in request body"));
    try std.testing.expect(isShortGatewayFlake("invalid_request_error", null, "Body must be valid JSON"));
    try std.testing.expect(isShortGatewayFlake("api_error", null, "Malformed JSON in request body"));
    try std.testing.expect(!isShortGatewayFlake("invalid_request_error", null, "invalid prompt"));
}

test "isTransientServerError (#opencode-parity): overload/server_error retry; quota/invalid/auth do not" {
    // transient server conditions → retry like a 5xx
    try std.testing.expect(isTransientServerError("overloaded_error", null, ""));
    try std.testing.expect(isTransientServerError("api_error", "server_error", ""));
    try std.testing.expect(isTransientServerError("", "server_is_overloaded", ""));
    try std.testing.expect(isTransientServerError("", null, "The server is Overloaded, please try again")); // case-insensitive, in message
    // billing / input / auth → NOT transient, must hard-fail
    try std.testing.expect(!isTransientServerError("insufficient_quota", "insufficient_quota", "You exceeded your current quota"));
    try std.testing.expect(!isTransientServerError("invalid_request_error", null, "invalid prompt"));
    try std.testing.expect(!isTransientServerError("authentication_error", null, "invalid api key"));
    try std.testing.expect(!isTransientServerError("service_unavailable", "model_unavailable", "server overloaded; retry after 3 seconds"));
    // a bare "Internal Server Error" stays on the shorter gateway-flake ladder
    try std.testing.expect(!isTransientServerError("api_error", null, "Internal Server Error"));
}

test "ADR 0148 (reverses #1019): token-parse 500 rides the transient server ladder, not overflow" {
    const msg = "Internal error during token parsing";
    // The Responses WS arm calls afterServerErrorOrParseReject with etype "".
    try std.testing.expect(isTransientServerError("", null, msg));
    try std.testing.expect(isTransientServerError("api_error", null, msg));
    try std.testing.expect(isTransientServerError("", null, "xai api error: Internal error during token parsing"));
    // Never overflow: no trim, no meter pin — the same request body is resent.
    try std.testing.expect(!@import("agent_overflow.zig").isContextOverflow(msg, null));
    try std.testing.expect(!@import("agent_overflow.zig").isContextOverflow("xai api error: " ++ msg, null));
    // Not a body-parse rejection either; and the no-carve-out flake gate agrees it is retryable.
    try std.testing.expect(!isBodyParseRejection(msg));
    try std.testing.expect(isShortGatewayFlake("", null, msg));
    // Wording: the retry line names a mid-response provider error, not an overload.
    try std.testing.expectEqualStrings("provider error mid-response", transientServerLabel(msg));
    try std.testing.expectEqualStrings("server overloaded", transientServerLabel("The server is overloaded"));
}

test "serverRetryDelayMs honors try-again/retry-after seconds, ignores 0 and >60s" {
    try std.testing.expectEqual(@as(u64, 3), parseRetryAfterSeconds("try again in 3 seconds").?);
    try std.testing.expectEqual(@as(u64, 5), parseRetryAfterSeconds("Please Retry After 5s").?);
    try std.testing.expectEqual(@as(u64, 12), parseRetryAfterSeconds("TRY AGAIN IN  12 seconds.").?);
    try std.testing.expect(parseRetryAfterSeconds("Internal error during token parsing") == null);
    try std.testing.expectEqual(@as(u64, 3000), serverRetryDelayMs("overloaded; try again in 3 seconds").?);
    try std.testing.expect(serverRetryDelayMs("try again in 0 seconds") == null);
    try std.testing.expect(serverRetryDelayMs("retry after 90 seconds") == null);
    try std.testing.expect(serverRetryDelayMs("try again in 350000 seconds") == null);
}

test "#748: error-only SSE is not a truncated gateway body" {
    const err_sse = "event: error\ndata: {\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad\"}}\n";
    try std.testing.expect(sseLooksLikeError(err_sse));
    try std.testing.expect(sseLooksLikeError("data: {\"error\":{\"message\":\"only auto\"}}\n"));
    try std.testing.expect(!sseLooksLikeError(": OPENROUTER PROCESSING\n"));
    try std.testing.expect(!sseLooksLikeError("data: {\"choices\":[{\"delta\":{}}]}\n"));
}
