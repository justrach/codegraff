//! Which cold-boot catalog fetches landed after boot moved on.
//!
//! Boot never waits on a live catalog GET (ADR 0340): a provider with no disk
//! cache starts on its baked rows and its fetch runs on a detached
//! `catalog_bounded` worker. The worker cannot activate what it fetched — the
//! model table and the session arena belong to the main thread — so it only
//! reports here, and the main thread activates the cache the worker wrote at
//! its next model-surface beat (`router_catalog_boot.activateLanded`).
//!
//! The state is static atomics, nothing the exit path frees, so a worker that
//! finishes while the process is tearing down writes into nothing that is
//! gone. A slot boot did not mark stays idle whatever its worker reports: a
//! stale cache's refresh behind still lands for the next process only.

const std = @import("std");
const provider = @import("provider.zig");
const Job = @import("catalog_bounded.zig").Job;

const idle: u8 = 0;
const pending: u8 = 1;
const landed: u8 = 2;

/// One slot per baked provider, the workspace's additional router, and Kimi.
pub const additional_slot = provider.provider_specs.len;
pub const kimi_slot = provider.provider_specs.len + 1;
var slots: [provider.provider_specs.len + 2]std.atomic.Value(u8) = @splat(.init(idle));

pub fn slotOf(job: Job) usize {
    return switch (job) {
        .kimi => kimi_slot,
        .router => |r| for (provider.provider_specs, 0..) |spec, i| {
            if (std.mem.eql(u8, spec.id, r.spec.id)) break i;
        } else additional_slot,
    };
}

/// Boot is detaching `job` with no cache to show: activate it when it lands.
/// Called before the worker starts, so its report always finds the mark.
pub fn expect(job: Job) void {
    slots[slotOf(job)].store(pending, .release);
}

/// Worker side: the fetch ended, `ok` when it wrote a cache. A failed fetch
/// clears the mark, so nothing re-reads a cache that is not there and nothing
/// starts a second GET: the once-per-process attempt latch already holds.
pub fn settle(job: Job, ok: bool) void {
    _ = slots[slotOf(job)].cmpxchgStrong(pending, if (ok) landed else idle, .acq_rel, .acquire);
}

/// Main thread: claim a landed slot, exactly once.
pub fn take(slot: usize) bool {
    return slots[slot].cmpxchgStrong(landed, idle, .acq_rel, .acquire) == null;
}

/// Whether boot is still waiting on `slot`'s detached fetch.
pub fn waiting(slot: usize) bool {
    return slots[slot].load(.acquire) == pending;
}

/// Tests only: forget every mark.
pub fn reset() void {
    for (&slots) |*s| s.store(idle, .release);
}

test "a landing is taken once, a failure or an unmarked refresh never is" {
    reset();
    defer reset();
    const spec = provider.specFor("zai").?;
    const job: @import("catalog_bounded.zig").Job = .{ .router = .{ .spec = spec, .source = .environment } };
    const slot = slotOf(job);
    // A stale cache's refresh behind: never marked, so its landing is ignored.
    settle(job, true);
    try std.testing.expect(!take(slot));
    // A cold boot's fetch that lands is activated exactly once.
    expect(job);
    try std.testing.expect(waiting(slot));
    settle(job, true);
    try std.testing.expect(!waiting(slot));
    try std.testing.expect(take(slot));
    try std.testing.expect(!take(slot));
    // A failed one clears the mark: nothing to activate, nothing left pending.
    expect(job);
    settle(job, false);
    try std.testing.expect(!waiting(slot));
    try std.testing.expect(!take(slot));
    try std.testing.expectEqual(kimi_slot, slotOf(.kimi));
}
