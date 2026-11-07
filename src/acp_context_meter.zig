//! The standard ACP context meter: `usage_update` (stable in ACP v1) with the
//! tokens in context, the model's window, and the session's cost when it is
//! fully known. It replaces the graff-only `gui_context_meter`, which no ACP
//! client but the old in-repo desktop understood (#1290), so Harness and other
//! clients showed no context remaining at all.
//!
//! Sent at the end of every prompt turn and, during a turn, after tool steps
//! whenever the count moved, so a client sees context fill up and drop again
//! after compaction.

const std = @import("std");
const Io = std.Io;
const proto = @import("acp_protocol.zig");
const pricing = @import("pricing.zig");

/// Cumulative session cost in USD, or null when any call was unpriced,
/// subscription-billed, or missing usage: the meter never shows a guess.
pub fn knownCostUsd(io: Io) ?f64 {
    const c = pricing.g_cost.snap(io);
    const complete = c.missing_usage_calls == 0 and c.unreported_failed_attempts == 0 and c.sub_calls == 0 and c.unpriced_calls == 0;
    return if (complete and c.api_calls > 0) c.usd else null;
}

/// `savings` rides as `_meta["codegraff/savings"]` once any count is nonzero
/// (context_savings.zig); clients that don't know it ignore `_meta`.
pub fn write(w: *Io.Writer, sid: []const u8, used: u64, size: u64, cost_usd: ?f64, savings: Savings) !void {
    const v2 = @import("acp_v2.zig");
    if (v2.on()) return v2.writeUsage(w, sid, used, size);
    const meta = .{ .@"codegraff/savings" = savings };
    if (cost_usd) |usd| {
        const cost = .{ .amount = usd, .currency = "USD" };
        if (savings.any()) return proto.writeNotification(w, "session/update", .{
            .sessionId = sid,
            .update = .{ .sessionUpdate = "usage_update", .used = used, .size = size, .cost = cost, ._meta = meta },
        });
        return proto.writeNotification(w, "session/update", .{
            .sessionId = sid,
            .update = .{ .sessionUpdate = "usage_update", .used = used, .size = size, .cost = cost },
        });
    }
    if (savings.any()) return proto.writeNotification(w, "session/update", .{
        .sessionId = sid,
        .update = .{ .sessionUpdate = "usage_update", .used = used, .size = size, ._meta = meta },
    });
    try proto.writeNotification(w, "session/update", .{
        .sessionId = sid,
        .update = .{ .sessionUpdate = "usage_update", .used = used, .size = size },
    });
}

pub const Savings = @import("context_savings.zig").Snapshot;

/// A per-turn step hook for acp_stream.EventSink: emits only when the count
/// changed since the last meter this session sent.
pub const Step = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, w: *Io.Writer) void,
};

test "usage_update carries used and size, and cost only when known" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&w, "s1", 53000, 200000, null, .{});
    const plain = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"sessionUpdate\":\"usage_update\",\"used\":53000,\"size\":200000}") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "cost") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "gui_context_meter") == null);
    w = .fixed(&buf);
    try write(&w, "s1", 1, 2, 0.045, .{});
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"cost\":{\"amount\":0.045,\"currency\":\"USD\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "_meta") == null);
}

test "usage_update carries graff's savings once there are any" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&w, "s1", 10, 100, null, .{ .handleBytes = 96000, .compactedTokens = 78000, .cacheReadTokens = 4000 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"_meta\":{\"codegraff/savings\":{\"handleBytes\":96000,\"compactedTokens\":78000,\"cacheReadTokens\":4000}}") != null);
    w = .fixed(&buf);
    try write(&w, "s1", 10, 100, 0.5, .{ .cacheReadTokens = 1 });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"cost\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"cacheReadTokens\":1") != null);
}
