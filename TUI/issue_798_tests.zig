//! #798: prompt history must clear the rendered composer after Down.
const std = @import("std");
const sim = @import("sim.zig");

fn composerContains(vis: []const u8, first_row: usize, needle: []const u8) bool {
    var row: usize = 0;
    var lines = std.mem.splitScalar(u8, vis, '\n');
    while (lines.next()) |line| : (row += 1) {
        if (row >= first_row and std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

test "#798: Down from a wrapped prompt leaves only the fresh composer draft" {
    const a = std.testing.allocator;
    var term: sim.Term = undefined;
    term.init(a, 80, 24);
    defer term.deinit();

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(a);
    try prompt.appendSlice(a, "issue-798-recalled-head ");
    for (0..32) |_| try prompt.appendSlice(a, "a wrapped submitted segment ");
    try prompt.appendSlice(a, "issue-798-recalled-tail");

    // Submit through the same sim feed path as the fullscreen loop.
    _ = term.typeText(prompt.items);
    _ = term.enter();
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), term.model.prompt_hist.items.len);

    // The live history cursor sits just past the newest item before Up. Keep
    // this seam explicit: the regression starts after Up has recalled the row.
    term.model.hist_idx = term.model.prompt_hist.items.len;
    _ = term.feed("\x1b[A");
    try std.testing.expectEqualStrings(prompt.items, term.model.input.getValue());
    const recalled = try term.screen();
    defer a.free(recalled);
    try std.testing.expect(composerContains(recalled, term.model.prompt_origin, "issue-798-recalled-tail"));

    _ = term.feed("\x1b[B");
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    try std.testing.expectEqual(@as(?usize, null), term.model.hist_idx);
    const fresh = try term.screen();
    defer a.free(fresh);
    try std.testing.expect(!composerContains(fresh, term.model.prompt_origin, "issue-798-recalled-tail"));

    _ = term.typeText("ONLY-FRESH-TYPED");
    try std.testing.expectEqualStrings("ONLY-FRESH-TYPED", term.model.input.getValue());
    const typed = try term.screen();
    defer a.free(typed);
    try std.testing.expect(composerContains(typed, term.model.prompt_origin, "ONLY-FRESH-TYPED"));
    try std.testing.expect(!composerContains(typed, term.model.prompt_origin, "issue-798-recalled-tail"));
}
