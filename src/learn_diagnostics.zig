//! Privacy boundary for diagnostics emitted by pinned learning adapters.
//!
//! Raw stderr and executable paths may contain prompts, repository text,
//! credentials, or usernames. They are hidden unless the human explicitly
//! opts in on the local `graff learn run` command line.

const std = @import("std");

var detailed_value: std.atomic.Value(bool) = .init(false);

pub fn setDetailed(enabled: bool) void {
    detailed_value.store(enabled, .release);
}

pub fn detailed() bool {
    return detailed_value.load(.acquire);
}

fn excerpt(stderr: []const u8) []const u8 {
    return stderr[0..@min(stderr.len, 4096)];
}

pub fn reportTimeout(operation: []const u8, program: []const u8, timeout_ms: u64, stderr: []const u8) void {
    if (!detailed()) {
        std.debug.print("learn: {s} adapter timed out after {d} ms; private diagnostics hidden (rerun locally with --show-adapter-stderr)\n", .{ operation, timeout_ms });
        return;
    }
    const shown = excerpt(stderr);
    std.debug.print("learn: {s} adapter {s} timed out after {d} ms; raw stderr explicitly enabled ({d} of {d} bytes):\n{s}\n", .{ operation, program, timeout_ms, shown.len, stderr.len, shown });
}

pub fn reportFailure(operation: []const u8, program: []const u8, term: std.process.Child.Term, stderr: []const u8) void {
    if (!detailed()) {
        std.debug.print("learn: {s} adapter failed ({any}); private diagnostics hidden (rerun locally with --show-adapter-stderr)\n", .{ operation, term });
        return;
    }
    const shown = excerpt(stderr);
    std.debug.print("learn: {s} adapter {s} failed ({any}); raw stderr explicitly enabled ({d} of {d} bytes):\n{s}\n", .{ operation, program, term, shown.len, stderr.len, shown });
}
