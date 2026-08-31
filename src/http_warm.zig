//! Shared HTTP client CA-bundle warming.

const std = @import("std");
const Io = std.Io;

/// Pre-load the shared HTTP client's CA bundle single-threaded so concurrent
/// agents never race Zig's lazy first-connect rescan.
pub fn prewarmCaBundle(client: *std.http.Client, gpa: std.mem.Allocator, io: Io) !void {
    const now = Io.Clock.real.now(io);
    try client.ca_bundle.rescan(gpa, io, now);
    client.now = now;
}

/// Warm off the launch critical path. Outbound users wait on
/// `http.g_client_ready`, so prompt painting can overlap the scan safely.
pub fn prewarmCaBundleTask(client: *std.http.Client, gpa: std.mem.Allocator, io: Io, ready: *Io.Event, failed: *std.atomic.Value(bool)) void {
    defer ready.set(io);
    prewarmCaBundle(client, gpa, io) catch failed.store(true, .release);
}
