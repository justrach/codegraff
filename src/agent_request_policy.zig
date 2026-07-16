//! Request retry and provider-error policy shared by the request loop.

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const RetryPlan = http.RetryPlan;
const telemetry = @import("telemetry.zig");

pub fn isAuthError(msg: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(msg, "api key") != null or
        std.ascii.indexOfIgnoreCase(msg, "unauthorized") != null or
        std.ascii.indexOfIgnoreCase(msg, "expired") != null or
        std.ascii.indexOfIgnoreCase(msg, "authentication") != null or
        std.ascii.indexOfIgnoreCase(msg, "invalid_api_key") != null;
}

test "isAuthError (#148): auth failures only, not credits/rate/other" {
    // real provider 401 phrasings → refresh + retry
    try std.testing.expect(isAuthError("The API Key appears to be invalid or may have expired."));
    try std.testing.expect(isAuthError("Unauthorized"));
    try std.testing.expect(isAuthError("authentication_error"));
    try std.testing.expect(isAuthError("invalid_api_key"));
    // NOT auth — must never trigger a refresh loop
    try std.testing.expect(!isAuthError("You have run out of credits or need a Grok subscription."));
    try std.testing.expect(!isAuthError("rate limit exceeded"));
    try std.testing.expect(!isAuthError("model not found"));
    try std.testing.expect(!isAuthError("context length exceeded"));
}

/// True if `msg` is a provider's "input is over the context window" rejection,
/// across wire formats: codex/responses ("exceeds the context window"), openai
/// ("maximum context length", "context_length_exceeded"), anthropic ("prompt is
/// too long", "exceed context limit"). Drives the in-turn emergency-trim + retry
/// recovery symmetrically for every provider (#193) — before it, only the codex
/// path recovered and anthropic/openai died on an over-window turn.
fn isContextOverflow(msg: []const u8, code: ?[]const u8) bool {
    // #203: match the structured error code first (openai/codex parity — a local or
    // non-English provider whose message text differs still recovers), then fall back
    // to the human-readable phrasing.
    if (code) |c| {
        const codes = [_][]const u8{ "context_length_exceeded", "context_window_exceeded" };
        for (codes) |k| if (std.mem.eql(u8, c, k)) return true;
    }
    const needles = [_][]const u8{
        "context window", // codex/responses: "exceeds the context window"
        "context length", // openai: "maximum context length is N tokens"
        "context_length_exceeded", // openai error code echoed into the message
        "context limit", // anthropic: "input length and max_tokens exceed context limit"
        "prompt is too long", // anthropic: "prompt is too long: N tokens > M maximum"
        "maximum context", // defensive: "maximum context ... exceeded"
    };
    for (needles) |n| if (std.mem.indexOf(u8, msg, n) != null) return true;
    return false;
}

/// The structured error code from a parsed error envelope, if any: openai / lmstudio /
/// deepseek put it at root.error.code; some providers use a top-level root.code (#203).
pub fn errorCode(root: std.json.ObjectMap) ?[]const u8 {
    if (root.get("error")) |ev| {
        if (ev == .object) {
            if (ev.object.get("code")) |cv| {
                if (cv == .string) return cv.string;
            }
        }
    }
    if (root.get("code")) |cv| {
        if (cv == .string) return cv.string;
    }
    // Responses failure events wrap the same error object under `response`.
    if (root.get("response")) |rv| {
        if (rv == .object) {
            if (rv.object.get("error")) |ev| {
                if (ev == .object) {
                    if (ev.object.get("code")) |cv| {
                        if (cv == .string) return cv.string;
                    }
                }
            }
            if (rv.object.get("code")) |cv| {
                if (cv == .string) return cv.string;
            }
        }
    }
    return null;
}

/// #193 follow-up: shared in-turn context-overflow recovery for the three
/// anthropic/openai error branches (streamed error event, non-streamed
/// `{"type":"error"}` envelope, and the generic apiErrorMessage path). Before
/// this, only the codex/.responses branch recovered — anthropic/openai died on an
/// over-window turn. Returns true if the caller should `continue` the rebuild loop
/// (emergency-trimmed, retry the same request once); false to fall through to the
/// normal error. Pins the meter to the window FIRST so the between-turns
/// compaction engages even when we can't recover here (the rejected request
/// returns no usage to correct the lagging meter). Guarded by `retried` (one
/// `context_retried` shared across every branch of a request) so a second overflow
/// falls through and never loops. These wire formats send the full input each
/// rebuild, so — unlike the codex branch — no closeCodexWs re-anchor is needed.
pub fn recoverContextOverflow(self: *Agent, msg: []const u8, code: ?[]const u8, retried: *bool) bool {
    if (!isContextOverflow(msg, code)) return false;
    self.last_request_context_overflow = true;
    // Rejection proves at least the advertised window, not an exact total.
    // Preserve stronger server/local evidence already above that floor.
    const local = self.fullRequestEstimateTokens();
    self.last_context_tokens = @max(self.effectiveContextTokens(), self.provider.context);
    self.context_local_tokens = local;
    // compact() marks its synthetic summary request explicitly. Generic
    // in-request recovery is destructive there: the synthetic compact
    // instruction is the newest clean user turn, so emergencyTrim can discard
    // the entire real conversation and retry with only "summarize it". Let the
    // outer compactOrRecover policy handle a failed summary after compact()'s
    // errdefer removes that synthetic instruction.
    if (self.compaction_request) return false;
    if (retried.* or self.emergencyTrim() == 0) return false;
    retried.* = true;
    if (self.tracer) |tr| tr.note("context", "input over the window — emergency-trimmed and retrying the turn");
    return true;
}

const max_server_retries: usize = 3; // #opencode-parity: bounded retries for a transient in-stream server overload

/// #opencode-parity: an in-band error event (an SSE {"type":"error"} or a JSON
/// error envelope) naming a TRANSIENT server condition — Anthropic overloaded_error,
/// OpenAI server_error / server_is_overloaded, or plain "overloaded" — is a 5xx that
/// surfaced mid-stream and should be retried, not hard-failed. Billing / quota /
/// invalid-input errors are NOT transient and fall through to a hard fail.
fn isTransientServerError(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    const needles = [_][]const u8{ "overloaded", "server_error", "server_is_overloaded" };
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(etype, n) != null) return true;
        if (std.ascii.indexOfIgnoreCase(msg, n) != null) return true;
        if (code) |c| if (std.ascii.indexOfIgnoreCase(c, n) != null) return true;
    }
    return false;
}

/// If an in-stream error names a transient server overload, back off and retry the
/// request (bounded), like a 5xx — returns true to signal the caller to `continue`.
/// Esc during the backoff propagates as error.Interrupted. #opencode-parity.
pub fn retryTransientServerError(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, retries: *usize) !bool {
    if (!isTransientServerError(etype, code, msg)) return false;
    if (retries.* >= max_server_retries) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity(); // fresh re-stream after the retry, no concat
    const delay_ms = RetryPlan.delayMs(true, retries.* - 1); // 1·2·4s
    try self.say("[server overloaded — retrying in {d}s ({d}/{d})]\n", .{ delay_ms / 1000, retries.*, max_server_retries });
    if (self.tracer) |tr| tr.note("retry", "server overloaded (in-stream)");
    if (telemetry.g_telem) |t| t.errorEvent("server_overloaded", if (msg.len > 0) msg else etype);
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
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
}

/// #opencode-parity: a 429 body naming a billing/quota cap (OpenAI insufficient_quota,
/// "exceeded your current quota", "quota exceeded") — a usage limit a retry can't
/// clear, unlike transient rate-limit throttling — so we fail fast + fail over rather
/// than burning retry attempts.
pub fn isQuotaExceeded(body: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(body, "insufficient_quota") != null or
        std.ascii.indexOfIgnoreCase(body, "insufficient quota") != null or
        std.ascii.indexOfIgnoreCase(body, "exceeded your current quota") != null or
        std.ascii.indexOfIgnoreCase(body, "quota exceeded") != null;
}

test "isQuotaExceeded (#opencode-parity): billing cap detected, transient throttle not" {
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}"));
    try std.testing.expect(isQuotaExceeded("Quota Exceeded for this key"));
    // transient rate-limit -> NOT a quota cap; must still retry
    try std.testing.expect(!isQuotaExceeded("Rate limit reached. Please try again in 20s."));
    try std.testing.expect(!isQuotaExceeded("429 too many requests"));
}

test "isContextOverflow (#193/#203): matches structured code + every provider's phrasing, not unrelated errors" {
    // codex/responses, openai, anthropic wire-format rejections all recover in-turn
    try std.testing.expect(isContextOverflow("Your input exceeds the context window of 272000 tokens", null));
    try std.testing.expect(isContextOverflow("This model's maximum context length is 128000 tokens. However, you requested 130000", null));
    try std.testing.expect(isContextOverflow("context_length_exceeded", null));
    try std.testing.expect(isContextOverflow("prompt is too long: 219373 tokens > 200000 maximum", null));
    try std.testing.expect(isContextOverflow("input length and max_tokens exceed context limit", null));
    // #203: a structured error code recovers even when the message text is unfamiliar
    // (a local / non-English provider whose phrasing we don't match on)
    try std.testing.expect(isContextOverflow("de invoerlengte overschrijdt het venster", "context_length_exceeded"));
    try std.testing.expect(isContextOverflow("", "context_window_exceeded"));
    // unrelated API errors must NOT trigger a trim + retry, by message or by code
    try std.testing.expect(!isContextOverflow("The API Key appears to be invalid or may have expired.", null));
    try std.testing.expect(!isContextOverflow("tool_choice is not supported", null));
    try std.testing.expect(!isContextOverflow("rate limit exceeded", null));
    try std.testing.expect(!isContextOverflow("model not found", null));
    try std.testing.expect(!isContextOverflow("some unrelated failure", "rate_limit_exceeded"));
}

test "errorCode (#203): pulls root.error.code (openai/lmstudio), falls back to root.code, else null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // openai/lmstudio/deepseek shape: {"error":{"code":"context_length_exceeded",...}}
    var err: std.json.ObjectMap = .empty;
    try err.put(a, "code", .{ .string = "context_length_exceeded" });
    var root1: std.json.ObjectMap = .empty;
    try root1.put(a, "error", .{ .object = err });
    try std.testing.expectEqualStrings("context_length_exceeded", errorCode(root1).?);
    // top-level code fallback
    var root2: std.json.ObjectMap = .empty;
    try root2.put(a, "code", .{ .string = "context_window_exceeded" });
    try std.testing.expectEqualStrings("context_window_exceeded", errorCode(root2).?);
    // neither present → null (falls back to substring detection)
    var root3: std.json.ObjectMap = .empty;
    try root3.put(a, "message", .{ .string = "hi" });
    try std.testing.expect(errorCode(root3) == null);

    // Responses stream shape: {response:{error:{code}}}.
    var responses_error: std.json.ObjectMap = .empty;
    try responses_error.put(a, "code", .{ .string = "context_length_exceeded" });
    var responses_payload: std.json.ObjectMap = .empty;
    try responses_payload.put(a, "error", .{ .object = responses_error });
    var root4: std.json.ObjectMap = .empty;
    try root4.put(a, "response", .{ .object = responses_payload });
    try std.testing.expectEqualStrings("context_length_exceeded", errorCode(root4).?);
}

test "recoverContextOverflow (#193): overflow trims + retries once; guard and non-overflow fall through" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // a runaway tool-loop history emergencyTrim can reclaim (mirrors the #163 shape:
    // one clean user turn then only tool outputs, so trimOldestToolOutputs recovers)
    var msgs = std.json.Array.init(a);
    var um: std.json.ObjectMap = .empty;
    try um.put(a, "role", .{ .string = "user" });
    try um.put(a, "content", .{ .string = "do a thing" });
    try msgs.append(.{ .object = um });
    const big = try a.alloc(u8, 5000);
    @memset(big, 'x');
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "type", .{ .string = "function_call_output" });
        try o.put(a, "call_id", .{ .string = "c" });
        try o.put(a, "output", .{ .string = big });
        try msgs.append(.{ .object = o });
    }
    var agent: Agent = undefined;
    agent.arena = a;
    agent.messages = msgs;
    agent.tracer = null;
    agent.provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = "claude", .context = 100000 };
    agent.last_context_tokens = 0;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_anthropic = "";
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    agent.stream_quiet = true;
    agent.compaction_request = true;
    agent.last_request_context_overflow = false;

    // A compaction-summary request must never run generic emergency recovery:
    // its synthetic user instruction would become a destructive trim boundary.
    const before_quiet = agent.messages.items.len;
    var quiet_retried = false;
    try std.testing.expect(!recoverContextOverflow(&agent, "prompt is too long", null, &quiet_retried));
    try std.testing.expect(!quiet_retried);
    try std.testing.expect(agent.last_request_context_overflow);
    try std.testing.expectEqual(before_quiet, agent.messages.items.len);
    try std.testing.expectEqual(agent.provider.context, agent.last_context_tokens);
    agent.compaction_request = false;
    agent.last_context_tokens = 0;

    // Quiet one-shot output is not compaction. It must still recover normally.
    var retried = false;
    try std.testing.expect(recoverContextOverflow(&agent, "prompt is too long: 999 tokens > 100 maximum", null, &retried));
    try std.testing.expect(retried);
    // a second overflow this request -> guard blocks a re-trim (no loop), but the
    // meter stays pinned to the window so the between-turns compaction still engages
    try std.testing.expect(!recoverContextOverflow(&agent, "prompt is too long", null, &retried));
    try std.testing.expectEqual(agent.provider.context, agent.last_context_tokens);
    // an unrelated error never recovers, regardless of the guard
    var retried2 = false;
    try std.testing.expect(!recoverContextOverflow(&agent, "invalid api key", null, &retried2));
    try std.testing.expect(!retried2);
}
