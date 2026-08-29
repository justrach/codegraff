//! Wait policy for background bash jobs and subagents — ADR 0010.
//!
//! grok-build waits for completion inside the tool (or wakes once on exit).
//! graff used to cap `wait_ms` at 30s and return on *new output*, so a
//! `gh run watch` loop paid one model hop every 30s. Trajectory 69cb38
//! spent 199 of 203 `bash_output` calls immediately followed by an API
//! call. This module is the measured fix: `wait_ms > 0` blocks until the
//! job exits (10h cap); the old 1–30000 poll values are promoted to that
//! cap so a model that still says `wait_ms=30000` waits for done.

const std = @import("std");

/// Same 10-hour ceiling grok-build uses for a foreground/background wait.
pub const wait_cap_ms: u64 = 10 * 60 * 60 * 1000;

/// Legacy `bash_output` / `agent_output` poll signature (schema said 0–30000).
pub const legacy_poll_ms: u64 = 30_000;

/// Map a model-supplied `wait_ms` onto a real deadline.
///
/// * `0` — snapshot now (do not block).
/// * `> 0` — wait until exit (or Esc), always `wait_cap_ms`. Mid-range
///   "safety timeouts" (60s–240s) used to be honored as a bounded
///   deadline (#640) and bounced the model every few minutes.
pub fn resolveDeadline(wait_ms: u64) u64 {
    if (wait_ms == 0) return 0;
    return wait_cap_ms;
}

test "resolveDeadline: snapshot stays zero" {
    try std.testing.expectEqual(@as(u64, 0), resolveDeadline(0));
}

test "resolveDeadline: the 30s poll signature waits for exit (10h)" {
    try std.testing.expectEqual(wait_cap_ms, resolveDeadline(1));
    try std.testing.expectEqual(wait_cap_ms, resolveDeadline(legacy_poll_ms));
}

test "resolveDeadline: mid-range and huge values are the 10h exit cap (#640)" {
    try std.testing.expectEqual(wait_cap_ms, resolveDeadline(60_000));
    try std.testing.expectEqual(wait_cap_ms, resolveDeadline(240_000));
    try std.testing.expectEqual(wait_cap_ms, resolveDeadline(wait_cap_ms));
    try std.testing.expectEqual(wait_cap_ms, resolveDeadline(wait_cap_ms + 1));
}

test "resolveDeadline: 10h is 36_000_000 ms" {
    try std.testing.expectEqual(@as(u64, 36_000_000), wait_cap_ms);
}
