//! Structured startup phase receipts. Milestones recorded before the trace
//! file exists are buffered in a fixed array, then flushed when main attaches
//! the session tracer. Later milestones stream directly to that same trace.

const std = @import("std");
const Io = std.Io;
const trace = @import("trace.zig");

/// #364's teardown-side mirror of this module: `GRAFF_SHUTDOWN_DEBUG` phase
/// stamps for the quit path. Re-exported here — rather than imported directly
/// — because its only arming call site is main.zig, which sits exactly at the
/// 600-line ceiling and has no room for an import of its own. `arm`/`at`
/// return their `Io` for the same reason; see shutdown_trace.zig's header.
pub const shutdown_trace = @import("shutdown_trace.zig");

pub const Tracker = struct {
    const max_phases = 16;
    const Phase = struct { label: []const u8, cumulative_ms: i64, phase_ms: i64 };

    started: Io.Timestamp,
    debug: bool,
    phases: [max_phases]Phase = undefined,
    phases_len: usize = 0,
    last_ms: i64 = 0,
    tracer: ?*trace.Tracer = null,

    pub fn init(io: Io, debug: bool) Tracker {
        return .{ .started = Io.Timestamp.now(io, .awake), .debug = debug };
    }

    pub fn mark(self: *Tracker, io: Io, label: []const u8) void {
        const cumulative_ms: i64 = @intCast(@max(0, self.started.untilNow(io, .awake).toMilliseconds()));
        const phase: Phase = .{
            .label = label,
            .cumulative_ms = cumulative_ms,
            .phase_ms = @max(0, cumulative_ms - self.last_ms),
        };
        self.last_ms = cumulative_ms;
        if (shouldPrint(self.debug, phase.phase_ms))
            std.debug.print("[boot +{d}ms, phase {d}ms] {s}\n", .{ phase.cumulative_ms, phase.phase_ms, label });
        if (self.tracer) |tracer| {
            emit(tracer, phase);
        } else if (self.phases_len < self.phases.len) {
            self.phases[self.phases_len] = phase;
            self.phases_len += 1;
        }
    }

    pub fn attach(self: *Tracker, tracer: *trace.Tracer) void {
        if (self.tracer != null) return;
        self.tracer = tracer;
        for (self.phases[0..self.phases_len]) |phase| emit(tracer, phase);
        self.phases_len = 0;
    }

    /// `GRAFF_BOOT_DEBUG` prints every phase. Interactive boots also name
    /// anything ≥80ms so a hang after `plugins:` is visible without an env var.
    pub fn shouldPrint(debug: bool, phase_ms: i64) bool {
        return debug or phase_ms >= 80;
    }

    fn emit(tracer: *trace.Tracer, phase: Phase) void {
        tracer.write(.{
            .t = tracer.elapsedMs(),
            .ev = "startup_phase",
            .phase = phase.label,
            .phase_ms = phase.phase_ms,
            .startup_ms = phase.cumulative_ms,
        });
    }
};

test "startup phases retain order and non-negative deltas before attach" {
    var tracker = Tracker.init(std.testing.io, false);
    tracker.mark(std.testing.io, "args");
    tracker.mark(std.testing.io, "credentials");
    try std.testing.expectEqual(@as(usize, 2), tracker.phases_len);
    try std.testing.expectEqualStrings("args", tracker.phases[0].label);
    try std.testing.expectEqualStrings("credentials", tracker.phases[1].label);
    try std.testing.expect(tracker.phases[0].phase_ms >= 0);
    try std.testing.expect(tracker.phases[1].cumulative_ms >= tracker.phases[0].cumulative_ms);
}

test "slow boot phases print without GRAFF_BOOT_DEBUG" {
    try std.testing.expect(!Tracker.shouldPrint(false, 0));
    try std.testing.expect(!Tracker.shouldPrint(false, 79));
    try std.testing.expect(Tracker.shouldPrint(false, 80));
    try std.testing.expect(Tracker.shouldPrint(true, 0));
}
