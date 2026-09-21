//! Privacy-safe classification of the clipboard helper's bounded reply.
//! AppKit reads do not send Apple Events; a failed helper is not evidence
//! that the terminal needs Automation permission (#883).
const std = @import("std");
const clip = @import("vision_clipboard.zig");
const runner = @import("process_runner.zig");

pub const Result = union(enum) {
    image: clip.Flavor,
    empty,
    changed,
    failed: clip.FailKind,
};

pub fn classify(r: runner.CappedRun) Result {
    if (r.timed_out) return .{ .failed = .timeout };
    if (r.cancelled) return .{ .failed = .unavailable };
    if (!runner.ranOk(r)) {
        // Only the system's explicit Apple Event denial code warrants a
        // permission category. Never show raw stderr (it may contain paths).
        if (r.term == .exited and !r.stderr_truncated and std.mem.endsWith(u8, std.mem.trim(u8, r.stderr, " \r\n"), "(-1743)"))
            return .{ .failed = .denied };
        return .{ .failed = .unavailable };
    }
    if (r.stdout_truncated) return .{ .failed = .extract };
    const status = std.mem.trim(u8, r.stdout, " \r\n");
    if (std.mem.eql(u8, status, "changed")) return .changed;
    if (std.mem.eql(u8, status, "empty")) return .empty;
    if (std.mem.eql(u8, status, "convert")) return .{ .failed = .convert };
    if (std.mem.startsWith(u8, status, "ok:")) {
        if (std.meta.stringToEnum(clip.Flavor, status[3..])) |flavor|
            return .{ .image = flavor };
    }
    return .{ .failed = .extract };
}
