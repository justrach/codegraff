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

pub const Stats = struct {
    active_id: u64,
    active_refs: usize,
    retired: usize,
    total_refs: usize,
    shutting_down: bool,
};

pub const Recovery = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    idle: Io.Condition = .init,
    original: Generation,
    active: *Generation,
    retired: ?*Generation = null,
    next_id: u64 = 1,
    total_refs: usize = 0,
    shutting_down: bool = false,
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

    pub fn beginShutdown(self: *Recovery) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.shutting_down = true;
    }

    pub fn shutdown(self: *Recovery) void {
        self.beginShutdown();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.total_refs != 0) self.idle.waitUncancelable(self.io, &self.mutex);
    }

    pub fn deinit(self: *Recovery) void {
        self.shutdown();
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
        if (self.shutting_down) return .{ .client = requested, .available = false };
        self.active.refs += 1;
        self.total_refs += 1;
        return .{ .client = self.active.client, .owner = self, .generation = self.active, .generation_id = self.active.id };
    }

    pub fn stats(self: *Recovery) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var retired: usize = 0;
        var cursor = self.retired;
        while (cursor) |generation| : (cursor = generation.next) retired += 1;
        return .{
            .active_id = self.active.id,
            .active_refs = self.active.refs,
            .retired = retired,
            .total_refs = self.total_refs,
            .shutting_down = self.shutting_down,
        };
    }

    /// Retire the generation that failed while constructing a request. If a
    /// concurrent caller already rotated it, this is a successful no-op: the
    /// next retry will acquire that newer generation.
    pub fn recoverConstructionTls(self: *Recovery, failed: *std.http.Client) RecoveryOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutting_down) return .unavailable;
        if (failed != self.active.client)
            return if (failed == self.original.client or self.isRetired(failed)) .already_rotated else .unavailable;

        const client = self.gpa.create(std.http.Client) catch return .unavailable;
        client.* = .{ .allocator = self.gpa, .io = self.io };
        var ca_warm_failed = false;
        if (self.warm_replacements) {
            if (builtin.is_test and g_test_fail_ca_warm.swap(false, .acq_rel)) {
                ca_warm_failed = true;
            } else warm.prewarmCaBundle(client, self.gpa, self.io) catch {
                ca_warm_failed = true;
            };
        }
        if (builtin.is_test and g_test_fail_generation_alloc.swap(false, .acq_rel)) {
            client.deinit();
            self.gpa.destroy(client);
            return .unavailable;
        }
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
        self.total_refs -= 1;
        if (generation.retired and generation.refs == 0) self.reclaim(generation);
        if (self.shutting_down and self.total_refs == 0) self.idle.broadcast(self.io);
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
    available: bool = true,

    pub fn release(self: *Lease) void {
        if (self.owner) |owner| owner.release(self.generation.?);
        self.* = .{ .client = self.client };
    }
};

var g_lifecycle_mutex: Io.Mutex = .init;
var g_lifecycle_idle: Io.Condition = .init;
var g_ready_waiters: usize = 0;
var g_closing: bool = false;
var g_recovery: ?*Recovery = null;
var g_client_ready: ?*Io.Event = null;
var g_closed_client: ?*std.http.Client = null;
var g_test_wait_entered: ?*Io.Event = null;
var g_ca_warm_failed: std.atomic.Value(bool) = .init(false);
const no_test_failure = std.math.maxInt(u64);
var g_test_fail_generation: std.atomic.Value(u64) = .init(no_test_failure);
var g_test_fail_through_generation: std.atomic.Value(u64) = .init(no_test_failure);
var g_test_fail_ca_warm: std.atomic.Value(bool) = .init(false);
var g_test_fail_generation_alloc: std.atomic.Value(bool) = .init(false);
var g_test_tls_arrivals: ?*std.atomic.Value(usize) = null;
var g_test_tls_all_arrived: ?*Io.Event = null;
var g_test_tls_release: ?*Io.Event = null;

pub fn acquire(requested: *std.http.Client) Lease {
    g_lifecycle_mutex.lockUncancelable(requested.io);
    defer g_lifecycle_mutex.unlock(requested.io);
    if (g_recovery) |recovery| return recovery.acquire(requested);
    if (g_closed_client == requested) return .{ .client = requested, .available = false };
    return .{ .client = requested };
}

/// True when a `transport.request()` construction error must traverse the
/// TLS recovery path: the handshake failed outright — or (Windows) died
/// mid-read, where NTSTATUS LOCAL_DISCONNECT surfaces as error.Unexpected
/// out of the handshake read instead of TlsInitializationFailed. Gated to
/// https so a plain-HTTP connect error is never mislabeled a TLS failure.
pub fn constructionTlsFailure(err: anyerror, url: []const u8) bool {
    return err == error.TlsInitializationFailed or
        (err == error.Unexpected and std.mem.startsWith(u8, url, "https://"));
}

pub fn constructionTlsError(failed: *std.http.Client) anyerror {
    g_lifecycle_mutex.lockUncancelable(failed.io);
    defer g_lifecycle_mutex.unlock(failed.io);
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

pub fn injectConstructionTlsThroughGenerationForTest(last_generation: u64) void {
    if (builtin.is_test) g_test_fail_through_generation.store(last_generation, .release);
}

pub fn injectReplacementCaWarmFailureForTest() void {
    if (builtin.is_test) g_test_fail_ca_warm.store(true, .release);
}

pub fn injectGenerationAllocationFailureForTest() void {
    if (builtin.is_test) g_test_fail_generation_alloc.store(true, .release);
}

pub fn injectLaunchCaWarmFailureForTest() void {
    if (builtin.is_test) g_ca_warm_failed.store(true, .release);
}

pub fn installConstructionTlsBarrierForTest(arrivals: *std.atomic.Value(usize), all_arrived: *Io.Event, release: *Io.Event) void {
    if (!builtin.is_test) return;
    g_test_tls_arrivals = arrivals;
    g_test_tls_all_arrived = all_arrived;
    g_test_tls_release = release;
}

inline fn resetTestHooks() void {
    if (comptime !builtin.is_test) return;
    g_test_wait_entered = null;
    g_test_fail_generation.store(no_test_failure, .release);
    g_test_fail_through_generation.store(no_test_failure, .release);
    g_test_fail_ca_warm.store(false, .release);
    g_test_fail_generation_alloc.store(false, .release);
    g_test_tls_arrivals = null;
    g_test_tls_all_arrived = null;
    g_test_tls_release = null;
}

pub fn installForTest(recovery: *Recovery, ready: ?*Io.Event, wait_entered: ?*Io.Event) void {
    if (!builtin.is_test) return;
    g_lifecycle_mutex.lockUncancelable(recovery.io);
    defer g_lifecycle_mutex.unlock(recovery.io);
    g_closing = false;
    g_closed_client = null;
    g_recovery = recovery;
    g_client_ready = ready;
    resetTestHooks();
    g_test_wait_entered = wait_entered;
    g_ca_warm_failed.store(false, .release);
}

pub fn uninstallForTest() void {
    if (!builtin.is_test) return;
    const recovery = g_recovery orelse return;
    g_lifecycle_mutex.lockUncancelable(recovery.io);
    defer g_lifecycle_mutex.unlock(recovery.io);
    g_closing = true;
    while (g_ready_waiters != 0) g_lifecycle_idle.waitUncancelable(recovery.io, &g_lifecycle_mutex);
    g_recovery = null;
    g_client_ready = null;
    g_closed_client = null;
    g_closing = false;
    resetTestHooks();
}

pub inline fn injectedConstructionTls(lease: *const Lease) ?anyerror {
    if (comptime !builtin.is_test) return null;
    if (lease.owner == null) return null;
    const through = g_test_fail_through_generation.load(.acquire);
    const should_fail = through != no_test_failure and lease.generation_id <= through or
        g_test_fail_generation.cmpxchgStrong(lease.generation_id, no_test_failure, .acq_rel, .acquire) == null;
    if (!should_fail) return null;
    if (g_test_tls_arrivals) |arrivals| {
        if (arrivals.fetchAdd(1, .acq_rel) + 1 == 2) g_test_tls_all_arrived.?.set(lease.owner.?.io);
        g_test_tls_release.?.waitUncancelable(lease.owner.?.io);
    }
    return constructionTlsError(lease.client);
}

pub fn waitForReady(io: Io) void {
    g_lifecycle_mutex.lockUncancelable(io);
    if (g_closing or g_client_ready == null) {
        g_lifecycle_mutex.unlock(io);
        return;
    }
    const ready = g_client_ready.?;
    g_ready_waiters += 1;
    g_lifecycle_mutex.unlock(io);

    if (comptime builtin.is_test) if (g_test_wait_entered) |entered| entered.set(io);
    ready.waitUncancelable(io);

    g_lifecycle_mutex.lockUncancelable(io);
    g_ready_waiters -= 1;
    if (g_closing and g_ready_waiters == 0) g_lifecycle_idle.broadcast(io);
    g_lifecycle_mutex.unlock(io);
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

        g_lifecycle_mutex.lockUncancelable(io);
        g_closing = false;
        g_closed_client = null;
        g_recovery = &self.recovery;
        g_client_ready = &self.ready;
        resetTestHooks();
        g_ca_warm_failed.store(false, .release);
        g_lifecycle_mutex.unlock(io);
        self.warm_future = io.async(warm.prewarmCaBundleTask, .{ &self.client, gpa, io, &self.ready, &g_ca_warm_failed });
    }

    pub fn deinit(self: *Runtime, await_io: Io) void {
        g_lifecycle_mutex.lockUncancelable(self.io);
        g_closing = true;
        self.recovery.beginShutdown();
        while (g_ready_waiters != 0) g_lifecycle_idle.waitUncancelable(self.io, &g_lifecycle_mutex);
        g_lifecycle_mutex.unlock(self.io);

        self.recovery.shutdown();
        _ = self.warm_future.await(await_io);

        g_lifecycle_mutex.lockUncancelable(self.io);
        g_client_ready = null;
        g_recovery = null;
        g_closed_client = &self.client;
        resetTestHooks();
        self.recovery.deinit();
        self.client.deinit();
        g_lifecycle_mutex.unlock(self.io);
    }
};
