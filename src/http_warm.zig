//! Shared CA-bundle warming for HTTP and WSS.

const std = @import("std");
const Io = std.Io;

/// Process-lifetime bundle. Always `page_allocator` so a test GPA cannot
/// free it while a later WSS dial still holds the pointer.
var process_ca: std.crypto.Certificate.Bundle = .empty;
var process_ca_rw: Io.RwLock = .init;
var process_ca_init: Io.Mutex = .init;
var process_ca_ready = std.atomic.Value(bool).init(false);

/// Test seam: how many times the process bundle actually hit the disk.
pub var process_ca_rescans: u32 = 0;

pub fn processCa() *std.crypto.Certificate.Bundle {
    return &process_ca;
}

pub fn processCaLock() *Io.RwLock {
    return &process_ca_rw;
}

/// Scan the host CA store once. Later WSS reconnects reuse the same bytes.
pub fn ensureProcessCa(io: Io) !void {
    if (process_ca_ready.load(.acquire)) return;
    process_ca_init.lockUncancelable(io);
    defer process_ca_init.unlock(io);
    if (process_ca_ready.load(.acquire)) return;
    const now = Io.Clock.real.now(io);
    process_ca.rescan(std.heap.page_allocator, io, now) catch return error.HandshakeFailed;
    process_ca_rescans += 1;
    process_ca_ready.store(true, .release);
}

/// Pre-load the shared HTTP client's CA bundle single-threaded so concurrent
/// agents never race Zig's lazy first-connect rescan. Also warms the process
/// bundle so the first WSS dial does not pay a second disk walk.
pub fn prewarmCaBundle(client: *std.http.Client, gpa: std.mem.Allocator, io: Io) !void {
    const now = Io.Clock.real.now(io);
    try client.ca_bundle.rescan(gpa, io, now);
    client.now = now;
    ensureProcessCa(io) catch return;
}

/// Warm off the launch critical path. Outbound users wait on
/// `http.g_client_ready`, so prompt painting can overlap the scan safely.
pub fn prewarmCaBundleTask(client: *std.http.Client, gpa: std.mem.Allocator, io: Io, ready: *Io.Event, failed: *std.atomic.Value(bool)) void {
    defer ready.set(io);
    prewarmCaBundle(client, gpa, io) catch failed.store(true, .release);
}
