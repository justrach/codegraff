//! Codegraff ACP extension: cumulative known usage, never an inferred bill.
const std = @import("std");
const pricing = @import("pricing.zig");
const proto = @import("acp_protocol.zig");

/// Supplemental delivery never changes the original turn's result. Caller owns
/// the ACP output lock; do not split serialization and flush across lock scopes.
pub fn writeBestEffort(w: *std.Io.Writer, sid: []const u8, tally: *pricing.CostTally, io: std.Io) void {
    write(w, sid, tally, io) catch return;
    w.flush() catch {};
}

pub fn write(w: *std.Io.Writer, sid: []const u8, tally: *pricing.CostTally, io: std.Io) !void {
    const c = tally.snap(io);
    const complete = c.missing_usage_calls == 0 and c.unreported_failed_attempts == 0;
    const cost_complete = complete and c.sub_calls == 0 and c.unpriced_calls == 0;
    try proto.writeNotification(w, "_codegraff/usage", .{
        .sessionId = sid,
        .usage = .{
            .scope = "connection",
            .usage_complete = complete,
            .cost_complete = cost_complete,
            .cost_usd = if (cost_complete) @as(?f64, c.usd) else null,
            .known_cost_usd = c.usd,
            .input_tokens = c.in_tokens +| c.cache_tokens,
            .cache_read_tokens = c.cache_tokens,
            .cache_write_tokens = c.cache_write_tokens,
            .output_tokens = c.out_tokens,
            .api_calls = c.api_calls,
            .missing_usage_calls = c.missing_usage_calls,
            .unreported_failed_attempts = c.unreported_failed_attempts,
            .subscription_calls = c.sub_calls,
            .unpriced_calls = c.unpriced_calls,
        },
    });
}

test "ACP usage preserves failed-attempt uncertainty and subscription unknown dollars" {
    const io = std.testing.io;
    var tally: pricing.CostTally = .{};
    tally.add(io, .sub, "fixture", 10, 4, 3, 2);
    tally.failedWithoutUsage(io, 1);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, "session-fixture", &tally, io);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("session-fixture", params.get("sessionId").?.string);
    try std.testing.expectEqualStrings("_codegraff/usage", parsed.value.object.get("method").?.string);
    const update = params.get("usage").?.object;
    try std.testing.expect(!update.get("usage_complete").?.bool);
    try std.testing.expect(update.get("cost_usd").? == .null);
    try std.testing.expectEqual(@as(i64, 17), update.get("input_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 1), update.get("unreported_failed_attempts").?.integer);
    try std.testing.expectEqual(@as(i64, 1), update.get("api_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 3), update.get("cache_write_tokens").?.integer);
}

test "ACP supplemental usage tolerates a rejected writer" {
    var storage: [0]u8 = .{};
    var broken = std.Io.Writer.fixed(&storage);
    var tally: pricing.CostTally = .{};
    // Prove this writer actually rejects the real serialized notification.
    try std.testing.expectError(error.WriteFailed, write(&broken, "disconnected", &tally, std.testing.io));
    writeBestEffort(&broken, "disconnected", &tally, std.testing.io);
}
