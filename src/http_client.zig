//! Launch-level HTTP client generations for model traffic.
//!
//! A `TlsInitializationFailed` raised by `Client.request` occurs before a
//! Request exists, so the connection-poison cleanup in http.zig cannot touch
//! it. Model calls lease the active generation through this module. On that
//! construction error, one caller rotates the generation; in-flight callers
//! keep their old lease, and owned retired clients are reclaimed only after
//! their final lease is released.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const warm = @import("http_warm.zig");

const Generation = struct {
    client: *std.http.Client,
    id: u64,
    refs: usize = 0,
    retired: bool = false,
    owned: bool,
    next: ?*Generation = null,
};

pub const RecoveryOutcome = enum {
    unavailable,
    rotated,
    rotated_ca_warm_failed,
    already_rotated,
};

pub const Recovery = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    original: Generation,
    active: *Generation,
    retired: ?*Generation = null,
    next_id: u64 = 1,
    warm_replacements: bool,

    pub fn init(self: *Recovery, gpa: Allocator, io: Io, original: *std.http.Client, warm_replacements: bool) void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .original = .{ .client = original, .id = 0, .owned = false },
            .active = undefined,
            .warm_replacements = warm_replacements,
        };
        self.active = &self.original;
    }

    pub fn deinit(self: *Recovery) void {
        std.debug.assert(self.active.refs == 0);
        if (self.active.owned) self.destroyOwned(self.active);
        var cursor = self.retired;
        while (cursor) |generation| {
            const next = generation.next;
            std.debug.assert(generation.refs == 0);
            if (generation.owned) self.destroyOwned(generation);
            cursor = next;
        }
        self.retired = null;
    }

    pub fn acquire(self: *Recovery, requested: *std.http.Client) Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (requested != self.original.client and requested != self.active.client)
            return .{ .client = requested };
        self.active.refs += 1;
        return .{ .client = self.active.client, .owner = self, .generation = self.active, .generation_id = self.active.id };
    }

    /// Retire the generation that failed while constructing a request. If a
    /// concurrent caller already rotated it, this is a successful no-op: the
    /// next retry will acquire that newer generation.
    pub fn recoverConstructionTls(self: *Recovery, failed: *std.http.Client) RecoveryOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (failed != self.active.client)
            return if (failed == self.original.client or self.isRetired(failed)) .already_rotated else .unavailable;

        const client = self.gpa.create(std.http.Client) catch return .unavailable;
        client.* = .{ .allocator = self.gpa, .io = self.io };
        var ca_warm_failed = false;
        if (self.warm_replacements) warm.prewarmCaBundle(client, self.gpa, self.io) catch {
            ca_warm_failed = true;
        };
        const generation = self.gpa.create(Generation) catch {
            client.deinit();
            self.gpa.destroy(client);
            return .unavailable;
        };
        generation.* = .{ .client = client, .id = self.next_id, .owned = true };
        self.next_id += 1;

        const old = self.active;
        old.retired = true;
        old.next = self.retired;
        self.retired = old;
        self.active = generation;
        if (old.refs == 0) self.reclaim(old);
        return if (ca_warm_failed) .rotated_ca_warm_failed else .rotated;
    }

    fn release(self: *Recovery, generation: *Generation) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(generation.refs > 0);
        generation.refs -= 1;
        if (generation.retired and generation.refs == 0) self.reclaim(generation);
    }

    fn isRetired(self: *Recovery, client: *std.http.Client) bool {
        var cursor = self.retired;
        while (cursor) |generation| : (cursor = generation.next) {
            if (generation.client == client) return true;
        }
        return false;
    }

    fn reclaim(self: *Recovery, target: *Generation) void {
        var link = &self.retired;
        while (link.*) |generation| {
            if (generation == target) {
                link.* = generation.next;
                generation.next = null;
                generation.retired = false;
                if (generation.owned) self.destroyOwned(generation);
                return;
            }
            link = &generation.next;
        }
    }

    fn destroyOwned(self: *Recovery, generation: *Generation) void {
        generation.client.deinit();
        self.gpa.destroy(generation.client);
        self.gpa.destroy(generation);
    }
};

pub const Lease = struct {
    client: *std.http.Client,
    owner: ?*Recovery = null,
    generation: ?*Generation = null,
    generation_id: u64 = 0,

    pub fn release(self: *Lease) void {
        if (self.owner) |owner| owner.release(self.generation.?);
        self.* = .{ .client = self.client };
    }
};

var g_recovery: ?*Recovery = null;
var g_client_ready: ?*Io.Event = null;
var g_ca_warm_failed: std.atomic.Value(bool) = .init(false);
const no_test_failure = std.math.maxInt(u64);
var g_test_fail_generation: std.atomic.Value(u64) = .init(no_test_failure);

pub fn acquire(requested: *std.http.Client) Lease {
    if (g_recovery) |recovery| return recovery.acquire(requested);
    return .{ .client = requested };
}

pub fn constructionTlsError(failed: *std.http.Client) anyerror {
    const outcome = if (g_recovery) |recovery| recovery.recoverConstructionTls(failed) else .unavailable;
    return switch (outcome) {
        .unavailable => error.TlsInitializationFailed,
        .rotated_ca_warm_failed => error.TlsRequestConstructionCaWarmFailed,
        .rotated, .already_rotated => error.TlsRequestConstructionFailed,
    };
}

pub fn injectConstructionTlsForTest(generation: u64) void {
    if (builtin.is_test) g_test_fail_generation.store(generation, .release);
}

pub fn injectedConstructionTls(lease: *const Lease) ?anyerror {
    if (!builtin.is_test) return null;
    if (g_test_fail_generation.cmpxchgStrong(lease.generation_id, no_test_failure, .acq_rel, .acquire) == null)
        return constructionTlsError(lease.client);
    return null;
}

pub fn waitForReady(io: Io) void {
    if (g_client_ready) |ready| ready.waitUncancelable(io);
}

pub fn takeCaWarmFailure() bool {
    return g_ca_warm_failed.swap(false, .acq_rel);
}

pub const Runtime = struct {
    gpa: Allocator,
    io: Io,
    client: std.http.Client,
    ready: Io.Event,
    warm_future: Io.Future(void),
    recovery: Recovery,

    pub fn init(self: *Runtime, gpa: Allocator, io: Io) void {
        self.gpa = gpa;
        self.io = io;
        self.client = .{ .allocator = gpa, .io = io };
        self.ready = .unset;
        self.recovery.init(gpa, io, &self.client, true);
        g_recovery = &self.recovery;
        g_client_ready = &self.ready;
        g_ca_warm_failed.store(false, .release);
        self.warm_future = io.async(warm.prewarmCaBundleTask, .{ &self.client, gpa, io, &self.ready, &g_ca_warm_failed });
    }

    pub fn deinit(self: *Runtime, await_io: Io) void {
        _ = self.warm_future.await(await_io);
        g_client_ready = null;
        g_recovery = null;
        self.recovery.deinit();
        self.client.deinit();
    }
};

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

fn recoverTask(recovery: *Recovery, client: *std.http.Client) RecoveryOutcome {
    return recovery.recoverConstructionTls(client);
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
