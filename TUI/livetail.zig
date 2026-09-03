//! Live stream tail for an in-flight turn. Split from scrollback.zig so
//! the transcript layout stays under the 600-line ceiling.

const std = @import("std");

const app = @import("app.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// Drop escapes/C0 from the live tail so a CR cannot rewind the row.
pub fn strip(a: std.mem.Allocator, s: []const u8) []const u8 {
    return @import("markdown.zig").sanitize(a, s) catch s;
}

/// True once the engine has put tokens (or raw bash) on the wire. The
/// pending "Thinking" row is then redundant — liveAnswer is the reply.
pub fn liveHasBytes(self: *const Model) bool {
    const job = self.pending orelse return false;
    if (self.cancel_requested) return false;
    return job.stream.len.load(.acquire) > 0 or job.raw.len.load(.acquire) > 0;
}

/// Live prose uses the same renderer as a settled assistant row. Raw bash
/// stays sanitized-only — those bytes are a terminal, not markdown.
pub fn liveTail(self: *const Model, a: std.mem.Allocator, live: []const u8, raw_bash: bool, width: usize) ![]const u8 {
    const clean = strip(a, live);
    if (raw_bash) return tail(a, clean, width, 4);
    const painted = @import("markdown.zig").renderThemed(a, clean, self.theme(), width -| 4) catch clean;
    return tail(a, painted, width, 48);
}

pub fn tail(a: std.mem.Allocator, s: []const u8, width: usize, max_lines: usize) ![]const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, s, '\n');
    // Live tail is prose, or the raw bash projection when that buf is live.
    while (it.next()) |ln| try lines.append(ln);
    const start = if (lines.items.len > max_lines) lines.items.len - max_lines else 0;
    var out = std.array_list.Managed(u8).init(a);
    for (lines.items[start..], 0..) |ln, n| {
        if (n > 0) try out.append('\n');
        try out.appendSlice(try theme_mod.wrapToWidth(a, try std.fmt.allocPrint(a, "    {s}", .{ln}), width));
    }
    return out.items;
}
