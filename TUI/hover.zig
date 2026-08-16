//! Hover affordance: make a clickable row LOOK clickable before the click.
//!
//! ?1003h (any-event tracking) is already on for the image-chip preview, so
//! the pointer's position reaches keys.mouseKey as a mouse report with button
//! 35 on every motion. Until now every one of those that did not land on an
//! image chip was DROPPED — the TUI knew where the pointer was and said
//! nothing. This is the other half: the row under the pointer is looked up in
//! the same map a click uses, and if it is a target it is painted with a
//! background one step off the canvas and, when it is a collapsed group, with
//! its leading mark swapped for the chevron that announces expandability.
//!
//! ONE HIT TEST. `hitTest` is the single answer to "what is on screen row y",
//! and keys.mouseKey routes its click through the same function. Hover and
//! click cannot disagree about what is clickable, because there is only one
//! opinion in the codebase.
//!
//! PRESENTATION ONLY. The hovered row, the click counter and the tint are all
//! screen state. What is FOLDABLE, and which entry a row belongs to, come from
//! the Model's typed entries (`kind == .tool`, `Entry.folded`) and from the
//! layout cache — never from reading the rendered text back.
//!
//! DOUBLE CLICK. Two presses on the same cell inside `double_ms`. The first
//! press always does exactly what a press does today (the existing tests pin
//! that); the SECOND suppresses the single-click action and runs the
//! double-click one instead, so a double click on a fold header is one net
//! toggle rather than an expand followed by a collapse. A press that MOVED is
//! a drag, never a click: selection.zig owns that distinction and calls
//! `dragged` the instant motion proves it, so the counter is not a second,
//! divergent copy of the same state machine.
//!
//! COST. Hover repaints ride the ordinary frame path. A sweep across N rows is
//! N motion reports, which pacing.zig's storm window folds into a bounded
//! number of composed frames exactly as it folds a momentum flick — see the
//! pacing lane's budget, and `scripts/test-tui-hover.py` for the pty proof.

const std = @import("std");

const app = @import("app.zig");
const glyphs = @import("glyphs.zig");
const key_mod = @import("key.zig");
const layout_cache = @import("layout_cache.zig");
const theme_mod = @import("theme.zig");
const tint = @import("theme_tint.zig");
const Model = app.Model;

/// Two presses inside this window, on the same cell, are one double click.
pub const double_ms: u64 = 400;

/// SGR button for motion with no button held, under ?1003h. Motion WITH the
/// left button down is 32 and belongs to the drag, not to hover.
pub const motion_btn: u8 = 35;

/// What sits on a screen row. Only rows a press actually does something to are
/// targets: an affordance that announced a click which does nothing would be
/// worse than no affordance at all.
pub const Target = enum {
    /// Nothing clickable (blank padding, an overlay body, chrome).
    none,
    /// A row belonging to a tool run — a press toggles the whole group.
    tool,
    /// The sticky-header pin: a scrolled-past user prompt. A press does
    /// nothing today; a DOUBLE press jumps the viewport back to it.
    sticky,
    /// The composer. A press focuses it.
    composer,
};

pub const Hit = struct {
    target: Target = .none,
    /// History index the row maps to. Set for `.tool` only.
    idx: ?usize = null,
    /// The group is folded, so its mark should announce that it opens.
    collapsed: bool = false,
};

/// Presentation state. Lives on the Model beside `sel` and `layout`.
pub const State = struct {
    /// 0-based screen row under the pointer, or null when nothing is hovered.
    row: ?usize = null,
    hit: Hit = .{},
    /// Cell and time of the last press, for the double-click window.
    last_ms: u64 = 0,
    last_row: usize = 0,
    last_col: usize = 0,
    /// A press is banked here; the next one on the same cell inside the window
    /// completes a double. Zeroed by a drag and by every scroll.
    armed: bool = false,
};

// --------------------------------------------------------------- hit test

/// What screen row `y` (0-based) is, this frame. The row→entry map is the
/// layout cache's, which is the same one keys.mouseKey clicks through.
pub fn hitTest(m: *Model, y: usize) Hit {
    // An overlay owns the whole screen and any press merely closes it; there is
    // no per-row target to announce, so nothing is highlighted while one is up.
    if (m.overlay != .none) return .{};
    if (y >= m.prompt_origin) return .{ .target = .composer };
    if (y < m.mid_origin) return .{};
    // Sticky chrome OCCLUDES the top content rows: the blank separator row
    // under the pin is chrome too, and neither maps to what is beneath them.
    if (y < m.mid_origin + m.sticky_rows) {
        return if (m.sticky_rows > 0 and y == m.mid_origin) .{ .target = .sticky } else .{};
    }
    const vis = y - m.mid_origin + m.mid_skip;
    const i = layout_cache.indexAtVisual(m, vis, m.last_term_width) orelse return .{};
    if (m.history.items[i].kind != .tool) return .{};
    const run = m.toolRun(i);
    return .{ .target = .tool, .idx = i, .collapsed = m.history.items[run.start].folded };
}

// ----------------------------------------------------------------- motion

/// A mouse report. Returns true when it was pure hover motion and nothing else
/// should see it. A drag in progress owns the pointer, so hover stands down.
pub fn mouse(m: *Model, ev: key_mod.Mouse) bool {
    if (ev.btn != motion_btn) return false;
    if (m.sel.active or m.sel.pressed) {
        clear(m);
        return false; // image.zig still wants the report for its chip preview
    }
    const y: usize = if (ev.y > 0) ev.y - 1 else 0;
    const hit = hitTest(m, y);
    if (hit.target == .none) {
        clear(m);
        return false;
    }
    m.hover.row = y;
    m.hover.hit = hit;
    return false; // never consumed: the image chip preview reads it too
}

/// Drop the highlight. Called when the pointer leaves a target, when the
/// screen scrolls under it (the row no longer means what it meant), and on
/// every teardown of the frame's geometry.
pub fn clear(m: *Model) void {
    m.hover.row = null;
    m.hover.hit = .{};
}

/// A scroll moved the content out from under the pointer, and the pointer did
/// not move: the highlight would now be announcing a different row than the
/// one the user is actually over. Drop it and let the next motion re-arm.
pub fn scrolled(m: *Model) void {
    clear(m);
    m.hover.armed = false;
}

// ----------------------------------------------------------- click counting

/// Record a press. True when it COMPLETES a double click, in which case the
/// caller must run the double-click action INSTEAD of the single-click one:
/// the first press already did today's thing, and repeating it would undo it.
pub fn press(m: *Model, y: usize, x: usize) bool {
    const same = m.hover.armed and
        m.hover.last_row == y and m.hover.last_col == x and
        m.now_ms -| m.hover.last_ms <= double_ms;
    m.hover.last_row = y;
    m.hover.last_col = x;
    m.hover.last_ms = m.now_ms;
    // A completed double disarms, so a third press opens a fresh single rather
    // than firing the double action again on every press that follows.
    m.hover.armed = !same;
    return same;
}

/// selection.zig calls this the instant motion turns a press into a drag. A
/// gesture that moved is not a click, so it can never be half of a double one.
pub fn dragged(m: *Model) void {
    m.hover.armed = false;
    clear(m);
}

/// Double click on the sticky pin: put the prompt it is pinning back on the
/// top row of the viewport. No-op when there is nothing pinned or nothing to
/// scroll — the same numbers render.zig used to lay the frame out.
pub fn jumpToSticky(m: *Model) void {
    const c = layout_cache.ensure(m, m.last_term_width);
    if (layout_cache.stickyUserAbove(c, m.mid_skip) == null) return;
    var i = layout_cache.indexAt(c, m.mid_skip) orelse m.history.items.len;
    const line = while (i > 0) {
        i -= 1;
        if (m.history.items[i].kind == .user) break layout_cache.lineOf(c, i) orelse return;
    } else return;
    const view_h = m.prompt_origin -| m.mid_origin -| m.preview_rows;
    if (view_h == 0 or c.total <= view_h) return;
    // `scroll` counts lines from the BOTTOM (render.zig: start = max - scroll).
    m.scroll = (c.total - view_h) -| line;
    m.follow = m.scroll == 0;
    scrolled(m);
}

// ------------------------------------------------------------------ paint

/// Post-pass over the COMPOSED frame, exactly like selection.paint: the row
/// builders stay unaware of hover, and the row lands on the screen row the
/// mouse reported.
///
/// The theme background is written per ROW by the painter, BEFORE the row's
/// bytes (paint.zig), so opening the row with a different background is all it
/// takes to retint it — including the padding the painter adds after it, which
/// inherits whatever the row left active.
pub fn paint(m: *Model, a: std.mem.Allocator, frame: []const u8, width: usize) ![]const u8 {
    _ = width;
    const row = m.hover.row orelse return frame;
    if (m.hover.hit.target == .none) return frame;
    const bg = tint.hoverBg(m.theme_id);
    var out = std.array_list.Managed(u8).init(a);
    var r: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    var found = false;
    while (it.next()) |ln| : (r += 1) {
        if (r > 0) try out.append('\n');
        if (r != row) {
            try out.appendSlice(ln);
            continue;
        }
        found = true;
        try out.appendSlice(bg);
        if (m.hover.hit.collapsed) {
            try out.appendSlice(try swapMark(a, ln));
        } else try out.appendSlice(ln);
    }
    // The pointer is parked on a row the frame no longer reaches (the transcript
    // shrank under it). Nothing to tint, and the stale row must not paint.
    if (!found) return frame;
    return out.items;
}

/// The affordance swap: a collapsed row's tool mark becomes the chevron, so
/// "this opens" is said before the click rather than after it. Both glyphs are
/// registered one-column (glyphs.zig), so nothing beside the mark moves.
fn swapMark(a: std.mem.Allocator, ln: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, ln, glyphs.tool) orelse return ln;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{
        ln[0..at],
        glyphs.expand,
        ln[at + glyphs.tool.len ..],
    });
}
