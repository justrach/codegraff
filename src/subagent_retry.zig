//! Bounded, class-filtered retry for a FLEET WORKER's turn — the resilience
//! the root agent has had all along and a worker had none of.
//!
//! The root gets providers.runTurnWithFallback: on a clear auth/model failure
//! it re-runs the turn, rotating credentials. A WORKER got one shot —
//! subagent_run.runSub called agent.runTurn() exactly once and whatever came
//! back was final. A real fleet run showed the bill: four parallel reviewers
//! sharing ONE credential, one died with "api error: The API Key appears to
//! be invalid or may have expired" and the phase reported "subagent sa-001
//! failed before producing a report" while its three siblings, on that same
//! key, finished normally. A credential serving three concurrent workers is
//! not expired. That response was flaky or model-gated, and one re-ask would
//! very likely have saved the report.
//!
//! So: re-ask the SAME provider, a bounded number of times, only for the
//! failure classes where re-asking can help. That is deliberately the small
//! version (kimi-code's shape): no cross-provider failover for workers.
//! Provider locality is a consent boundary in this codebase
//! (subagent_run.childProvider), and a worker quietly answering from a
//! provider the user did not pick is a worse outcome than an honest failure.
//!
//! Weng gate — no verifier, no blind loop: every ladder here has a fixed
//! ceiling and a class filter, and both are visible to the caller. A hard auth
//! rejection retried ten times is abuse, not resilience, so auth gets exactly
//! ONE extra ask (that is all the sibling-success evidence licenses) before
//! the parent is told, verbatim, what failed and how many times it was tried.
//!
//! Layering: workflow.zig already retries a failed task once at the PHASE
//! level (a whole fresh worker). This sits BENEATH it, so one flaky HTTP
//! response is absorbed here instead of burning that phase-level retry. It
//! also sits ABOVE the request layer's own bounded ladders (http.RetryPlan's
//! 5-6 connection tries, agent_request's 2 stall/drop reconnects,
//! agent_request_policy's 3 in-stream overload retries) — and what it adds
//! that none of those can is RESUMPTION: a worker turn is many requests, and
//! re-entering runTurn re-asks against the history as it stands, so a stall on
//! the sixth request no longer throws away the first five.
//!
//! The cost of that layering, stated rather than hidden: a worker whose stream
//! stalls hopelessly now spends up to 3 asks x (1 + 2 reconnects) instead of
//! 1 x 3 before giving up. That ceiling is fixed, it is the price of not
//! discarding a nearly-finished worker over one bad socket, and a /loop
//! deadline (pastDeadline) cuts it short whenever the run has one.

const std = @import("std");

const subagent_run = @import("subagent_run.zig");
const FailKind = subagent_run.FailKind;
const http = @import("http.zig");
const policy = @import("agent_request_policy.zig");
const Tracer = @import("trace.zig").Tracer;
const util = @import("util.zig");

/// Total asks (the first one included) a transient failure class is worth.
/// Three, not kimi-code's ten: a worker is one of N parallel siblings sharing
/// a credential AND the run's model-call budget, so a long private ladder here
/// multiplies across the whole fleet — and the phase-level retry in
/// workflow.zig still sits above this with a pass of its own.
pub const transient_attempts: u8 = 3;

/// Total asks an auth-shaped rejection is worth: the first, plus ONE.
/// Justified by exactly one observation and no more — siblings succeeding on
/// the same credential at the same moment means the rejection can be flaky. If
/// the key really is dead the second ask says so too, and it stops there.
pub const auth_attempts: u8 = 2;

/// Billing/credit refusals that no amount of waiting clears. Mirrors the two
/// places the rest of the harness already decided this: the marker
/// agent_request stamps on a capped 429 (policy.quota_cap_marker, checked
/// below) and providers.zig's `gateway_billing` needles. Kept as text matching
/// because that is all a worker HAS — by the time a failure reaches here it is
/// a `last_api_error` string, the status code and body are gone.
const hard_cap_needles = [_][]const u8{
    policy.quota_cap_marker,
    "credits exhausted",
    "insufficient credits",
    "credit balance",
    "no credits",
    "out of credits",
    "billing limit",
    "billing_hard_limit_reached",
    "billing hard limit",
};

/// Is this `.quota` failure the account being CAPPED rather than throttled?
/// The classifier folds both into one FailKind (`quota` matches "quota",
/// "billing", "credits", "429", "overloaded" alike), and they want opposite
/// treatment: a cap is as structural as a bad model id, while a throttle is
/// the single case where the server has told us that waiting works.
pub fn hardQuotaCap(detail: ?[]const u8) bool {
    const msg = detail orelse return false;
    if (policy.isQuotaExceeded(msg)) return true;
    for (hard_cap_needles) |n| if (util.indexOfIgnoreCase(msg, n) != null) return true;
    return false;
}

/// How many times this worker may ask, given what the last failure looked
/// like. `1` means "the ask that just failed was the only one worth making".
/// `detail` is the raw `last_api_error`: the CLASS alone is too coarse for
/// `.quota`, so the one class that spans both a retryable and an unretryable
/// failure is split on the text the request layer already wrote.
pub fn attemptBudget(kind: FailKind, detail: ?[]const u8) u8 {
    return switch (kind) {
        // Wire flakes and shapes we could not classify: the classes where the
        // same request can genuinely succeed next time.
        .transport, .unknown => transient_attempts,
        // A throttle or an overload keeps the ladder — that is a server saying
        // "later", and later is exactly what a retry offers. A hard cap does
        // not: agent_request.zig:263 already refused to spend its own 5
        // throttle attempts on one, so spending 3 worker asks here would undo
        // that decision one layer up and bill the user for the privilege.
        .quota => if (hardQuotaCap(detail)) 1 else transient_attempts,
        .auth => auth_attempts,
        // Structural: an unavailable model, a malformed request, or the
        // harness's own dry call budget. Re-asking is guaranteed to fail
        // identically, and is still CHARGED for trying.
        .model, .invalid, .budget_exhausted => 1,
    };
}

/// Which error VALUES are wire failures at all. Classification alone is not
/// enough of a gate: a stale `last_api_error` mentioning "503" must never earn
/// a retry for an error.OutOfMemory or an error.Interrupted, and a user's Esc
/// is a decision, not a flake.
pub fn eligibleError(err: anyerror) bool {
    return switch (err) {
        error.ApiError, error.StreamStalled, error.StreamDropped => true,
        else => false,
    };
}

/// The whole gate: `attempts_done` asks have been made and the last one failed
/// with `err` (classified `kind`, cause text `detail`) — is another warranted?
pub fn shouldRetry(err: anyerror, kind: FailKind, detail: ?[]const u8, attempts_done: u8) bool {
    if (!eligibleError(err)) return false;
    return attempts_done < attemptBudget(kind, detail);
}

/// Backoff before the ask that follows `attempts_done`. Reuses the request
/// layer's own ladder (http.RetryPlan) so there is one backoff policy in the
/// codebase, not two that drift.
pub fn backoffMs(kind: FailKind, attempts_done: u8) u64 {
    const prior: usize = if (attempts_done == 0) 0 else attempts_done - 1;
    return switch (kind) {
        // The sibling-success case: waiting does not un-expire a key, so if
        // this is going to work it works now. Short enough to be honest about
        // being an immediate re-ask, long enough not to hammer.
        .auth => 250,
        // A refusal that named a limit is the one case where the server is
        // telling us to wait; give it the throttle ladder (1s, 2s).
        .quota => http.RetryPlan.delayMs(true, prior),
        // Flake ladder (250ms, 500ms).
        else => http.RetryPlan.delayMs(false, prior),
    };
}

/// A /loop deadline the run has already passed buys nothing by being waited
/// out — the parent will discard the late answer anyway. Pure so the call site
/// stays testable without a clock.
pub fn pastDeadline(now_ms: i64, deadline_ms: ?i64) bool {
    const d = deadline_ms orelse return false;
    return now_ms >= d;
}

/// "attempt" / "attempts" — the failure text names a count, so it has to read
/// like English or it reads like a bug.
pub fn attemptsWord(n: u8) []const u8 {
    return if (n == 1) "attempt" else "attempts";
}

/// One trace line per re-ask, naming the worker, which ask this is, the class
/// that bought it, and the cause. Without this a retried worker looks in the
/// trace exactly like a worker that was simply slow.
pub fn traceAttempt(tracer: ?*Tracer, sub_id: []const u8, attempts_done: u8, kind: FailKind, cause: ?[]const u8) void {
    const tr = tracer orelse return;
    var buf: [320]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "{s} retrying (ask {d} of {d}) after a {s} failure: {s}", .{
        sub_id,
        @as(u16, attempts_done) + 1,
        attemptBudget(kind, cause),
        kind.label(),
        util.utf8Prefix(cause orelse "no cause recorded", 160),
    }) catch "worker retry";
    tr.note("subagent_retry", detail);
}

/// The ceiling the module is CLAIMING, written as a literal so the assertions
/// below cannot be satisfied by moving the constant they are meant to police.
const asserted_ceiling: u8 = 3;

test "attemptBudget: transient classes get a bounded ladder, structural ones get none" {
    // The classes where the identical request can succeed next time.
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.transport, null));
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.quota, "429 too many requests"));
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.unknown, null));
    // Auth: the first ask plus exactly one more — never the transient ladder.
    try std.testing.expectEqual(@as(u8, 2), attemptBudget(.auth, null));
    try std.testing.expect(attemptBudget(.auth, null) < attemptBudget(.transport, null));
    // Structural: re-asking cannot help and is still charged for.
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.model, null));
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.invalid, null));
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.budget_exhausted, null));
    // Every ladder is finite and small — the Weng gate, asserted against a
    // LITERAL ceiling. `<= transient_attempts` would have been self-referential:
    // it holds just as well at transient_attempts = 100, which is the exact
    // property the comment claims to rule out.
    try std.testing.expect(transient_attempts <= asserted_ceiling);
    try std.testing.expect(auth_attempts <= asserted_ceiling);
    for ([_]FailKind{ .quota, .transport, .model, .invalid, .auth, .budget_exhausted, .unknown }) |k| {
        for ([_]?[]const u8{ null, "429 too many requests", "insufficient_quota" }) |d| {
            try std.testing.expect(attemptBudget(k, d) >= 1);
            try std.testing.expect(attemptBudget(k, d) <= asserted_ceiling);
        }
    }
}

test "attemptBudget: a hard billing cap gets ONE ask; genuine throttling keeps the ladder" {
    // agent_request.zig:263 already decided a capped 429 is not transient and
    // failed fast rather than burn its own 5 throttle attempts (~23s) on it.
    // A worker ladder that re-asked 3x would silently undo that — same refusal,
    // three times, each one billed.
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.quota, "rate limited (429): quota/billing cap — {\"error\":{\"code\":\"insufficient_quota\"}}"));
    try std.testing.expect(hardQuotaCap("rate limited (429): " ++ policy.quota_cap_marker ++ " — capped"));
    // The gateway/provider phrasings providers.zig already treats as billing.
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.quota, "You have run out of credits or need a Grok subscription."));
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.quota, "Your credit balance is too low to access the Anthropic API"));
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.quota, "insufficient credits"));
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.quota, "Billing limit reached for this organization"));
    try std.testing.expectEqual(@as(u8, 1), attemptBudget(.quota, "You exceeded your current quota, please check your plan"));

    // Genuine rate limiting / overload: the server said "later", and later is
    // precisely what a re-ask offers. These keep the full ladder.
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.quota, "rate limited (429): Rate limit reached. Please try again in 20s."));
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.quota, "429 too many requests"));
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.quota, "overloaded"));
    // No cause recorded at all: unknowable, so it keeps the transient default
    // rather than being punished for the harness failing to capture text.
    try std.testing.expectEqual(@as(u8, transient_attempts), attemptBudget(.quota, null));
    try std.testing.expect(!hardQuotaCap(null));

    // And the gate that actually spends it agrees, both ways.
    try std.testing.expect(!shouldRetry(error.ApiError, .quota, "rate limited (429): quota/billing cap — no credits", 1));
    try std.testing.expect(shouldRetry(error.ApiError, .quota, "429 too many requests", 1));
}

test "eligibleError: only wire-level turn failures are retryable at all" {
    try std.testing.expect(eligibleError(error.ApiError));
    try std.testing.expect(eligibleError(error.StreamStalled));
    try std.testing.expect(eligibleError(error.StreamDropped));
    // An Esc is a decision, not a flake.
    try std.testing.expect(!eligibleError(error.Interrupted));
    // The harness's own ceilings and local failures are not wire failures.
    try std.testing.expect(!eligibleError(error.RunBudgetExhausted));
    try std.testing.expect(!eligibleError(error.OutOfMemory));
    try std.testing.expect(!eligibleError(error.FileNotFound));
}

test "shouldRetry: the gate needs BOTH a wire error and unspent budget" {
    // The observed failure: an auth-shaped rejection while siblings succeed.
    // One re-ask, then honest surfacing.
    try std.testing.expect(shouldRetry(error.ApiError, .auth, null, 1));
    try std.testing.expect(!shouldRetry(error.ApiError, .auth, null, 2));
    // A transient class walks the full ladder and then stops. Bounded.
    try std.testing.expect(shouldRetry(error.ApiError, .transport, null, 1));
    try std.testing.expect(shouldRetry(error.StreamDropped, .transport, null, 2));
    try std.testing.expect(!shouldRetry(error.StreamDropped, .transport, null, 3));
    try std.testing.expect(!shouldRetry(error.ApiError, .quota, null, 99));
    // Structural failures never get a second ask, not even the first retry.
    try std.testing.expect(!shouldRetry(error.ApiError, .model, null, 1));
    try std.testing.expect(!shouldRetry(error.ApiError, .invalid, null, 1));
    try std.testing.expect(!shouldRetry(error.ApiError, .budget_exhausted, null, 1));
    // A retryable-looking CLASS cannot rescue a non-wire error value: this is
    // the arm that stops a stale envelope from retrying an interrupt or an OOM.
    try std.testing.expect(!shouldRetry(error.Interrupted, .transport, null, 1));
    try std.testing.expect(!shouldRetry(error.OutOfMemory, .unknown, null, 1));
    try std.testing.expect(!shouldRetry(error.RunBudgetExhausted, .quota, null, 1));
}

test "backoffMs: bounded waits; a named limit waits longer than a flake" {
    // Auth re-asks near-immediately — waiting does not un-expire a key.
    try std.testing.expectEqual(@as(u64, 250), backoffMs(.auth, 1));
    // A throttle gets the server-directed ladder; a flake gets the short one.
    try std.testing.expect(backoffMs(.quota, 1) > backoffMs(.transport, 1));
    try std.testing.expectEqual(@as(u64, 250), backoffMs(.transport, 1));
    try std.testing.expectEqual(@as(u64, 500), backoffMs(.transport, 2));
    // Nothing on any ladder we can actually reach is a long sleep: the whole
    // in-worker budget must stay far under the phase-level retry it sits under.
    for ([_]FailKind{ .transport, .quota, .unknown, .auth }) |k| {
        var a: u8 = 0;
        var total: u64 = 0;
        while (a < attemptBudget(k, null)) : (a += 1) total += backoffMs(k, a);
        try std.testing.expect(total <= 4000);
    }
}

test "pastDeadline: no /loop deadline never blocks a retry; a passed one always does" {
    try std.testing.expect(!pastDeadline(1_000, null));
    try std.testing.expect(!pastDeadline(999, 1_000));
    try std.testing.expect(pastDeadline(1_000, 1_000));
    try std.testing.expect(pastDeadline(1_001, 1_000));
}

test "attemptsWord: the count in the failure text reads like English" {
    try std.testing.expectEqualStrings("attempt", attemptsWord(1));
    try std.testing.expectEqualStrings("attempts", attemptsWord(2));
    try std.testing.expectEqualStrings("attempts", attemptsWord(transient_attempts));
}
