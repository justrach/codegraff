const std = @import("std");
const builtin = @import("builtin");
const runner = @import("process_runner.zig");

test "clipboard runner deadline survives pipe EOF" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    const started = std.Io.Timestamp.now(io, .awake);
    const result = try runner.runCappedWithOptions(std.testing.allocator, io, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec sleep 30" }, 8, 8, 200, .{});
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.timed_out);
    try std.testing.expect(started.untilNow(io, .awake).toMilliseconds() < 2000);
}

test "clipboard runner EOF still returns natural exit and capped output" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const result = try runner.runCappedWithOptions(std.testing.allocator, std.testing.io, &.{ "/bin/sh", "-c", "printf 123456789; printf error >&2; exec 1>&- 2>&-; sleep 0.05; exit 7" }, 4, 3, 0, .{});
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 7), result.term.exited);
    try std.testing.expectEqualStrings("1234", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expect(result.stdout_truncated and result.stderr_truncated);
    try std.testing.expect(!result.timed_out and !result.cancelled);
}

fn cancelSoon(io: std.Io) void {
    io.sleep(.fromMilliseconds(100), .awake) catch return;
    @import("agent.zig").Agent.esc_cancel.store(true, .release);
}

test "clipboard runner Esc survives pipe EOF without deadline" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    defer @import("agent.zig").Agent.esc_cancel.store(false, .release);
    var cancel = try io.concurrent(cancelSoon, .{io});
    defer cancel.cancel(io);
    const started = std.Io.Timestamp.now(io, .awake);
    const result = try runner.runCappedWithOptions(std.testing.allocator, io, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec sleep 30" }, 8, 8, 0, .{ .kill_process_tree = true });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.cancelled and !result.timed_out);
    try std.testing.expect(started.untilNow(io, .awake).toMilliseconds() < 2000);
}

fn cappedAllocation(gpa: std.mem.Allocator) !void {
    const result = try runner.runCappedWithOptions(gpa, std.testing.io, &.{ "/bin/sh", "-c", "printf 123456789; printf err >&2" }, 4, 8, 2000, .{});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings("1234", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expect(result.stdout_truncated);
    try std.testing.expect(!result.stderr_truncated);
}

test "clipboard runner capped stdout allocation failures" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cappedAllocation, .{});
}
