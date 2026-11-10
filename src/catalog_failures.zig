//! Why a provider's live model list did not refresh.
//!
//! A failed catalog fetch falls back to the list cached on disk, which is the
//! right thing offline. It was also silent: a key the provider rejects kept
//! serving a weeks-old list, a model released since was an "unknown model",
//! and `graff refresh` reported nothing wrong. The fetch records the status
//! a provider refused it with and the listing commands say it. A provider
//! that could not be reached is not recorded: offline, or a local server that
//! is not running, is the case the cache is for.

const std = @import("std");
const Io = std.Io;
const provider = @import("provider.zig");

const none_recorded: u16 = 0;

/// One slot per baked provider, plus the workspace's additional router.
var slots: [provider.provider_specs.len + 1]std.atomic.Value(u16) = @splat(.init(none_recorded));

fn slot(id: []const u8) *std.atomic.Value(u16) {
    for (provider.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, id)) return &slots[i];
    }
    return &slots[provider.provider_specs.len];
}

/// A fetch for `id` is starting: forget its previous failure.
pub fn clear(id: []const u8) void {
    slot(id).store(none_recorded, .monotonic);
}

/// Record that `id`'s fetch failed with `status` and return the null the
/// fetch hands back, so a call site is one expression.
pub fn none(comptime T: type, id: []const u8, status: u16) ?T {
    slot(id).store(status, .monotonic);
    return null;
}

fn reason(buf: []u8, status: u16) []const u8 {
    return switch (status) {
        401, 403 => std.fmt.bufPrint(buf, "the key was rejected (HTTP {d}); replace it, then run `graff refresh`", .{status}) catch "the key was rejected",
        429 => "the provider rate-limited the request (HTTP 429)",
        else => std.fmt.bufPrint(buf, "the provider answered HTTP {d}", .{status}) catch "the provider answered an error",
    };
}

/// One line per provider whose last live fetch failed. Prints nothing when
/// every fetch that ran succeeded.
pub fn report(out: *Io.Writer) !void {
    for (provider.provider_specs, 0..) |spec, i| try line(out, spec.id, slots[i].load(.monotonic));
    if (provider.additional_router) |spec| try line(out, spec.id, slots[provider.provider_specs.len].load(.monotonic));
}

fn line(out: *Io.Writer, id: []const u8, status: u16) !void {
    if (status == none_recorded) return;
    var buf: [96]u8 = undefined;
    try out.print("{s}: live model list not refreshed, {s}. Showing the cached list.\n", .{ id, reason(&buf, status) });
}

/// `report` for a command that has already flushed its own output.
pub fn reportStdout(io: Io) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    report(&w.interface) catch {};
    w.interface.flush() catch {};
}

test "a rejected key is named once, and a later fetch clears it" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    defer clear("anthropic");
    defer clear("xai");
    clear("anthropic"); // whatever an earlier test's fetch left behind
    clear("xai");

    try report(&aw.writer);
    try std.testing.expectEqualStrings("", aw.written());

    try std.testing.expect(none(u8, "anthropic", 401) == null);
    try std.testing.expect(none(u8, "xai", 503) == null);
    try report(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "anthropic: live model list not refreshed, the key was rejected (HTTP 401); replace it, then run `graff refresh`. Showing the cached list.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "xai: live model list not refreshed, the provider answered HTTP 503.") != null);

    clear("anthropic");
    clear("xai");
    aw.clearRetainingCapacity();
    try report(&aw.writer);
    try std.testing.expectEqualStrings("", aw.written());
}
