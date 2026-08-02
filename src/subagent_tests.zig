//! Tests split out of subagent.zig, which sits at the 600-line cap (the
//! `<mod>_tests.zig` pattern, wired into the test root by test_hooks.zig).

const std = @import("std");

const util = @import("util.zig");
const repl_glue = @import("repl_glue.zig");
const subagent = @import("subagent.zig");
const subagent_run = @import("subagent_run.zig");

const FailKind = subagent_run.FailKind;
const classifyFailure = subagent_run.classifyFailure;

test "variantJudgePrompt: bounded, names the phase, keeps the score contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big_task = util.repeatBytes("T", 4000);
    const big_out = util.repeatBytes("O", 5000);
    const p = try subagent.variantJudgePrompt(a, "code-review", &big_task, &big_out);

    // Names the shared phase so the judge has the tournament context.
    try std.testing.expect(std.mem.indexOf(u8, p, "\"code-review\" phase") != null);
    // Task is prefix-capped and output tail-capped — neither lands verbatim.
    try std.testing.expect(std.mem.indexOf(u8, p, &big_task) == null);
    try std.testing.expect(std.mem.indexOf(u8, p, &big_out) == null);
    // The `score:` contract parseEvalScore depends on is spelled out…
    try std.testing.expect(std.mem.indexOf(u8, p, "score: <N>") != null);
    // …and it round-trips: a judge tail like this parses back to the score.
    try std.testing.expectEqual(@as(?f64, 87), repl_glue.parseEvalScore("ok\nscore: 87"));
}

test "classifyFailure: maps the child's api-error detail to a category + retry-safety" {
    // A stream stall/drop names itself via the error kind — its stale envelope
    // (if any) must not override the transport verdict.
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.StreamStalled, null));
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.StreamDropped, "api error (some_error): stale"));
    // No detail to go on → unknown (and a retry is still allowed to be tried).
    try std.testing.expectEqual(FailKind.unknown, classifyFailure(error.ApiError, null));
    // Real provider envelopes (the shapes sayApiError formats into last_api_error).
    try std.testing.expectEqual(FailKind.quota, classifyFailure(error.ApiError, "api error (rate_limit_error): Number of requests exceeded"));
    try std.testing.expectEqual(FailKind.quota, classifyFailure(error.ApiError, "api error: You have run out of credits or need a Grok subscription."));
    try std.testing.expectEqual(FailKind.auth, classifyFailure(error.ApiError, "api error: The API Key appears to be invalid or may have expired."));
    // invalid_request_error carries "invalid", but a missing-model message is
    // classified as model-availability because that phrase is checked first.
    try std.testing.expectEqual(FailKind.model, classifyFailure(error.ApiError, "api error (invalid_request_error): The model `gpt-foo` does not exist or you do not have access to it."));
    try std.testing.expectEqual(FailKind.invalid, classifyFailure(error.ApiError, "api error (invalid_request_error): This model's maximum context length is 8192 tokens."));
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.ApiError, "network error: HttpConnectionClosing (gave up after 6 attempts)"));

    // Retry-safety contract: transient failures may retry, structural ones must not.
    try std.testing.expect(FailKind.quota.retrySafe());
    try std.testing.expect(FailKind.transport.retrySafe());
    try std.testing.expect(!FailKind.model.retrySafe());
    try std.testing.expect(!FailKind.invalid.retrySafe());
    try std.testing.expect(!FailKind.auth.retrySafe());
}
