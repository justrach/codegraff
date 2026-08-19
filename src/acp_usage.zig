//! ACP token-usage projection.
//!
//! PromptResponse.usage is the per-turn CostTally *delta* (ADR 0012). That is
//! the official v1 home for end-turn tokens ([RFD](https://agentclientprotocol.com/rfds/end-turn-token-usage));
//! `inputTokens` is the full prompt (ordinary + cache-write + cache-read), the
//! same number grok ACP's `updates.jsonl` calls `inputTokens` and the same
//! sum `--json` reports as `input_tokens`. Session context + cumulative $
//! belong on `session/update` `usage_update`, not here.

const std = @import("std");
const pricing = @import("pricing.zig");

/// ACP `Usage` on `session/prompt`'s result. Field names are the wire names.
pub const Usage = struct {
    totalTokens: u64,
    inputTokens: u64,
    outputTokens: u64,
    cachedReadTokens: u64 = 0,
    cachedWriteTokens: u64 = 0,
};

/// ACP `usage_update` session notification (context window + cumulative cost).
pub const SessionUsage = struct {
    used: u64,
    size: u64,
    cost_usd: f64,
};

/// What one dispatched turn hands back to the protocol layer.
pub const TurnOutcome = struct {
    text: []const u8,
    usage: ?Usage = null,
    session: ?SessionUsage = null,
};

/// Tokens this turn added to the process-wide tally.
///
/// `CostTally.in_tokens` is ordinary input plus cache writes; cache reads sit
/// in `cache_tokens`. Adding those two deltas is the full prompt the provider
/// billed. A later snap that went backwards (reset, wrap) saturates at 0.
pub fn fromTallyDelta(before: pricing.CostTally, after: pricing.CostTally) Usage {
    const ordinary_and_write = after.in_tokens -| before.in_tokens;
    const cached_read = after.cache_tokens -| before.cache_tokens;
    const cached_write = after.cache_write_tokens -| before.cache_write_tokens;
    const output = after.out_tokens -| before.out_tokens;
    const input = ordinary_and_write +| cached_read;
    return .{
        .totalTokens = input +| output,
        .inputTokens = input,
        .outputTokens = output,
        .cachedReadTokens = cached_read,
        .cachedWriteTokens = cached_write,
    };
}

const testing = std.testing;

test "fromTallyDelta: inputTokens is the full prompt, including cache reads" {
    const before: pricing.CostTally = .{
        .in_tokens = 100,
        .cache_tokens = 80,
        .cache_write_tokens = 10,
        .out_tokens = 5,
    };
    const after: pricing.CostTally = .{
        .in_tokens = 140, // +40 ordinary+write (includes +8 write)
        .cache_tokens = 200, // +120 read
        .cache_write_tokens = 18, // +8 write
        .out_tokens = 25, // +20
    };
    const u = fromTallyDelta(before, after);
    try testing.expectEqual(@as(u64, 160), u.inputTokens); // 40 + 120
    try testing.expectEqual(@as(u64, 20), u.outputTokens);
    try testing.expectEqual(@as(u64, 120), u.cachedReadTokens);
    try testing.expectEqual(@as(u64, 8), u.cachedWriteTokens);
    try testing.expectEqual(@as(u64, 180), u.totalTokens);
}

test "fromTallyDelta: a later snap that went backwards saturates at zero" {
    const before: pricing.CostTally = .{ .in_tokens = 50, .cache_tokens = 10, .out_tokens = 3 };
    const after: pricing.CostTally = .{ .in_tokens = 10, .cache_tokens = 0, .out_tokens = 1 };
    const u = fromTallyDelta(before, after);
    try testing.expectEqual(@as(u64, 0), u.inputTokens);
    try testing.expectEqual(@as(u64, 0), u.outputTokens);
    try testing.expectEqual(@as(u64, 0), u.cachedReadTokens);
    try testing.expectEqual(@as(u64, 0), u.totalTokens);
}

test "fromTallyDelta: a cold first turn reports the absolute tally" {
    const u = fromTallyDelta(.{}, .{
        .in_tokens = 3767,
        .cache_tokens = 3712,
        .cache_write_tokens = 0,
        .out_tokens = 12,
    });
    try testing.expectEqual(@as(u64, 7479), u.inputTokens);
    try testing.expectEqual(@as(u64, 3712), u.cachedReadTokens);
    try testing.expectEqual(@as(u64, 12), u.outputTokens);
    try testing.expectEqual(@as(u64, 7491), u.totalTokens);
}
