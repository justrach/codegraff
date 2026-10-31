//! Quota caps and ChatGPT plan errors: a limit a retry cannot clear, unlike
//! transient throttling, and the plan codes OpenAI says to retry or stop on.
//! Split out of agent_request_policy.zig for the 600-line cap; the quota
//! checks are re-exported there, so their call sites keep saying `policy.`.

const std = @import("std");
const util = @import("util.zig");

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
    // ChatGPT plan usage limits (ADR 0221): stop, never retry into them.
    const needles = [_][]const u8{
        plan_limit_code,                                "insufficient_quota",           "insufficient quota",
        "exceeded your current quota",                  "quota exceeded",               quota_cap_marker,
        "exhausted credit",                             "credits exhausted",            "credit exhausted",
        "insufficient credit",                          "not enough credit",            "no credits",
        "out of credits",                               "credit balance",               "requires more credits",
        "payment required",                             "payment_required",             "billing limit",
        "billing_hard_limit_reached",                   "billing hard limit",           "insufficient_credits",
        "credits_exhausted",                            "credit_limit_exceeded",        "insufficient_funds",
        "http 402",                                     "exhausted_credit",             "credit_balance_too_low",
        "subscription_sharing_v2_usage_limit_exceeded",
        // Kimi Code's plan window: "You've reached your 5-hour usage limit".
        "exceeded_current_quota_error",
        // A Claude subscription past its extra usage answers 400
        // invalid_request_error with only this phrase to go on.
        "out of extra usage",
    };
    for (needles) |needle| if (util.indexOfIgnoreCase(body, needle) != null) return true;
    return false;
}

/// Terminal faults take precedence over an envelope's generic server-error
/// type or "try again" wording. Keep these distinct for headless exit policy.
pub const Fault = enum { quota, authentication, access_denied };

pub fn classify(etype: []const u8, code: ?[]const u8, msg: []const u8) ?Fault {
    const c = code orelse "";
    if (std.mem.eql(u8, c, "402") or isQuotaExceeded(c) or isQuotaExceeded(etype) or isQuotaExceeded(msg)) return .quota;
    if (std.mem.eql(u8, c, "401") or isAuthenticationFailure(c) or isAuthenticationFailure(etype) or isAuthenticationFailure(msg)) return .authentication;
    if (std.mem.eql(u8, c, "403")) return .access_denied;
    for ([_][]const u8{ "permission_denied", "permission_error", "permission denied", "access_denied", "access denied", "forbidden" }) |needle| {
        if (util.indexOfIgnoreCase(c, needle) != null or util.indexOfIgnoreCase(etype, needle) != null or util.indexOfIgnoreCase(msg, needle) != null) return .access_denied;
    }
    return null;
}

fn isAuthenticationFailure(text: []const u8) bool {
    // "expired" alone may describe an upstream request, not a credential.
    for ([_][]const u8{
        "authentication",      "unauthorized",                      "invalid_api_key",                      "invalid_token",
        "invalid api key",     "invalid token",                     "incorrect api key",                    "missing api key",
        "api key is invalid",  "api key appears to be invalid",     "expired api key",                      "api key expired",
        "api key has expired", "token is expired",                  "token has expired",                    "token expired",
        "expired token",       "subscription_sharing_invalid_user", "subscription_sharing_v2_invalid_user",
    }) |needle| if (util.indexOfIgnoreCase(text, needle) != null) return true;
    return false;
}

/// Some OpenAI-compatible envelopes put the HTTP status in error.code as a
/// number. Preserve only known terminal statuses; never coerce arbitrary ids.
pub fn numericStatusCode(v: std.json.Value) ?[]const u8 {
    if (v != .integer) return null;
    return switch (v.integer) {
        401 => "401",
        402 => "402",
        403 => "403",
        else => null,
    };
}

/// Transport adapters can preserve a terminal HTTP status without copying an
/// untrusted or non-JSON response body into diagnostics or the retry ladder.
pub fn httpError(status: u16) ?anyerror {
    return switch (status) {
        401 => error.ProviderAuthenticationFailed,
        402 => error.ProviderQuotaExceeded,
        403 => error.ProviderAccessDenied,
        else => null,
    };
}

pub fn transportCode(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ProviderQuotaExceeded => "402",
        error.ProviderAuthenticationFailed => "401",
        error.ProviderAccessDenied => "403",
        else => null,
    };
}

/// The existing one-shot login refresh and consented plan handoff remain the
/// only exceptions. Never send a quota fault through an auth refresh ladder.
pub fn handle(self: *@import("agent.zig").Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, refreshed: *bool) !bool {
    // A retry, handoff or unrelated rejection must not retain a prior action.
    self.last_api_reauth = null;
    const fault = classify(etype, code, msg) orelse return false;
    const policy = @import("agent_request_policy.zig");
    if (fault == .quota and policy.handOffExhaustedPlan(self)) {
        self.closeCodexWs(); // an existing socket still carries the spent credential
        return true;
    }
    if (fault == .authentication and policy.retryAfterAuthRefresh(self, if (policy.isAuthError(msg)) msg else "authentication_error", refreshed)) {
        self.closeCodexWs();
        return true;
    }
    // This boundary sees both verified transport statuses and parsed JSON/SSE
    // faults, after the existing refresh/handoff policy has declined a retry.
    // Classification already established auth; retain any structured code so
    // a non-auth code still vetoes a login action (including generic 403).
    // ADR 0310: the text and metadata name the seat that failed: a sign-in,
    // or a metered key (perhaps the one a spent plan handed over to).
    const auth = @import("auth_recovery.zig");
    if (fault == .authentication) self.last_api_reauth = auth.forAuthFault(self.provider, code orelse "authentication_error");
    self.last_api_error = switch (fault) {
        .quota => "provider quota/billing cap: credit or allowance exhausted; retry requires account action",
        .authentication => auth.failureText(self.arena, self.provider, @import("credential_failover.zig").promoted(self.provider.id)),
        .access_denied => "provider access denied: check account permissions or route eligibility",
    };
    if (self.tracer) |tr| tr.note("provider_terminal", self.last_api_error.?);
    return switch (fault) {
        .quota => error.ProviderQuotaExceeded,
        .authentication => error.ProviderAuthenticationFailed,
        .access_denied => error.ProviderAccessDenied,
    };
}

/// A failure after async tools started skips the retry ladder (the turn has
/// side effects in flight), but an authentication rejection still names the
/// credential that failed, as handle() does.
pub fn afterToolsStarted(self: *@import("agent.zig").Agent, code: ?[]const u8, msg: []const u8, diagnostic: []const u8) !void {
    const auth = @import("auth_recovery.zig");
    if (classify("", code, msg) != .authentication) {
        self.last_api_reauth = auth.forFailure(self.provider, code, msg);
        return self.sayApiError("{s}", .{diagnostic});
    }
    self.last_api_reauth = if (self.provider.source == .login) auth.forFailure(self.provider, code, msg) else auth.forAuthFault(self.provider, code orelse "authentication_error");
    try self.sayApiError("{s}", .{auth.failureText(self.arena, self.provider, @import("credential_failover.zig").promoted(self.provider.id))});
}

// ChatGPT plan errors, as OpenAI's errors-and-recovery page classifies them
// (ADR 0221). Only a spent allowance is a limit (429, resets after hours).
const plan_limit_code = "subscription_sharing_usage_limit_exceeded";
const plan_prefix = "subscription_sharing_";

/// A plan code's reason, in either naming: some responses still carry the
/// older `subscription_sharing_v2_` form of the same code.
fn planReason(code: ?[]const u8) ?[]const u8 {
    const c = code orelse return null;
    if (!std.mem.startsWith(u8, c, plan_prefix)) return null;
    const reason = c[plan_prefix.len..];
    return if (std.mem.startsWith(u8, reason, "v2_")) reason["v2_".len..] else reason;
}

pub fn isPlanUsageLimit(code: ?[]const u8) bool {
    return std.mem.eql(u8, planReason(code) orelse return false, "usage_limit_exceeded");
}

/// Any ChatGPT plan code, including the `chatpass_` grant errors. None of them
/// is a gateway flake: each is either a temporary outage with its own ladder
/// or a request to stop.
pub fn isPlanCode(code: ?[]const u8) bool {
    return planReason(code) != null or std.mem.startsWith(u8, code orelse return false, "chatpass_");
}

/// Usage or user data temporarily unavailable (503): keep the credentials and
/// retry with bounded backoff, like an overload.
pub fn isPlanTransient(code: ?[]const u8) bool {
    const reason = planReason(code) orelse return false;
    return std.mem.eql(u8, reason, "usage_unavailable") or std.mem.eql(u8, reason, "user_unavailable");
}

/// Every other plan code stops the turn: a spent allowance (429), an account,
/// workspace or policy that is not eligible (403), an unsupported route (403)
/// or capability (400), or a user the route no longer accepts (401, which the
/// auth refresh sees first). A new code stops too rather than spend usage.
pub fn isPlanStop(code: ?[]const u8) bool {
    return isPlanCode(code) and !isPlanTransient(code);
}

test "isQuotaExceeded (#opencode-parity): billing cap detected, transient throttle not" {
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}"));
    try std.testing.expect(isQuotaExceeded("Quota Exceeded for this key"));
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}"));
    try std.testing.expect(isQuotaExceeded("{\"error\":{\"message\":\"You've reached your 5-hour usage limit.\",\"type\":\"exceeded_current_quota_error\"}}"));
    try std.testing.expectEqual(Fault.quota, classify("invalid_request_error", null, "You're out of extra usage. Add more at claude.ai/settings/usage and keep going.").?);
    // transient rate-limit -> NOT a quota cap; must still retry
    try std.testing.expect(!isQuotaExceeded("Rate limit reached. Please try again in 20s."));
    try std.testing.expect(!isQuotaExceeded("429 too many requests"));
}

test "ChatGPT plan codes follow OpenAI's recovery table" {
    // A spent allowance stops; an unavailable usage or user check is a 503 to
    // retry, not a limit; an ineligible account or unsupported request stops.
    try std.testing.expect(isPlanUsageLimit("subscription_sharing_usage_limit_exceeded"));
    try std.testing.expect(!isPlanUsageLimit("subscription_sharing_usage_unavailable"));
    try std.testing.expect(!isQuotaExceeded("{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}"));
    try std.testing.expect(isPlanTransient("subscription_sharing_usage_unavailable"));
    try std.testing.expect(isPlanTransient("subscription_sharing_user_unavailable"));
    try std.testing.expect(isPlanTransient("subscription_sharing_v2_user_unavailable"));
    try std.testing.expect(!isPlanTransient("subscription_sharing_usage_limit_exceeded"));
    try std.testing.expect(!isPlanStop("subscription_sharing_usage_unavailable"));
    for ([_][]const u8{
        "subscription_sharing_usage_limit_exceeded",
        "subscription_sharing_user_not_eligible",
        "subscription_sharing_route_not_supported",
        "subscription_sharing_unsupported_capability",
        "subscription_sharing_invalid_user",
        "subscription_sharing_v2_user_not_eligible",
        "subscription_sharing_v2_client_not_enabled",
        "chatpass_v2_scope_not_authorized",
    }) |c| try std.testing.expect(isPlanStop(c));
    try std.testing.expect(!isPlanCode("rate_limit_exceeded") and !isPlanCode(null) and !isPlanStop(null));
}

test "terminal provider faults: credit variants outrank transient wording and auth hints" {
    for ([_][]const u8{
        "exhausted credit",                                                "Exhausted Credits",      "credits exhausted",          "credit exhausted",
        "insufficient credits",                                            "insufficient credit",    "payment required",           "payment_required",
        "This request requires more credits",                              "credit balance too low", "billing_hard_limit_reached", "insufficient_credits",
        "credits_exhausted",                                               "credit_limit_exceeded",  "insufficient_funds",         "HTTP 402",
        "The API key has exhausted credit; server_error, try again later", "exhausted_credits",      "credit_balance_too_low",     "subscription_sharing_v2_usage_limit_exceeded",
    }) |msg| {
        try std.testing.expect(isQuotaExceeded(msg));
        try std.testing.expectEqual(Fault.quota, classify("server_error", null, msg).?);
    }
    try std.testing.expectEqual(Fault.quota, classify("server_error", "402", "temporarily unavailable").?);
    try std.testing.expectEqual(Fault.authentication, classify("server_error", "401", "try again later").?);
    try std.testing.expectEqual(Fault.authentication, classify("authentication_error", null, "upstream overloaded").?);
    try std.testing.expectEqual(Fault.access_denied, classify("permission_error", "403", "upstream overloaded").?);
    try std.testing.expect(classify("server_error", "rate_limit_exceeded", "try again later") == null);
    try std.testing.expect(classify("", null, "too many concurrent requests") == null);
    try std.testing.expect(classify("server_error", null, "upstream request expired; try again") == null);
    try std.testing.expect(classify("", "subscription_sharing_usage_unavailable", "temporarily unavailable") == null);
}

test "terminal provider faults: numeric HTTP status codes survive envelope parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"error\":{\"code\":402,\"message\":\"try again\"}}",
        "{\"code\":402,\"error\":\"try again\"}",
    }) |raw| {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{});
        try std.testing.expectEqualStrings("402", @import("agent_request_policy.zig").errorCode(root.object).?);
    }
    try std.testing.expectEqualStrings("401", numericStatusCode(.{ .integer = 401 }).?);
    try std.testing.expectEqualStrings("403", numericStatusCode(.{ .integer = 403 }).?);
    try std.testing.expect(numericStatusCode(.{ .integer = 429 }) == null);
    try std.testing.expectEqualStrings("402", transportCode(error.ProviderQuotaExceeded).?);
    try std.testing.expectEqualStrings("401", transportCode(error.ProviderAuthenticationFailed).?);
    try std.testing.expectEqualStrings("403", transportCode(error.ProviderAccessDenied).?);
    try std.testing.expect(transportCode(error.Timeout) == null);
}

test "terminal provider faults: hard caps and env auth stop without a refresh or retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var self: @import("agent.zig").Agent = undefined;
    self.provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 1000, .source = .environment };
    self.tracer = null;
    self.arena = arena.allocator();
    var refreshed = false;
    try std.testing.expectError(error.ProviderQuotaExceeded, handle(&self, "server_error", null, "API key: exhausted credit; try again", &refreshed));
    try std.testing.expect(!refreshed);
    try std.testing.expect(isQuotaExceeded(self.last_api_error.?));
    try std.testing.expectError(error.ProviderAuthenticationFailed, handle(&self, "authentication_error", null, "overloaded", &refreshed));
    try std.testing.expect(!refreshed);
    try std.testing.expectEqualStrings("Codegraff API key was rejected (environment): replace or remove the key. Your sign-in is not affected.", self.last_api_error.?);
    try std.testing.expectEqualStrings("api_key_rejected", self.last_api_reauth.?.kind);
    try std.testing.expectError(error.ProviderAccessDenied, handle(&self, "permission_error", "403", "", &refreshed));
    try std.testing.expect(!try handle(&self, "server_error", null, "overloaded", &refreshed));
    self.provider.source = .login;
    try std.testing.expectError(error.ProviderQuotaExceeded, handle(&self, "", null, "API key: exhausted credit", &refreshed));
    try std.testing.expect(!refreshed); // even a login credential must not refresh for a billing cap
}
