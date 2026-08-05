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
const postWatched = http.postWatched;
const RetryPlan = http.RetryPlan;

const tools_mod = @import("tools.zig");
const apiErrorMessage = tools_mod.apiErrorMessage;
const mentionsReasoningEffort = tools_mod.mentionsReasoningEffort;
const telemetry = @import("telemetry.zig");
const run_budget_mod = @import("run_budget.zig");

const policy = @import("agent_request_policy.zig");
const errorCode = policy.errorCode;
const isQuotaExceeded = policy.isQuotaExceeded;
const recoverContextOverflow = policy.recoverContextOverflow;
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

/// Keep the normal request hot path allocation-free while avoiding a permanent
/// RSS high-water mark after one anomalously large stream. Small scratch arenas
/// retain their pages for the next request; large ones return all pages to the
/// backing allocator. History never lives here, so either reset mode is safe at
/// the start of the next request.
const scratch_retain_limit = 4 * 1024 * 1024;

fn resetRequestScratch(scratch: *std.heap.ArenaAllocator) void {
    if (scratch.queryCapacity() > scratch_retain_limit) {
        _ = scratch.reset(.free_all);
    } else {
        _ = scratch.reset(.retain_capacity);
    }
}

pub fn request(self: *Agent, tools: ?[]const u8) !std.json.ObjectMap {
    // Startup paints the prompt while CA loading continues. The root turn and
    // title task rendezvous here, then issue their requests concurrently.
    http.waitForClientReady(self.io);
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
    self.last_request_context_overflow = false;
    self.last_request_write_failed = false;
    self.last_usage_includes_output = false;
    var force = !self.review_mode and (self.strict or self.eval_cmd != null) and tools != null;
    var stream_usage = true; // openai stream_options; dropped if rejected
    var auth_refreshed = false; // #148: at most one forced token refresh + retry
    // #124: reclaim last request's transient parse garbage FIRST, so everything
    // below (per-event parse trees, tool-arg parses) can use the scratch arena
    // for this request. Safe: all scratch data is
    // consumed before the next request(); messages/todos/prompts live on the
    // session arena.
    if (self.scratch_arena) |sa| resetRequestScratch(sa);
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
                        if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, 0, body.len, 0, 0, 0, true);
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
                    self.last_request_write_failed = std.mem.eql(u8, @errorName(err), "WriteFailed");
                    if (telemetry.g_telem) |t| t.errorEvent("net", @errorName(err));
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, 0, body.len, 0, 0, 0, true);
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
                // #287/#299: sayApiError so the body snippet survives as
                // last_api_error; with plain say a subagent's parent got only
                // the literal "ApiError" for this failure.
                try self.sayApiError("unparseable codex response: {s}", .{resp_body[0..@min(resp_body.len, 600)]});
                if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                return error.ApiError;
            };
            switch (r) {
                .ok => |obj| {
                    if (!self.compaction_request) self.compact_transport_failures = 0;
                    self.recordUsageResponses(obj, body.len);
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                    if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                    return obj;
                },
                .err => |failure| {
                    const msg = failure.message;
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
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
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
                    if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
                    try self.sayApiError("api error ({s}): {s}", .{ etype, emsg });
                    return error.ApiError;
                };
                self.recordUsage(root, body.len);
                if (!self.compaction_request) self.compact_transport_failures = 0;
                if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
                if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
                return root;
            }
        }

        const resp = std.json.parseFromSliceLeaky(Value, self.messageMutationAlloc(), resp_body, .{
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
            if (try retryTransientServerError(self, "", errorCode(root), msg, &server_retries)) continue; // #opencode-parity: transient server overload → retry, not hard-fail
            if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, 0, 0, true);
            try self.sayApiError("api error: {s}", .{msg});
            return error.ApiError;
        }

        self.recordUsage(root, body.len);
        if (!self.compaction_request) self.compact_transport_failures = 0;
        if (self.tracer) |tr| tr.api(self.label, self.sub, self.provider.model, ms, body.len, resp_body.len, self.last_context_tokens, self.last_cache_read, false);
        if (main_mod.json_mode and !self.sub) self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
        return root;
    }
}

test "request scratch retains normal capacity but releases an oversized spike" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();

    _ = try scratch.allocator().alloc(u8, 1024);
    const normal_capacity = scratch.queryCapacity();
    try std.testing.expect(normal_capacity > 0);
    resetRequestScratch(&scratch);
    try std.testing.expectEqual(normal_capacity, scratch.queryCapacity());

    _ = try scratch.allocator().alloc(u8, scratch_retain_limit + 1);
    try std.testing.expect(scratch.queryCapacity() > scratch_retain_limit);
    resetRequestScratch(&scratch);
    try std.testing.expectEqual(@as(usize, 0), scratch.queryCapacity());
}
