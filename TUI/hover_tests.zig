//! Dispatch-level tests for the hover affordance: what a motion report does to
//! the Model, what the post-pass does to the frame, and where the double-click
//! window opens and closes. Reached from root.zig — a test module nobody
//! references compiles for nobody and silently never runs.

const std = @import("std");

const app = @import("app.zig");
const glyphs = @import("glyphs.zig");
const hover = @import("hover.zig");
const keys = @import("keys.zig");
const render_mod = @import("render.zig");
const tint = @import("theme_tint.zig");
const Model = app.Model;

const testing = std.testing;

/// The mouse reports the TUI actually receives. `y`/`x` are 1-based, as a
/// terminal sends them; every handler converts on the way in.
fn motion(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = hover.motion_btn, .x = x, .y = y, .down = true } });
}

fn press(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 0, .x = x, .y = y, .down = true } });
}

fn drag(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 32, .x = x, .y = y, .down = true } });
}

/// A model with one collapsed tool run in a fixed, hand-placed geometry — the
/// same shape selection.zig's tests use, so the two agree about the viewport.
fn folded(m: *Model) !void {
    m.setup(testing.allocator);
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    m.last_term_height = 24;
    m.last_term_width = 80;
    m.mid_origin = 1;
    m.mid_skip = 0;
    m.prompt_origin = 20;
}

test "motion over a collapsed tool row arms the hover; leaving it clears" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    try testing.expect(m.history.items[1].folded);

    motion(&m, 4, 3); // screen row 2 — the folded group's summary
    try testing.expectEqual(@as(?usize, 2), m.hover.row);
    try testing.expectEqual(hover.Target.tool, m.hover.hit.target);
    try testing.expect(m.hover.hit.collapsed);
    // Hover NEVER folds, selects or focuses anything: it only says a click
    // would do something.
    try testing.expect(m.history.items[1].folded);

    motion(&m, 4, 15); // blank padding below the transcript
    try testing.expectEqual(@as(?usize, null), m.hover.row);
    try testing.expectEqual(hover.Target.none, m.hover.hit.target);
}

test "the composer is a hover target; a row above the viewport is not" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    motion(&m, 5, 21); // inside the composer
    try testing.expectEqual(hover.Target.composer, m.hover.hit.target);
    try testing.expectEqual(@as(?usize, 20), m.hover.row);
    motion(&m, 5, 1); // the top bar, above mid_origin
    try testing.expectEqual(hover.Target.none, m.hover.hit.target);
}

test "an expanded group hovers as a target but never claims to expand" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    m.toggleToolGroup(1);
    try testing.expect(!m.history.items[1].folded);
    motion(&m, 4, 3);
    try testing.expectEqual(hover.Target.tool, m.hover.hit.target);
    // Already open: the chevron would be a lie, so the mark stays put.
    try testing.expect(!m.hover.hit.collapsed);
}

/// Screen row (0-based) of the first composed line containing `needle`. The
/// frame decides its own geometry, so a test that wants to point at a row has
/// to ask the frame where it is rather than assume.
fn rowOf(frame: []const u8, needle: []const u8) ?usize {
    var r: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |ln| : (r += 1) {
        if (std.mem.indexOf(u8, ln, needle) != null) return r;
    }
    return null;
}

test "the hovered row is repainted with the theme's hover background" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    const bg = tint.hoverBg(m.theme_id);

    const cold = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(cold);
    try testing.expect(std.mem.indexOf(u8, cold, bg) == null);
    const summary: u16 = @intCast(rowOf(cold, "Called").? + 1);

    motion(&m, 4, summary);
    const warm = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(warm);
    // Exactly one row carries it: hover highlights a row, not a region.
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, warm, '\n');
    while (it.next()) |ln| {
        if (std.mem.indexOf(u8, ln, bg) != null) rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), rows);

    // ...and moving off restores the frame byte for byte.
    motion(&m, 4, 15);
    const cooled = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(cooled);
    try testing.expectEqualStrings(cold, cooled);
}

test "a collapsed row under the pointer swaps its tool mark for the chevron" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    const cold = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(cold);
    try testing.expect(std.mem.indexOf(u8, cold, glyphs.tool) != null);

    motion(&m, 4, @intCast(rowOf(cold, "Called").? + 1));
    const warm = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(warm);
    // The one folded group's mark is gone, replaced by the expand chevron.
    try testing.expect(std.mem.indexOf(u8, warm, glyphs.tool) == null);
    try testing.expect(std.mem.indexOf(u8, warm, glyphs.expand) != null);
    // The swap costs no columns, so nothing beside the mark steps sideways.
    try testing.expectEqual(
        @import("theme.zig").visibleLen(glyphs.tool),
        @import("theme.zig").visibleLen(glyphs.expand),
    );
}

test "an expanded row keeps its tool mark under the pointer" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    m.toggleToolGroup(1);
    const cold = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(cold);
    motion(&m, 4, @intCast(rowOf(cold, "bash").? + 1));
    const warm = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(warm);
    try testing.expect(std.mem.indexOf(u8, warm, glyphs.tool) != null);
}

test "a scroll drops the hover: the row under a still pointer now means something else" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    motion(&m, 4, 3);
    try testing.expectEqual(hover.Target.tool, m.hover.hit.target);
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 64, .x = 4, .y = 3, .down = true } });
    try testing.expectEqual(@as(?usize, null), m.hover.row);
    try testing.expectEqual(hover.Target.none, m.hover.hit.target);
}

test "a drag stands the hover down and disarms the click counter" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    motion(&m, 4, 3);
    press(&m, 4, 3);
    drag(&m, 30, 6); // motion with the button held: this is a selection now
    try testing.expect(m.sel.active);
    try testing.expectEqual(@as(?usize, null), m.hover.row);
    // The press that turned into a drag cannot be half of a double click, so
    // the press that ends the drag opens a fresh single.
    try testing.expect(!m.hover.armed);
    // Motion WITH the button down is the drag's, never hover's.
    try testing.expectEqual(hover.Target.none, m.hover.hit.target);
}

// ------------------------------------------------------- double-click window

test "two presses on one cell inside the window are one double click" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    m.now_ms = 1000;
    try testing.expect(!hover.press(&m, 5, 5));
    m.now_ms = 1000 + hover.double_ms;
    try testing.expect(hover.press(&m, 5, 5));
    // A third press is a fresh single, not another double.
    m.now_ms += 10;
    try testing.expect(!hover.press(&m, 5, 5));
}

test "the window closes on time and on distance" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    // One millisecond past the window is a single click.
    m.now_ms = 1000;
    try testing.expect(!hover.press(&m, 5, 5));
    m.now_ms = 1001 + hover.double_ms;
    try testing.expect(!hover.press(&m, 5, 5));
    // A different cell inside the window is a single click too — a double is
    // two presses on ONE cell, not two presses anywhere.
    m.now_ms += 10;
    try testing.expect(!hover.press(&m, 6, 5));
    m.now_ms += 10;
    try testing.expect(!hover.press(&m, 5, 6));
}

test "a single click still expands, and a double click is one net toggle" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    m.now_ms = 5000;
    try testing.expect(m.history.items[1].folded);

    // Today's behaviour, unchanged: one press expands the group.
    press(&m, 4, 3);
    try testing.expect(!m.history.items[1].folded);

    // A second press inside the window would have collapsed it again, leaving
    // a double click looking like it did nothing. It is one net toggle now.
    m.now_ms += 100;
    press(&m, 4, 3);
    try testing.expect(!m.history.items[1].folded);

    // ...and two presses far enough apart are still two independent clicks.
    m.now_ms += 10 * hover.double_ms;
    press(&m, 4, 3);
    try testing.expect(m.history.items[1].folded);
}

test "a double click on the sticky pin scrolls its prompt back onto the screen" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try m.push(.user, "FINDME the pinned prompt");
    var i: usize = 0;
    while (i < 60) : (i += 1) try m.push(.assistant, "a filler answer line");
    // Compose once so the viewport, the sticky pin and the layout cache exist.
    const first = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    testing.allocator.free(first);
    try testing.expect(m.sticky_rows > 0); // the prompt HAS scrolled past
    try testing.expect(m.mid_skip > 0);

    m.now_ms = 9000;
    const pin: u16 = @intCast(m.mid_origin + 1); // 1-based row of the pin
    press(&m, 3, pin);
    const after_single = m.mid_skip;
    // A single press on the pin is inert, exactly as before.
    const mid = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    testing.allocator.free(mid);
    try testing.expectEqual(after_single, m.mid_skip);

    m.now_ms += 100;
    press(&m, 3, pin);
    const jumped = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(jumped);
    // The prompt is on screen again, and the viewport is no longer following.
    try testing.expect(std.mem.indexOf(u8, jumped, "FINDME") != null);
    try testing.expect(!m.follow);
    try testing.expect(m.mid_skip < after_single);
}

test "content arriving under a still pointer clears the hover instead of lying" {
    // The pointer never moves; the transcript grows under it. The remembered
    // row now names a different entry, so an unverified highlight would be
    // announcing a click that lands somewhere else entirely.
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    const cold = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(cold);
    motion(&m, 4, @intCast(rowOf(cold, "Called").? + 1));
    try testing.expectEqual(hover.Target.tool, m.hover.hit.target);

    // Enough answer to overflow the viewport: following the tail slides the
    // group off the row the pointer is parked on, without the pointer moving.
    var i: usize = 0;
    while (i < 40) : (i += 1) try m.push(.assistant, "a streamed answer line");
    const moved = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(moved);
    try testing.expectEqual(@as(?usize, null), m.hover.row);
    try testing.expect(std.mem.indexOf(u8, moved, tint.hoverBg(m.theme_id)) == null);
}

test "a group that folds under the pointer starts announcing that it opens" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    m.toggleToolGroup(1); // open it first
    const open = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(open);
    motion(&m, 4, @intCast(rowOf(open, "bash").? + 1));
    try testing.expect(!m.hover.hit.collapsed);

    // Folded by the keyboard, with the pointer still parked on the row: the
    // mark has to start announcing the expansion without a new motion report.
    m.toggleToolGroup(1);
    const shut = try render_mod.render(&m, testing.allocator, 80, 24, 0);
    defer testing.allocator.free(shut);
    try testing.expect(m.hover.hit.collapsed);
    try testing.expect(std.mem.indexOf(u8, shut, glyphs.expand) != null);
}

test "hover clears when the pointer is over an overlay, which has no row targets" {
    var m: Model = undefined;
    try folded(&m);
    defer m.deinit();
    motion(&m, 4, 3);
    try testing.expectEqual(hover.Target.tool, m.hover.hit.target);
    m.openOverlay(.help);
    motion(&m, 4, 3);
    try testing.expectEqual(hover.Target.none, m.hover.hit.target);
    try testing.expectEqual(@as(?usize, null), m.hover.row);
}
