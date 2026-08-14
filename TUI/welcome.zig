//! Welcome pane. ANSI only.

const std = @import("std");

const app = @import("app.zig");
const Model = app.Model;

/// Idle mid-pane is empty — Grok's pager is a blank field over the composer.
pub fn render(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    _ = self;
    _ = a;
    _ = width;
    return "";
}

test "idle welcome is empty" {
    try std.testing.expectEqualStrings("", try render(undefined, std.testing.allocator, 80));
}
