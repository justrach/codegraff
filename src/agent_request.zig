//! The provider round trip: request() builds+sends the body (with the
//! retry/backoff loop for flaky transport and 429/5xx), buildBody()
//! serializes it per wire format (Anthropic/OpenAI/Responses), and
//! recordUsage/recordUsageResponses/recordCost tally tokens + cost into
//! the session-wide g_cost. parseResponses reassembles the Codex/Responses
//! SSE stream into a synthetic {output, usage} object (the streaming
//! Anthropic/OpenAI SSE reassembly — assembleAnthropic/assembleOpenAI —
//! lives in agent_steps.zig instead, since it feeds the step* functions
//! there). Split out of the Agent struct (#123, 600-line goal).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const max_tokens = main_mod.max_tokens;

const pricing = @import("pricing.zig");
const oauth = @import("oauth.zig");
const g_cost = &pricing.g_cost;

const messages_mod = @import("messages.zig");
const sanitizeMessagesUtf8 = messages_mod.sanitizeMessagesUtf8;
const normalizeResponsesHistory = messages_mod.normalizeResponsesHistory;
const normalizeOpenAIHistory = messages_mod.normalizeOpenAIHistory;

const serde = @import("serde.zig");
const writeAnthropicMessages = serde.writeAnthropicMessages;
const writeOpenAIMessageNormalized = serde.writeOpenAIMessageNormalized;
const util = @import("util.zig");

const http = @import("http.zig");
const postWatched = http.postWatched;
const RetryPlan = http.RetryPlan;

const tools_mod = @import("tools.zig");
const apiErrorMessage = tools_mod.apiErrorMessage;
const mentionsReasoningEffort = tools_mod.mentionsReasoningEffort;

const telemetry = @import("telemetry.zig");

/// POST the current history; returns the parsed response root object
/// (arena-owned). Reports API error envelopes and returns error.ApiError.
/// In strict mode we force tool_choice; if a provider rejects that (e.g.
/// the codegraff gateway with thinking on), we retry once without forcing
/// and lean on the strict system prompt instead. Root requests stream:
/// text deltas print live (postStream) and the buffered SSE events are
/// reassembled into the non-streaming response shape afterwards.
/// #148: does a provider error message look like an auth failure (a stale/
/// revoked OAuth token), so we refresh + retry rather than give up? Matches the
/// common 401 phrasings ("invalid api key", "expired", "unauthorized", …).
fn isAuthError(msg: []const u8) bool {
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
fn errorCode(root: std.json.ObjectMap) ?[]const u8 {
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
fn recoverContextOverflow(self: *Agent, msg: []const u8, code: ?[]const u8, retried: *bool) bool {
    if (!isContextOverflow(msg, code)) return false;
    self.last_context_tokens = self.provider.context;
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
fn retryTransientServerError(self: *Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, retries: *usize) !bool {
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
fn isQuotaExceeded(body: []const u8) bool {
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
}

test "recordUsage (#202): floors the meter from the local estimate when usage is absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    var m: std.json.ObjectMap = .empty;
    try m.put(a, "role", .{ .string = "user" });
    try m.put(a, "content", .{ .string = "the quick brown fox jumps over the lazy dog" });
    try msgs.append(.{ .object = m });

    var agent: Agent = undefined;
    agent.arena = a;
    agent.messages = msgs;
    agent.last_context_tokens = 0;

    // a response body with NO usage object previously froze the meter at its stale
    // value; now it floors to max(full-input estimate, req_body_len/4) so the
    // between-turns compaction gate can still fire.
    const root: std.json.ObjectMap = .empty;
    recordUsage(&agent, root, 4000);

    try std.testing.expect(agent.last_context_tokens > 0);
    const expected = @max(fullInputEstimateTokens(&agent), @as(u64, 1000)); // 4000/4
    try std.testing.expectEqual(expected, agent.last_context_tokens);
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

    // overflow + trimmable history -> recovers (retry the turn), guard flips
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

test "fullInputEstimateTokens (#174): counts retained reasoning the chained usage never reports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    var agent: Agent = undefined;
    agent.messages = msgs;
    try std.testing.expectEqual(@as(u64, 0), fullInputEstimateTokens(&agent) / 100); // empty history ≈ nothing
    // a fat encrypted-reasoning item — exactly what a WS-chained total_tokens excludes
    const blob = "{\"type\":\"reasoning\",\"encrypted_content\":\"" ++ ("A" ** 8192) ++ "\"}";
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, blob, .{}));
    agent.messages = msgs;
    const est = fullInputEstimateTokens(&agent);
    try std.testing.expect(est > 2000); // ~8KB serialized / 4 bytes-per-token
}

pub fn request(self: *Agent, tools: ?[]const u8) !std.json.ObjectMap {
    var force = self.strict and tools != null;
    var stream_usage = true; // openai stream_options; dropped if rejected
    var auth_refreshed = false; // #148: at most one forced token refresh + retry
    // #124: reclaim last request's transient parse garbage FIRST, so everything
    // below (oauth refresh internals, per-event parse trees, tool-arg parses)
    // can use the scratch arena for this request. Safe: all scratch data is
    // consumed before the next request(); messages/todos/prompts live on the
    // session arena.
    if (self.scratch_arena) |sa| _ = sa.reset(.retain_capacity);
    // #148: a login-sourced OAuth token (kimi/xai, ~1h) expires mid-session and
    // is minted only at startup; refresh it in place before the call when near
    // expiry so a long session — or a subagent that inherited the on-disk token —
    // never 401s. Login-sourced keys only (env keys untouched); a cheap disk read
    // unless actually near expiry. The refresh internals (file read + JSON parse,
    // ~1-2KB) are scratch (#124); only the token itself is duped to survive
    // future requests.
    if (self.provider.source == .login) {
        if (oauth.refreshOAuthKey(self.io, self.gpa, self.scratchAlloc(), self.home, self.provider.id, false)) |fresh| {
            self.provider.api_key = self.arena.dupe(u8, fresh) catch self.provider.api_key;
        }
    }
    // #95: scrub any malformed function_call_output before it hits the wire.
    sanitizeMessagesUtf8(self.arena, &self.messages); // invalid UTF-8 (any source/format) -> '?' so content never serializes as a byte-int array the API rejects
    if (self.provider.kind == .responses) normalizeResponsesHistory(self.arena, &self.messages);
    if (self.provider.kind == .openai) normalizeOpenAIHistory(self.arena, &self.messages); // #99: chat-completions sibling of the above
    // #193 follow-up: bound any single oversized tool output (an uncapped MCP
    // result, a huge fetch on a small-window model) before send. The responses
    // path already hard-caps output above (normalizeResponsesHistory); this is the
    // provider-agnostic sibling so one pathological result can't alone overflow the
    // window past what the in-turn recovery below can reclaim (it keeps the most
    // recent outputs verbatim). Window-proportional, so large-context models keep
    // full tool results untouched.
    const capped = self.capOversizedToolOutputs(self.provider.perOutputCap());
    if (capped > 0) {
        // #202: don't truncate silently. The model already sees an inline marker;
        // surface it to the trace and (interactively) to the user too.
        if (self.tracer) |tr| tr.note("context", "capped an oversized tool output before send");
        if (!main_mod.json_mode and !self.sub)
            self.say("[tool output over this model's per-result cap — truncated {d} bytes before send (#193)]\n", .{capped}) catch {};
    }
    var context_retried = false; // #193: at most one in-turn overflow recovery per request
    // #56: bounded stream-stall / drop reconnect budget (codex's stream_max_retries
    // analog). Declared outside the rebuild loop so a WS reanchor can't reset it.
    var stall_retries: usize = 0;
    const max_stall_retries: usize = 2;
    const stall_reconnect_backoff_ms = 750; // brief pause before reconnecting on a fresh stream
    var server_retries: usize = 0; // #opencode-parity: bounded retries for a transient in-stream server overload
    var openai404_retries: usize = 0; // #opencode-parity: bounded retries for OpenAI's spurious model 404s
    const max_openai404_retries: usize = 2;
    rebuild: while (true) {
        const live = !self.sub and self.out != null and !self.stream_quiet;
        self.streamed_text = false;
        self.streamed_args = .none;
        const body = try self.buildBody(tools, force, live, stream_usage);
        defer self.gpa.free(body);
        const t0: Io.Timestamp = .now(self.io, .awake);
        if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_started", .provider = self.provider.id, .model = self.provider.model });
        // HTTP calls are flaky: a kept-alive connection the server closed
        // (HttpConnectionClosing), a reset, a truncated TLS read. Retry a
        // few times with a fresh connection; on persistent failure surface
        // error.ApiError so the REPL returns to the prompt, never crashes.
        const resp_body = blk: {
            var attempt: usize = 0;
            while (true) : (attempt += 1) {
                const attempt_body = if (live)
                    self.postLive(body)
                else
                    postWatched(self.gpa, self.io, self.client, self.provider, body);
                if (attempt_body) |ok| break :blk ok else |err| {
                    if (self.streamed_text) if (self.out) |w| {
                        w.writeAll("\n") catch {};
                        w.flush() catch {};
                    };
                    self.streamed_text = false;
                    self.streamed_args = .none;
                    // Esc is a deliberate stop, not a flaky network — no retry.
                    if (err == error.Interrupted) return error.Interrupted;
                    // #56: a mid-stream idle stall or a connection drop (the
                    // provider closed/reset before its terminal event) — NOT a
                    // user Esc, which is handled above. Usually transient, so
                    // reconnect on a fresh stream and re-send the full request,
                    // like codex's stream_max_retries (restart the request; the
                    // partial was never committed to history). Bounded; on
                    // exhaustion end the turn recorded as a stall/drop, never a
                    // user Esc (#134). The budget lives outside the rebuild loop
                    // so a WS reanchor can't reset it.
                    if (err == error.StreamStalled or err == error.StreamDropped) {
                        const stalled = err == error.StreamStalled;
                        const what: []const u8 = if (stalled) "stream stalled" else "stream dropped";
                        if (stall_retries < max_stall_retries) {
                            stall_retries += 1;
                            // #56: give a fresh WS one reconnect; if it stalls again,
                            // fall back to the reliable SSE transport for the rest of
                            // the session — codex's WS→SSE fallback, and consistent
                            // with how a WS transport error is already handled (ws_off).
                            if (stall_retries > 1) self.ws_off = true;
                            const via: []const u8 = if (self.ws_off) " (SSE)" else "";
                            try self.say("[{s} — reconnecting{s} ({d}/{d})]\n", .{ what, via, stall_retries, max_stall_retries });
                            if (self.tracer) |tr| tr.note("stream_retry", what);
                            if (telemetry.g_telem) |t| t.errorEvent("stream_retry", what);
                            self.partial_text.clearRetainingCapacity(); // fresh stream re-streams cleanly, no concat
                            self.closeCodexWs(); // tear down the dead WS + null codex_prev_id for a full re-send (no-op off codex WS)
                            self.sleepInterruptible(stall_reconnect_backoff_ms) catch return error.Interrupted;
                            continue :rebuild;
                        }
                        if (stalled) {
                            self.last_api_error = std.fmt.allocPrint(self.arena, "stream stalled: no data from the model for {d}s — ended the turn after {d} reconnect attempts (raise GRAFF_STREAM_STALL_SECS if your model needs longer)", .{ http.stream_stall_ms / 1000, max_stall_retries }) catch null;
                            if (telemetry.g_telem) |t| t.errorEvent("stream_stall", self.last_api_error orelse "stream stalled");
                            if (self.tracer) |tr| tr.note("stream_stall", self.last_api_error orelse "stream stalled");
                            return error.StreamStalled;
                        }
                        self.last_api_error = "stream dropped: the provider closed the connection before the response completed — ended the turn after reconnect attempts";
                        if (telemetry.g_telem) |t| t.errorEvent("stream_dropped", self.last_api_error.?);
                        if (self.tracer) |tr| tr.note("stream_dropped", self.last_api_error.?);
                        return error.StreamDropped;
                    }
                    // (#codex-ws) postLive already closed the dead WS session —
                    // rebuild (full input, no previous_response_id) + retry via
                    // a fresh WS instead of replaying the stale delta over SSE.
                    // codex_prev_id is now null, so this can't recur this request.
                    if (err == error.CodexWsReanchor) continue :rebuild;
                    // #opencode-parity: OpenAI proper spuriously 404s available models.
                    // Retry a bounded number of times; a PERSISTENT 404 is a real
                    // model-not-found, so surface it (with the body) as an ApiError whose
                    // message drives cross-provider failover, not a generic flake give-up.
                    if (err == error.OpenAiFlaky404) {
                        if (openai404_retries < max_openai404_retries) {
                            openai404_retries += 1;
                            try self.say("[openai 404 (often spurious) — retrying ({d}/{d})]\n", .{ openai404_retries, max_openai404_retries });
                            if (self.tracer) |tr| tr.note("retry", "openai 404");
                            self.sleepInterruptible(RetryPlan.delayMs(false, openai404_retries - 1)) catch return error.Interrupted;
                            continue;
                        }
                        self.last_api_error = std.fmt.allocPrint(self.arena, "openai 404 (model not found?): {s}", .{if (main_mod.g_5xx_body_len > 0) main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len] else "not found"}) catch "openai 404: model not found";
                        if (telemetry.g_telem) |t| t.errorEvent("openai_404", self.last_api_error orelse "openai 404");
                        return error.ApiError;
                    }
                    // 429/5xx: the server asked us to back off — wait
                    // (1s·2ⁿ, capped at 8s; Esc cancels) and allow a few
                    // more attempts than a plain transport flake gets.
                    const throttled = err == error.RateLimited or err == error.ServerError;
                    const max_attempts: usize = RetryPlan.maxAttempts(throttled);
                    // #opencode-parity: a 429 that's a billing/quota cap (not
                    // transient throttling) won't clear by retrying — fail fast so
                    // cross-provider /fallback can take over, instead of burning all
                    // 5 attempts (~23s). Detected from the captured 429 body.
                    if (err == error.RateLimited and main_mod.g_5xx_body_len > 0 and
                        isQuotaExceeded(main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len]))
                    {
                        self.last_api_error = std.fmt.allocPrint(self.arena, "rate limited (429): quota/billing cap — {s}", .{main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len]}) catch "rate limited (429): quota exceeded";
                        if (telemetry.g_telem) |t| t.errorEvent("quota", self.last_api_error orelse "quota exceeded");
                        if (self.tracer) |tr| tr.api(self.label, self.provider.model, 0, body.len, 0, 0, 0, true);
                        return error.ApiError;
                    }
                    if (attempt < max_attempts) {
                        if (throttled) {
                            // #retry-after: prefer the provider's Retry-After
                            // (429/503) over our computed backoff, capped — like
                            // opencode, so we wait exactly as long as the server asked.
                            const server_ra = main_mod.g_retry_after_ms;
                            const delay_ms = if (server_ra > 0) server_ra else RetryPlan.delayMs(throttled, attempt);
                            const ra_note: []const u8 = if (server_ra > 0) " (server retry-after)" else "";
                            const what: []const u8 = if (err == error.RateLimited) "rate limited (429)" else "server error (5xx)";
                            if (main_mod.g_5xx_body_len > 0) {
                                try self.say("[{s}{s} — retrying in {d}s ({d}/{d})] {s}\n", .{ what, ra_note, delay_ms / 1000, attempt + 1, max_attempts, main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len] });
                            } else {
                                try self.say("[{s}{s} — retrying in {d}s ({d}/{d})]\n", .{ what, ra_note, delay_ms / 1000, attempt + 1, max_attempts });
                            }
                            if (self.tracer) |tr| tr.note("retry", if (main_mod.g_5xx_body_len > 0) main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len] else what);
                            self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                        } else {
                            // Transport flake (HttpConnectionClosing, a reset,
                            // a truncated TLS read): back off before a fresh
                            // connection. Rapid-fire retries against a
                            // just-closed keep-alive almost always re-fail
                            // (#86). 250ms·2ⁿ, capped at 4s over 6 tries; Esc cancels.
                            const delay_ms = RetryPlan.delayMs(throttled, attempt);
                            try self.say("[network error: {t} — retrying in {d}ms ({d}/{d})]\n", .{ err, delay_ms, attempt + 1, max_attempts });
                            // Same trace breadcrumb the 429/5xx branch leaves: a
                            // transport-flake retry is otherwise invisible in the
                            // session trace, hiding how flaky a provider really is.
                            if (self.tracer) |tr| tr.note("retry", @errorName(err));
                            self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                        }
                        continue;
                    }
                    if (main_mod.g_5xx_body_len > 0) {
                        try self.say("[request failed: {t} — giving up this turn] {s}\n", .{ err, main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len] });
                    } else {
                        try self.say("[request failed: {t} — giving up this turn]\n", .{err});
                    }
                    // Network give-up is its own error kind: the ApiError
                    // handler's last_api_error would otherwise be an API
                    // envelope, stale or null on a pure transport failure —
                    // record the real reason so the failed turn's --json error
                    // event and trajectory node preserve it (#86).
                    self.last_api_error = std.fmt.allocPrint(self.arena, "network error: {s} (gave up after {d} attempts)", .{ @errorName(err), max_attempts }) catch null;
                    if (telemetry.g_telem) |t| t.errorEvent("net", @errorName(err));
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, 0, body.len, 0, 0, 0, true);
                    return error.ApiError;
                }
            }
        };
        defer self.gpa.free(resp_body);
        const ms: i64 = t0.untilNow(self.io, .awake).toMilliseconds();

        // object — pull the final `response` out of it (or an error).
        // object — pull the final `response` out of it (or an error).
        if (self.provider.kind == .responses) {
            const r = self.parseResponses(resp_body) catch {
                try self.say("unparseable codex response: {s}\n", .{resp_body[0..@min(resp_body.len, 600)]});
                if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                return error.ApiError;
            };
            switch (r) {
                .ok => |obj| {
                    self.recordUsageResponses(obj, body.len);
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                    if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                    return obj;
                },
                .err => |msg| {
                    // (#codex-ws) Belt-and-braces mirror of openai/codex: server
                    // rejected previous_response_id (stale WS session it no
                    // longer recognizes) — close it and retry once with full
                    // input. Gated on codex_prev_id != null (a delta was
                    // actually sent); it's null after the retry, so this can't
                    // loop for this request.
                    if (self.codex_prev_id != null and std.mem.indexOf(u8, msg, "previous_response_id") != null) {
                        self.closeCodexWs();
                        if (self.tracer) |tr| tr.note("ws", "server rejected previous_response_id — re-anchoring with full input");
                        continue :rebuild;
                    }
                    // #174: a context-window rejection means the true input
                    // size blew past the wall while the chained meter lagged —
                    // and the rejected request never returns usage to correct
                    // it, so the meter would stay stuck under compact@ and the
                    // session would wedge (every retry resends the same
                    // oversized history). Pin the meter to the window so the
                    // ApiError compact-and-recover path engages.
                    if (isContextOverflow(msg, null)) {
                        self.last_context_tokens = self.provider.context;
                        // #193: the local pre-send gate uses a byte/4 LOWER bound, so
                        // the backend can still reject an input it let through. A good
                        // harness recovers the turn invisibly instead of failing it:
                        // reclaim room in place and retry the SAME request once
                        // (opencode compactAfterOverflow + rebuild). emergencyTrim does
                        // no summary request, so this can't reenter request(); the guard
                        // means a second overflow falls through to the error below, so we
                        // never loop. closeCodexWs re-anchors so the retry sends the
                        // trimmed full input, not a stale WS delta.
                        if (!context_retried and self.emergencyTrim() > 0) {
                            context_retried = true;
                            self.closeCodexWs();
                            if (self.tracer) |tr| tr.note("context", "input over the window — emergency-trimmed and retrying the turn");
                            continue :rebuild;
                        }
                    }
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                    try self.sayApiError("codex api error: {s}", .{msg});
                    return error.ApiError;
                },
            }
        }

        // Streamed anthropic/openai bodies are SSE too: reassemble them.
        // null → the body wasn't SSE (a JSON error envelope, or a
        // provider that ignored `stream`) — fall through to the regular
        // parse, which also handles the soft-strict retry.
        if (live) {
            if (try self.assembleStream(resp_body)) |root| {
                if (root.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "error")) {
                    const eo = if (root.get("error")) |ev| (if (ev == .object) ev.object else null) else null;
                    const etype = if (eo) |e| (if (e.get("type")) |tv| (if (tv == .string) tv.string else "error") else "error") else "error";
                    const emsg = if (eo) |e| (if (e.get("message")) |mv| (if (mv == .string) mv.string else "") else "") else "";
                    const ecode = if (eo) |e| (if (e.get("code")) |cv| (if (cv == .string) cv.string else null) else null) else null;
                    if (recoverContextOverflow(self, emsg, ecode, &context_retried)) continue; // #193/#203: streamed error event overflow (by code or phrasing) → trim + retry
                    if (try retryTransientServerError(self, etype, ecode, emsg, &server_retries)) continue; // #opencode-parity: transient server overload → retry
                    if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                    try self.sayApiError("api error ({s}): {s}", .{ etype, emsg });
                    return error.ApiError;
                };
                self.recordUsage(root, body.len);
                if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                return root;
            }
        }

        const resp = std.json.parseFromSliceLeaky(Value, self.arena, resp_body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sayApiError("unparseable response: {s}", .{resp_body[0..@min(resp_body.len, 400)]});
            return error.ApiError;
        };
        const root = resp.object;

        if (root.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "error")) {
            const eo = if (root.get("error")) |ev| (if (ev == .object) ev.object else null) else null;
            const etype = if (eo) |e| (if (e.get("type")) |tv| (if (tv == .string) tv.string else "error") else "error") else "error";
            const emsg = if (eo) |e| (if (e.get("message")) |mv| (if (mv == .string) mv.string else "") else "") else "";
            const ecode = if (eo) |e| (if (e.get("code")) |cv| (if (cv == .string) cv.string else null) else null) else null;
            if (recoverContextOverflow(self, emsg, ecode, &context_retried)) continue; // #193/#203: {"type":"error"} overflow (by code or phrasing) → trim + retry
            if (try retryTransientServerError(self, etype, ecode, emsg, &server_retries)) continue; // #opencode-parity: transient server overload → retry
            if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
            try self.sayApiError("api error ({s}): {s}", .{ etype, emsg });
            return error.ApiError;
        };
        if (apiErrorMessage(root)) |msg| {
            if (force and std.mem.indexOf(u8, msg, "tool_choice") != null) {
                force = false; // provider can't force a tool; soft-strict
                continue;
            }
            if (stream_usage and std.mem.indexOf(u8, msg, "stream_options") != null) {
                stream_usage = false; // provider can't report streamed usage
                continue;
            }
            if (!self.cap_new and std.mem.indexOf(u8, msg, "max_completion_tokens") != null) {
                self.cap_new = true; // provider wants the post-deprecation name
                continue;
            }
            if (!self.effort_rejected and mentionsReasoningEffort(msg)) {
                self.effort_rejected = true; // model rejects the effort hint here; drop + retry
                continue;
            }
            // #148: a stale login token 401s here with the provider's "API Key
            // invalid/expired"; force a refresh and retry once (kimi-code's
            // buildAuth(true)). Give up only if the fresh token also fails.
            if (!auth_refreshed and self.provider.source == .login and isAuthError(msg)) {
                if (oauth.refreshOAuthKey(self.io, self.gpa, self.scratchAlloc(), self.home, self.provider.id, true)) |fresh| {
                    auth_refreshed = true;
                    // #124: dupe off the scratch refresh internals — the key must
                    // survive every later request of the session.
                    self.provider.api_key = self.arena.dupe(u8, fresh) catch self.provider.api_key;
                    if (self.tracer) |tr| tr.note("oauth_refresh", "auth error — refreshed login token, retrying");
                    continue;
                }
            }
            // #193 follow-up: recover an anthropic/openai context-window rejection
            // in-turn instead of failing the turn (before this only codex recovered;
            // anthropic and openai died). Shared with the two error branches above.
            // #203: openai-compatible errors arrive here (no top-level "type":"error"),
            // so pull the structured code from root.error.code for isContextOverflow — a
            // local provider whose message text we don't match on still recovers.
            if (recoverContextOverflow(self, msg, errorCode(root), &context_retried)) continue;
            if (try retryTransientServerError(self, "", errorCode(root), msg, &server_retries)) continue; // #opencode-parity: transient server overload → retry, not hard-fail
            if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
            try self.sayApiError("api error: {s}", .{msg});
            return error.ApiError;
        }

        self.recordUsage(root, body.len);
        if (self.tracer) |tr| tr.api(self.label, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
        if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
        return root;
    }
}

pub fn recordUsage(self: *Agent, root: std.json.ObjectMap, req_body_len: usize) void {
    self.last_cache_read = 0;
    // #202: keep the context meter live when the provider omits usage — otherwise
    // the between-turns compaction gate freezes at a stale value and a long session
    // can wedge. Mirror the codex/.responses fallback (req_body_len/4, floored at the
    // full-input estimate) that recordUsageResponses already applies (#174).
    const usage = root.get("usage") orelse return floorContextTokens(self, req_body_len / 4);
    if (usage != .object) return floorContextTokens(self, req_body_len / 4);
    const u = usage.object;
    switch (self.provider.kind) {
        .anthropic => {
            var total: i64 = 0;
            const fields = [_][]const u8{
                "input_tokens",            "output_tokens",
                "cache_read_input_tokens", "cache_creation_input_tokens",
            };
            for (fields) |f| total += usageInt(u, f);
            if (total > 0) self.last_context_tokens = @intCast(total);
            const cache = usageInt(u, "cache_read_input_tokens");
            if (cache > 0) self.last_cache_read = @intCast(cache);
            // cache writes bill ~like input; fold them into uncached input.
            self.recordCost(usageInt(u, "input_tokens") + usageInt(u, "cache_creation_input_tokens"), cache, usageInt(u, "output_tokens"));
        },
        .openai => {
            if (usageInt(u, "total_tokens") > 0) self.last_context_tokens = @intCast(usageInt(u, "total_tokens"));
            // deepseek reports prompt_cache_hit_tokens; the OpenAI shape
            // nests cached_tokens under prompt_tokens_details.
            var cache = usageInt(u, "prompt_cache_hit_tokens");
            if (cache == 0) if (u.get("prompt_tokens_details")) |d| if (d == .object) {
                cache = usageInt(d.object, "cached_tokens");
            };
            if (cache > 0) self.last_cache_read = @intCast(cache);
            self.recordCost(usageInt(u, "prompt_tokens") - cache, cache, usageInt(u, "completion_tokens"));
        },
        // codex uses recordUsageResponses on its own path.
        .responses => {},
    }
}

/// #202: floor the context meter at the local estimate (full-input byte/4, or the
/// request-body byte/4 when the history isn't serialized yet) when the API omits
/// usage, so auto-compaction still triggers. Never lowers an existing higher count.
fn floorContextTokens(self: *Agent, est: u64) void {
    const floor = @max(self.fullInputEstimateTokens(), est);
    if (floor > self.last_context_tokens) self.last_context_tokens = floor;
}

/// An integer usage field, or 0 if absent / wrong type.
pub fn usageInt(obj: std.json.ObjectMap, name: []const u8) i64 {
    if (obj.get(name)) |v| if (v == .integer) return v.integer;
    return 0;
}

/// Record one request's usage into the session-wide tally (g_cost):
/// token counts always; USD only for API-key providers with a
/// price_table row. Subscription providers (codex, claude) bill flat
/// and tally as sub_calls; unpriced models as unpriced_calls.
pub fn recordCost(self: *Agent, uncached_in: i64, cache_in: i64, out: i64) void {
    g_cost.add(self.io, self.provider.id, self.provider.model, uncached_in, cache_in, out);
}

pub const ResponsesResult = union(enum) { ok: std.json.ObjectMap, err: []const u8 };

/// Pull the final `response` object out of a Codex SSE stream. Scans
/// `data:` lines for the last `response.completed`/`response.incomplete`
/// event; reports `response.failed`/`error` events or a plain JSON error
/// body as an error.
pub fn parseResponses(self: *Agent, body: []const u8) !ResponsesResult {
    // The final output items arrive as individual `response.output_item.done`
    // events; `response.completed` carries usage but an empty output array.
    // Collect the done-items and synthesize a {output, usage} object.
    //
    // #124 slice 2b: every SSE event of the stream parses on the per-request
    // scratch arena — the text deltas are the bulk of the body and their parse
    // trees used to pile up on the session arena forever (~30-45 KB/turn
    // measured). Only what escapes this request is detached onto the session
    // arena: the output items (stepResponses appends them to history verbatim)
    // via dupeJsonValue, and the usage/id/error scalars.
    const scratch = self.scratchAlloc();
    var items = std.json.Array.init(self.arena);
    var usage: ?Value = null;
    var resp_id: ?[]const u8 = null; // response.id, for previous_response_id delta continuation (#codex-ws)
    var saw_completed = false;
    var err_msg: ?[]const u8 = null;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
        const v = std.json.parseFromSliceLeaky(Value, scratch, payload, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        const t = v.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "response.output_item.done")) {
            if (v.object.get("item")) |item| try items.append(try util.dupeJsonValue(self.arena, item));
        } else if (std.mem.eql(u8, t.string, "response.completed") or std.mem.eql(u8, t.string, "response.incomplete")) {
            saw_completed = true;
            if (v.object.get("response")) |r| if (r == .object) {
                if (r.object.get("usage")) |u| usage = try util.dupeJsonValue(self.arena, u);
                if (r.object.get("id")) |idv| if (idv == .string) {
                    resp_id = try self.arena.dupe(u8, idv.string);
                };
            };
        } else if (std.mem.eql(u8, t.string, "response.failed") or std.mem.eql(u8, t.string, "error")) {
            err_msg = if (errorMessage(v.object)) |m|
                self.arena.dupe(u8, m) catch "codex stream reported a failure"
            else
                "codex stream reported a failure";
        }
    }
    if (saw_completed or items.items.len > 0) {
        var resp: std.json.ObjectMap = .empty;
        try resp.put(self.arena, "output", .{ .array = items });
        if (usage) |u| try resp.put(self.arena, "usage", u);
        if (resp_id) |rid| try resp.put(self.arena, "id", .{ .string = rid });
        return .{ .ok = resp };
    }
    if (err_msg) |m| return .{ .err = m };
    // Not an SSE stream — maybe a JSON error body (401, rate limit, …). The
    // message is duped off the scratch parse: sayApiError re-formats it onto
    // the session arena, but the retry loop may also inspect it after another
    // rebuild iteration reset the scratch arena.
    const v = std.json.parseFromSliceLeaky(Value, scratch, body, .{ .allocate = .alloc_always }) catch return error.Unparseable;
    if (v == .object) if (errorMessage(v.object)) |m|
        return .{ .err = self.arena.dupe(u8, m) catch "unparseable provider error" };
    return error.Unparseable;
}

pub fn errorMessage(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) return m.string;
        } else if (e == .string) return e.string;
    }
    if (obj.get("response")) |r| if (r == .object) {
        if (r.object.get("error")) |e| if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) return m.string;
        };
    };
    if (obj.get("detail")) |d| if (d == .string) return d.string;
    if (obj.get("message")) |m| if (m == .string) return m.string;
    return null;
}

/// #174: ~4-bytes/token estimate of the FULL history serialized as Responses
/// `input` items — the cost of the next full-history resend (runTurn closes
/// the WS per turn, so every turn's first request replays everything). The
/// chained WS usage can sit far below this: with previous_response_id the
/// server discards prior-turn reasoning from context, while a resend pays for
/// every retained encrypted reasoning item again. Counting discard writer —
/// no allocation.
pub fn fullInputEstimateTokens(self: *Agent) u64 {
    var buf: [512]u8 = undefined;
    var d: Io.Writer.Discarding = .init(&buf);
    var s: std.json.Stringify = .{ .writer = &d.writer };
    // On a serialize failure, fall back to the bytes counted so far, never a
    // spurious 0 — a 0 here would blind the pre-send gate (inputOverCompactThreshold)
    // AND the #202 meter floor (recordUsageResponses) at once. The Discarding sink is
    // infallible today so this catch is unreachable; it future-proofs a stricter sink.
    s.write(Value{ .array = self.messages }) catch return d.fullCount() / 4;
    return d.fullCount() / 4;
}

/// Pre-send overflow gate (#193). `last_context_tokens` only updates from the
/// server's returned usage, so it lags tool output appended *within* a turn: a
/// burst of large tool results can push this turn's input past the model's wall
/// before the between-turns 80% meter ever sees it (the "input exceeds the
/// context window" rejection on codex/gpt-5.x). Estimating the full input
/// locally before each request lets the turn loop compact first — the analogue
/// of codex's run_pre_sampling_compact / opencode's isOverflow-before-each-turn.
/// Guarded on a known window (compactAt()==0 → don't compact blindly).
pub fn inputOverCompactThreshold(self: *Agent) bool {
    const threshold = self.provider.compactAt();
    if (threshold == 0) return false;
    // The server-reported meter (the same last_context_tokens the between-turns
    // gates at mainloop.zig:683/734 already trust) is refreshed mid-turn by
    // recordUsageResponses (agent_request.zig:905/924). On codex/.responses it can
    // sit far above the local byte/4 estimate — retained encrypted-reasoning items
    // are billed server-side but the local serialize under-counts them — so on a
    // long turn it held ~511k while fullInputEstimateTokens stayed under the wall
    // and the next resend was rejected for "input exceeds the context window"
    // before any compaction ran. Trip a pre-send compact on the accurate meter too.
    if (self.last_context_tokens >= threshold) return true;
    // #203: fullInputEstimateTokens omits the ever-present system prompt + tool
    // schemas, so it undercounts the real input and this gate under-fires. Add a
    // baseline for that fixed prefill, clamped to 1/8 of the window so it can never
    // dominate a small (local) window. (Kept out of fullInputEstimateTokens itself,
    // which must stay pure over self.messages for the unit tests.)
    const prefill_baseline_tokens: u64 = 8000;
    const prefill = @min(prefill_baseline_tokens, self.provider.context / 8);
    return fullInputEstimateTokens(self) + prefill >= threshold;
}

test "inputOverCompactThreshold (#193): local estimate gates a pre-send compact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    var agent: Agent = undefined;
    agent.messages = msgs;
    agent.last_context_tokens = 0; // the gate now reads this too; `= undefined` won't apply the field default
    // small window: compactAt() = 10_000/10*8 = 8_000 tokens ≈ 32_000 serialized bytes
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 10_000 };
    try std.testing.expect(!inputOverCompactThreshold(&agent)); // empty history → under
    // one fat tool output (~40KB serialized ≈ 10k est tokens) crosses 8k in a single append
    const big = "{\"type\":\"function_call_output\",\"output\":\"" ++ ("x" ** 40000) ++ "\"}";
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, big, .{}));
    agent.messages = msgs;
    try std.testing.expect(inputOverCompactThreshold(&agent)); // burst → over → compact before send
    // the server-reported meter alone trips the gate even with an empty local history —
    // the codex mid-turn case where retained reasoning items undercount the byte/4 estimate
    agent.messages = std.json.Array.init(a);
    agent.last_context_tokens = agent.provider.compactAt();
    try std.testing.expect(inputOverCompactThreshold(&agent));
    agent.last_context_tokens = 0;
    // unknown window (context 0) never gates
    agent.provider.context = 0;
    try std.testing.expect(!inputOverCompactThreshold(&agent));
}

pub fn recordUsageResponses(self: *Agent, response: std.json.ObjectMap, req_body_len: usize) void {
    self.last_cache_read = 0;
    // Fallback estimate (~4 bytes/token) from the serialized request body,
    // which holds the full conversation — keeps the ctx meter and the
    // compact@ trigger live when codex omits usage counts entirely.
    const est: u64 = req_body_len / 4;
    const usage = response.get("usage") orelse {
        if (est > 0) self.last_context_tokens = est;
        return;
    };
    if (usage != .object) {
        if (est > 0) self.last_context_tokens = est;
        return;
    }
    const u = usage.object;
    const in_tokens = usageInt(u, "input_tokens");
    const out_tokens = usageInt(u, "output_tokens");
    const total_tokens = usageInt(u, "total_tokens");
    if (total_tokens > 0) {
        self.last_context_tokens = @intCast(total_tokens);
    } else {
        // Some Codex/Responses builds report only input/output counts.
        // Still surface the prompt token counter instead of leaving the
        // prompt stuck at "model · sub" with no context usage.
        const computed_total = in_tokens + out_tokens;
        if (computed_total > 0) {
            self.last_context_tokens = @intCast(computed_total);
        } else if (est > 0) {
            self.last_context_tokens = est;
        }
    }
    // #174: the server's chained number undercounts what the next full-history
    // resend will cost, and the resend is the request that gets rejected — so
    // the meter must never sit below the local full-input estimate. Same
    // correction codex CLI applies (get_non_last_reasoning_items_tokens).
    // Without it a long Extra-high session reads "95k/270k" right up until the
    // backend rejects the resend for exceeding the window, and auto-compaction
    // (gated on this meter) never rescues it.
    const full_est = fullInputEstimateTokens(self);
    if (full_est > self.last_context_tokens) self.last_context_tokens = full_est;
    var cached: i64 = 0;
    if (u.get("input_tokens_details")) |d| if (d == .object) {
        cached = usageInt(d.object, "cached_tokens");
        if (cached > 0) self.last_cache_read = @intCast(cached);
    };
    self.recordCost(in_tokens - cached, cached, out_tokens);
}

pub fn buildBody(self: *Agent, tools: ?[]const u8, force_tool: bool, stream: bool, stream_usage: bool) ![]u8 {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(self.provider.model);
    switch (self.provider.kind) {
        .anthropic => {
            try s.objectField("max_tokens");
            try s.write(max_tokens);
            if (stream) {
                try s.objectField("stream");
                try s.write(true);
            }
            // Forced tool_choice conflicts with adaptive thinking; skip
            // thinking only when forcing.
            if (!force_tool) {
                try s.objectField("thinking");
                try s.print("{s}", .{"{\"type\":\"adaptive\"}"});
            }
            // Prompt caching (Anthropic): a cache_control breakpoint on the
            // system block caches the whole stable prefix (system + tools).
            // Must be block-level — a top-level cache_control is invalid.
            // Other anthropic-format providers (minimax) get a plain
            // string, since cache_control isn't part of their API.
            try s.objectField("system");
            const cc = "{\"type\":\"ephemeral\"}";
            if (std.mem.eql(u8, self.provider.id, "anthropic")) {
                try s.beginArray();
                try s.beginObject();
                try s.objectField("type");
                try s.write("text");
                try s.objectField("text");
                try s.write(self.systemPrompt());
                try s.objectField("cache_control");
                try s.print("{s}", .{cc});
                try s.endObject();
                try s.endArray();
            } else {
                try s.write(self.systemPrompt());
            }
            if (tools) |t| {
                try s.objectField("tools");
                try s.print("{s}", .{t});
                if (force_tool) {
                    try s.objectField("tool_choice");
                    try s.print("{s}", .{"{\"type\":\"any\"}"});
                }
            }
            try s.objectField("messages");
            // Cache the conversation prefix too (not just system) on the real
            // Anthropic API: a rolling cache_control breakpoint on the last
            // message. minimax (anthropic-format, no cache_control) is excluded.
            const cache_msgs = std.mem.eql(u8, self.provider.id, "anthropic");
            try writeAnthropicMessages(&s, self.messages, cache_msgs);
        },
        .openai => {
            // graff's MakeOpenAiCompat: OpenAI deprecated max_tokens in
            // favor of max_completion_tokens — send the new name to the
            // direct OpenAI API, and to any provider that rejected the
            // old one (cap_new, learned via the retry in request()).
            const cap_field = if (std.mem.eql(u8, self.provider.id, "openai") or self.cap_new)
                "max_completion_tokens"
            else
                "max_tokens";
            try s.objectField(cap_field);
            try s.write(max_tokens);
            if (stream) {
                try s.objectField("stream");
                try s.write(true);
                // Without include_usage the stream carries no token
                // counts (context tracking + auto-compaction need them).
                if (stream_usage) {
                    try s.objectField("stream_options");
                    try s.print("{s}", .{"{\"include_usage\":true}"});
                }
            }
            if (tools) |t| {
                try s.objectField("tools");
                try s.print("{s}", .{t});
                if (force_tool) {
                    try s.objectField("tool_choice");
                    try s.write("required");
                }
            }
            try s.objectField("messages");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("role");
            try s.write("system");
            try s.objectField("content");
            try s.write(self.systemPrompt());
            try s.endObject();
            for (self.messages.items) |m| try writeOpenAIMessageNormalized(&s, m);
            try s.endArray();
            // Reasoning-effort hint for OpenAI-compatible providers that
            // honor it (codegraff gateway, deepseek). Mirrors the
            // Responses `reasoning.effort` set in the branch below.
            if (self.effortApplies() and !self.effort_rejected) {
                try s.objectField("reasoning_effort");
                try s.write(if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
            }
            // Kimi K2.7's model card recommends temperature 1.0 + top_p 0.95
            // for its (always-on) Thinking mode; graff otherwise leaves
            // sampling to the server default.
            if (std.mem.eql(u8, self.provider.id, "kimi")) {
                try s.objectField("temperature");
                try s.write(@as(f64, 1.0));
                try s.objectField("top_p");
                try s.write(@as(f64, 0.95));
            }
        },
        .responses => {
            // Codex / ChatGPT Responses API. system prompt → instructions;
            // history items are valid input items; stream is required by
            // the backend (we buffer + parse the SSE). reasoning items are
            // returned encrypted and passed back for cross-turn continuity.
            try s.objectField("instructions");
            try s.write(self.systemPrompt());
            // Codex WS delta: once a response.id is held on a live WS session,
            // send previous_response_id + only the items the server does not yet
            // hold, instead of the full history (avoids the huge frame that the
            // backend rejects → WriteFailed). Full input otherwise (first turn/SSE).
            if (self.codex_ws != null) if (self.codex_prev_id) |pid| {
                try s.objectField("previous_response_id");
                try s.write(pid);
            };
            try s.objectField("input");
            if (self.codex_ws != null and self.codex_prev_id != null and self.codex_sent_upto <= self.messages.items.len) {
                var delta = std.json.Array.init(self.arena);
                for (self.messages.items[self.codex_sent_upto..]) |m| try delta.append(m);
                try s.write(Value{ .array = delta });
            } else {
                try s.write(Value{ .array = self.messages });
            }
            if (tools) |t| {
                try s.objectField("tools");
                try s.print("{s}", .{t});
                try s.objectField("tool_choice");
                try s.write(if (force_tool) "required" else "auto");
                try s.objectField("parallel_tool_calls");
                try s.write(true);
            }
            // Codex "fast" mode (/fast): request the priority service
            // tier for lower latency. This branch is codex-only, so it is
            // never emitted for other providers.
            if (self.fast) {
                try s.objectField("service_tier");
                try s.write("priority");
            }
            try s.objectField("reasoning");
            try s.beginObject();
            try s.objectField("effort");
            // Ultra is a Graff/Codex client preset: maximum server reasoning
            // plus automatic delegation. The backend wire value is `max`.
            try s.write(if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
            try s.endObject();
            try s.objectField("include");
            try s.beginArray();
            try s.write("reasoning.encrypted_content");
            try s.endArray();
            try s.objectField("store");
            try s.write(false);
            try s.objectField("stream");
            try s.write(true);
        },
    }
    try s.endObject();
    return aw.toOwnedSlice();
}
