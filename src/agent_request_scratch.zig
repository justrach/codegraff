//! Per-request scratch and keep-alive retry helpers for the request loop.
//!
//! Split from agent_request.zig so that file stays under the 600-line ceiling
//! after the Codex WS error-frame merge (#693).

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const run_budget_mod = @import("run_budget.zig");

/// Keep the normal request hot path allocation-free while avoiding a permanent
/// RSS high-water mark after one anomalously large stream. Small scratch arenas
/// retain their pages for the next request; large ones return all pages to the
/// backing allocator. History never lives here, so either reset mode is safe at
/// the start of the next request.
const scratch_retain_limit = 4 * 1024 * 1024;

pub fn reset(scratch: *std.heap.ArenaAllocator) void {
    if (scratch.queryCapacity() > scratch_retain_limit) {
        _ = scratch.reset(.free_all);
    } else {
        _ = scratch.reset(.retain_capacity);
    }
}

/// Detached recaps are cosmetic: keep recovered transport details in the trace,
/// but do not surface them as raw worker chatter in the normal REPL.
pub fn showRecoveredTransportRetry(kind: run_budget_mod.CallKind) bool {
    return kind != .recap;
}

/// A response body of only SSE comment lines (`: OPENROUTER PROCESSING` …)
/// means the gateway queued us and never produced tokens — back off and re-ask
/// like a 5xx instead of dying on an "unparseable" JSON parse.
pub fn retryKeepAliveOnly(self: *Agent, body: []const u8, retries: *usize) !bool {
    return @import("agent_gateway_retry.zig").retryDegenerateBody(self, body, retries);
}

test "recovered recap transport retries stay out of normal REPL output" {
    try std.testing.expect(!showRecoveredTransportRetry(.recap));
    try std.testing.expect(showRecoveredTransportRetry(.root));
    try std.testing.expect(showRecoveredTransportRetry(.child));
}

test "request scratch retains normal capacity but releases an oversized spike" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();

    _ = try scratch.allocator().alloc(u8, 1024);
    const normal_capacity = scratch.queryCapacity();
    try std.testing.expect(normal_capacity > 0);
    reset(&scratch);
    try std.testing.expectEqual(normal_capacity, scratch.queryCapacity());

    _ = try scratch.allocator().alloc(u8, scratch_retain_limit + 1);
    try std.testing.expect(scratch.queryCapacity() > scratch_retain_limit);
    reset(&scratch);
    try std.testing.expectEqual(@as(usize, 0), scratch.queryCapacity());
}
