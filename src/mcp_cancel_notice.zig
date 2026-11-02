//! `notifications/cancelled` for a legacy Streamable HTTP session: graff's
//! word to the server that it stopped waiting on a request.
//!
//! The hung request still holds its connection, so the notice needs a new
//! one. On a busy machine every local port can be in TIME_WAIT for a moment
//! and the connect fails with `AddressUnavailable`; the notice used to be
//! dropped then, silently, and the server kept working on a request nobody
//! wanted. Ports free up within moments, so that one error is retried for a
//! bounded time. Any other failure still gives up at once: it is best effort.

const std = @import("std");
const mcp_http = @import("mcp_http.zig");
const mcp_notify = @import("mcp_notify.zig");

/// Tries after the first, 100 ms apart: two seconds at most.
const retries = 20;

/// Tell a legacy session to stop request `id`. Bounded, and the turn's
/// cancel flag (still set) must not abort this send.
pub fn notify(http: *mcp_http.HttpTransport, protocol_version: []const u8, id: i64) void {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const line = mcp_notify.cancelledLine(fba.allocator(), id) catch return;
    const Send = struct {
        http: *mcp_http.HttpTransport,
        line: []const u8,
        protocol_version: []const u8,

        fn send(s: @This()) anyerror!void {
            const reply = try mcp_http.postWith(s.http, s.line, .{ .protocol_version = s.protocol_version, .method = "notifications/cancelled", .modern = false }, null, .{ .watch_cancel = false, .timeout_s = 3 });
            if (reply) |bytes| s.http.client.allocator.free(bytes);
        }

        fn pause(s: @This()) bool {
            s.http.client.io.sleep(.fromMilliseconds(100), .awake) catch return false;
            return true;
        }
    };
    _ = retrying(Send, .{ .http = http, .line = line, .protocol_version = protocol_version }, Send.send, Send.pause);
}

/// Calls `send` until it succeeds, fails with anything but
/// `AddressUnavailable`, `pause` says stop, or the tries run out. Returns
/// how many times it sent.
fn retrying(comptime Ctx: type, ctx: Ctx, comptime send: fn (Ctx) anyerror!void, comptime pause: fn (Ctx) bool) usize {
    var sent: usize = 0;
    while (true) {
        sent += 1;
        send(ctx) catch |err| {
            if (err != error.AddressUnavailable or sent > retries or !pause(ctx)) return sent;
            continue;
        };
        return sent;
    }
}

const Fake = struct {
    fail: []const anyerror,
    sent: *usize,

    fn send(f: Fake) anyerror!void {
        defer f.sent.* += 1;
        if (f.sent.* < f.fail.len) return f.fail[f.sent.*];
    }

    fn pause(_: Fake) bool {
        return true;
    }
};

test "cancel notice: out of ports is retried until it goes; other errors and the bound stop it" {
    var n: usize = 0;
    // Two connects out of ports, then the notice goes.
    try std.testing.expectEqual(@as(usize, 3), retrying(Fake, .{ .fail = &.{ error.AddressUnavailable, error.AddressUnavailable }, .sent = &n }, Fake.send, Fake.pause));
    // A refused or timed-out server is not waited for.
    n = 0;
    try std.testing.expectEqual(@as(usize, 1), retrying(Fake, .{ .fail = &.{error.ConnectionRefused}, .sent = &n }, Fake.send, Fake.pause));
    // Never a free port: bounded.
    n = 0;
    const always: [retries + 5]anyerror = @splat(error.AddressUnavailable);
    try std.testing.expectEqual(@as(usize, retries + 1), retrying(Fake, .{ .fail = &always, .sent = &n }, Fake.send, Fake.pause));
}
