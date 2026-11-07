//! Machine-readable one-shot lifecycle. Unknown charges are never reported as zero.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const pricing = @import("pricing.zig");
const quota = @import("agent_request_quota.zig");
const util = @import("util.zig");

pub const Failure = struct { reason: []const u8, exit_code: u8, retryable: bool = false };

pub fn classify(err: anyerror, detail: []const u8) Failure {
    if (err == error.Interrupted or err == error.Canceled) return .{ .reason = "cancelled", .exit_code = 130 };
    if (err == error.RunBudgetExhausted or err == error.ToolBudgetExhausted) return .{ .reason = "budget_exhausted", .exit_code = 3 };
    if (err == error.OutputLengthExceeded) return .{ .reason = "output_length_exhausted", .exit_code = 2 };
    if (err == error.FallbackConsentRequired) return .{ .reason = "authentication_required", .exit_code = 77 };
    if (err == error.ProviderQuotaExceeded) return .{ .reason = "quota_exhausted", .exit_code = 4 };
    if (err == error.ProviderAuthenticationFailed or err == error.ProviderAccessDenied)
        return .{ .reason = "authentication_required", .exit_code = 77 };
    if (quota.classify("", null, detail)) |fault| return switch (fault) {
        .quota => .{ .reason = "quota_exhausted", .exit_code = 4 },
        .authentication, .access_denied => .{ .reason = "authentication_required", .exit_code = 77 },
    };
    if (util.indexOfIgnoreCase(detail, "HTTP 401") != null or util.indexOfIgnoreCase(detail, "HTTP 403") != null)
        return .{ .reason = "authentication_required", .exit_code = 77 };
    if (err == error.EmptyCompletion or err == error.StreamStalled or err == error.StreamDropped or err == error.HungRequest or err == error.RateLimited or err == error.ServerError or
        err == error.StreamInterrupted or err == error.StreamReadFailed or err == error.UnknownHostName or err == error.ConnectionResetByPeer or err == error.ConnectionRefused or
        util.indexOfIgnoreCase(detail, "timeout") != null or util.indexOfIgnoreCase(detail, "timed out") != null or
        util.indexOfIgnoreCase(detail, "network error:") != null or util.indexOfIgnoreCase(detail, "rate limited (429)") != null or
        util.indexOfIgnoreCase(detail, "server error (5xx)") != null or util.indexOfIgnoreCase(detail, "HTTP 429") != null or
        util.indexOfIgnoreCase(detail, "HTTP 500") != null or util.indexOfIgnoreCase(detail, "HTTP 502") != null or
        util.indexOfIgnoreCase(detail, "HTTP 503") != null or util.indexOfIgnoreCase(detail, "HTTP 504") != null)
        return .{ .reason = "transient_failure", .exit_code = 75, .retryable = true };
    if (util.indexOfIgnoreCase(detail, "HTTP 400") != null or util.indexOfIgnoreCase(detail, "invalid_request") != null)
        return .{ .reason = "invalid_request", .exit_code = 78 };
    return .{ .reason = "failed", .exit_code = 1 };
}

pub const Run = struct {
    started: std.Io.Timestamp,
    turns: u64 = 1,

    pub fn start(root: *Agent) Run {
        const run: Run = .{ .started = .now(root.io, .awake) };
        if (@import("main.zig").json_mode) {
            root.emit(.{ .type = "run_started", .run_id = &@import("scoring.zig").g_run_id, .session_id = root.session_name, .parent_session_id = root.session_parent });
        } else {
            // stderr is a JSON line too: wrappers can obtain a handle without
            // changing the existing plain-answer stdout contract.
            const line = std.json.Stringify.valueAlloc(root.arena, .{ .type = "run_started", .run_id = &@import("scoring.zig").g_run_id, .session_id = root.session_name, .parent_session_id = root.session_parent }, .{}) catch return run;
            std.debug.print("{s}\n", .{line});
        }
        return run;
    }

    pub fn finish(run: Run, root: *Agent, failure: ?Failure, answer: []const u8, saved: bool) void {
        if (!@import("main.zig").json_mode) return;
        const c = pricing.g_cost.snap(root.io);
        const cost_complete = c.unpriced_calls == 0 and c.missing_usage_calls == 0 and c.unreported_failed_attempts == 0;
        root.emit(.{
            .type = "result",
            .run_id = &@import("scoring.zig").g_run_id,
            .session_id = root.session_name,
            .parent_session_id = root.session_parent,
            .status = if (failure) |f| (if (f.exit_code == 130) "cancelled" else "failed") else "completed",
            .reason = if (failure) |f| f.reason else "completed",
            .exit_code = if (failure) |f| f.exit_code else @as(u8, 0),
            .retryable = if (failure) |f| f.retryable else false,
            .session_saved = saved,
            .turns = run.turns,
            .model_calls = if (root.run_budget) |b| b.used() else c.api_calls,
            .duration_ms = @max(0, run.started.untilNow(root.io, .awake).toMilliseconds()),
            .usage = .{ .input_tokens = c.in_tokens +| c.cache_tokens, .cached_input_tokens = c.cache_tokens, .cache_write_tokens = c.cache_write_tokens, .output_tokens = c.out_tokens, .api_calls = c.api_calls, .missing_usage_calls = c.missing_usage_calls, .failed_attempts_without_usage = c.unreported_failed_attempts },
            .total_cost_usd = if (cost_complete) @as(?f64, c.usd) else null,
            .known_cost_usd = c.usd,
            .cost_complete = cost_complete,
            .unpriced_calls = c.unpriced_calls,
            .subscription_calls = c.sub_calls,
            .result = answer,
        });
    }
};

test "headless result classifies terminal limits separately from transient failures" {
    try std.testing.expectEqual(@as(u8, 3), classify(error.RunBudgetExhausted, "").exit_code);
    try std.testing.expectEqual(@as(u8, 4), classify(error.ApiError, "HTTP 402 payment required").exit_code);
    try std.testing.expectEqual(@as(u8, 77), classify(error.ApiError, "invalid_api_key").exit_code);
    try std.testing.expectEqual(@as(u8, 78), classify(error.ApiError, "HTTP 400 invalid request").exit_code);
    try std.testing.expect(classify(error.EmptyCompletion, "").retryable);
    try std.testing.expectEqualStrings("output_length_exhausted", classify(error.OutputLengthExceeded, "").reason);
    try std.testing.expectEqual(@as(u8, 130), classify(error.Interrupted, "").exit_code);
    try std.testing.expect(!classify(error.ApiError, "insufficient_quota").retryable);
    try std.testing.expect(classify(error.ApiError, "network error: TemporaryNameServerFailure (gave up after 6 attempts)").retryable);
    try std.testing.expect(!classify(error.ProviderQuotaExceeded, "server error (5xx)").retryable);
}
