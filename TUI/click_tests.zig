//! Single-click semantics (click.zig), pinned.
//!
//! Four boundaries live here, and every one of them is a place the gesture
//! could quietly do the wrong thing:
//!
//!   * a fold header answers a click with EXACTLY one net toggle, however fast
//!     the second click arrives,
//!   * a press that MOVED is a selection and never a fold toggle; a press that
//!     did not is a click and never touches the clipboard,
//!   * the scroll gutter owns its column before the selection can anchor in
//!     it, and gives the pointer back on the button-up,
//!   * a list row picks, the row that already carries the highlight confirms,
//!     and the backdrop around the panel dismisses it.
//!
//! The overlay cases drive a REAL composed frame and find their row by reading
//! it back, so the click map (overlays.rowSpan) is checked against the bytes
//! the renderer actually produced rather than against a second opinion.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const chrome = @import("chrome.zig");
const engine = @import("engine.zig");
const hover = @import("hover.zig");
const keys = @import("keys.zig");
const overlays = @import("overlays.zig");
const render_mod = @import("render.zig");
const scrollbar = @import("scrollbar.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

const alloc = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn press(m: *Model, x: u16, y: u16) app.Effect {
    return keys.handle(m, .{ .mouse = .{ .btn = 0, .x = x, .y = y, .down = true } });
}

fn release(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 0, .x = x, .y = y, .down = false } });
}

fn motion(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 32, .x = x, .y = y, .down = true } });
}

/// A click: press and release on the SAME cell with nothing in between.
fn clickAt(m: *Model, x: u16, y: u16) app.Effect {
    const e = press(m, x, y);
    release(m, x, y);
    return e;
}

fn frame(m: *Model, w: usize, h: usize) ![]const u8 {
    return render_mod.render(m, alloc, w, h, m.now_ms);
}

/// 0-based screen row of the first frame line carrying `needle`.
fn rowOf(f: []const u8, needle: []const u8) ?usize {
    var r: usize = 0;
    var it = std.mem.splitScalar(u8, f, '\n');
    while (it.next()) |ln| : (r += 1) {
        if (std.mem.indexOf(u8, ln, needle) != null) return r;
    }
    return null;
}

/// A transcript with one collapsed tool group, laid out by hand so the row a
/// press lands on is arithmetic rather than a search through the frame.
fn foldModel(m: *Model) !void {
    m.setup(alloc);
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    m.last_term_width = 80;
    m.last_term_height = 24;
    m.mid_origin = 1;
    m.mid_skip = 0;
    m.prompt_origin = 20;
}

// ------------------------------------------------------------------- folds

test "a motionless click on a fold header is exactly one net toggle" {
    var m: Model = undefined;
    try foldModel(&m);
    defer m.deinit();
    try expect(m.history.items[1].folded);
    _ = clickAt(&m, 4, 3);
    try expect(!m.history.items[1].folded);
    // A click is not a selection: no band, no capture, no toast claiming one.
    try expect(!m.sel.active);
    try expect(!m.sel.pressed);
    try expectEqual(@as(usize, 0), m.sel_text.len);
    try std.testing.expectEqualStrings("", m.toast);
    // ...and the next click, outside the double-click window, puts it back.
    m.now_ms += hover.double_ms + 1;
    _ = clickAt(&m, 4, 3);
    try expect(m.history.items[1].folded);
}

test "two clicks inside the double-click window are ONE net toggle" {
    // The pinned semantics: the first press toggles, the second REPLACES that
    // action rather than repeating it, so the pair opens the group and leaves
    // it open. Toggling twice would look like the gesture did nothing at all.
    var m: Model = undefined;
    try foldModel(&m);
    defer m.deinit();
    try expect(m.history.items[1].folded);
    _ = clickAt(&m, 4, 3);
    _ = clickAt(&m, 4, 3); // same cell, same millisecond
    try expect(!m.history.items[1].folded);
    // A third press, still inside the window, opens a fresh single click: the
    // completed double disarmed, so the counter cannot fire twice in a row.
    _ = clickAt(&m, 4, 3);
    try expect(m.history.items[1].folded);
}

test "a press that MOVES is a selection, and leaves the fold as it was" {
    var m: Model = undefined;
    try foldModel(&m);
    defer m.deinit();
    try expect(m.history.items[1].folded);
    _ = press(&m, 4, 3);
    motion(&m, 30, 5);
    // The optimistic expand is reverted the instant motion proves the drag.
    try expect(m.history.items[1].folded);
    try expect(m.sel.active);
    // A gesture that moved can never be half of a double click either.
    try expect(!m.hover.armed);
    release(&m, 30, 5);
    try expect(m.history.items[1].folded);
}

// --------------------------------------------------------------- the gutter

/// A transcript long enough to scroll, composed for real so the band, the
/// thumb and the viewport all agree with each other.
fn scrolledModel(m: *Model) !void {
    m.setup(alloc);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        try m.push(.assistant, try std.fmt.bufPrint(&buf, "line {d:0>3}", .{i}));
    }
    const first = try frame(m, 80, 24);
    alloc.free(first);
    keys.scrollBy(m, 40);
    const second = try frame(m, 80, 24);
    alloc.free(second);
}

test "a press on the gutter seeks the viewport and never anchors a band" {
    var m: Model = undefined;
    try scrolledModel(&m);
    defer m.deinit();
    try expect(m.band.live);
    try expect(scrollbar.current(&m) != null);
    const track_top: u16 = @intCast(m.band.top + 1);
    const track_bottom: u16 = @intCast(m.band.top + m.band.len);
    // The bottom of the track is the tail of the transcript.
    _ = press(&m, 80, track_bottom);
    try expect(m.click.gutter);
    try expectEqual(@as(usize, 0), m.scroll);
    try expect(m.follow);
    // A scrollbar gesture is never a drag-copy, and never a fold toggle.
    try expect(!m.sel.pressed);
    try expect(!m.sel.active);
    try expectEqual(app.Focus.prompt, m.focus);
    release(&m, 80, track_bottom);
    try expect(!m.click.gutter);
    // ...and the top of the track is the top of the transcript.
    _ = press(&m, 80, track_top);
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    try expectEqual(@as(usize, 0), m.band.off -| m.sticky_rows);
    try expect(rowOf(f, "line 000") != null);
    release(&m, 80, track_top);
}

test "a drag down the gutter walks the viewport, one report at a time" {
    var m: Model = undefined;
    try scrolledModel(&m);
    defer m.deinit();
    const track_top: u16 = @intCast(m.band.top + 1);
    _ = press(&m, 80, track_top);
    try expect(m.click.gutter);
    const at_top = m.scroll;
    var y = track_top;
    var last = at_top;
    while (y < @as(u16, @intCast(m.band.top + m.band.len))) : (y += 1) {
        motion(&m, 80, y + 1);
        // Monotone: dragging DOWN the track only ever moves toward the tail.
        try expect(m.scroll <= last);
        last = m.scroll;
        // Still the gutter's pointer — the motion never became a selection.
        try expect(!m.sel.active);
    }
    try expect(last < at_top);
    release(&m, 80, @intCast(m.band.top + m.band.len));
    try expect(!m.click.gutter);
}

test "a faded gutter is not a target: the press means what it always meant" {
    var m: Model = undefined;
    try scrolledModel(&m);
    defer m.deinit();
    keys.scrollBy(&m, -1000); // back to the tail
    const f = try frame(&m, 80, 24);
    alloc.free(f);
    m.now_ms += scrollbar.fade_ms + 1;
    try expect(scrollbar.current(&m) == null);
    const row: u16 = @intCast(m.band.top + 2);
    _ = press(&m, 80, row);
    try expect(!m.click.gutter);
    try expectEqual(@as(usize, 0), m.scroll);
    // The ordinary transcript press ran instead.
    try expectEqual(app.Focus.scrollback, m.focus);
    release(&m, 80, row);
}

test "a key hands the pointer back when the gutter's release goes missing" {
    var m: Model = undefined;
    try scrolledModel(&m);
    defer m.deinit();
    _ = press(&m, 80, @intCast(m.band.top + 1));
    try expect(m.click.gutter);
    _ = keys.handle(&m, .{ .char = 'x' });
    try expect(!m.click.gutter);
}

// -------------------------------------------------------------- list rows

fn modelOverlay(m: *Model) !void {
    m.setup(alloc);
    m.openOverlay(.model);
}

test "a click on a model row highlights it, and a second click picks it" {
    engine.g_models = "alpha-one, beta-two, gamma-three";
    engine.g_model_name = "alpha-one";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
    }
    var m: Model = undefined;
    try modelOverlay(&m);
    defer m.deinit();
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    const row = rowOf(f, "gamma-three") orelse return error.NoModelRow;
    _ = press(&m, 3, @intCast(row + 1));
    try expectEqual(app.Overlay.model, m.overlay); // selecting is not picking
    try expectEqual(@as(usize, 2), m.overlay_sel);
    _ = press(&m, 3, @intCast(row + 1));
    try expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("gamma-three", engine.g_model_name);
}

test "the panel keeps a press, and the backdrop around it dismisses" {
    engine.g_models = "alpha-one, beta-two, gamma-three";
    defer engine.g_models = "";
    var m: Model = undefined;
    try modelOverlay(&m);
    defer m.deinit();
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    // The title is inside the panel: inert, and the overlay stays up.
    const title = rowOf(f, "Model ›") orelse return error.NoTitle;
    _ = press(&m, 3, @intCast(title + 1));
    try expectEqual(app.Overlay.model, m.overlay);
    try expectEqual(@as(usize, 0), m.overlay_sel);
    // Below the body's last line is the backdrop, and a press there closes it
    // exactly like Esc.
    const below: u16 = @intCast(m.mid_origin + m.mid_total + 1);
    try expect(below <= m.prompt_origin);
    _ = press(&m, 3, below);
    try expectEqual(app.Overlay.none, m.overlay);
}

test "an overlay with no rows to pick still closes on any press" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.help);
    const f = try frame(&m, 80, 24);
    alloc.free(f);
    try expect(overlays.rowSpan(&m) == null);
    _ = press(&m, 10, @intCast(m.mid_origin + 3));
    try expectEqual(app.Overlay.none, m.overlay);
}

test "a settings row opens the picker it names" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.settings);
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    const row = rowOf(f, "Theme") orelse return error.NoSettingsRow;
    _ = press(&m, 3, @intCast(row + 1)); // highlight
    try expectEqual(@as(usize, 3), m.overlay_sel);
    _ = press(&m, 3, @intCast(row + 1)); // confirm
    try expectEqual(app.Overlay.theme, m.overlay);
}

test "hover announces a list row, so the tint and the click agree" {
    engine.g_models = "alpha-one, beta-two, gamma-three";
    defer engine.g_models = "";
    var m: Model = undefined;
    try modelOverlay(&m);
    defer m.deinit();
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    const row = rowOf(f, "beta-two") orelse return error.NoModelRow;
    const hit = hover.hitTest(&m, row);
    try expectEqual(hover.Target.row, hit.target);
    try expectEqual(@as(?usize, 1), hit.idx);
    // The title is not a target — an affordance on a row a press ignores
    // would be worse than none.
    const title = rowOf(f, "Model ›") orelse return error.NoTitle;
    try expectEqual(hover.Target.none, hover.hitTest(&m, title).target);
}

// ------------------------------------------------------------ slash menu

test "a click on a completion row highlights it, and on the current one runs it" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.focus = .prompt;
    try m.input.setValue("/");
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    try expect(m.slash_rows > 2);
    try expectEqual(@as(usize, 0), m.slash_sel);
    const w = chrome.slashWindow(&m) orelse return error.NoMenu;
    const trimmed = w.show -| m.slash_rows;
    _ = press(&m, 3, @intCast(m.prompt_origin + 3));
    try expectEqual(w.first + trimmed + 2, m.slash_sel);
    // ...and the draft is untouched: highlighting is not running.
    try std.testing.expectEqualStrings("/", m.input.getValue());
}

test "a click on the highlighted completion row runs that command" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.focus = .prompt;
    try m.input.setValue("/plan");
    const f = try frame(&m, 80, 24);
    defer alloc.free(f);
    const w = chrome.slashWindow(&m) orelse return error.NoMenu;
    try expectEqual(@as(usize, 1), w.n);
    try expectEqual(@as(usize, 1), m.slash_rows);
    try expectEqual(app.AgentMode.normal, m.mode);
    _ = press(&m, 3, @intCast(m.prompt_origin + 1));
    try expectEqual(app.AgentMode.plan, m.mode);
    try std.testing.expectEqualStrings("", m.input.getValue());
}

// ------------------------------------------------------- the map vs the bytes

/// Every body line fits the width, and the span's rows carry `want` in order.
/// This is the drift guard: `rowSpan` states each renderer's header shape as
/// arithmetic, and the day a renderer grows a line the arithmetic is a lie —
/// clicks would land one row off, silently, on the wrong item.
fn checkSpan(m: *Model, width: usize, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const body = try chrome.overlay(m, arena.allocator(), width);
    var lines = std.array_list.Managed([]const u8).init(arena.allocator());
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |ln| try lines.append(ln);
    // A list row is CUT, never wrapped: one item is one line, or the map that
    // turns a screen row into an item index cannot be arithmetic at all.
    for (lines.items) |ln| try expect(theme_mod.visibleLen(ln) <= width);
    const span = overlays.rowSpan(m) orelse return error.NoSpan;
    try expectEqual(want.len, span.rows);
    for (want, 0..) |text, k| {
        const ln = lines.items[span.line0 + k];
        if (std.mem.indexOf(u8, ln, text) == null) {
            std.debug.print("row {d} (body line {d}) = {s}\n", .{ k, span.line0 + k, ln });
            return error.RowDrifted;
        }
    }
}

test "the click map names the rows the model picker drew" {
    engine.g_models = "alpha-one, beta-two, gamma-three";
    defer engine.g_models = "";
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.model);
    try checkSpan(&m, 80, &.{ "alpha-one", "beta-two", "gamma-three" });
}

test "the click map names the rows the effort picker drew" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.effort);
    try checkSpan(&m, 80, &.{ "low", "medium", "high", "xhigh", "max", "ultra" });
}

test "the click map names the rows the file picker drew, however long the path" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.files_cache = try alloc.dupe(u8, "src/a.zig\n" ++
        "a/very/deeply/nested/directory/tree/that/runs/past/the/screen/edge/file.zig\n" ++
        "docs/b.md");
    m.openOverlay(.file);
    try checkSpan(&m, 80, &.{ "src/a.zig", "a/very/deeply", "docs/b.md" });
    // ...and at a width where the long path can only be a cut row.
    try checkSpan(&m, 40, &.{ "src/a.zig", "a/very/deeply", "docs/b.md" });
}

test "the click map names the rows the settings, theme and jump panels drew" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.settings);
    try checkSpan(&m, 80, &.{ "Model", "Effort", "Mode", "Theme" });
    m.openOverlay(.theme);
    var want: [theme_mod.all.len][]const u8 = undefined;
    for (theme_mod.all, 0..) |id, i| want[i] = id.label();
    try checkSpan(&m, 80, &want);
    try m.push(.user, "first turn");
    try m.push(.assistant, "ok");
    try m.push(.user, "second turn");
    m.openOverlay(.jump);
    try checkSpan(&m, 80, &.{ "first turn", "second turn" });
}

test "the click map names the rows the command palette drew" {
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.palette);
    try m.input.setValue("/th");
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter("/th", &idx);
    try expect(n > 0 and n <= 12);
    var want = std.array_list.Managed([]const u8).init(alloc);
    defer want.deinit();
    for (idx[0..n]) |i| try want.append(catalog.items[i].name);
    try checkSpan(&m, 80, want.items);
}

test "a click on a SCROLLED overlay body still names the row under it" {
    // The picker's window follows the highlight and the body itself scrolls
    // once it outgrows the viewport, so both offsets have to be in the map.
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    for (0..40) |i| {
        if (i > 0) try list.appendSlice(", ");
        var buf: [16]u8 = undefined;
        try list.appendSlice(try std.fmt.bufPrint(&buf, "mdl-{d:0>2}", .{i}));
    }
    engine.g_models = list.items;
    defer engine.g_models = "";
    var m: Model = undefined;
    m.setup(alloc);
    defer m.deinit();
    m.openOverlay(.model);
    m.overlay_sel = 30; // window scrolled well down the list
    const f = try frame(&m, 80, 20);
    defer alloc.free(f);
    try expect(m.mid_skip > 0); // the body scrolled too
    const row = rowOf(f, "mdl-25") orelse return error.NoModelRow;
    _ = press(&m, 3, @intCast(row + 1));
    try expectEqual(@as(usize, 25), m.overlay_sel);
    try expectEqual(app.Overlay.model, m.overlay);
}
