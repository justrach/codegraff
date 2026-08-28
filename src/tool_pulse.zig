//! Silence heartbeat for long-running tools — the "is it stuck?" line.
//!
//! A blocking tool call (a foreground `bash` build, a `bash_output wait_ms>0`
//! wait per ADR 0010) can hold the turn for many minutes with zero visible
//! output; #607's pre-push hook sat silent for 13 of them and the session read
//! as hung. The fix is presentation-only: after enough SILENCE, emit one dim
//! `session_notice` pulse saying how long the call has run. ADR 0020 keeps raw
//! bytes behind /debug; an elapsed line is chrome, not output. The event is a
//! pulse, so --json drops it and no wire shape changes.

const std = @import("std");
const Io = std.Io;

const engine_sink = @import("engine_sink.zig");
const main_mod = @import("main.zig");
const style = &@import("ansi.zig").style;

/// First "still running" line after this much silence…
pub const first_silence_ms: u64 = 15_000;
/// …then every interval of continued silence (reset by any new output).
pub const silence_interval_ms: u64 = 60_000;

/// Per-call schedule state. Pure: callers own the clock.
pub const Pulse = struct {
    /// Silence total that triggers the next line.
    next_at_ms: u64 = first_silence_ms,
    /// Continued-silence spacing between beats. Injectable so tests can run
    /// the real schedule without waiting out the production intervals.
    interval_ms: u64 = silence_interval_ms,

    pub fn reset(self: *Pulse) void {
        self.next_at_ms = first_silence_ms;
    }

    /// True exactly once each time accumulated silence crosses the schedule.
    pub fn due(self: *Pulse, silence_ms: u64) bool {
        if (silence_ms < self.next_at_ms) return false;
        // Align the next beat relative to the crossing so a coarse poll
        // (~200ms ticks, 100ms job waits) cannot drift into double fires.
        const over = silence_ms - self.next_at_ms;
        self.next_at_ms = silence_ms + self.interval_ms - (over % self.interval_ms);
        return true;
    }
};

/// `2m10s`-style elapsed for humans.
pub fn formatElapsed(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch buf[0..0];
    const m = s / 60;
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ m, s % 60 }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ m / 60, m % 60 }) catch buf[0..0];
}

/// One dim chrome line per threshold. Frontend sink first (fullscreen TUI);
/// the line REPL/headless keep the process-default sink on the turn thread,
/// which a pool-thread tool cannot reach — so chrome lands straight on stdout,
/// the same privilege exec_bash_stream's live chunks (and tick_gate's cards)
/// already hold. Presentation pulse: --json and -p drop it (ADR 0020: chrome,
/// not output). `-p` sets `unattended` and promises stdout is only the answer;
/// rematch 2026-08-28 `schema-output` failed `json.load` because
/// `· turn still going ·` rode `g_out` ahead of the object.
pub fn emitNotice(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (engine_sink.hostedSink()) |sink| {
        sink.emit(io, .{ .session_notice = .{ .text = text, .tone = .dim } });
        return;
    }
    if (!chromeGoesToStdout()) return;
    const w = main_mod.g_out orelse return;
    w.print("{s}{s}{s}\n", .{ style.dim, text, style.reset }) catch return;
    w.flush() catch {};
}

/// Line-REPL only. Hosted TUI/ACP still get the pulse via `hostedSink`.
pub fn chromeGoesToStdout() bool {
    return !main_mod.json_mode and !main_mod.unattended;
}

test "Pulse fires once per silence threshold, then on the interval" {
    var p: Pulse = .{};
    try std.testing.expect(!p.due(0));
    try std.testing.expect(!p.due(first_silence_ms - 1));
    try std.testing.expect(p.due(first_silence_ms));
    // The next beat is a full interval past the crossing, not past zero.
    try std.testing.expect(!p.due(first_silence_ms + silence_interval_ms - 1));
    try std.testing.expect(p.due(first_silence_ms + silence_interval_ms));
    // New output resets the whole schedule.
    p.reset();
    try std.testing.expect(!p.due(first_silence_ms - 1));
    try std.testing.expect(p.due(first_silence_ms));
}

test "Pulse tolerates a coarse poll skipping a beat" {
    var p: Pulse = .{};
    // A 5x-interval jump (a stalled clock) fires once, not five times.
    try std.testing.expect(p.due(5 * first_silence_ms));
    try std.testing.expect(p.due(first_silence_ms + 4 * silence_interval_ms + 1));
}

test "formatElapsed renders seconds, minutes, and hours" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatElapsed(&buf, 0));
    try std.testing.expectEqualStrings("59s", formatElapsed(&buf, 59_000));
    try std.testing.expectEqualStrings("1m00s", formatElapsed(&buf, 60_000));
    try std.testing.expectEqualStrings("2m10s", formatElapsed(&buf, 130_000));
    try std.testing.expectEqualStrings("1h00m", formatElapsed(&buf, 3_600_000));
}

test "chrome does not ride --json or -p stdout" {
    const prev_u = main_mod.unattended;
    const prev_j = main_mod.json_mode;
    defer {
        main_mod.unattended = prev_u;
        main_mod.json_mode = prev_j;
    }
    main_mod.unattended = false;
    main_mod.json_mode = false;
    try std.testing.expect(chromeGoesToStdout());
    main_mod.unattended = true;
    try std.testing.expect(!chromeGoesToStdout());
    main_mod.unattended = false;
    main_mod.json_mode = true;
    try std.testing.expect(!chromeGoesToStdout());
}
