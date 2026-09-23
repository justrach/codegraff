//! Exact gateway charge ingestion; never derive a settled amount from a list rate.
const std = @import("std");

pub fn add(tally: anytype, io: std.Io, input: i64, output: i64, charge_micro_usd: u64) void {
    tally.mutex.lockUncancelable(io);
    defer tally.mutex.unlock(io);
    tally.api_calls +|= 1;
    tally.in_tokens +|= @intCast(@max(input, 0));
    tally.out_tokens +|= @intCast(@max(output, 0));
    tally.usd += @as(f64, @floatFromInt(charge_micro_usd)) / 1_000_000;
}
