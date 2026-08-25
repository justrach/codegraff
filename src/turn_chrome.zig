//! Dim chrome for long inner-loop turns and API transport retries (retry n/N).
//!
//! Production default: unlimited inner-loop model calls (`max_turn_model_calls = 0`).
//! `GRAFF_MAX_TURN_MODEL_CALLS` is the opt-in cap. JSON mode is dropped inside
//! `tool_pulse.emitNotice` (ADR 0020: chrome, not output).

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
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
    if (cap == 0)
        return std.fmt.bufPrint(buf, "· turn still going · model call {d} · {d} tools", .{ call_n, tools }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "· turn still going · model call {d}/{d} · {d} tools", .{ call_n, cap, tools }) catch buf[0..0];
}

pub fn emitRetryNotice(io: Io, class: []const u8, attempt: usize, max_attempts: usize) void {
    var buf: [120]u8 = undefined;
    const text = formatRetryNotice(&buf, class, attempt, max_attempts);
    if (text.len == 0) return;
    tool_pulse.emitNotice(io, "{s}", .{text});
}

/// Count this inner-loop request, pulse from call 2, optionally pause if a
/// non-zero cap is set. Returns pause text or null to proceed. Never pauses
/// when the cap is 0.
pub fn beforeRequest(self: *Agent) !?[]const u8 {
    self.model_calls_this_turn += 1;
    const cap = max_turn_model_calls;
    if (self.model_calls_this_turn >= 2 and !self.sub and !main_mod.json_mode) {
        var buf: [120]u8 = undefined;
        const text = formatTurnPulse(&buf, self.model_calls_this_turn, cap, self.tool_calls_this_turn);
        if (text.len > 0) tool_pulse.emitNotice(self.io, "{s}", .{text});
    }
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

test "formatTurnPulse omits a denominator when the cap is unlimited" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("· turn still going · model call 3 · 11 tools", formatTurnPulse(&buf, 3, 0, 11));
    try std.testing.expectEqualStrings("· turn still going · model call 3/64 · 11 tools", formatTurnPulse(&buf, 3, 64, 11));
}
