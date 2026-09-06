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
    // #367: a prose line is not a score. pytest's summary used to parse as a
    // leading number — 4/100 for a green suite, and "1 failed" → 1 → the
    // [0,1] fraction rule → 100/100 on a FAILING suite.
    try std.testing.expectEqual(@as(?f64, null), repl_glue.parseEvalScore("4 passed in 0.01s"));
    try std.testing.expectEqual(@as(?f64, null), repl_glue.parseEvalScore("2 failed, 2 passed in 0.02s"));
    try std.testing.expectEqual(@as(?f64, null), repl_glue.parseEvalScore("1 failed in 0.01s"));
    // A last line that IS a number still works, as does an explicit fraction.
    try std.testing.expectEqual(@as(?f64, 85), repl_glue.parseEvalScore("all checks done\n85"));
    try std.testing.expectEqual(@as(?f64, 90), repl_glue.parseEvalScore("{\"score\": 0.9}"));
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

// Moved off subagent.zig when the §2c tournament gate needed room there — the
// tests are unchanged, and this is the file that exists for exactly that.

test "agentStatusText: running/completed/failed shapes carry the usage summary, and a failure is never silent (#276 P0-3)" {
    const gpa = std.testing.allocator;

    const running = try subagent.agentStatusText(gpa, 7, false, false, .{}, "");
    defer gpa.free(running);
    try std.testing.expectEqualStrings("[agent 7: running]", running);

    const ok = try subagent.agentStatusText(gpa, 7, true, false, .{ .duration_ms = 1200, .tool_calls = 3, .context_tokens = 4500, .cache_read_tokens = 100 }, "final report");
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "1200ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "3 tool call") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "final report") != null);

    const failed_text = "subagent sa-014-abcd failed before producing a report: connection reset [transport failure, 3 attempts]. retry is likely safe";
    const failed = try subagent.agentStatusText(gpa, 9, true, true, .{ .duration_ms = 300 }, failed_text);
    defer gpa.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "failed") != null); // status names the failure — never silent
    try std.testing.expect(std.mem.indexOf(u8, failed, failed_text) != null); // the child's own diagnostic rides along verbatim
}

test "agentStatusText: composes with isolation:\"worktree\" — a kept-worktree note in the result survives verbatim (#276 P0-3 design point 5)" {
    const gpa = std.testing.allocator;
    const result_with_worktree = "final report text\n\n[worktree kept (has changes) — path: .graff/worktrees/agent-sa-001-aa11, branch: graff/agents/sa-001-aa11]";
    const out = try subagent.agentStatusText(gpa, 3, true, false, .{ .duration_ms = 500 }, result_with_worktree);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[worktree kept (has changes) — path:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "branch: graff/agents/sa-001-aa11") != null);
}

test "admitOneLocked: admits up to the cap, queues the rest, FIFO order (#276 P0-3 design point 6)" {
    const gpa = std.testing.allocator;
    var registry: subagent.AgentJobs = .{};
    defer registry.list.deinit(gpa);

    var stub_jobs: [subagent.max_concurrent_background_agents + 3]subagent.AgentJob = undefined;
    for (&stub_jobs, 0..) |*j, i| j.* = .{
        .id = @intCast(i + 1),
        .label = @constCast(""),
        .prompt = @constCast(""),
        .niche = @constCast(""),
        .isolation = .shared_cwd,
        .isolation_fallback = false,
        .ctx = undefined,
    };
    for (&stub_jobs) |*j| try registry.list.append(gpa, j);

    var admitted_order: [stub_jobs.len]u32 = undefined;
    var n: usize = 0;
    while (subagent.admitOneLocked(&registry)) |j| : (n += 1) admitted_order[n] = j.id;

    try std.testing.expectEqual(@as(usize, subagent.max_concurrent_background_agents), n);
    try std.testing.expectEqual(subagent.max_concurrent_background_agents, registry.active);
    for (admitted_order[0..n], 1..) |id, expect| try std.testing.expectEqual(@as(u32, @intCast(expect)), id);

    var still_queued: usize = 0;
    for (stub_jobs) |j| if (!j.admitted) {
        still_queued += 1;
    };
    try std.testing.expectEqual(stub_jobs.len - n, still_queued);

    registry.active -= 1;
    const next = subagent.admitOneLocked(&registry).?;
    try std.testing.expectEqual(@as(u32, subagent.max_concurrent_background_agents + 1), next.id);
}
