//! Read-only adapters for legacy listener discovery; never grants stop authority.
const std = @import("std");
const discovery = @import("server_discovery.zig");
const doctor = @import("doctor.zig");
const A = std.mem.Allocator;

pub fn findings(arena: A, result: discovery.Result) A.Error![]const doctor.Check {
    var out: std.ArrayList(doctor.Check) = .empty;
    if (result.incomplete) try out.append(arena, .{
        .id = "LISTENER_PROBE_UNAVAILABLE",
        .severity = .warn,
        .title = "listener discovery incomplete",
        .detail = "A bounded process or socket probe could not complete. Missing evidence does not mean no orphan listeners exist; no processes were stopped.",
    });
    for (result.candidates) |candidate| try out.append(arena, .{
        .id = "ORPHANED_LISTENER_CANDIDATE",
        .severity = .warn,
        .title = "possible pre-registry listener",
        .detail = try std.fmt.allocPrint(arena, "Orphan group {d}, listener {d}: inherited Graff marker is only a hint, not ownership or stop authority. Inspect with graff servers; no process was adopted or stopped.", .{ candidate.pid, candidate.listener }),
    });
    return out.toOwnedSlice(arena);
}

pub fn capture(arena: A, io: std.Io) A.Error![]const doctor.Check {
    var result = discovery.scan(arena, io, arena) catch discovery.Result{ .incomplete = true };
    const registry = @import("job_registry.zig");
    const records = registry.list(io, arena, registry.home);
    var suspects: std.ArrayList(discovery.Candidate) = .empty;
    for (result.candidates) |candidate| {
        var recorded = false;
        for (records) |record| {
            if (record.pid == candidate.pid and registry.state(io, record) == .running) recorded = true;
        }
        if (!recorded) try suspects.append(arena, candidate);
    }
    result.candidates = suspects.items;
    return findings(arena, result);
}

pub fn warnStartup(arena: A, io: std.Io) void {
    const checks = capture(arena, io) catch return;
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    for (checks) |check| writer.interface.print("warning: {s}: {s}\n", .{ check.title, check.detail }) catch return;
    writer.interface.flush() catch {};
}

test "orphan diagnostics preserve uncertainty without stop authority" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const checks = try findings(arena.allocator(), .{ .incomplete = true, .candidates = &.{.{ .pid = 42, .listener = 43 }} });
    try std.testing.expectEqual(@as(usize, 2), checks.len);
    try std.testing.expectEqualStrings("LISTENER_PROBE_UNAVAILABLE", checks[0].id);
    try std.testing.expectEqualStrings("ORPHANED_LISTENER_CANDIDATE", checks[1].id);
    try std.testing.expect(std.mem.indexOf(u8, checks[1].detail, "not ownership or stop authority") != null);
}

test "empty complete orphan scan makes no finding" {
    const checks = try findings(std.testing.allocator, .{});
    defer std.testing.allocator.free(checks);
    try std.testing.expectEqual(@as(usize, 0), checks.len);
}
