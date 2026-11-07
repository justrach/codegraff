//! Stream reconnect accounting and terminal stall diagnostics.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const http_stall = @import("http_stall.zig");

/// #680: what request() does before each stall reconnect. The partial is
/// cleared so the fresh stream re-streams cleanly (no concat), and the
/// between-lines budget widens (http_stall.budgetMsWidened) so the retry can
/// outlast the pause that killed the last attempt, instead of re-paying the
/// whole generation into the identical wait.
pub fn noteStallRetry(self: *Agent, retries: usize) void {
    self.partial_text.clearRetainingCapacity();
    self.stall.widen = @intCast(@min(retries, 255));
    if (self.tracer) |tr| {
        const widened = http_stall.budgetMsWidened(http.stream_stall_ms, true, self.stall.widen);
        tr.note("stall_budget", std.fmt.allocPrint(self.arena, "reconnect {d}: between-lines budget {d}s", .{ retries, widened / 1000 }) catch "widened");
    }
}

pub fn stallGiveUpMessage(self: *Agent, retries: usize) ?[]const u8 {
    const base = http_stall.streamPolicy(self.provider.model, self.provider.url, http.stream_stall_ms).silence_ms;
    const waited = if (self.stall.tripped_ms != 0) self.stall.tripped_ms else base;
    return std.fmt.allocPrint(self.arena, "stream stalled: no data from the model for {d}s — ended the turn after {d} reconnect attempts, each waiting longer (stream silence allowance {d}s; set GRAFF_STREAM_STALL_SECS to override)", .{ waited / 1000, retries, base / 1000 }) catch null;
}
