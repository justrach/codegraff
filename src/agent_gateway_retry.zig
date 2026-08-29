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

/// One gate for the envelope-fatal paths: the pre-existing transient
/// server-overload retry first (unchanged semantics), then the bounded
/// gateway-artifact retry when this request already endured >=2 timeouts.
pub fn afterServerErrorOrParseReject(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, server_retries: *usize, state: *GatewayRetryState) !bool {
    if (try policy.retryTransientServerError(self, etype, code, msg, server_retries)) return true;
    return retryBodyParseAfterTimeouts(self, msg, state);
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
