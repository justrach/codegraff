//! Behavioral tests for the field-backed tool transcript (#551). They drive
//! `scrollback.render` through the public Model, so they hold the CONTRACT —
//! what a reader sees — rather than any one helper's shape. Split out of
//! scrollback.zig for the 600-line ceiling.

const std = @import("std");

const app = @import("app.zig");
const glyphs = @import("glyphs.zig");
const scrollback = @import("scrollback.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// The COLUMN `needle` starts at on its rendered row — SGR and glyph widths
/// resolved, which is the only measure a terminal agrees with.
fn labelCol(text: []const u8, needle: []const u8) ?usize {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        const at = std.mem.indexOf(u8, ln, needle) orelse continue;
        return theme_mod.visibleLen(ln[0..at]);
    }
    return null;
}

test "the pending label holds its column across every blink frame" {
    // grok-build's rule: animated chrome is exactly one column, so the label
    // and any timer beside it never step sideways as the animation ticks.
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.pending, "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var col: ?usize = null;
    var seen = std.mem.zeroes([glyphs.thinking.len]bool);
    // Six samples across three blink periods: more than the four frames the
    // live pty proof watches, and enough to see both frames twice.
    for ([_]u64{ 0, 500, 1000, 1500, 2000, 2500 }) |now_ms| {
        const text = try scrollback.render(&m, arena.allocator(), 80, now_ms);
        const at = labelCol(text, "Thinking") orelse return error.NoPendingLabel;
        if (col) |want| try std.testing.expectEqual(want, at) else col = at;
        for (glyphs.thinking, 0..) |f, i| {
            if (std.mem.indexOf(u8, text, f) != null) seen[i] = true;
        }
    }
    for (seen) |s| try std.testing.expect(s); // it really animated
    // Two columns of selection field, one of glyph, one of space.
    try std.testing.expectEqual(@as(usize, 4), col.?);
}

test "a settled row's body starts in the same column the pending row used" {
    // The gutter is shared: the blink is replaced by a static mark when the
    // turn lands, and a mark of a different width would jerk the whole answer
    // sideways at exactly the moment the reader starts reading it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var live_m: Model = undefined;
    live_m.setup(std.testing.allocator);
    defer live_m.deinit();
    try live_m.push(.pending, "");
    const live = try scrollback.render(&live_m, arena.allocator(), 80, 0);
    const pending_col = labelCol(live, "Thinking") orelse return error.NoPendingLabel;
    var done_m: Model = undefined;
    done_m.setup(std.testing.allocator);
    defer done_m.deinit();
    try done_m.push(.assistant, "Landed");
    const done = try scrollback.render(&done_m, arena.allocator(), 80, 0);
    try std.testing.expectEqual(pending_col, labelCol(done, "Landed") orelse return error.NoBody);
}

test "classification reads the tool name, not the whole row (#551)" {
    // `bash` running a command that merely mentions a search word is a call,
    // not a search — the old whole-line substring test got this wrong.
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.pushTool(.{ .name = "bash", .detail = "grep -rn needle | head" });
    try m.pushTool(.{ .name = "bash", .detail = "found 3", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try scrollback.render(&m, arena.allocator(), 100, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "Called 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Searched") == null);
    // And the argument survives the " | " that used to truncate the title.
    m.toggleToolGroup(0);
    const open = try scrollback.render(&m, arena.allocator(), 100, 0);
    try std.testing.expect(std.mem.indexOf(u8, open, "grep -rn needle | head") != null);
}

test "an mcp run summarises as MCP tools, off the name prefix" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.pushTool(.{ .name = "mcp__codedbpro__memo", .detail = "note" });
    try m.pushTool(.{ .name = "mcp__codedbpro__memo", .detail = "saved", .done = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try scrollback.render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "Called 2 MCP tools") != null);
}

test "an assistant line that starts with a status glyph is NOT a tool row (#551)" {
    // The phantom-row bug: turn.zig used to harvest any streamed line starting
    // "✓ " into the transcript as a tool. Answer text is answer text.
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "did it work?");
    try m.push(.assistant, "✓ all three checks passed");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try scrollback.render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "all three checks passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Called") == null);
    for (m.history.items) |e| try std.testing.expect(e.kind != .tool);
}

test "a legacy text-only tool row still renders (session migration)" {
    // Rows restored from a session written before the typed contract carry no
    // fields. They must still show up — just without pairing or a preview.
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.tool, "⚙ bash");
    try m.push(.tool, "✓ bash | ok");
    for (m.history.items) |e| try std.testing.expect(e.tool == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const folded = try scrollback.render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, folded, "Called 2") != null);
    m.toggleToolGroup(0);
    const open = try scrollback.render(&m, arena.allocator(), 80, 0);
    try std.testing.expect(std.mem.indexOf(u8, open, "⚙ bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "✓ bash | ok") != null);
}

test "a failed call is marked, a refused one is marked differently" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.pushTool(.{ .name = "bash", .detail = "false" });
    try m.pushTool(.{ .name = "bash", .detail = "exit 1", .done = true, .is_error = true });
    try m.pushTool(.{ .name = "write_file", .detail = "/etc/passwd" });
    try m.pushTool(.{ .name = "write_file", .detail = "refused by plan mode", .done = true, .is_error = true, .denied = true });
    m.toggleToolGroup(0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try scrollback.render(&m, arena.allocator(), 100, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "✗ bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "⊘ write") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "refused by plan mode") != null);
}
