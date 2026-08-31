//! Per-request scratch and keep-alive retry helpers for the request loop.
//!
//! Split from agent_request.zig so that file stays under the 600-line ceiling
//! after the Codex WS error-frame merge (#693).

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const policy = @import("agent_request_policy.zig");
const http = @import("http.zig");
const RetryPlan = http.RetryPlan;
const run_budget_mod = @import("run_budget.zig");

const max_server_retries: usize = 3;

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
    if (!policy.sseKeepAliveOnly(body)) return false;
    if (retries.* >= max_server_retries) return false;
    retries.* += 1;
    self.partial_text.clearRetainingCapacity();
    const delay_ms = RetryPlan.delayMs(true, retries.* - 1); // 1·2·4s
    try self.say("[provider queued the request (keep-alive only, no tokens) — retrying in {d}s ({d}/{d})]\n", .{ delay_ms / 1000, retries.*, max_server_retries });
    self.sleepInterruptible(delay_ms) catch return error.Interrupted;
    return true;
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
