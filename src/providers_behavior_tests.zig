//! Behavioral root-scope regression tests for provider fallback.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const Keys = @import("provider.zig").Keys;
const providers = @import("providers.zig");
const trace = @import("trace.zig");

test "runTurnWithFallback: blocked return closes behavioral root scope" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var events: Io.Writer.Allocating = .init(gpa);
    defer events.deinit();
    var behavior: trace.BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &events.writer,
        .run_id = "blocked-fallback-run",
    };
    behavior.start("test", 1);
    var tracer: trace.Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    const previous_trajectory = trace.g_traj;
    trace.g_traj = null;
    defer trace.g_traj = previous_trajectory;

    var root: Agent = undefined;
    root.tracer = &tracer;
    root.fallback_blocked = true;
    const keys: Keys = .{ .values = @splat(null) };
    try std.testing.expectError(
        error.FallbackConsentRequired,
        providers.runTurnWithFallback(&root, @constCast(&keys), gpa, null),
    );

    try std.testing.expectEqual(@as(u64, 0), behavior.currentTurn());
    try std.testing.expectEqual(
        @as(u64, 0),
        behavior.recordApiMetric(false, 1, 2, 3, 4, 5, false),
    );

    var turn_starts: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, events.writer.buffered(), "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(Value, gpa, line, .{});
        defer parsed.deinit();
        const kind = parsed.value.object.get("kind") orelse continue;
        if (kind == .string and std.mem.eql(u8, kind.string, "turn_started")) turn_starts += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), turn_starts);
}
