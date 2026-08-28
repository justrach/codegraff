//! Dim chrome for long inner-loop turns and API transport retries (retry n/N).
//!
//! Production default: unlimited inner-loop model calls (`max_turn_model_calls = 0`).
//! `GRAFF_MAX_TURN_MODEL_CALLS` is the opt-in cap. Inner-loop counters stay
//! off the transcript (ADR 0021); retry notices still go through
//! `tool_pulse.emitNotice` (ADR 0020: chrome, not output; --json drops them).

const std = @import("std");
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const tool_pulse = @import("tool_pulse.zig");

/// Per-turn inner-loop cap. 0 = unlimited (the production default).
pub var max_turn_model_calls: u64 = 0;

pub fn parseMaxTurnCalls(raw: []const u8) u64 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

pub fn formatRetryNotice(buf: []u8, class: []const u8, attempt: usize, max_attempts: usize) []const u8 {
    return std.fmt.bufPrint(buf, "· retry {d}/{d} · {s}", .{ attempt, max_attempts, class }) catch buf[0..0];
}

pub fn formatTurnPulse(buf: []u8, call_n: u64, cap: u64, tools: u64) []const u8 {
    // Inner-loop counters are bookkeeping (ADR 0021). Tool rows already
    // show the work; "model call N · N tools" sat at the same weight as
    // "Wrote 1 file" and made a turn unreadable.
    _ = buf;
    _ = call_n;
    _ = cap;
    _ = tools;
    return "";
}

pub fn emitRetryNotice(io: Io, class: []const u8, attempt: usize, max_attempts: usize) void {
    var buf: [120]u8 = undefined;
    const text = formatRetryNotice(&buf, class, attempt, max_attempts);
    if (text.len == 0) return;
    tool_pulse.emitNotice(io, "{s}", .{text});
}

/// Count this inner-loop request and optionally pause if a non-zero cap is
/// set. Returns pause text or null to proceed. Never pauses when the cap is 0.
pub fn beforeRequest(self: *Agent) !?[]const u8 {
    self.model_calls_this_turn += 1;
    const cap = max_turn_model_calls;
    // Call 2+ used to print an inner-loop counter line. That line is gone;
    // formatTurnPulse is the pin that keeps it gone.
    if (cap != 0 and self.model_calls_this_turn > cap) {
        return try std.fmt.allocPrint(
            self.arena,
            "paused after {d} model calls this turn ({d} tools). Reply to continue, or steer.",
            .{ cap, self.tool_calls_this_turn },
        );
    }
    return null;
}

test "default inner-loop cap is unlimited / 0 unless an explicit override parses" {
    try std.testing.expectEqual(@as(u64, 0), max_turn_model_calls);
    try std.testing.expectEqual(@as(u64, 0), parseMaxTurnCalls(""));
    try std.testing.expectEqual(@as(u64, 0), parseMaxTurnCalls("   "));
    try std.testing.expectEqual(@as(u64, 0), parseMaxTurnCalls("nope"));
    try std.testing.expectEqual(@as(u64, 32), parseMaxTurnCalls("32"));
    try std.testing.expectEqual(@as(u64, 16), parseMaxTurnCalls(" 16 "));
}

test "formatRetryNotice names HungRequest and UnknownHostName with attempt n/N" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("· retry 3/6 · HungRequest", formatRetryNotice(&buf, "HungRequest", 3, 6));
    try std.testing.expectEqualStrings("· retry 1/6 · UnknownHostName", formatRetryNotice(&buf, "UnknownHostName", 1, 6));
}

test "formatTurnPulse stays off the transcript (ADR 0021)" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("", formatTurnPulse(&buf, 3, 0, 11));
    try std.testing.expectEqualStrings("", formatTurnPulse(&buf, 3, 64, 11));
}

test "beforeRequest does not print an inner-loop pulse (ADR 0021)" {
    const src = @embedFile("turn_chrome.zig");
    const start = std.mem.indexOf(u8, src, "pub fn beforeRequest").?;
    const rest = src[start + 1 ..];
    const end = std.mem.indexOf(u8, rest, "\ntest ").?;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "emitNotice") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "turn still going") == null);
}
