//! Request retry and provider-error policy shared by the request loop.

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const RetryPlan = http.RetryPlan;
const oauth = @import("oauth.zig");
const billing = @import("billing.zig"); // #471 seat billing class
const credential_failover = @import("credential_failover.zig"); // #471 parked metered key
const oauth_helpers = @import("oauth_helpers.zig"); // tests pin g_codex_home, the resolver startup sets
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");

pub fn isAuthError(msg: []const u8) bool {
    return util.indexOfIgnoreCase(msg, "api key") != null or
        util.indexOfIgnoreCase(msg, "unauthorized") != null or
        util.indexOfIgnoreCase(msg, "expired") != null or
        util.indexOfIgnoreCase(msg, "authentication") != null or
        util.indexOfIgnoreCase(msg, "invalid_api_key") != null;
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

/// Bind a refreshed credential to the LIVE provider. The ChatGPT account id
/// travels WITH the token: it is the chatgpt-account-id header on every codex
/// request (http_headers.zig, agent_ws.zig), so a new bearer paired with the
/// previous account's id just 401/403s again. Both are duped onto the session
/// arena — the refresh internals are scratch (#124), and a /login caller's arena
/// may be scoped.
///
/// Called only when the credential actually CHANGED, which is also why the WS
/// transport latch is released here: an expired bearer fails the WebSocket
/// HANDSHAKE, and that failure never reaches the `.responses` error arm where
/// this recovery lives — postLive counts it as a transport failure and latches
/// `ws_off` (persistent SSE) for the rest of the session (agent_ws.zig). Those
/// failures belonged to the credential; a credential that just changed earns the
/// transport back, and the existing ladder re-latches after two fresh failures
/// if the socket really was the problem.
pub fn adoptFreshAuth(self: *Agent, fresh: oauth.FreshKey) void {
    self.provider.api_key = self.arena.dupe(u8, fresh.key) catch self.provider.api_key;
    if (fresh.account.len > 0 and !std.mem.eql(u8, fresh.account, self.provider.account))
        self.provider.account = self.arena.dupe(u8, fresh.account) catch self.provider.account;
    self.ws_off = false;
    self.ws_transport_failures = 0;
}

/// A grant succeeded but its rotated credential could not be written back.
/// OpenAI kills the old refresh_token the moment the new one is issued, so the
/// in-memory token is now the only live credential: say so, instead of letting
/// the next session start logged out with no explanation.
fn warnUnpersistedRefresh(self: *Agent) void {
    const name = oauth.takePersistError() orelse return;
    if (self.tracer) |tr| tr.note("oauth_refresh", "refreshed token could not be written to auth.json");
    self.say("[⚠ refreshed the Codex token but could not save it ({s}) — run `graff login codex` before your next session]\n", .{name}) catch {};
}

/// #148/#402: adopt a credential another writer has already produced BEFORE the
/// request goes out — codex-rs's STEP 1, run preemptively instead of only after
/// a rejection, so a `graff login` in another terminal (or the real codex CLI)
/// heals a live session without waiting for it to 401 first. Runs for the root
/// and for subagents alike: the credential resolver needs neither the root's
/// model catalog nor a `home`, and it resolves the ONE directory every login
/// flow writes (oauth.codexHomeDir), so this read can no longer revert a
/// `/login` that just succeeded — the reported #402 symptom.
///
/// kimi/xai refresh only near expiry; the codex read is unconditional, because a
/// ChatGPT access token carries no expiry field we could check cheaply.
///
/// The read + JSON parse are scoped to a LOCAL arena rather than
/// `self.scratchAlloc()`. This runs on every single request, and a subagent has
/// no scratch arena — scratchAlloc() falls back to the session arena, which is
/// never reclaimed, so the ~1-2KB per request would accumulate for the whole
/// life of the child. adoptFreshAuth dupes what it keeps onto the session arena,
/// so nothing here outlives this frame.
pub fn refreshLoginKeyBeforeSend(self: *Agent) void {
    if (self.provider.source != .login) return;
    var scratch = std.heap.ArenaAllocator.init(self.gpa);
    defer scratch.deinit();
    const fresh = oauth.refreshOAuthKey(self.io, self.gpa, scratch.allocator(), self.home, self.provider.id, false, null, self.provider.account) orelse return;
    // Only adopt on a real CHANGE: an unchanged credential must not churn the
    // session arena, nor hand the WS transport latch back on every request.
    if (std.mem.eql(u8, fresh.key, self.provider.api_key)) return;
    adoptFreshAuth(self, fresh);
}

test "refreshLoginKeyBeforeSend (#402): an out-of-band login heals a live session, at no per-request cost" {
    const io = std.testing.io;
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const arena = scratch_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try writeTestAuth(io, arena, codex_home, "startup-tok", "", "acct-1");

    const saved = oauth_helpers.g_codex_home;
    defer oauth_helpers.g_codex_home = saved;
    oauth_helpers.g_codex_home = codex_home;

    // A CHILD: no catalog, no home, and no scratch arena — everything it
    // allocates lands on the session arena below and is never reclaimed.
    var agent = testChildAgent(io, session.allocator(), "acct-1");
    agent.provider.api_key = "startup-tok";

    // Nothing changed on disk: every request re-reads, and none of it may stick.
    const settled = blk: {
        var i: usize = 0;
        while (i < 4) : (i += 1) refreshLoginKeyBeforeSend(&agent);
        break :blk session.queryCapacity();
    };
    var i: usize = 0;
    while (i < 200) : (i += 1) refreshLoginKeyBeforeSend(&agent);
    try std.testing.expectEqual(settled, session.queryCapacity());
    try std.testing.expectEqualStrings("startup-tok", agent.provider.api_key);

    // `graff login` in another terminal, mid-session: picked up on the very next
    // request, with its account id, without waiting for a 401 — and the WS
    // transport the dead credential latched off is handed back.
    try writeTestAuth(io, arena, codex_home, "relogin-tok", "", "acct-1");
    refreshLoginKeyBeforeSend(&agent);
    try std.testing.expectEqualStrings("relogin-tok", agent.provider.api_key);
    try std.testing.expect(!agent.ws_off);

    // An env-sourced key has no login file behind it and must never be touched.
    agent.provider.source = .environment;
    try writeTestAuth(io, arena, codex_home, "third-tok", "", "acct-1");
    refreshLoginKeyBeforeSend(&agent);
    try std.testing.expectEqualStrings("relogin-tok", agent.provider.api_key);
}

/// #148/#402: a login-sourced credential was rejected. Adopt a token an
/// in-session `/login` (or another process) has already written to disk, else
/// spend the refresh grant — then retry the request once with the new bearer.
///
/// Bounded exactly like codex-rs's UnauthorizedRecovery (reload → refresh →
/// give up and surface the error): `refreshed` is declared OUTSIDE the caller's
/// rebuild loop and is set the moment we attempt anything, so a permanently
/// dead credential fails the turn instead of re-sending a full history forever
/// — the #402 symptom, where every user message re-fired a ~302KB turn body and
/// a ~868KB compaction body. A refresh that hands back the SAME token could not
/// have helped either, so it does not earn a retry. Neither does a credential
/// belonging to a DIFFERENT ChatGPT account (refreshOAuthKey returns null).
pub fn retryAfterAuthRefresh(self: *Agent, msg: []const u8, refreshed: *bool) bool {
    if (refreshed.* or self.provider.source != .login or !isAuthError(msg)) return false;
    refreshed.* = true;
    const fresh = oauth.refreshOAuthKey(self.io, self.gpa, self.scratchAlloc(), self.home, self.provider.id, true, self.provider.api_key, self.provider.account) orelse return false;
    warnUnpersistedRefresh(self);
    if (std.mem.eql(u8, fresh.key, self.provider.api_key)) return false;
    adoptFreshAuth(self, fresh);
    if (self.tracer) |tr| tr.note("oauth_refresh", "auth error — refreshed login token, retrying");
    return true;
}

test "retryAfterAuthRefresh (#402): one attempt per request, login-sourced auth errors only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent: Agent = undefined;
    agent.arena = arena_state.allocator();
    agent.tracer = null;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "expired-tok", .model = "gpt-5.6", .context = 272000, .source = .environment };
    const expired = "Provided authentication token is expired. Please re-authenticate.";

    // An env key has no refresh flow — it must never reach the network.
    var refreshed = false;
    try std.testing.expect(!retryAfterAuthRefresh(&agent, expired, &refreshed));
    try std.testing.expect(!refreshed);

    // Already attempted this request: no second refresh, so no second resend of a
    // full history (#402's runaway 302KB + 868KB bodies).
    agent.provider.source = .login;
    refreshed = true;
    try std.testing.expect(!retryAfterAuthRefresh(&agent, expired, &refreshed));

    // Non-auth failures must never burn a refresh token. A broadened isAuthError
    // would rotate credentials on quota 429s and context rejections.
    for ([_][]const u8{
        "rate limit exceeded",
        "You have run out of credits or need a Grok subscription.",
        "prompt is too long: 219373 tokens > 200000 maximum",
        "model not found",
    }) |msg| {
        var not_auth = false;
        try std.testing.expect(!retryAfterAuthRefresh(&agent, msg, &not_auth));
        try std.testing.expect(!not_auth);
    }
}

/// A subagent-shaped agent: `model_catalog` is root-only (agent.zig) and
/// `home` is never set on a child (subagent_run.zig), which is exactly the pair
/// the old code resolved the codex credential dir from.
fn testChildAgent(io: std.Io, arena: std.mem.Allocator, account: []const u8) Agent {
    var agent: Agent = undefined;
    agent.io = io;
    agent.gpa = std.testing.allocator;
    agent.arena = arena;
    agent.scratch_arena = null;
    agent.home = "";
    agent.model_catalog = null;
    agent.sub = true;
    agent.out = null;
    agent.label = "child";
    agent.tracer = null;
    agent.ws_off = true; // the expired bearer already failed the WS handshake
    agent.ws_transport_failures = 2;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "expired-tok", .model = "gpt-5.6", .context = 272000, .account = account, .source = .login };
    return agent;
}

fn writeTestAuth(io: std.Io, arena: std.mem.Allocator, dir: []const u8, access: []const u8, refresh: []const u8, account: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/auth.json", .{dir}),
        .data = try std.fmt.allocPrint(arena, "{{\"tokens\":{{\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"account_id\":\"{s}\"}}}}", .{ access, refresh, account }),
    });
}

test "retryAfterAuthRefresh (#402): a codex 401 adopts the token /login wrote — subagents included" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const env_home = try std.fmt.allocPrint(arena, "{s}/env-codex-home", .{base});
    try writeTestAuth(io, arena, env_home, "fresh-tok", "r1", "acct-1");

    const saved = oauth_helpers.g_codex_home;
    defer oauth_helpers.g_codex_home = saved;
    oauth_helpers.g_codex_home = env_home; // what startup pinned from $CODEX_HOME

    // CODEX_HOME set, and the agent is a CHILD: no model catalog, no home. Both
    // recovery paths used to be unconditional no-ops here, and a long codex run
    // spends most of its wall clock inside subagents — where a token is most
    // likely to cross expiry.
    var agent = testChildAgent(io, arena, "acct-1");
    const expired = "Provided authentication token is expired. Please re-authenticate.";
    var refreshed = false;
    try std.testing.expect(retryAfterAuthRefresh(&agent, expired, &refreshed));
    try std.testing.expect(refreshed);
    try std.testing.expectEqualStrings("fresh-tok", agent.provider.api_key);
    try std.testing.expectEqualStrings("acct-1", agent.provider.account);
    // The WS handshake failures that latched persistent SSE were the expired
    // credential's; a credential that just changed earns the transport back.
    try std.testing.expect(!agent.ws_off);
    try std.testing.expectEqual(@as(u8, 0), agent.ws_transport_failures);
    try std.testing.expect(!retryAfterAuthRefresh(&agent, expired, &refreshed)); // bounded

    // A refresh that can only hand back the SAME token cannot help; retrying would
    // just re-send the whole history for another guaranteed 401.
    try writeTestAuth(io, arena, env_home, "fresh-tok", "", "acct-1");
    var again = false;
    try std.testing.expect(!retryAfterAuthRefresh(&agent, expired, &again));
    try std.testing.expect(again); // attempt was spent, so the turn fails instead of looping

    // CODEX_HOME UNSET: the same recovery, from ~/.codex, for an agent that does
    // have a home. One resolver serves both.
    oauth_helpers.g_codex_home = "";
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});
    try writeTestAuth(io, arena, try std.fmt.allocPrint(arena, "{s}/.codex", .{home}), "home-tok", "r2", "acct-1");
    var root = testChildAgent(io, arena, "acct-1");
    root.home = home;
    var root_refreshed = false;
    try std.testing.expect(retryAfterAuthRefresh(&root, expired, &root_refreshed));
    try std.testing.expectEqualStrings("home-tok", root.provider.api_key);
}

test "retryAfterAuthRefresh (#402): a different ChatGPT account is never adopted" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try writeTestAuth(io, arena, codex_home, "other-tok", "r1", "acct-two");

    const saved = oauth_helpers.g_codex_home;
    defer oauth_helpers.g_codex_home = saved;
    oauth_helpers.g_codex_home = codex_home;

    // codex-rs's reload_if_account_id_matches: someone re-authenticated as a
    // SECOND ChatGPT account while this session was live. Adopting that bearer
    // under this session's chatgpt-account-id header only 401/403s again, with
    // the one recovery attempt already spent.
    var agent = testChildAgent(io, arena, "acct-one");
    var refreshed = false;
    try std.testing.expect(!retryAfterAuthRefresh(&agent, "Unauthorized", &refreshed));
    try std.testing.expect(refreshed);
    try std.testing.expectEqualStrings("expired-tok", agent.provider.api_key);
    try std.testing.expectEqualStrings("acct-one", agent.provider.account);

    // The same file IS adopted by a session that belongs to that account.
    var sibling = testChildAgent(io, arena, "acct-two");
    var sibling_refreshed = false;
    try std.testing.expect(retryAfterAuthRefresh(&sibling, "Unauthorized", &sibling_refreshed));
    try std.testing.expectEqualStrings("other-tok", sibling.provider.api_key);
}

/// #414: overflow classification (which failures mean "the input is over the
/// window", which only look like it, and the HTTP-200 shapes that never say so)
/// moved to agent_overflow.zig — this file was at the 600-line cap and the new
/// guard list plus behavioral detectors did not fit. Re-exported so existing
/// call sites resolve, and the two tests below stay HERE deliberately: they are
/// the contract the request loop depends on, and moving their names would read
/// as deleted coverage in the behavioral eval harness.
pub const isContextOverflow = @import("agent_overflow.zig").isContextOverflow;
pub const recoverContextOverflow = @import("agent_overflow.zig").recoverContextOverflow;

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

const max_server_retries: usize = 3; // #opencode-parity: bounded retries for a transient in-stream server overload

/// #opencode-parity: an in-band error event (an SSE {"type":"error"} or a JSON
/// error envelope) naming a TRANSIENT server condition — Anthropic overloaded_error,
/// OpenAI server_error / server_is_overloaded, or plain "overloaded" — is a 5xx that
/// surfaced mid-stream and should be retried, not hard-failed. Billing / quota /
/// invalid-input errors are NOT transient and fall through to a hard fail.
fn isTransientServerError(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    const needles = [_][]const u8{ "overloaded", "server_error", "server_is_overloaded" };
    for (needles) |n| {
        if (util.indexOfIgnoreCase(etype, n) != null) return true;
        if (util.indexOfIgnoreCase(msg, n) != null) return true;
        if (code) |c| if (util.indexOfIgnoreCase(c, n) != null) return true;
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

/// #gateway-artifact: a 4xx whose body rejects the REQUEST BODY as unparseable
/// JSON ("Body must be valid JSON", "Malformed JSON in request body", ...) is a
/// real client bug — unless the same attempt-sequence just endured consecutive
/// transport timeouts. The body bytes do not change between attempts, so they
/// cannot become invalid mid-turn; a gateway answering from a half-recovered
/// state (redeploy, failover, reset pool) is the likelier story. Matched from
/// the message so any vendor phrasing of the same rejection classifies alike.
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

pub const min_timeout_history_for_parse_retry: usize = 2; // a lone timeout is not a pattern
pub const max_gateway_parse_retries: usize = 2; // then surface the provider's message

/// Gate (pure, testable): a body-parse rejection is retried only when THIS
/// request already hit enough transport timeouts to indict the gateway and the
/// bounded retry budget is not spent. Without the timeout history it stays a
/// fail-fast 400, exactly as before.
pub fn shouldRetryBodyParseAfterTimeouts(msg: []const u8, transport_timeouts: usize, retries: usize) bool {
    if (transport_timeouts < min_timeout_history_for_parse_retry) return false;
    if (retries >= max_gateway_parse_retries) return false;
    return isBodyParseRejection(msg);
}

/// The gate on the Agent: announce, trace, back off (1·2s — the gateway just
/// answered, give it a beat), clear partial text for a fresh re-stream, and
/// tell the caller to `continue`. Esc during the backoff still propagates.
pub fn retryBodyParseAfterTimeouts(self: *Agent, msg: []const u8, transport_timeouts: usize, retries: *usize) !bool {
    if (!shouldRetryBodyParseAfterTimeouts(msg, transport_timeouts, retries.*)) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity(); // fresh re-stream after the retry, no concat
    const delay_ms = RetryPlan.delayMs(true, retries.* - 1); // 1·2s
    try self.say("[gateway answered after {d} timeouts with a body-parse rejection — retrying in {d}s ({d}/{d})]\n", .{ transport_timeouts, delay_ms / 1000, retries.*, max_gateway_parse_retries });
    if (self.tracer) |tr| tr.note("retry", "body-parse rejection after transport timeouts (gateway artifact?)");
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
}

/// SSE keep-alive-only body: every non-blank line is an SSE comment (':' prefix)
/// — OpenRouter's ": OPENROUTER PROCESSING" queue pings. No data events ever
/// arrived, so the stream reassembler returns null and the plain-JSON fallback
/// parse fails. A retry is exactly right: the upstream was queued, not broken.
pub fn sseKeepAliveOnly(body: []const u8) bool {
    var any_comment = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != ':') return false;
        any_comment = true;
    }
    return any_comment;
}

test "sseKeepAliveOnly: comment-only bodies true, data/error/JSON bodies false" {
    try std.testing.expect(sseKeepAliveOnly(": OPENROUTER PROCESSING\n: OPENROUTER PROCESSING\n"));
    try std.testing.expect(sseKeepAliveOnly("\n\n: ping\n"));
    try std.testing.expect(!sseKeepAliveOnly(""));
    try std.testing.expect(!sseKeepAliveOnly("data: {\"choices\":[]}\n"));
    try std.testing.expect(!sseKeepAliveOnly("{\"error\":{\"message\":\"x\"}}"));
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
/// The phrase agent_request stamps into `last_api_error` when a 429 body named
/// a billing/credit cap rather than transient throttling. It is a const, not a
/// literal spelled twice, because a second reader now depends on it: a worker's
/// in-turn retry ladder (subagent_retry.hardQuotaCap) reads this marker back
/// out of the message to tell "the account is capped" — where re-asking is
/// pure waste — from "slow down", where re-asking is the whole point.
pub const quota_cap_marker = "quota/billing cap";

pub fn isQuotaExceeded(body: []const u8) bool {
    return util.indexOfIgnoreCase(body, "insufficient_quota") != null or
        util.indexOfIgnoreCase(body, "insufficient quota") != null or
        util.indexOfIgnoreCase(body, "exceeded your current quota") != null or
        util.indexOfIgnoreCase(body, "quota exceeded") != null;
}

test "isQuotaExceeded (#opencode-parity): billing cap detected, transient throttle not" {
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}"));
    try std.testing.expect(isQuotaExceeded("Quota Exceeded for this key"));
    // transient rate-limit -> NOT a quota cap; must still retry
    try std.testing.expect(!isQuotaExceeded("Rate limit reached. Please try again in 20s."));
    try std.testing.expect(!isQuotaExceeded("429 too many requests"));
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
    // #414: the guard list is consulted FIRST — a throttle whose wording collides
    // with the generic "too many tokens" fallback stays on the retry ladder.
    try std.testing.expect(!isContextOverflow("ThrottlingException: Too many tokens, please wait before trying again.", null));
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

/// #471: this seat is a flat-rate plan that has just reported a quota cap, and
/// a metered credential was parked behind it at startup. Hand over to that key
/// for the rest of the session and say so, returning true so the caller retries
/// the SAME request on the new credential instead of failing the turn.
///
/// Gated on the seat being `.sub`: a metered seat hitting a billing cap has
/// nothing better to switch to, and promoting there would burn the reserve on
/// a wall it cannot get past. One-way by construction — credential_failover
/// promotes once per provider, so a second cap falls through to the normal
/// error path rather than looping on a credential that is also exhausted.
pub fn handOffExhaustedPlan(self: *Agent) bool {
    if (billing.forProvider(self.provider) != .sub) return false;
    const promotion = credential_failover.promote(self.provider.id) orelse return false;
    self.provider.api_key = self.arena.dupe(u8, promotion.key) catch promotion.key;
    self.provider.source = promotion.source;
    self.ws_off = false;
    self.ws_transport_failures = 0;
    if (self.tracer) |tr| tr.note("credential_failover", "plan exhausted — switched to the parked metered key");
    self.say(
        "[⚠ your {s} plan is out of quota — switching to the {s} API key for the rest of this session. Calls now bill PER TOKEN.]\n",
        .{ self.provider.id, promotion.source.label() },
    ) catch {};
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
