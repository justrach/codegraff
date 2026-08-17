//! Single click as an ACTION.
//!
//! Everything AROUND the press was already wired: hover.zig tints the row
//! under the pointer, the wheel scrolls, a drag paints a band and copies it,
//! and scrollbar.zig draws a thumb on the right edge. The press itself still
//! only ever did three things - focus the composer, toggle a fold, or dismiss
//! whatever overlay was up - so every list on screen looked clickable and was
//! not. This file is the missing half.
//!
//! THREE TARGETS, ONE RULE. A press answers the thing it LANDED on:
//!
//!   * the scroll gutter (the last column of the band) seeks the viewport, and
//!     keeps seeking while the button is held,
//!   * a row of an open list picks it,
//!   * a row of the slash completion menu picks that command,
//!
//! and a press that lands on none of them falls through to exactly what it did
//! before, byte for byte.
//!
//! SELECT, THEN CONFIRM. A click on a list row moves the highlight to it; a
//! click on the row that ALREADY carries the highlight fires it, like Enter.
//! That is one rule, not two, and it is also why a double click confirms
//! without a second copy of the double-click window: the first press makes the
//! row current and the second one lands on a current row. hover.zig's press
//! counter stays out of it - a list has no "one net toggle" problem to solve.
//!
//! CLICK IS NOT DRAG. A gutter press never reaches selection.zig, so it can
//! never anchor a band (a scrollbar that fought the copy gesture would be
//! worse than no scrollbar). Everywhere else the boundary is the one
//! selection.zig already owns: a press only ARMS the transcript's fold toggle
//! and records an anchor, and the instant motion proves the gesture was a
//! drag, `selection.extend` puts the fold back. So a motionless press+release
//! is a click, a press that moved is a selection, and neither ever does both.
//!
//! PRESENTATION ONLY. Which row a list highlights, where the viewport sits and
//! which command the menu offers are all screen state. What a picked row DOES
//! is not re-implemented here: a list row goes through `overlays.activate` and
//! a menu row through `dispatch.runCommand`, which are the two calls Enter
//! already makes.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const chrome = @import("chrome.zig");
const dispatch = @import("dispatch.zig");
const key_mod = @import("key.zig");
const overlays = @import("overlays.zig");
const scrollbar = @import("scrollbar.zig");
const Model = app.Model;
const Effect = app.Effect;

/// Gesture state. One flag: whether the gutter currently owns the pointer.
pub const State = struct {
    /// A press landed on the scroll gutter and the button has not come up.
    /// Every report until it does is a seek, and none of them is a selection.
    gutter: bool = false,
};

// -------------------------------------------------------------- the gutter

/// The gutter gesture, run BEFORE selection.zig sees the report. Returns true
/// when the gutter owns this event.
///
/// A press on the track jumps toward it; the motion reports that follow keep
/// seeking, which is what makes the thumb draggable. The release ends it. A
/// motion report with NO button held (35) can only mean the release went
/// missing - a terminal that lost focus mid-drag - so it ends the gesture
/// rather than leaving the pointer captured forever.
pub fn gutterGesture(self: *Model, ev: key_mod.Mouse) bool {
    if (self.click.gutter) {
        if (ev.btn == 35) {
            self.click.gutter = false;
            return false;
        }
        if (!ev.down) {
            self.click.gutter = false;
            return true;
        }
        if (ev.btn == 32 or ev.btn == 0) {
            seek(self, ev.y);
            return true;
        }
        return false;
    }
    if (!ev.down or ev.btn != 0) return false;
    if (!onGutter(self, ev)) return false;
    self.click.gutter = true;
    seek(self, ev.y);
    return true;
}

/// Is this press on the gutter? Only while a thumb is actually SHOWING: the
/// gutter fades out of a tail-parked viewport (scrollbar.zig), and a column
/// the user cannot see must not swallow a click on the text under it.
fn onGutter(self: *const Model, ev: key_mod.Mouse) bool {
    if (self.last_term_width < 2) return false;
    const x: usize = if (ev.x > 0) ev.x - 1 else 0;
    if (x != self.last_term_width - 1) return false;
    const y: usize = if (ev.y > 0) ev.y - 1 else 0;
    if (y < self.band.top or y >= self.band.top + self.band.len) return false;
    return scrollbar.current(self) != null;
}

/// Put the viewport where the pointer is pointing.
///
/// The thumb is CENTRED on the row under the pointer, the way a browser's is:
/// grabbing it anywhere and dragging then moves it by the number of rows the
/// pointer moved, instead of snapping its top edge under the cursor.
///
/// The arithmetic runs in the scrollbar's own coordinates - `band.off` lines
/// above the viewport, out of `band.total` - and comes back through the one
/// door every other scroll uses (`keys.scrollBy`), so the fade clock, the
/// follow latch and the hover drop are wound exactly once, here as anywhere.
fn seek(self: *Model, row1: u16) void {
    const b = self.band;
    if (!b.live or b.len == 0 or b.total <= b.len) return;
    const t = scrollbar.current(self) orelse return;
    const y: usize = if (row1 > 0) row1 - 1 else 0;
    const in_track = std.math.clamp(y, b.top, b.top + b.len - 1) - b.top;
    const span = b.len - t.len; // rows the thumb's TOP can take
    const max_off = b.total - b.len;
    const want_top = @min(in_track -| t.len / 2, span);
    const off = if (span == 0) max_off else (want_top * max_off + span / 2) / span;
    // `scroll` counts from the BOTTOM, `off` from the top; the sticky header
    // occludes rows the scroll never reaches, so the achievable maximum falls
    // short of `max_off` by exactly those rows (render.zig).
    const target = @min(max_off - off, b.total -| (b.len + self.sticky_rows));
    if (target == self.scroll) return;
    const d: i64 = @as(i64, @intCast(target)) - @as(i64, @intCast(self.scroll));
    @import("keys.zig").scrollBy(self, std.math.lossyCast(i32, d));
}

// ---------------------------------------------------------------- the lists

/// A press that reached the click layer: the wheel, the drag and the image
/// card have all already declined it, and it is a left-button DOWN report.
/// Returns the effect when a list answered it, else null - and null is what
/// keeps every pre-existing meaning of a press intact.
pub fn press(self: *Model, ev: key_mod.Mouse) ?Effect {
    const y: usize = if (ev.y > 0) ev.y - 1 else 0;
    if (self.overlay == .none) return slashPress(self, y);
    if (self.overlay == .image) return null; // a card, not a panel
    return overlayPress(self, y);
}

/// The list item on screen row `y` of an open overlay, or null. Shared with
/// hover.zig so the tint and the click cannot disagree about what a row is.
pub fn overlayRowAt(self: *const Model, y: usize) ?usize {
    const span = overlays.rowSpan(self) orelse return null;
    if (y < self.mid_origin or y >= self.prompt_origin) return null;
    const line = (y - self.mid_origin) + self.mid_skip;
    if (line < span.line0 or line >= span.line0 + span.rows) return null;
    return span.first + (line - span.line0);
}

/// A press with a list overlay up. Inside the panel it picks a row or does
/// nothing; OUTSIDE it - the backdrop under a short panel, the top bar, the
/// composer - it declines, and the press closes the overlay exactly as it
/// always has (keys.zig), which is the click-outside-to-dismiss half.
fn overlayPress(self: *Model, y: usize) ?Effect {
    // An overlay with no list (help, the observability HUD, the rewind
    // prompt) has no rows to pick and keeps its click-anywhere dismissal.
    _ = overlays.rowSpan(self) orelse return null;
    if (y < self.mid_origin or y >= self.prompt_origin) return null;
    const line = (y - self.mid_origin) + self.mid_skip;
    if (line >= self.mid_total) return null; // padding below a short panel
    const item = overlayRowAt(self, y) orelse return .stay; // title, footer: inert
    return overlays.clickRow(self, item);
}

/// A press on the slash completion menu, which sits at the TOP of the bottom
/// block - the rows `prompt_origin` names before the composer box starts. Same
/// select-then-confirm rule as an overlay list.
fn slashPress(self: *Model, y: usize) ?Effect {
    if (self.slash_rows == 0) return null;
    if (y < self.prompt_origin or y >= self.prompt_origin + self.slash_rows) return null;
    const w = chrome.slashWindow(self) orelse return null;
    // The menu is a PANEL: its first line is a border, its last is another,
    // and a windowed list spends one more on the "N below" row. Work in block
    // lines, not screen rows. A short terminal trims the bottom block from the
    // TOP (render.zig), so the first line still on screen is not line 0.
    const trimmed = w.lines -| self.slash_rows;
    const line = (y - self.prompt_origin) + trimmed;
    if (line < w.line0 or line >= w.line0 + w.show) return null; // an edge
    const item = w.first + (line - w.line0);
    if (item >= w.n) return null;
    if (@min(self.slash_sel, w.n - 1) != item) {
        self.slash_sel = item;
        return .stay;
    }
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(self.input.getValue(), &idx);
    if (n == 0 or item >= n) return .stay;
    const pick = catalog.items[idx[item]];
    self.input.setValue("") catch {};
    return dispatch.runCommand(self, pick.name);
}

test {
    // The tests live next door so this file stays under the ceiling. Without
    // this reference they compile for nobody and silently never run.
    _ = @import("click_tests.zig");
}
