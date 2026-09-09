//! Citation control markup must not appear as raw PUA in the TUI transcript (#805).

const std = @import("std");
const sim = @import("sim.zig");

test "TUI transcript strips citation annotations (#805)" {
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.assistant, "See the docs\u{E200}cite\u{E202}turn0view0\u{E201} for details.");
    try std.testing.expectEqualStrings("See the docs for details.", term.model.history.items[0].text);
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "See the docs for details.") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "turn0view0") == null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "\u{E200}") == null);
}
