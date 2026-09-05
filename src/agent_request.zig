//! Provider round trip and retry loop.
//!
//! Request policy, context accounting, Responses reassembly, and body
//! serialization live in focused sibling modules and are re-exported here so
//! Agent's public method aliases remain source-compatible.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;

const messages_mod = @import("messages.zig");
const sanitizeMessagesUtf8 = messages_mod.sanitizeMessagesUtf8;
const normalizeResponsesHistory = messages_mod.normalizeResponsesHistory;
const normalizeOpenAIHistory = messages_mod.normalizeOpenAIHistory;

const http = @import("http.zig");
const http_headers = @import("http_headers.zig");
const postWatched = http.postWatched;
const RetryPlan = http.RetryPlan;

const tools_mod = @import("tools.zig");
const apiErrorMessage = tools_mod.apiErrorMessage;
const mentionsReasoningEffort = tools_mod.mentionsReasoningEffort;
const telemetry = @import("telemetry.zig");
const tool_spill = @import("tool_spill.zig"); // #409: did the cap preserve the bytes, or destroy them?
const run_budget_mod = @import("run_budget.zig");
const wire_messages = @import("messages.zig");
const policy = @import("agent_request_policy.zig");

const overflow = @import("agent_overflow.zig");
const errorCode = policy.errorCode;
const isQuotaExceeded = policy.isQuotaExceeded;
const recoverContextOverflow = overflow.recoverContextOverflow;
// #414: an HTTP 200 that overflowed silently — the provider accepted an
// over-window input and answered with nothing (z.ai), or truncated our input
// to fit and had no room left to generate (MiMo). Neither shape produces an
// error to keyword-match, so it is classified from the reported usage instead.
const recoverBehavioralOverflow = overflow.recoverBehavioralOverflow;
const retryAfterAuthRefresh = policy.retryAfterAuthRefresh;
const retryTransientServerError = policy.retryTransientServerError;

const context = @import("agent_context.zig");
pub const recordUsage = context.recordUsage;
pub const usageInt = context.usageInt;
pub const recordCost = context.recordCost;
pub const fullInputEstimateTokens = context.fullInputEstimateTokens;
pub const fullRequestEstimateTokens = context.fullRequestEstimateTokens;
pub const contextEstimate = context.contextEstimate;
pub const contextEstimateFromInputBytes = context.contextEstimateFromInputBytes;
pub const effectiveContextTokens = context.effectiveContextTokens;
pub const pairContextMeterWithCurrentLocal = context.pairContextMeterWithCurrentLocal;
pub const rebaseContextMeter = context.rebaseContextMeter;
pub const inputOverCompactThreshold = context.inputOverCompactThreshold;
pub const recordUsageResponses = context.recordUsageResponses;

const responses = @import("agent_responses.zig");
pub const ResponsesFailure = responses.ResponsesFailure;
pub const ResponsesResult = responses.ResponsesResult;
pub const parseResponses = responses.parseResponses;
pub const errorMessage = responses.errorMessage;

pub const buildBody = @import("agent_request_body.zig").buildBody;
const codex_chain = @import("codex_chain.zig");

const req_stats = @import("req_stats.zig"); // GRAFF_REQ_STATS anatomy (session_settings arms req_stats.g_armed)
const scratch = @import("agent_request_scratch.zig");

/// #390 — appended once, on the run's final admitted model call, right where
/// the tools disappear, so the model knows WHY and lands instead of retrying.
pub const landing_note =
    "[budget landing] This is the final model call this run's --max-model-calls budget admits, so " ++
    "no tools are offered. Land the answer NOW from the evidence already gathered: state what was " ++
    "completed and what was verified, then name what remains unchecked. Honestly-labeled partial " ++
    "results beat dying mid-tool-call.";

pub fn request(self: *Agent, tools_in: ?[]const u8) !std.json.ObjectMap {
    // Root and title requests rendezvous after launch-time CA loading.
    http.waitForClientReady(self.io);
    if (http.takeCaWarmFailure()) if (self.tracer) |tr| tr.note("ca_prewarm_failed", "CA bundle rescan failed; request will use lazy TLS initialization");
    if (self.registry) |reg| {
        if (@import("mcp_boot.zig").joinBeforeRequest(reg)) {
            self.invalidateRootTools();
            try self.ensureRootTools(self.provider.kind);
        }
    }
    var budget_permit: ?run_budget_mod.Permit = null;
    if (self.run_budget) |budget| {
        const kind: run_budget_mod.CallKind = if (self.compaction_request) .compaction else self.call_kind;
        budget_permit = budget.acquire(self.io, self.depth, kind) catch |err| {
            self.last_api_error = switch (err) {
                error.RunBudgetExhausted => "model-call budget exhausted for this graff run — restart or raise --max-model-calls",
                error.AgentDepthExceeded => "agent depth limit reached (max depth 1)",
                else => @errorName(err),
            };
            if (self.tracer) |tr| tr.note("budget", self.last_api_error.?);
            return err;
        };
    }
    defer if (budget_permit) |*permit| permit.release();
    // #390 — the landing reserve's root half: the pool's FINAL admitted call
    // belongs to the answer. Offer no tools (compaction's trick) and say why,
    // so the model lands a text answer now instead of asking for a tool the
    // budget can never pay for — which is how the audit smoke died narrating.
    // compaction/title requests pass tools=null already and skip this whole.
    var tools = tools_in;
    if (self.tracer) |tr| {
        if (tools) |t| if (t.len == 0) tr.note("tools", "empty catalog at request time (#695)");
    }
    if (self.run_budget) |b| if (budget_permit) |p| {
        if (b.max_model_calls != 0 and p.call_number == b.max_model_calls and tools != null) {
            tools = null;
            try self.messages.append(try wire_messages.textMessage(self.arena, "user", landing_note));
            if (self.tracer) |tr| tr.note("budget", "final call: tools withheld so the run lands its answer (#390)");
        }
    };
    self.last_request_context_overflow = false;
    self.last_request_write_failed = false;
    self.last_usage_includes_output = false;
    var force = !self.review_mode and (self.strict or self.eval_cmd != null or self.named_work_nudges > 0) and tools != null;
    var stream_usage = true; // openai stream_options; dropped if rejected
    var auth_refreshed = false; // #148: at most one forced token refresh + retry
    // #124: reclaim last request's transient parse garbage FIRST, so everything
    // below (per-event parse trees, tool-arg parses) can use the scratch arena
    // for this request. Safe: all scratch data is
    // consumed before the next request(); messages/todos/prompts live on the
    // session arena.
    if (self.scratch_arena) |sa| scratch.reset(sa);
    // #148/#402: a login-sourced OAuth token expires mid-session and is minted
    // only at startup; pick up whatever is currently on disk before the call, so
    // a long session — or a subagent that inherited the token — never 401s over
    // a credential somebody has already replaced. Login-sourced keys only (env
    // keys untouched), and see refreshLoginKeyBeforeSend for why its transients
    // do NOT go on the scratch arena.
    policy.refreshLoginKeyBeforeSend(self);
    // #95: scrub any malformed function_call_output before it hits the wire.
    const message_arena = self.messageMutationAlloc();
    sanitizeMessagesUtf8(message_arena, &self.messages); // invalid UTF-8 (any source/format) -> '?' so content never serializes as a byte-int array the API rejects
    if (self.provider.kind == .responses) normalizeResponsesHistory(message_arena, &self.messages);
    if (self.provider.kind == .openai) normalizeOpenAIHistory(message_arena, &self.messages); // #99: chat-completions sibling of the above
    // #193 follow-up: bound any single oversized tool output (an uncapped MCP
    // result, a huge fetch on a small-window model) before send. The responses
    // path already hard-caps output above (normalizeResponsesHistory); this is the
    // provider-agnostic sibling so one pathological result can't alone overflow the
    // window past what the in-turn recovery below can reclaim (it keeps the most
    // recent outputs verbatim). Window-proportional, so large-context models keep
    // full tool results untouched.
    //
    // #440 narrowed this to a BACKSTOP. Every tool result this process produced
    // already met the handle contract at tool time, under a threshold clamped to
    // this very cap (tool_handle.effectiveThreshold), so nothing from runTools can
    // reach here oversized. What still can: a session resumed from a build that
    // predates #440, and any future path that appends a tool output without going
    // through runTools. Both are exactly the cases where destroying the bytes
    // would be the alternative, so the pass stays.
    const spills_before = tool_spill.spillCount();
    const capped = self.capOversizedToolOutputs(self.provider.perOutputCap());
    if (capped > 0) {
        // #202: don't truncate silently. The model already sees an inline marker;
        // surface it to the trace and (interactively) to the user too. #409: say
        // which of the two happened — the elided bytes are only GONE when there
        // was no durable session to spill them to.
        const spilled = tool_spill.spillCount() > spills_before;
        if (self.tracer) |tr| tr.note("context", if (spilled)
            "capped an oversized tool output before send (full bytes kept as a session artifact)"
        else
            "capped an oversized tool output before send");
        if (!main_mod.json_mode and !self.sub) {
            if (spilled)
                self.say("[tool output over this model's per-result cap — {d} bytes elided before send; the full output is in this session's artifacts and the model has the path (#409)]\n", .{capped}) catch {}
            else
                self.say("[tool output over this model's per-result cap — truncated {d} bytes before send (#193)]\n", .{capped}) catch {};
        }
    }
    var context_retried = false; // #193: at most one in-turn overflow recovery per request
    // #56: bounded stream-stall / drop reconnect budget (codex's stream_max_retries analog), outside the rebuild loop so a WS reanchor can't reset it.
    self.stall = .{}; // #680: a fresh widen ladder + tripped budget per request
    var stall_retries: usize = 0;
    const max_stall_retries: usize = 2;
    const stall_reconnect_backoff_ms = 750; // brief pause before reconnecting on a fresh stream
    var server_retries: usize = 0; // #opencode-parity: bounded retries for a transient in-stream server overload
    var openai404_retries: usize = 0; // #opencode-parity: bounded retries for OpenAI's spurious model 404s
    const max_openai404_retries: usize = 2;
    var gw_retry = policy.GatewayRetryState{}; // #gateway-artifact state (agent_gateway_retry.zig)
    rebuild: while (true) {
        const live = self.usesLiveTransport();
        self.streamed_text = false;
        self.streamed_args = .none;
        const body = try self.buildBody(tools, force, live, stream_usage);
        defer self.gpa.free(body);
        if (!self.sub) {
            const hud = @import("prompt_cache_hud.zig");
            hud.noteRequest(self.io, self.systemPrompt(), tools orelse "");
            var aff_buf: [96]u8 = undefined;
            hud.noteAffinity(
                http_headers.promptCacheKey(self.io, self.label, self, &aff_buf),
                std.mem.eql(u8, self.provider.id, "xai"),
                self.provider.kind == .responses,
            );
        }
        // GRAFF_REQ_STATS=1: per-call request anatomy + body dumps (req_stats.zig).
        req_stats.report(self.io, body, tools, self.sys_normal);
        const t0: Io.Timestamp = .now(self.io, .awake);
        self.request_started = t0;
        self.first_token_traced = false;
        if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_started", .provider = self.provider.id, .model = self.provider.model });
        // HTTP calls are flaky: a kept-alive connection the server closed
        // (HttpConnectionClosing), a reset, a truncated TLS read. Retry a
        // few times with a fresh connection; on persistent failure surface
        // error.ApiError so the REPL returns to the prompt, never crashes.
        const resp_body = blk: {
            var attempt: usize = 0;
            var retry_limit: ?usize = null;
            while (true) : (attempt += 1) {
                var conv_buf: [96]u8 = undefined;
                const conv = http_headers.promptCacheKey(self.io, self.label, self, &conv_buf);
                const attempt_body = if (live)
                    self.postLive(body)
                else
                    postWatched(self.gpa, self.io, self.client, self.provider, body, conv);
                if (attempt_body) |ok| break :blk ok else |err| {
                    if (err == error.ModelLoop) return err;
                    if (self.streamed_text) if (self.out) |w| {
                        w.writeAll("\n") catch {};
                        w.flush() catch {};
                    };
                    self.streamed_text = false;
                    self.streamed_args = .none;
                    // Esc and task cancellation are deliberate stops, not flaky
                    // transport. In particular, session-close cancellation of a
                    // detached title must not launch a replacement request.
                    if (err == error.Interrupted) return error.Interrupted;
                    if (err == error.Canceled) return error.Canceled;
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
                            if (self.tracer) |tr| tr.note("stream_retry", what);
                            if (telemetry.g_telem) |t| t.errorEvent("stream_retry", what);
                            @import("agent_stream.zig").noteStallRetry(self, stall_retries); // #680: clears the partial (fresh stream, no concat) + widens the between-lines budget
                            self.closeCodexWs(); // tear down the dead WS + null codex_prev_id for a full re-send (no-op off codex WS)
                            self.sleepInterruptible(stall_reconnect_backoff_ms) catch return error.Interrupted;
                            continue :rebuild;
                        }
                        // Budget gone: the turn is ending. Mid-turn cuts stayed silent.
                        @import("engine_sink.zig").forAgent(self).emit(self.io, .{ .transport_aborted = .{ .reason = if (stalled) .stalled else .dropped, .turn_ending = true } });
                        if (stalled) {
                            self.last_api_error = @import("agent_stream.zig").stallGiveUpMessage(self, max_stall_retries); // #680: reports the wait that tripped, not the configured total
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
                    const max_attempts = retry_limit orelse RetryPlan.maxAttempts(throttled);
                    retry_limit = max_attempts;
                    // #opencode-parity: a 429 that's a billing/quota cap (not
                    // transient throttling) won't clear by retrying — fail fast so
                    // cross-provider /fallback can take over, instead of burning all
                    // 5 attempts (~23s). Detected from the captured 429 body.
                    if (err == error.RateLimited and main_mod.g_5xx_body_len > 0 and
                        isQuotaExceeded(main_mod.g_5xx_body_buf[0..main_mod.g_5xx_body_len]))
                    {
                        // #471: a flat-rate plan that has run out is exactly
                        // when the metered key it outranked earns its keep.
                        // Hand over and retry rather than failing a session
                        // with a working credential sitting unused. One-way
                        // and announced — see credential_failover.
                        if (policy.handOffExhaustedPlan(self)) continue;
                        self.last_api_error = std.fmt.allocPrint(self.arena, "rate limited (429): {s}", .{policy.quota_cap_marker}) catch "rate limited (429): quota exceeded";
                        if (telemetry.g_telem) |t| t.errorEvent("quota", self.last_api_error orelse "quota exceeded");
                        if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, 0, body.len, 0, 0, 0, true);
                        return error.ApiError;
                    }
                    if (err == error.TlsRequestConstructionFailed or err == error.TlsRequestConstructionCaWarmFailed) if (self.tracer) |tr| tr.note(
                        "tls_request_construction",
                        if (err == error.TlsRequestConstructionCaWarmFailed) "rotated shared HTTP client generation; replacement CA prewarm failed" else "rotated shared HTTP client generation",
                    );
                    if (attempt + 1 < max_attempts) {
                        if (throttled) {
                            // #retry-after: prefer the provider's Retry-After
                            // (429/503) over our computed backoff, capped — like
                            // opencode, so we wait exactly as long as the server asked.
                            const server_ra = main_mod.g_retry_after_ms;
                            const delay_ms = if (server_ra > 0) server_ra else RetryPlan.delayMs(throttled, attempt);
                            const ra_note: []const u8 = if (server_ra > 0) " (server retry-after)" else "";
                            const what: []const u8 = if (err == error.RateLimited) "rate limited (429)" else "server error (5xx)";
                            // Never echo the captured 429/5xx body. Envelopes from
                            // OpenRouter and similar include user ids, BYOK/settings
                            // URLs, and routing docs. Classifiers still read g_5xx_body_buf.
                            try self.say("[{s}{s} — retrying in {d}s ({d}/{d})]\n", .{ what, ra_note, delay_ms / 1000, attempt + 1, max_attempts });
                            policy.noteRetry(self, what);
                            self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                        } else {
                            // Transport flakes back off; rapid retries against a
                            // just-closed keep-alive re-fail (#86). Cap: 4s/6 tries.
                            const delay_ms = RetryPlan.delayMs(throttled, attempt);
                            @import("turn_chrome.zig").emitRetryNotice(self.io, @errorName(err), attempt + 1, max_attempts);
                            if (scratch.showRecoveredTransportRetry(self.call_kind))
                                try self.say("[network error: {t} — retrying in {d}ms ({d}/{d})]\n", .{ err, delay_ms, attempt + 1, max_attempts });
                            // Same trace breadcrumb the 429/5xx branch leaves: a
                            // transport-flake retry is otherwise invisible in the
                            // session trace, hiding how flaky a provider really is.
                            policy.noteFlake(self, &gw_retry, err);
                            self.sleepInterruptible(delay_ms) catch return error.Interrupted;
                        }
                        continue;
                    }
                    try self.say("[request failed: {t} — giving up this turn]\n", .{err});
                    // Preserve whether this was provider throttling or a transport failure in the failed turn's JSON/trajectory (#86).
                    const failure_kind = if (err == error.RateLimited) "rate limited (429)" else if (err == error.ServerError) "server error (5xx)" else "network error";
                    self.last_api_error = std.fmt.allocPrint(self.arena, "{s}: {s} (gave up after {d} attempts)", .{ failure_kind, @errorName(err), max_attempts }) catch null;
                    self.last_request_write_failed = std.mem.eql(u8, @errorName(err), "WriteFailed");
                    if (telemetry.g_telem) |t| t.errorEvent("net", @errorName(err));
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, 0, body.len, 0, 0, 0, true);
                    return error.ApiError;
                }
            }
        };
        defer self.gpa.free(resp_body);
        const ms: i64 = t0.untilNow(self.io, .awake).toMilliseconds();
        if (!live) self.traceFirstToken();

        // object — pull the final `response` out of it (or an error).
        if (self.provider.kind == .responses) {
            const r = self.parseResponses(resp_body) catch {
                // Preserve a useful last_api_error without copying an unparsed
                // provider envelope: it may contain echoed request/auth data.
                const diagnostic = try responses.failureDiagnostic(self.arena, self.provider.id, .{ .message = "unparseable codex response" });
                try self.sayApiError("{s}", .{diagnostic});
                if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                return error.ApiError;
            };
            switch (r) {
                .ok => |obj| {
                    if (!self.compaction_request) self.compact_transport_failures = 0;
                    self.recordUsageResponses(obj, body.len);
                    // #414: an empty output whose usage already fills the window
                    // is an overflow the provider never reported. Re-anchor like
                    // the error branch above: the recovery trims full history.
                    if (recoverBehavioralOverflow(self, obj, &context_retried)) {
                        self.closeCodexWs();
                        continue :rebuild;
                    }
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                    if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                    try @import("agent_model_loop.zig").checkResponse(self, obj);
                    return obj;
                },
                .err => |failure| {
                    const msg = failure.message;
                    const ws_error_frame = self.ws_api_error_pending;
                    self.ws_api_error_pending = false;
                    const diagnostic = try responses.failureDiagnostic(self.arena, self.provider.id, failure);
                    if (ws_error_frame) if (self.tracer) |tr| tr.note("ws_api_error", diagnostic);
                    if (codex_chain.shouldReanchorRequest(body, msg, failure.code)) {
                        self.closeCodexWs();
                        if (self.tracer) |tr| tr.note("ws", "server dropped previous_response_id — re-anchoring with full input");
                        continue :rebuild;
                    }
                    // #174: a context-window rejection means the true input
                    // size blew past the wall while the chained meter lagged —
                    // and the rejected request never returns usage to correct
                    // it, so the meter would stay stuck under compact@ and the
                    // session would wedge (every retry resends the same
                    // oversized history). Pin the meter to the window so the
                    // ApiError compact-and-recover path engages.
                    if (recoverContextOverflow(self, msg, failure.code, &context_retried)) {
                        // Responses may have sent a previous_response_id delta.
                        // Re-anchor after the shared recovery trims full history.
                        self.closeCodexWs();
                        continue :rebuild;
                    }
                    // #402: a ChatGPT-backend 401 ("Provided authentication
                    // token is expired") lands here as a plain JSON error body,
                    // so the #148 reactive refresh further down — which only
                    // anthropic/openai bodies reach — never saw it. Auth-expired
                    // was terminal on this path: the session, and every
                    // auto-compaction it triggered, 401'd forever even after a
                    // successful /login.
                    if (retryAfterAuthRefresh(self, msg, &auth_refreshed)) {
                        // PR #195: a mid-turn resend must re-anchor — the chained
                        // WS meter desyncs otherwise — and the held socket was
                        // dialed with the stale bearer besides.
                        self.closeCodexWs();
                        continue :rebuild;
                    }
                    // Codex Responses reports capacity failures through this
                    // response.failed arm too. Keep it on the same bounded
                    // overload retry path as SSE and JSON error envelopes.
                    if (try policy.afterServerErrorOrParseReject(self, "", failure.code, msg, &server_retries, &gw_retry)) continue :rebuild;
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                    try self.sayApiError("{s}", .{diagnostic});
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
                    if (try policy.afterServerErrorOrParseReject(self, etype, ecode, emsg, &server_retries, &gw_retry)) continue;
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                    try self.sayApiError("api error ({s}): {s}", .{ etype, emsg });
                    return error.ApiError;
                };
                self.recordUsage(root, body.len);
                if (recoverBehavioralOverflow(self, root, &context_retried)) continue; // #414: silent overflow / upstream truncation → trim + retry
                if (!self.compaction_request) self.compact_transport_failures = 0;
                if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                try @import("agent_model_loop.zig").checkResponse(self, root);
                return root;
            }
        }

        const resp = std.json.parseFromSliceLeaky(Value, self.messageMutationAlloc(), resp_body, .{
            .allocate = .alloc_always,
        }) catch {
            if (try scratch.retryKeepAliveOnly(self, resp_body, &server_retries)) continue;
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
            if (try policy.afterServerErrorOrParseReject(self, etype, ecode, emsg, &server_retries, &gw_retry)) continue;
            if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
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
            // #543: a provider without json_schema structured outputs (deepseek:
            // "This response_format type is unavailable now") must not lose the
            // --output-schema contract — retry in json_object mode with the
            // schema moved into the prompt, on the same ladder as cap_new.
            if (self.output_schema != null and !self.sox_json_object and
                (std.mem.indexOf(u8, msg, "response_format") != null or
                    std.mem.indexOf(u8, msg, "output_config") != null))
            {
                self.sox_json_object = true;
                continue;
            }
            if (!self.effort_rejected and mentionsReasoningEffort(msg)) {
                self.effort_rejected = true; // model rejects the effort hint here; drop + retry
                continue;
            }
            // #148: a stale login token 401s here with the provider's "API Key
            // invalid/expired"; adopt a newer on-disk token or force a refresh
            // and retry once (kimi-code's buildAuth(true)). Give up only if the
            // fresh token also fails. No closeCodexWs — this branch is never on
            // the codex WS.
            if (retryAfterAuthRefresh(self, msg, &auth_refreshed)) continue;
            // #193 follow-up: recover an anthropic/openai context-window rejection
            // in-turn instead of failing the turn (before this only codex recovered;
            // anthropic and openai died). Shared with the two error branches above.
            // #203: openai-compatible errors arrive here (no top-level "type":"error"),
            // so pull the structured code from root.error.code for isContextOverflow — a
            // local provider whose message text we don't match on still recovers.
            if (recoverContextOverflow(self, msg, errorCode(root), &context_retried)) continue;
            if (try policy.afterServerErrorOrParseReject(self, "", errorCode(root), msg, &server_retries, &gw_retry)) continue;
            if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
            try self.sayApiError("api error: {s}", .{msg});
            return error.ApiError;
        }

        self.recordUsage(root, body.len);
        if (recoverBehavioralOverflow(self, root, &context_retried)) continue; // #414: same, on the non-streamed body
        if (!self.compaction_request) self.compact_transport_failures = 0;
        if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
        if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
        try @import("agent_model_loop.zig").checkResponse(self, root);
        return root;
    }
}
