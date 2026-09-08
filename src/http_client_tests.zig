//! Unit tests for recoverable HTTP client generation lifetime and fault hooks.

const std = @import("std");
const http_client = @import("http_client.zig");
const Recovery = http_client.Recovery;
const RecoveryOutcome = http_client.RecoveryOutcome;

test "HTTP client integration coverage" {
    _ = @import("http_client_integration_tests.zig");
    _ = @import("http_client_trajectory_tests.zig");
}

fn recoverTask(recovery: *Recovery, client: *std.http.Client) RecoveryOutcome {
    return recovery.recoverConstructionTls(client);
}

fn shutdownTask(recovery: *Recovery) void {
    recovery.shutdown();
}

test "runtime teardown leaves the global transport closed to late acquisitions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    runtime.deinit(io);

    var late = http_client.acquire(&runtime.client);
    defer late.release();
    try std.testing.expect(!late.available);

    var unrelated: std.http.Client = .{ .allocator = gpa, .io = io };
    defer unrelated.deinit();
    var unmanaged = http_client.acquire(&unrelated);
    defer unmanaged.release();
    try std.testing.expect(unmanaged.available);
}

fn runtimeDeinitTask(runtime: *http_client.Runtime, io: std.Io) void {
    runtime.deinit(io);
}

test "runtime teardown closes admission before draining an active lease" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var runtime: http_client.Runtime = undefined;
    runtime.init(gpa, io);
    http_client.waitForReady(io);
    var lease = http_client.acquire(&runtime.client);
    try std.testing.expect(lease.available);

    var teardown = io.async(runtimeDeinitTask, .{ &runtime, io });
    for (0..100) |_| {
        if (runtime.recovery.stats().shutting_down) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(runtime.recovery.stats().shutting_down);
    var denied = http_client.acquire(&runtime.client);
    defer denied.release();
    try std.testing.expect(!denied.available);

    lease.release();
    _ = teardown.await(io);
}

fn waitReadyTask(io: std.Io) void {
    http_client.waitForReady(io);
}

fn uninstallTask() void {
    http_client.uninstallForTest();
}

test "lifecycle teardown drains callers already waiting for CA readiness" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();
    var ready: std.Io.Event = .unset;
    var wait_entered: std.Io.Event = .unset;
    http_client.installForTest(&recovery, &ready, &wait_entered);

    var waiter = io.async(waitReadyTask, .{io});
    wait_entered.waitUncancelable(io);
    var teardown = io.async(uninstallTask, .{});
    ready.set(io);
    _ = waiter.await(io);
    _ = teardown.await(io);
}

test "retired generation stays alive until its final concurrent lease releases" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();

    var first = recovery.acquire(&original);
    var second = recovery.acquire(&original);
    try std.testing.expectEqual(RecoveryOutcome.rotated, recovery.recoverConstructionTls(first.client));
    try std.testing.expectEqual(@as(usize, 1), recovery.stats().retired);
    first.release();
    try std.testing.expectEqual(@as(usize, 1), recovery.stats().retired);
    second.release();
    try std.testing.expectEqual(@as(usize, 0), recovery.stats().retired);
}

test "replacement allocation failures keep the current generation usable" {
    const backing = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = backing, .io = io };
    defer original.deinit();

    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var recovery: Recovery = undefined;
        recovery.init(failing.allocator(), io, &original, false);
        defer recovery.deinit();
        var lease = recovery.acquire(&original);
        defer lease.release();
        try std.testing.expectEqual(RecoveryOutcome.unavailable, recovery.recoverConstructionTls(lease.client));
        try std.testing.expectEqual(@as(u64, 0), recovery.stats().active_id);
    }
}

test "unmanaged client TLS failure does not rotate the launch generation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var unrelated: std.http.Client = .{ .allocator = gpa, .io = io };
    defer unrelated.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();

    try std.testing.expectEqual(RecoveryOutcome.unavailable, recovery.recoverConstructionTls(&unrelated));
    try std.testing.expectEqual(@as(u64, 0), recovery.stats().active_id);
}

test "replacement CA warm failure is attributed to the triggering rotation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, true);
    defer recovery.deinit();

    var failed = recovery.acquire(&original);
    defer failed.release();
    http_client.injectReplacementCaWarmFailureForTest();
    try std.testing.expectEqual(RecoveryOutcome.rotated_ca_warm_failed, recovery.recoverConstructionTls(failed.client));
}

test "request-construction TLS recovery reaches later root and child trajectories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();

    var failed_root = recovery.acquire(&original);
    try std.testing.expectEqual(@as(u64, 0), failed_root.generation_id);
    try std.testing.expectEqual(RecoveryOutcome.rotated, recovery.recoverConstructionTls(failed_root.client));

    var later_root = recovery.acquire(&original);
    defer later_root.release();
    var child = recovery.acquire(&original);
    defer child.release();
    try std.testing.expectEqual(@as(u64, 1), later_root.generation_id);
    try std.testing.expectEqual(later_root.generation_id, child.generation_id);
    try std.testing.expect(later_root.client == child.client);
    try std.testing.expect(later_root.client != failed_root.client);
    failed_root.release();
}

test "concurrent stale TLS reports rotate a generation only once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();

    var first = recovery.acquire(&original);
    var concurrent = recovery.acquire(&original);
    var first_fut = io.async(recoverTask, .{ &recovery, first.client });
    var second_fut = io.async(recoverTask, .{ &recovery, concurrent.client });
    const first_result = first_fut.await(io);
    const second_result = second_fut.await(io);
    try std.testing.expect(first_result != .unavailable);
    try std.testing.expect(second_result != .unavailable);
    try std.testing.expect(first_result != second_result);
    var after = recovery.acquire(&original);
    defer after.release();
    try std.testing.expectEqual(@as(u64, 1), after.generation_id);
    first.release();
    concurrent.release();
}

test "shutdown rejects new managed acquisitions and drains an in-flight replacement" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();

    var initial = recovery.acquire(&original);
    try std.testing.expectEqual(RecoveryOutcome.rotated, recovery.recoverConstructionTls(initial.client));
    initial.release();
    var in_flight = recovery.acquire(&original);
    try std.testing.expectEqual(@as(u64, 1), in_flight.generation_id);

    var shutdown = io.async(shutdownTask, .{&recovery});
    for (0..100) |_| {
        if (recovery.stats().shutting_down) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(recovery.stats().shutting_down);
    const denied = recovery.acquire(&original);
    try std.testing.expect(!denied.available);
    try std.testing.expectEqual(@as(usize, 1), recovery.stats().total_refs);

    in_flight.release();
    _ = shutdown.await(io);
    try std.testing.expectEqual(@as(usize, 0), recovery.stats().total_refs);
}

test "owned retired client remains alive until both stale leases release" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();

    var initial = recovery.acquire(&original);
    try std.testing.expectEqual(RecoveryOutcome.rotated, recovery.recoverConstructionTls(initial.client));
    initial.release();
    var first = recovery.acquire(&original);
    var second = recovery.acquire(&original);
    try std.testing.expectEqual(RecoveryOutcome.rotated, recovery.recoverConstructionTls(first.client));
    try std.testing.expectEqual(@as(usize, 1), recovery.stats().retired);
    first.release();
    try std.testing.expectEqual(@as(usize, 1), recovery.stats().retired);
    second.release();
    try std.testing.expectEqual(@as(usize, 0), recovery.stats().retired);
}

test "generation zero injection never intercepts an unmanaged client" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var unrelated: std.http.Client = .{ .allocator = gpa, .io = io };
    defer unrelated.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, false);
    defer recovery.deinit();
    http_client.installForTest(&recovery, null, null);
    defer http_client.uninstallForTest();

    http_client.injectConstructionTlsForTest(0);
    var unmanaged = recovery.acquire(&unrelated);
    defer unmanaged.release();
    try std.testing.expect(http_client.injectedConstructionTls(&unmanaged) == null);
    var managed = recovery.acquire(&original);
    defer managed.release();
    try std.testing.expectEqual(error.TlsRequestConstructionFailed, http_client.injectedConstructionTls(&managed).?);
}

test "post-prewarm generation allocation failure cleans up and preserves active client" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var original: std.http.Client = .{ .allocator = gpa, .io = io };
    defer original.deinit();
    var recovery: Recovery = undefined;
    recovery.init(gpa, io, &original, true);
    defer recovery.deinit();

    var lease = recovery.acquire(&original);
    defer lease.release();
    http_client.injectGenerationAllocationFailureForTest();
    try std.testing.expectEqual(RecoveryOutcome.unavailable, recovery.recoverConstructionTls(lease.client));
    try std.testing.expectEqual(@as(u64, 0), recovery.stats().active_id);
    try std.testing.expect(lease.client == &original);
}
