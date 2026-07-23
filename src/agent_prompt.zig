//! Compact prompt badges and context-meter formatting.

const std = @import("std");
const Io = std.Io;
const style = &@import("ansi.zig").style;

pub fn reasoningLabel(effort: anytype) []const u8 {
    return switch (effort) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "Extra high",
        .max => "Max",
        .ultra => "Ultra",
    };
}

pub fn reasoningColor(effort: anytype) []const u8 {
    return switch (effort) {
        .low => style.green,
        .medium => style.accent,
        .high => style.yellow,
        .xhigh => style.accent,
        .max => style.red,
        .ultra => style.accent,
    };
}

pub fn writeBadge(writer: *Io.Writer, color: []const u8, label: []const u8) !void {
    try writer.print("{s} · {s}{s}{s}{s}", .{ style.dim, style.reset, color, label, style.reset });
}

pub fn compactTokenCount(buf: []u8, tokens: u64) []const u8 {
    return if (tokens >= 1000)
        std.fmt.bufPrint(buf, "{d}k", .{tokens / 1000}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "?";
}

pub fn contextPercent(tokens: u64, window: u64) u64 {
    if (window == 0) return 0;
    return @min((tokens *| 100) / window, 100);
}

test "reasoning prompt label uses picker wording" {
    const Effort = enum { low, medium, high, xhigh, max, ultra };
    try std.testing.expectEqualStrings("Low", reasoningLabel(Effort.low));
    try std.testing.expectEqualStrings("Medium", reasoningLabel(Effort.medium));
    try std.testing.expectEqualStrings("High", reasoningLabel(Effort.high));
    try std.testing.expectEqualStrings("Extra high", reasoningLabel(Effort.xhigh));
    try std.testing.expectEqualStrings("Max", reasoningLabel(Effort.max));
    try std.testing.expectEqualStrings("Ultra", reasoningLabel(Effort.ultra));
}

test "compact token counts keep prompt usage readable" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("999", compactTokenCount(&buf, 999));
    try std.testing.expectEqualStrings("138k", compactTokenCount(&buf, 138_082));
}

test "context percent saturates malformed or over-window server meters" {
    try std.testing.expectEqual(@as(u64, 0), contextPercent(100, 0));
    try std.testing.expectEqual(@as(u64, 50), contextPercent(50_000, 100_000));
    try std.testing.expectEqual(@as(u64, 100), contextPercent(150_000, 100_000));
    try std.testing.expectEqual(@as(u64, 100), contextPercent(std.math.maxInt(u64), 100_000));
}
