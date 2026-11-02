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
const style = &@import("ansi.zig").style;

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

/// Gate for a turn-pulse line if one is ever reintroduced. `#665` emptied
/// `formatTurnPulse`; this still skips `-p` / `--json` / subagents so a
/// future pulse cannot land on eval stdout (ADR 0046).
pub fn shouldPulseTurn(unattended: bool, json_mode: bool, sub: bool, call_n: u64) bool {
    return call_n >= 2 and !sub and !json_mode and !unattended;
}

/// Count this inner-loop request and optionally pause if a non-zero cap is
/// set. Returns pause text or null to proceed. Never pauses when the cap is 0.
/// Call 2+ used to print an inner-loop counter; that line is gone (ADR 0021).
pub fn beforeRequest(self: *Agent) !?[]const u8 {
    if (try @import("subagent_interactive.zig").beforeRequest(self)) |text| {
        // ADR 0247: work that resumes the session is named above `›` by the
        // standing block on every redraw; print only what that will not say.
        if (!@import("subagent_interactive.zig").yield_wakes)
            try self.say("{s}↻ {s}{s}\n", .{ style.accent, text, style.reset });
        return text;
    }
    self.model_calls_this_turn += 1;
    const cap = max_turn_model_calls;
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

test "retry chrome stays out of ACP JSON and one-shot answer writers" {
    const main_mod = @import("main.zig");
    const prev_json = main_mod.json_mode;
    const prev_unattended = main_mod.unattended;
    const prev_out = main_mod.g_out;
    defer {
        main_mod.json_mode = prev_json;
        main_mod.unattended = prev_unattended;
        main_mod.g_out = prev_out;
    }
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    main_mod.g_out = &output.writer;
    for ([_][2]bool{ .{ true, false }, .{ false, true }, .{ true, true } }) |mode| {
        main_mod.json_mode = mode[0];
        main_mod.unattended = mode[1];
        emitRetryNotice(undefined, "UnknownHostName", 1, 6);
        emitRetryNotice(undefined, "HungRequest", 2, 6);
        try std.testing.expectEqualStrings("", output.written());
    }
    main_mod.json_mode = false;
    main_mod.unattended = false;
    emitRetryNotice(undefined, "UnknownHostName", 1, 6);
    emitRetryNotice(undefined, "HungRequest", 2, 6);
    const text = output.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "· retry 1/6 · UnknownHostName") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "· retry 2/6 · HungRequest") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[network error:") == null);
}

test "hosted retry chrome is one dim presentation notice, not a durable answer" {
    const sinks = @import("engine_sink.zig");
    const events = @import("engine_events.zig");
    const Capture = struct {
        count: usize = 0,
        dim: bool = false,
        durable: bool = false,
        text: [120]u8 = undefined,
        len: usize = 0,
        fn emit(ctx: *anyopaque, stamped: sinks.Stamped) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            self.durable = events.durable(stamped.event);
            if (stamped.event == .session_notice) {
                const notice = stamped.event.session_notice;
                self.dim = notice.tone == .dim;
                self.len = notice.text.len;
                @memcpy(self.text[0..self.len], notice.text);
            }
        }
    };
    var capture: Capture = .{};
    const vt: sinks.VTable = .{ .emit = Capture.emit, .durable = false };
    sinks.bindTurnSink(.{ .ctx = &capture, .vt = &vt });
    defer sinks.unbindTurnSink();
    emitRetryNotice(undefined, "HungRequest", 3, 6);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.dim);
    try std.testing.expect(!capture.durable);
    try std.testing.expectEqualStrings("· retry 3/6 · HungRequest", capture.text[0..capture.len]);
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

test "one-shot and --json do not pulse turn chrome onto stdout" {
    try std.testing.expect(shouldPulseTurn(false, false, false, 2));
    try std.testing.expect(!shouldPulseTurn(true, false, false, 2));
    try std.testing.expect(!shouldPulseTurn(false, true, false, 2));
    try std.testing.expect(!shouldPulseTurn(false, false, true, 2));
    try std.testing.expect(!shouldPulseTurn(false, false, false, 1));
}
