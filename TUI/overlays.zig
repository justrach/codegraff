//! Overlay key routing + activation (palette, theme, model, effort, settings,
//! rewind, @-file picker, /jump). Split from keys.zig for the line budget.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const dispatch = @import("dispatch.zig");
const engine = @import("engine.zig");
const files_mod = @import("files.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Key = @import("key.zig").Key;
const Model = app.Model;
const Effect = app.Effect;

/// Overlays whose body is a SHEET rather than a list: there is no highlight to
/// move, so the arrows and the page keys scroll the body instead. keys.zig
/// routes every key here before it reaches its own page handling, so without
/// this a /help taller than the terminal had no way at all to show its second
/// half — the arrows only walked an `overlay_sel` nothing rendered.
fn scrolls(o: app.Overlay) bool {
    return o == .help or o == .debug;
}

fn page(self: *const Model) usize {
    const h = self.last_term_height;
    return @max(if (h > 8) h - 6 else 3, 3);
}

/// One step of the sheet, clamped to its end by the frame composer (render.zig
/// knows the row count; this does not).
fn scrollSheet(self: *Model, k: Key) bool {
    switch (k) {
        .up => self.overlay_scroll -|= 3,
        .down => self.overlay_scroll += 3,
        .page_up => self.overlay_scroll -|= page(self),
        .page_down => self.overlay_scroll += page(self),
        else => return false,
    }
    return true;
}

pub fn key(self: *Model, k: Key) Effect {
    if (@import("image.zig").key(self, k)) return .stay;
    if (k == .escape) {
        self.closeOverlay();
        return .stay;
    }
    if (scrolls(self.overlay) and scrollSheet(self, k)) return .stay;
    if (k == .up) {
        self.overlay_sel -|= 1;
        return .stay;
    }
    if (k == .down) {
        self.overlay_sel += 1;
        return .stay;
    }
    if (k == .enter) return activate(self);
    if (self.overlay == .model or self.overlay == .effort or self.overlay == .file or self.overlay == .resume_pick) {
        switch (k) {
            .char => |c| self.typeOverlayFilter(c),
            .backspace => self.backspaceOverlayFilter(),
            else => {},
        }
        return .stay;
    }
    if (self.overlay == .palette or self.overlay == .theme) {
        self.input.handle(k);
    }
    return .stay;
}

/// One wheel notch moves the highlighted row of an open list by EXACTLY one
/// item — the same step the arrow keys take, so a trackpad that emits a burst
/// of notches walks the list one row per notch instead of skipping three at a
/// time (the transcript's scroll step) or scrolling the transcript out from
/// under the picker, which is what the wheel used to do here. Returns true when
/// a list consumed the event.
pub fn wheel(self: *Model, up: bool) bool {
    // The image card is a preview above the composer, not a list; it keeps its
    // own key handling and the transcript keeps the wheel.
    if (self.overlay != .none and self.overlay != .image) {
        // A sheet scrolls; only a LIST has a highlight for a notch to move.
        if (scrolls(self.overlay)) {
            if (up) self.overlay_scroll -|= 1 else self.overlay_scroll += 1;
        } else if (up) self.overlay_sel -|= 1 else self.overlay_sel += 1;
        return true;
    }
    const v = self.input.getValue();
    if (self.focus != .prompt or v.len == 0 or v[0] != '/') return false;
    if (up) {
        self.slash_sel -|= 1;
        return true;
    }
    // Clamped exactly as the Down key is: the highlight and the row Enter
    // fires can never diverge onto an invisible command (#522).
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter(v, &idx);
    if (n > 0 and self.slash_sel + 1 < n) self.slash_sel += 1;
    return true;
}

// ------------------------------------------------------------- row geometry

/// Where an open list overlay's ROWS sit inside its own composed body, in body
/// lines. render.zig lays that body out exactly like the transcript - screen
/// row `mid_origin + k` shows body line `mid_skip + k` - so this plus those two
/// numbers is the whole row map a click needs.
///
/// Every overlay is a PANEL now (panel.zig): its name and its tally ride in the
/// top edge and its keys in the bottom one, so the body a list composes is its
/// rows and nothing else, and the frame contributes exactly one line above them.
/// That is why `line0` is the same for all of them - the per-overlay header
/// shapes this used to track no longer exist. The panel also CLIPS every row to
/// its inner width instead of wrapping, which is what keeps one item on one
/// line and lets this map be arithmetic rather than a second pass over bytes.
pub const Span = struct {
    /// Body line of the first row drawn.
    line0: usize,
    /// Item index that row shows - a windowed list starts partway down.
    first: usize,
    /// Rows drawn.
    rows: usize,
    /// Items in the FILTERED list, which is what `overlay_sel` indexes.
    total: usize,
};

/// The panel's top edge, and the only reason `line0` is not zero.
const frame_rows: usize = 1;

pub fn rowSpan(self: *const Model) ?Span {
    const models = @import("models.zig");
    const effort_mod = @import("effort.zig");
    // Too narrow to frame is too narrow to CLIP: panel.zig hands the body back
    // untouched, the rows wrap, and one item stops being one line. Nothing is
    // clickable at that width rather than the wrong thing being.
    if (self.last_term_width < panel.min_width) return null;
    switch (self.overlay) {
        .palette => {
            var idx: [catalog.items.len]usize = undefined;
            const n = catalog.filter(self.input.getValue(), &idx);
            const show = @min(n, @as(usize, 12));
            if (show == 0) return null;
            return .{ .line0 = frame_rows, .first = 0, .rows = show, .total = show };
        },
        .theme => return .{ .line0 = frame_rows, .first = 0, .rows = theme_mod.all.len, .total = theme_mod.all.len },
        .settings => return .{ .line0 = frame_rows, .first = 0, .rows = 4, .total = 4 },
        .jump => {
            const total = self.userTurnCount();
            if (total == 0) return null;
            return .{ .line0 = frame_rows, .first = 0, .rows = total, .total = total };
        },
        .effort => {
            var buf: [effort_mod.all.len]engine.Effort = undefined;
            const n = effort_mod.filter(self.overlay_filter, &buf);
            if (n == 0) return null;
            return .{ .line0 = frame_rows, .first = 0, .rows = n, .total = n };
        },
        .model => {
            var rows: [models.max_models]engine.ModelEntry = undefined;
            const n = models.filterModels(engine.g_model_entries, self.overlay_filter, &rows);
            if (n == 0) return null;
            return windowed(frame_rows, n, self.overlay_sel % n, models.visible_rows);
        },
        .file => {
            var names: [files_mod.max_files][]const u8 = undefined;
            const n = files_mod.filterList(self.files_cache orelse "", self.overlay_filter, &names);
            if (n == 0) return null;
            return windowed(frame_rows, n, self.overlay_sel % n, files_mod.visible_rows);
        },
        .resume_pick => {
            const pick = @import("resume.zig");
            var rows: [pick.max_rows]pick.Row = undefined;
            const n = pick.filterRows(self.sessions_cache orelse "", self.overlay_filter, &rows);
            if (n == 0) return null;
            return windowed(frame_rows, n, self.overlay_sel % n, pick.visible_rows);
        },
        else => return null,
    }
}

/// The scrolling window the searchable pickers draw: `vis` rows that follow the
/// highlight, so it is always on screen and always the row Enter fires.
fn windowed(line0: usize, n: usize, sel: usize, vis_max: usize) Span {
    const vis = @min(vis_max, n);
    const off = if (sel >= vis) sel - vis + 1 else 0;
    return .{ .line0 = line0, .first = off, .rows = @min(vis, n - off), .total = n };
}

/// A click landed on item `item`. The first click on a row moves the highlight
/// there; a click on the row that already carries it CONFIRMS, exactly as
/// Enter does. Those two halves are also what make a double click a confirm,
/// without a second copy of hover.zig's double-click window.
pub fn clickRow(self: *Model, item: usize) Effect {
    const span = rowSpan(self) orelse return .stay;
    if (item >= span.total) return .stay;
    if (self.overlay_sel % span.total == item) return activate(self);
    self.overlay_sel = item;
    return .stay;
}

/// Open the @-picker immediately and load the session file list in the
/// background. Loading it inline blocked the render+input thread for up to the
/// runCapped 10s cap on the first @ of a session (#533).
pub fn openFiles(self: *Model) void {
    if (self.files_cache == null and engine.g_files_fn != null) {
        _ = @import("bgop.zig").start(self, .files, &.{}, "", "");
    }
    self.openOverlay(.file);
}

pub fn activate(self: *Model) Effect {
    switch (self.overlay) {
        .palette => {
            var idx: [catalog.items.len]usize = undefined;
            const n = catalog.filter(self.input.getValue(), &idx);
            if (n == 0) return .stay;
            const pick = catalog.items[idx[@min(self.overlay_sel, n - 1)]];
            self.closeOverlay();
            self.input.setValue("") catch {};
            return dispatch.runCommand(self, pick.name);
        },
        .theme => {
            const id: theme_mod.Id = @enumFromInt(self.overlay_sel % theme_mod.all.len);
            self.theme_id = id;
            self.closeOverlay();
            self.setToast(id.label());
        },
        .rewind => {
            self.closeOverlay();
            dispatch.rewind(self);
        },
        .model => {
            const models = @import("models.zig");
            var rows: [models.max_models]engine.ModelEntry = undefined;
            const n = models.filterModels(engine.g_model_entries, self.overlay_filter, &rows);
            const sel = if (n == 0) 0 else self.overlay_sel % n;
            self.closeOverlay();
            if (n == 0) return .stay;
            // THE row the user chose, provider and all. Handing the engine the
            // name alone let it re-route by first-name-match, so picking the
            // openai row for a model codex also serves landed on codex.
            const pick = rows[sel];
            if (engine.g_model_fn) |f| {
                if (f(engine.g_turn_ctx, self.alloc, pick.provider, pick.name)) |got| {
                    self.adoptModel(got);
                    self.setToast(got.model);
                    self.pushFmt(.system, "model → {s} · {s}", .{ got.model, got.provider }) catch {};
                } else self.setToast("couldn't switch");
            } else {
                engine.g_model_name = pick.name;
                engine.g_model_provider = pick.provider;
                self.setToast(pick.name);
            }
        },
        .effort => {
            if (@import("effort.zig").pick(self)) |e| {
                self.effort = e;
                self.setToast(@tagName(e));
            }
            self.closeOverlay();
        },
        .settings => {
            const which = self.overlay_sel % 4;
            switch (which) {
                0 => self.openOverlay(.model),
                1 => {
                    self.openOverlay(.effort);
                    self.overlay_sel = @intFromEnum(self.effort);
                },
                2 => self.cycleMode(),
                else => self.openOverlay(.theme),
            }
        },
        .file => {
            var names: [files_mod.max_files][]const u8 = undefined;
            const n = files_mod.filterList(self.files_cache orelse "", self.overlay_filter, &names);
            const sel = if (n == 0) 0 else self.overlay_sel % n;
            self.closeOverlay();
            if (n == 0) return .stay;
            // names point into files_cache, which closeOverlay leaves alone.
            self.input.insertSlice(names[sel]);
            self.input.handle(.{ .char = ' ' });
            self.focus = .prompt;
        },
        .resume_pick => @import("resume.zig").pick(self),
        .jump => {
            const total = self.userTurnCount();
            const sel = if (total == 0) 0 else self.overlay_sel % total;
            self.closeOverlay();
            if (total == 0) return .stay;
            var seen: usize = 0;
            for (self.history.items, 0..) |e, i| {
                if (e.kind != .user) continue;
                if (seen == sel) {
                    @import("nav.zig").jumpTo(self, i);
                    break;
                }
                seen += 1;
            }
        },
        else => self.closeOverlay(),
    }
    return .stay;
}

/// One SGR wheel report. 64 is a notch up, 65 a notch down.
fn notch(m: *Model, up: bool) void {
    _ = @import("keys.zig").handle(m, .{ .mouse = .{ .btn = if (up) 64 else 65, .x = 10, .y = 5, .down = true } });
}

test "a wheel notch moves an open picker by exactly one item" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    // Four notches down is four items — not twelve, and not one coalesced move.
    // A trackpad delivers a flick as a BURST of reports and run.zig hands every
    // one of them to keys.handle, so the per-event step is the whole contract.
    for (0..4) |i| {
        try std.testing.expectEqual(i, m.overlay_sel);
        notch(&m, false);
    }
    try std.testing.expectEqual(@as(usize, 4), m.overlay_sel);
    for (0..4) |_| notch(&m, true);
    try std.testing.expectEqual(@as(usize, 0), m.overlay_sel);
    notch(&m, true); // already at the top: saturates, never wraps to a huge index
    try std.testing.expectEqual(@as(usize, 0), m.overlay_sel);
    // ...and the transcript underneath never moved.
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
    try std.testing.expect(m.follow);
}

test "a wheel notch moves the completion menu one command, clamped to the list" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.focus = .prompt;
    try m.input.setValue("/");
    var idx: [catalog.items.len]usize = undefined;
    const n = catalog.filter("/", &idx);
    try std.testing.expect(n > 2);
    notch(&m, false);
    try std.testing.expectEqual(@as(usize, 1), m.slash_sel);
    notch(&m, false);
    try std.testing.expectEqual(@as(usize, 2), m.slash_sel);
    notch(&m, true);
    try std.testing.expectEqual(@as(usize, 1), m.slash_sel);
    // Spinning past the end parks on the last row rather than selecting a
    // command the menu is not showing.
    for (0..n + 8) |_| notch(&m, false);
    try std.testing.expectEqual(n - 1, m.slash_sel);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
}

test "with no list open the wheel still scrolls the transcript" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    notch(&m, true);
    try std.testing.expect(m.scroll > 0);
    try std.testing.expect(!m.follow);
    try std.testing.expectEqual(@as(usize, 0), m.overlay_sel);
}

test "file overlay Enter inserts the picked path after the @" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.files_cache = try std.testing.allocator.dupe(u8, "src/a.zig\ndocs/b.md");
    try m.input.setValue("look at @");
    m.openOverlay(.file);
    for ("bmd") |c| m.typeOverlayFilter(c);
    _ = key(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("look at @docs/b.md ", m.input.getValue());
}

test "jump overlay Enter selects the chosen user turn" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "one");
    try m.push(.assistant, "a");
    try m.push(.user, "two");
    try m.push(.assistant, "b");
    m.openOverlay(.jump);
    m.overlay_sel = 1;
    _ = key(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqual(@as(usize, 2), m.selected);
    try std.testing.expect(m.focus == .scrollback);
    try std.testing.expect(!m.follow);
}
