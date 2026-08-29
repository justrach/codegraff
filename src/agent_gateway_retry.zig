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

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const RetryPlan = http.RetryPlan;
const util = @import("util.zig");
const policy = @import("agent_request_policy.zig");

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

/// One gate for the envelope-fatal paths: overload first, then a short
/// Codegraff follow-up flake (ADR 0048 DeepSeek `-j 6` 110-byte / ~450ms
/// `api_error`), then the timeout-gated body-parse retry.
pub fn afterServerErrorOrParseReject(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, server_retries: *usize, state: *GatewayRetryState) !bool {
    if (try policy.retryTransientServerError(self, etype, code, msg, server_retries)) return true;
    if (try retryShortGatewayFlake(self, etype, code, msg, server_retries)) return true;
    return retryBodyParseAfterTimeouts(self, msg, state);
}

pub const max_short_flake_retries: usize = 2;

/// Tiny / generic envelopes that are not a real client bug. The DeepSeek
/// SWE `-j 6` follow-up was ~110 bytes, ~450 ms, `is_error`, no
/// "overloaded" / "server_error" needle — isolated serial retry passed.
/// Do not treat invalid_request / auth / quota as a flake.
pub fn isShortGatewayFlake(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    // Gateway 110-byte follow-up. etype is often invalid_request_error, which
    // would otherwise hard-fail on the "invalid" needle. Auth/quota still die.
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

/// Unparseable body that is keep-alive comments or a tiny truncated
/// payload (the 110-byte follow-up). Bounded. Real JSON error envelopes
/// do not reach this — they go through `afterServerErrorOrParseReject`.
pub fn retryDegenerateBody(self: *Agent, body: []const u8, retries: *usize) !bool {
    const tiny = body.len > 0 and body.len <= 256;
    if (!policy.sseKeepAliveOnly(body) and !tiny) return false;
    if (retries.* >= max_short_flake_retries) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity();
    const delay_ms = RetryPlan.delayMs(true, retries.* - 1);
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
    const delay_ms = RetryPlan.delayMs(true, retries.* - 1);
    try self.say("[gateway flake — retrying in {d}s ({d}/{d})]\n", .{ delay_ms / 1000, retries.*, max_short_flake_retries });
    if (self.tracer) |tr| tr.note("retry", "short gateway flake");
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
    const delay_ms = RetryPlan.delayMs(true, state.parse_retries - 1); // 1·2s
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
    try std.testing.expect(isShortGatewayFlake("invalid_request_error", null, "Body must be valid JSON"));
    try std.testing.expect(isShortGatewayFlake("api_error", null, "Malformed JSON in request body"));
    try std.testing.expect(!isShortGatewayFlake("invalid_request_error", null, "invalid prompt"));
}
