//! #379: escalation evidence for complete-but-unusable compaction summaries.
//! Sibling of agent_compact_test.zig (which is at the 600-line ceiling).

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const compact = @import("agent_compact.zig");
const repeatedEmptySummaryFailure = compact.repeatedEmptySummaryFailure;
const handoff_note = @import("compact_handoff_note.zig");
const session_transcript = @import("session_transcript.zig");
const compact_instruction = @import("prompts.zig").compact_instruction;

test "repeated empty summaries unlock bounded recovery (#379)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.messages = std.json.Array.init(a);
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.last_context_tokens = 85_000; // over compact@ (80%), well under 95%
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    agent.compact_summary_failures = 0;

    // One empty summary is not evidence; two consecutive are.
    try std.testing.expect(!repeatedEmptySummaryFailure(&agent, error.EmptySummary));
    try std.testing.expectEqual(@as(u8, 1), agent.compact_summary_failures);
    try std.testing.expect(repeatedEmptySummaryFailure(&agent, error.EmptySummary));

    // Truncated summaries count toward the same streak.
    agent.compact_summary_failures = 1;
    try std.testing.expect(repeatedEmptySummaryFailure(&agent, error.IncompleteSummary));

    // Any other failure kind breaks the streak — transport noise is not proof
    // the model can't summarize.
    agent.compact_summary_failures = 1;
    try std.testing.expect(!repeatedEmptySummaryFailure(&agent, error.ApiError));
    try std.testing.expectEqual(@as(u8, 0), agent.compact_summary_failures);

    // Under the compaction threshold there is nothing to escape from.
    agent.last_context_tokens = 10_000;
    agent.context_local_tokens = 0;
    agent.compact_summary_failures = 1;
    try std.testing.expect(!repeatedEmptySummaryFailure(&agent, error.EmptySummary));

    // Unknown context windows never authorize destructive recovery.
    agent.provider.context = 0;
    agent.last_context_tokens = 85_000;
    agent.compact_summary_failures = 1;
    try std.testing.expect(!repeatedEmptySummaryFailure(&agent, error.EmptySummary));
}

// #411 appended a "what persists" note to the summary REQUEST. #379 classifies
// the RESPONSE to that request, so the two must not interact: the request still
// LEADS with the byte-identical instruction, carries none of the after-the-fact
// ground truth, and two consecutive unusable replies still escalate exactly as
// they did. A note that changed the request's head is the shape of regression
// this guards - it would be invisible in #411's own tests.
test "#411's request note leaves #379's empty-summary escalation exactly as it was" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();

    var agent: Agent = undefined;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.messages = std.json.Array.init(a);
    agent.sub = false;
    agent.review_mode = false;
    agent.snapshots = null;
    agent.session_name = "";
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.last_context_tokens = 85_000;
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    agent.compact_summary_failures = 0;

    const request = try handoff_note.summaryRequest(a, &agent);
    try std.testing.expect(std.mem.startsWith(u8, request, compact_instruction));
    try std.testing.expect(std.mem.indexOf(u8, request, "durable state, re-derived") == null);
    try std.testing.expect(!repeatedEmptySummaryFailure(&agent, error.EmptySummary));
    try std.testing.expect(repeatedEmptySummaryFailure(&agent, error.EmptySummary));
    // And a usable summary still ends the streak, which is what stops a healthy
    // session accumulating its way into an emergency trim.
    agent.compact_summary_failures = 0;
    try std.testing.expect(!repeatedEmptySummaryFailure(&agent, error.ApiError));
}
