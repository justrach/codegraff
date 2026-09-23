const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const run = @import("subagent_run.zig");
const Provider = run.Provider;
const childProvider = run.childProvider;
const agentUsageEvent = run.agentUsageEvent;
const subagentFailure = run.subagentFailure;
const failureAllowsRetry = run.failureAllowsRetry;
const subagent_retry = @import("subagent_retry.zig");
test "child model pin crosses the current root provider only with consent" {
    const codex_root: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5.6-sol", .context = 272_000 };
    const terra: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5.6-terra", .context = 272_000 };
    const anthropic_root: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = "claude", .context = 200_000 };
    try std.testing.expectEqualStrings("gpt-5.6-terra", childProvider(codex_root, terra, false).model);
    try std.testing.expectEqualStrings("claude", childProvider(anthropic_root, terra, false).model);
    try std.testing.expectEqualStrings("gpt-5.6-terra", childProvider(anthropic_root, terra, true).model);
}

test "agentUsageEvent maps AgentUsage fields onto the wire event" {
    const ev = agentUsageEvent("sa-007-abcd", true, .{ .duration_ms = 4110, .tool_calls = 6, .context_tokens = 1820, .cache_read_tokens = 340 });
    try std.testing.expectEqualStrings("agent_usage", ev.type);
    try std.testing.expectEqualStrings("sa-007-abcd", ev.id);
    try std.testing.expect(ev.ok);
    try std.testing.expectEqual(@as(u64, 4110), ev.duration_ms);
    try std.testing.expectEqual(@as(u32, 6), ev.tool_calls);
    try std.testing.expectEqual(@as(u64, 1820), ev.context_tokens);
    try std.testing.expectEqual(@as(u64, 340), ev.cache_read_tokens);
    const failed = agentUsageEvent("sa-008-efgh", false, .{});
    try std.testing.expect(!failed.ok);
    try std.testing.expectEqual(@as(u64, 0), failed.duration_ms);
}

test "failureAllowsRetry keys off the harness's own retry-safety classification" {
    const gpa = std.testing.allocator;

    // A real auth failure: subagentFailure classifies it .auth (retrySafe:
    // false) and appends retry_unsafe_note — the gate must block a retry.
    const auth = subagentFailure(gpa, "sa-001", error.Unexpected, "401 unauthorized: invalid_api_key", 2);
    defer gpa.free(auth.text);
    try std.testing.expect(!failureAllowsRetry(auth.text));

    // A real transport/transient failure: classifies .transport (retrySafe:
    // true) and appends retry_ok_note — the gate must keep allowing retries.
    const transient = subagentFailure(gpa, "sa-002", error.StreamStalled, null, 3);
    defer gpa.free(transient.text);
    try std.testing.expect(failureAllowsRetry(transient.text));

    // A failure text with no subagentFailure marker at all (e.g. the
    // empty-report path, or an isolation-setup failure) — no marker means no
    // classification was made, so it must keep retrying like before this fix.
    try std.testing.expect(failureAllowsRetry("subagent finished without a report"));
}

test "a worker failure names how many asks it actually made (fleet honesty)" {
    const gpa = std.testing.allocator;

    // The observed run: one worker refused with an auth-shaped error while its
    // siblings on the SAME credential succeeded. subagent_retry buys that one
    // extra ask — and the parent must be able to tell "asked twice, refused
    // twice" from "never really tried". The old text said neither.
    const detail = "api error: The API Key appears to be invalid or may have expired.";
    const twice = subagentFailure(gpa, "sa-001-abcd", error.ApiError, detail, subagent_retry.auth_attempts);
    defer gpa.free(twice.text);
    try std.testing.expect(std.mem.indexOf(u8, twice.text, "[auth failure, 2 attempts]") != null);
    try std.testing.expect(std.mem.indexOf(u8, twice.text, detail) != null); // cause still verbatim
    try std.testing.expect(!failureAllowsRetry(twice.text)); // auth still blocks the PHASE retry above

    // The count must NOT push the cause out of workflow.zig's head-slice: the
    // prefix stays exactly as long as it was before retries existed, so the
    // 200-char excerpt still carries the provider's own words.
    try std.testing.expect(std.mem.startsWith(u8, twice.text, "subagent sa-001-abcd failed before producing a report: api error:"));
    const head = twice.text[0..@min(200, twice.text.len)]; // workflow.fail_excerpt_cap
    try std.testing.expect(std.mem.indexOf(u8, head, detail) != null);

    // A structural failure is asked once and says so — no plural implying a
    // ladder that never ran.
    const once = subagentFailure(gpa, "sa-002-abcd", error.ApiError, "model_not_found", 1);
    defer gpa.free(once.text);
    try std.testing.expect(std.mem.indexOf(u8, once.text, "[model-availability failure, 1 attempt]") != null);

    // The ladder runSub's loop can actually spend. Pinned here because these
    // are the numbers the sentence above is claiming to report.
    try std.testing.expectEqual(@as(u8, 2), subagent_retry.attemptBudget(.auth, null));
    try std.testing.expectEqual(@as(u8, 3), subagent_retry.attemptBudget(.transport, null));
    try std.testing.expectEqual(@as(u8, 1), subagent_retry.attemptBudget(.model, null));
    // A billing cap wearing the .quota label gets ONE ask, not the ladder —
    // the request layer already refused to keep paying for that refusal.
    try std.testing.expectEqual(@as(u8, 1), subagent_retry.attemptBudget(.quota, "rate limited (429): quota/billing cap — insufficient_quota"));
    try std.testing.expectEqual(@as(u8, 3), subagent_retry.attemptBudget(.quota, "rate limited (429): please retry shortly"));
}

test "a child's api-error cause reaches the parent verbatim (#287/#299)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // say() writes here instead of the terminal; what this pins is the copy
    // sayApiError leaves behind on the agent.
    var say_buf: [1024]u8 = undefined;
    var sink = Io.Writer.fixed(&say_buf);
    var child: Agent = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = true,
        .label = "child",
        .out = &sink,
    };

    // An empty body is a shape every wire format rejects. Each of these used to
    // `return error.ApiError` without recording a cause, so subagentFailure
    // fell back to @errorName and the parent's tool result read "ApiError" —
    // the opaque failure #287/#299 report.
    inline for (.{ Agent.stepAnthropic, Agent.stepOpenAI, Agent.stepResponses }) |step| {
        child.last_api_error = null;
        try std.testing.expectError(error.ApiError, step(&child, .empty));
        try std.testing.expect(child.last_api_error != null);
        const detail = child.last_api_error.?;

        // This is the wiring runSub depends on: agent.last_api_error ->
        // subagentFailure -> the string the parent's tool result carries.
        const out = subagentFailure(gpa, "sa-001-abcd", error.ApiError, child.last_api_error, 1);
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, detail) != null); // verbatim
        try std.testing.expect(std.mem.indexOf(u8, out.text, "ApiError") == null); // never the bare error name
    }
}
