//! Terminal JSON turn-event projection for the session-wide usage tally.

const std = @import("std");
const Io = std.Io;
const pricing = @import("pricing.zig");

pub const Event = struct {
    type: []const u8 = "turn",
    text: []const u8,
    context_tokens: u64,
    cost_usd: f64,
    input_tokens: u64,
    uncached_input_tokens: u64,
    cache_read_tokens: u64,
    output_tokens: u64,
    api_calls: u64,
    subscription_calls: u64,
    unpriced_calls: u64,
    complete: bool,
    metadata_complete: bool,
};

/// Build one terminal event from an internally consistent cumulative snapshot.
pub fn fromTally(tally: *pricing.CostTally, io: Io, text: []const u8, context_tokens: u64, complete: bool) Event {
    const c = tally.snap(io);
    return .{
        .text = text,
        .context_tokens = context_tokens,
        .cost_usd = c.usd,
        .input_tokens = c.in_tokens +| c.cache_tokens,
        .uncached_input_tokens = c.in_tokens,
        .cache_read_tokens = c.cache_tokens,
        .output_tokens = c.out_tokens,
        .api_calls = c.api_calls,
        .subscription_calls = c.sub_calls,
        .unpriced_calls = c.unpriced_calls,
        .complete = complete,
        .metadata_complete = context_tokens > 0,
    };
}
