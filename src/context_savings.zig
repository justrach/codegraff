//! What graff kept out of the model's context, for a client that shows it
//! next to the context meter (Harness). Every count is measured on what graff
//! actually handled in this process; none models what another agent would
//! have spent on the same task.
//!
//! - `handle_bytes`: tool results over the handle threshold were written to a
//!   file (#440). The bytes the model never received: the full result minus
//!   the preview and marker it got instead.
//! - `compacted_tokens`: estimated context tokens freed by compaction or an
//!   emergency trim (before minus after).
//! - `cache_read_tokens`: input the provider reported serving from its prompt
//!   cache (pricing.g_cost). Billed, but at the provider's cache rate.
//!
//! Process-wide, like pricing.g_cost: one ACP connection's sessions, with
//! subagents included.

const std = @import("std");
const Io = std.Io;

var handle_bytes: std.atomic.Value(u64) = .init(0);
var compacted_tokens: std.atomic.Value(u64) = .init(0);

/// A tool result of `full` bytes reached the model as `sent` bytes.
pub fn noteHandle(full: usize, sent: usize) void {
    if (full > sent) _ = handle_bytes.fetchAdd(full - sent, .monotonic);
}

/// Context went from `before` to `after` estimated tokens.
pub fn noteCompaction(before: u64, after: u64) void {
    if (before > after) _ = compacted_tokens.fetchAdd(before - after, .monotonic);
}

/// Wire names are the ACP `_meta["codegraff/savings"]` fields.
pub const Snapshot = struct {
    handleBytes: u64 = 0,
    compactedTokens: u64 = 0,
    cacheReadTokens: u64 = 0,

    pub fn any(s: Snapshot) bool {
        return s.handleBytes > 0 or s.compactedTokens > 0 or s.cacheReadTokens > 0;
    }
};

pub fn snap(io: Io) Snapshot {
    return .{
        .handleBytes = handle_bytes.load(.monotonic),
        .compactedTokens = compacted_tokens.load(.monotonic),
        .cacheReadTokens = @import("pricing.zig").g_cost.snap(io).cache_tokens,
    };
}

pub fn resetForTest() void {
    handle_bytes.store(0, .monotonic);
    compacted_tokens.store(0, .monotonic);
}

test "savings count only what was actually withheld or freed" {
    resetForTest();
    defer resetForTest();
    noteHandle(100_000, 4_000);
    noteHandle(10, 10); // passed through whole
    noteHandle(10, 20); // a marker longer than its input is not a saving
    noteCompaction(90_000, 12_000);
    noteCompaction(5, 9);
    try std.testing.expectEqual(@as(u64, 96_000), handle_bytes.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 78_000), compacted_tokens.load(.monotonic));
    try std.testing.expect((Snapshot{}).any() == false);
    try std.testing.expect((Snapshot{ .compactedTokens = 1 }).any());
}
