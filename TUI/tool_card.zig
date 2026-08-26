//! Tool-row title + live elapsed. Split from scrollback.zig so the 600-line
//! ceiling has room for the duration suffix without a scrollback/card cycle.

const std = @import("std");

const app = @import("app.zig");
const foldhdr = @import("foldhdr.zig");
const glyphs = @import("glyphs.zig");

const displayName = foldhdr.displayName;

/// Elapsed for a running row (`now - at`) or a finished one (`recorded_ms`).
/// Hidden under 100ms so a fast read does not flicker `0ms`.
pub fn timingSuffix(buf: []u8, done: bool, recorded_ms: u64, now_ms: u64, at_ms: u64) []const u8 {
    const ms: u64 = if (done) recorded_ms else now_ms -| at_ms;
    if (ms < 100) return "";
    return formatElapsed(buf, ms);
}

pub fn formatElapsed(buf: []u8, ms: u64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "";
    const s = ms / 1000;
    if (s < 60) {
        const tenths = (ms / 100) % 10;
        if (tenths == 0) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "";
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ s, tenths }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ s / 60, s % 60 }) catch "";
}

/// The head of a tool row: `[status mark] name  [argument preview]  [elapsed]`.
pub fn toolTitle(a: std.mem.Allocator, named: app.Entry, status: app.Entry, now_ms: u64) ![]const u8 {
    const t = named.tool orelse return named.text;
    const mark: []const u8 = if (status.tool) |s|
        (if (s.denied) glyphs.denied ++ " " else if (s.is_error) glyphs.failed ++ " " else "")
    else
        "";
    const name = displayName(t.name);
    const args = if (t.done) "" else t.detail;
    const recorded = if (status.tool) |s| s.ms else t.ms;
    const done = t.done or if (status.tool) |s| s.done else false;
    var tbuf: [16]u8 = undefined;
    const timing = timingSuffix(&tbuf, done, recorded, now_ms, named.at_ms);
    if (args.len == 0 and timing.len == 0)
        return if (mark.len == 0) name else std.fmt.allocPrint(a, "{s}{s}", .{ mark, name });
    if (args.len == 0)
        return std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, name, timing });
    if (timing.len == 0)
        return std.fmt.allocPrint(a, "{s}{s}  {s}", .{ mark, name, args });
    return std.fmt.allocPrint(a, "{s}{s}  {s}  {s}", .{ mark, name, args, timing });
}

test "timingSuffix hides sub-100ms, then shows live and recorded" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", timingSuffix(&buf, false, 0, 50, 0));
    try std.testing.expectEqualStrings("120ms", timingSuffix(&buf, false, 0, 120, 0));
    try std.testing.expectEqualStrings("1.2s", timingSuffix(&buf, true, 1200, 0, 0));
    try std.testing.expectEqualStrings("3s", timingSuffix(&buf, true, 3000, 0, 0));
}

test "toolTitle appends elapsed on a running row" {
    const e: app.Entry = .{
        .kind = .tool,
        .text = "ls",
        .at_ms = 0,
        .tool = .{ .name = "bash", .detail = "ls -la", .done = false },
    };
    const title = try toolTitle(std.testing.allocator, e, e, 1500);
    defer std.testing.allocator.free(title);
    try std.testing.expect(std.mem.indexOf(u8, title, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, title, "1.5s") != null);
}
