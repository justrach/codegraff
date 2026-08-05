//! #379: escalation evidence for complete-but-unusable compaction summaries.
//! Sibling of agent_compact_test.zig (which is at the 600-line ceiling).

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const compact = @import("agent_compact.zig");
const repeatedEmptySummaryFailure = compact.repeatedEmptySummaryFailure;

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
