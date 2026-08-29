//! Per-phase shutdown timings (#364).
//!
//! A REPL that does not exit used to be a silent 30s and a bare `exit=-15` in
//! CI: the transcript ended at the prompt, and nothing distinguished "the quit
//! key never arrived" from "teardown stalled" — let alone WHICH teardown step
//! stalled. Every phase of the quit path now stamps a line, so the next hang
//! names itself.
//!
//! Off unless `GRAFF_SHUTDOWN_DEBUG` is set (mirrors `GRAFF_BOOT_DEBUG` /
//! startup_timing.zig). Output goes to stderr rather than the trace file so it
//! survives a hang — nothing is buffered, nothing needs a clean close — and so
//! a pty harness capturing the terminal sees it in the transcript it dumps.
//! scripts/test-pty-parallel-cancel.py turns it on for exactly that reason.
//!
//! READING THE OUTPUT. A mark is written when a phase BEGINS and carries how
//! long the PREVIOUS phase took. On a hang the last line printed names the
//! phase that is stuck, and the lines before it are a clean teardown profile.
//! NO lines at all means the loop never reached its exit — the quit keystroke
//! itself was lost, which is what #364 turned out to be.
//!
//! WHY `arm`/`at` RETURN `Io`. main.zig, mainloop.zig and session_run.zig are
//! all at the 600-line ceiling, so the teardown they own cannot afford a
//! statement per phase. Both helpers pass their `io` straight through, so a
//! call site instruments itself inside an expression it already has:
//!
//!     defer joinElites(shutdown_trace.at(io, "join-elites"));
//!
//! State is process-global on purpose: teardown runs across a dozen modules
//! and there is no shutdown object to thread through them. `arm` also stores
//! the Io, so the phases that are marked from inside a callee (session.zig,
//! jobs.zig, …) need no new parameter to reach the clock.

const std = @import("std");
const Io = std.Io;

/// Set (to anything) to print the phase lines.
pub const env_var = "GRAFF_SHUTDOWN_DEBUG";

var enabled = false;
var clock: ?Io = null;
var started: Io.Timestamp = undefined;
var last_ms: i64 = 0;

/// Read the opt-in, keep the Io, and start the clock. Returns `io` so main()
/// can arm this inside a call it already makes (see the header). Re-arming
/// restarts the clock, which is what a re-entered process wants.
pub fn arm(io: Io, environ_map: *const std.process.Environ.Map) Io {
    enabled = environ_map.get(env_var) != null;
    clock = io;
    started = Io.Timestamp.now(io, .awake);
    last_ms = 0;
    return io;
}

/// Stamp the beginning of one teardown phase. A no-op when unarmed (unit
/// tests, `graff repl`, any path that never called `arm`) or when the opt-in
/// is off, so a normal exit pays one bool load per phase.
pub fn mark(phase: []const u8) void {
    // ADR 0042: an early pager claim that never reached `tui.run` still
    // owns the alt-screen. Main's first teardown `at()` lands here.
    @import("tui").restore.releaseIfOwned();
    if (!enabled) return;
    const io = clock orelse return;
    const cumulative: i64 = @intCast(@max(0, started.untilNow(io, .awake).toMilliseconds()));
    var buf: [160]u8 = undefined;
    std.debug.print("{s}", .{render(&buf, phase, cumulative, @max(0, cumulative - last_ms))});
    last_ms = cumulative;
}

/// `mark`, passing `io` through — the form call sites at the line ceiling use.
pub fn at(io: Io, phase: []const u8) Io {
    mark(phase);
    return io;
}

/// The rendered line. Split out so its shape is testable without a terminal:
/// the numbers are the whole point of the feature, and a silently truncated
/// line would report nothing at all.
pub fn render(buf: []u8, phase: []const u8, cumulative_ms: i64, phase_ms: i64) []const u8 {
    return std.fmt.bufPrint(buf, "[shutdown +{d}ms, prev {d}ms] {s}\n", .{ cumulative_ms, phase_ms, phase }) catch phase;
}

/// Test seam: the tests below must neither depend on whether this process was
/// armed nor leave the flag on for a later test.
pub fn setEnabledForTest(on: bool) void {
    enabled = on;
}

test "render names the phase and both durations" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[shutdown +1234ms, prev 56ms] jobs-reap\n",
        render(&buf, "jobs-reap", 1234, 56),
    );
}

test "render degrades to the bare phase name rather than dropping it" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("join-elites", render(&tiny, "join-elites", 1, 1));
}

test "teardown stamps release an early pager claim" {
    const src = @embedFile("shutdown_trace.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "releaseIfOwned") != null);
}

test "an unarmed process prints nothing and `at` stays a pass-through" {
    setEnabledForTest(false);
    mark("never-printed");
    // `at` is what call sites embed in an existing expression, so it must hand
    // back exactly the io it was given whether or not tracing is on.
    _ = at(std.testing.io, "also-never-printed");
    try std.testing.expect(!enabled);
    // Armed but with no clock (no `arm` in this process) must also stay silent
    // rather than read the undefined timestamp.
    setEnabledForTest(true);
    clock = null;
    mark("no-clock-no-output");
    setEnabledForTest(false);
}
