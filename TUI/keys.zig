//! Grok Build key bindings. Returns Effect — no zigzag Cmd.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const dispatch = @import("dispatch.zig");
const scrollback = @import("scrollback.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const theme_mod = @import("theme.zig");
const turn = @import("turn.zig");
const Key = key_mod.Key;
const Model = app.Model;
const Effect = app.Effect;

pub fn handle(self: *Model, k: Key) Effect {
    if (k == .ignore) return .stay;
    if (@import("nav.zig").handle(self, k)) |e| return e;
    // Job-control wins overlays so Ctrl+C always does something.
    if (isCtrl(k, 'c')) return ctrlC(self);
    if (k == .undo or isCtrl(k, 'z')) {
        if (self.input.undo()) self.setToast("undone");
        return .stay;
    }
    if (k == .mouse) return mouseKey(self, k.mouse);
    if (k == .paste_start) {
        self.pasting = true;
        self.focus = .prompt;
        return .stay;
    }
    if (k == .paste_end) {
        self.pasting = false;
        const v = std.mem.trim(u8, self.input.getValue(), " \t\r\n");
        if (@import("image.zig").attachDropped(self, v)) {
            self.input.setValue("") catch {};
        }
        return .stay;
    }
    if (self.pasting) {
        switch (k) {
            .enter => self.input.handle(.{ .char = '\n' }),
            .char => |c| self.input.handle(.{ .char = c }),
            else => {},
        }
        return .stay;
    }

    if (self.overlay != .none) return overlayKey(self, k);
    if (slashOpen(self) and slashKey(self, k)) return .stay;

    if (k == .escape) return esc(self);
    if (isCtrl(k, 'p') or (isChar(k, '?') and std.mem.trim(u8, self.input.getValue(), " \t").len == 0)) {
        self.openOverlay(.palette);
        return .stay;
    }
    if (isCtrl(k, 'x') or k == .f1) {
        self.openOverlay(.help);
        return .stay;
    }
    if (k == .f2) {
        self.openOverlay(.settings);
        return .stay;
    }
    if (k == .shift_tab) {
        self.cycleMode();
        return .stay;
    }
    if (k == .tab) {
        self.focus = if (self.focus == .prompt) .scrollback else .prompt;
        return .stay;
    }
    if (isCtrl(k, 'o')) {
        self.mode = if (self.mode == .always_approve) .normal else .always_approve;
        self.setToast(self.modeLabel());
        return .stay;
    }
    if (isCtrl(k, 'm')) {
        self.multiline = !self.multiline;
        return .stay;
    }
    if (k == .page_up) {
        scrollBy(self, @intCast(pageSize(self)));
        return .stay;
    }
    if (k == .page_down) {
        scrollBy(self, -@as(i32, @intCast(pageSize(self))));
        return .stay;
    }
    if (isCtrl(k, 'r')) {
        dispatch.recallPrev(self);
        return .stay;
    }
    if (isCtrl(k, 'v')) {
        dispatch.pasteClipboard(self);
        return .stay;
    }
    if (self.focus == .scrollback) return scrollbackKey(self, k);
    return promptKey(self, k);
}

fn promptKey(self: *Model, k: Key) Effect {
    if (k == .shift_enter) {
        self.input.handle(.{ .char = '\n' });
        return .stay;
    }
    if (k == .enter) {
        if (self.pasting or self.multiline) {
            self.input.handle(.{ .char = '\n' });
            return .stay;
        }
        if (self.pending != null) {
            turn.steerEnter(self);
            return .stay;
        }
        const effect = dispatch.applyLine(self, self.input.getValue());
        self.input.setValue("") catch {};
        return effect;
    }
    if (k == .up or k == .down) {
        if (self.hist_idx != null) {
            if (k == .up) dispatch.recallPrev(self) else dispatch.recallNext(self);
            return .stay;
        }
        if (std.mem.trim(u8, self.input.getValue(), " \t").len == 0) {
            scrollBy(self, if (k == .up) 3 else -3);
            return .stay;
        }
    }
    self.input.handle(k);
    return .stay;
}

fn pageSize(self: *const Model) u32 {
    const h = self.last_term_height;
    const room = if (h > 8) h - 6 else 3;
    return @intCast(@max(room, 3));
}

pub fn scrollBy(self: *Model, delta: i32) void {
    if (delta > 0) {
        self.scroll +|= @as(usize, @intCast(delta));
        self.follow = false;
        return;
    }
    const down: usize = @intCast(-delta);
    if (self.scroll <= down) {
        self.scroll = 0;
        self.follow = true;
    } else self.scroll -= down;
}

fn scrollbackKey(self: *Model, k: Key) Effect {
    const down = k == .down or (self.vim_mode and isChar(k, 'j'));
    const up = k == .up or (self.vim_mode and isChar(k, 'k'));
    if (down) {
        scrollBy(self, -3);
        return .stay;
    }
    if (up) {
        scrollBy(self, 3);
        return .stay;
    }
    if (k == .left) {
        if (self.selected < self.history.items.len) self.toggleToolGroup(self.selected);
        return .stay;
    }
    if (k == .right or k == .enter) {
        if (self.selected < self.history.items.len and self.history.items[self.selected].kind == .tool) {
            self.toggleToolGroup(self.selected);
            return .stay;
        }
        if (k == .enter or (self.vim_mode and isChar(k, 'i'))) {
            self.focus = .prompt;
        }
        return .stay;
    }
    if (!self.vim_mode) {
        if (k == .char or k == .ctrl) {
            self.focus = .prompt;
            return promptKey(self, k);
        }
    }
    return .stay;
}

fn lastToolIdx(self: *const Model) ?usize {
    var i = self.history.items.len;
    while (i > 0) {
        i -= 1;
        if (self.history.items[i].kind == .tool) return i;
    }
    return null;
}

fn mouseKey(self: *Model, ev: key_mod.Mouse) Effect {
    if (ev.btn == 64) {
        scrollBy(self, 3);
        return .stay;
    }
    if (ev.btn == 65) {
        scrollBy(self, -3);
        return .stay;
    }
    if (@import("image.zig").mouse(self, ev)) return .stay;
    if (!ev.down or ev.btn != 0) return .stay;
    if (self.overlay != .none) {
        self.closeOverlay();
        return .stay;
    }
    const y: usize = if (ev.y > 0) ev.y - 1 else 0;
    if (y >= self.prompt_origin) {
        self.focus = .prompt;
        return .stay;
    }
    if (y < self.mid_origin) return .stay;
    const vis = y - self.mid_origin + self.mid_skip;
    const idx = scrollback.indexAtVisual(self, vis, self.last_term_width) orelse lastToolIdx(self);
    self.focus = .scrollback;
    if (idx) |i| {
        self.selected = i;
        if (self.history.items[i].kind == .tool) self.toggleToolGroup(i);
    }
    return .stay;
}

fn overlayKey(self: *Model, k: Key) Effect {
    if (@import("image.zig").key(self, k)) return .stay;
    if (k == .escape) {
        self.closeOverlay();
        return .stay;
    }
    if (k == .up) {
        self.overlay_sel -|= 1;
        return .stay;
    }
    if (k == .down) {
        self.overlay_sel += 1;
        return .stay;
    }
    if (k == .enter) return activateOverlay(self);
    if (self.overlay == .model or self.overlay == .effort) {
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

fn activateOverlay(self: *Model) Effect {
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
            var names: [models.max_models][]const u8 = undefined;
            const n = models.filterModels(engine.g_models, self.overlay_filter, &names);
            const sel = if (n == 0) 0 else self.overlay_sel % n;
            self.closeOverlay();
            if (n == 0) return .stay;
            const pick = names[sel];
            if (engine.g_model_fn) |f| {
                if (f(engine.g_turn_ctx, self.alloc, pick)) |nm| {
                    engine.g_model_name = nm;
                    self.setToast(nm);
                } else self.setToast("couldn't switch");
            } else {
                engine.g_model_name = pick;
                self.setToast(pick);
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
        else => self.closeOverlay(),
    }
    return .stay;
}

fn slashOpen(self: *const Model) bool {
    const v = self.input.getValue();
    return self.focus == .prompt and v.len > 0 and v[0] == '/';
}

fn slashKey(self: *Model, k: Key) bool {
    if (k == .down) {
        self.slash_sel += 1;
        return true;
    }
    if (k == .up) {
        self.slash_sel -|= 1;
        return true;
    }
    if (k == .tab or k == .enter) {
        var idx: [catalog.items.len]usize = undefined;
        const n = catalog.filter(self.input.getValue(), &idx);
        if (n == 0) return false;
        const pick = catalog.items[idx[@min(self.slash_sel, n - 1)]];
        if (k == .tab) {
            self.input.setValue(pick.name) catch {};
            return true;
        }
        self.input.setValue("") catch {};
        _ = dispatch.runCommand(self, pick.name);
        return true;
    }
    return false;
}

fn esc(self: *Model) Effect {
    if (slashOpen(self)) {
        self.input.setValue("") catch {};
        return .stay;
    }
    if (self.pending != null) {
        turn.cancelTurn(self);
        self.setToast("cancelled");
        return .stay;
    }
    const empty = std.mem.trim(u8, self.input.getValue(), " \t\r\n").len == 0;
    if (!empty) {
        if (self.esc_arm == .clear and self.now_ms <= self.esc_until_ms) {
            self.input.setValue("") catch {};
            self.esc_arm = .none;
            self.setToast("cleared");
        } else {
            self.esc_arm = .clear;
            self.esc_until_ms = self.now_ms + app.ESC_MS;
            self.setToast("press again to clear");
        }
        return .stay;
    }
    if (self.userTurnCount() > 0) {
        if (self.esc_arm == .rewind and self.now_ms <= self.esc_until_ms) {
            self.esc_arm = .none;
            self.openOverlay(.rewind);
        } else {
            self.esc_arm = .rewind;
            self.esc_until_ms = self.now_ms + app.ESC_MS;
        }
    }
    return .stay;
}

fn ctrlC(self: *Model) Effect {
    if (self.pending != null and !self.cancel_requested) {
        turn.cancelTurn(self);
        self.setToast("cancelled — Ctrl+C again to quit");
        return .stay;
    }
    return .quit;
}

fn isCtrl(k: Key, c: u8) bool {
    return switch (k) {
        .ctrl => |x| x == c,
        else => false,
    };
}

fn isChar(k: Key, c: u8) bool {
    return switch (k) {
        .char => |x| x == c,
        else => false,
    };
}

test "Esc on a draft arms clear, second press clears" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.now_ms = 1000;
    m.input.setValue("draft") catch {};
    _ = esc(&m);
    try std.testing.expectEqual(app.EscArm.clear, m.esc_arm);
    try std.testing.expectEqualStrings("draft", m.input.getValue());
    m.now_ms = 1200;
    _ = esc(&m);
    try std.testing.expectEqualStrings("", m.input.getValue());
}

test "Ctrl+C quits when idle" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(Effect.quit, handle(&m, .{ .ctrl = 'c' }));
    try m.input.setValue("ab");
    _ = handle(&m, .{ .char = 'x' });
    try std.testing.expectEqual(Effect.stay, handle(&m, .{ .ctrl = 'z' }));
    try std.testing.expectEqualStrings("ab", m.input.getValue());
}

test "Tab toggles focus" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(app.Focus.prompt, m.focus);
    _ = handle(&m, .tab);
    try std.testing.expectEqual(app.Focus.scrollback, m.focus);
    _ = handle(&m, .tab);
    try std.testing.expectEqual(app.Focus.prompt, m.focus);
}

test "Shift+Tab cycles Normal Plan Always-approve" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(app.AgentMode.normal, m.mode);
    _ = handle(&m, .shift_tab);
    try std.testing.expectEqual(app.AgentMode.plan, m.mode);
    _ = handle(&m, .shift_tab);
    try std.testing.expectEqual(app.AgentMode.always_approve, m.mode);
    _ = handle(&m, .shift_tab);
    try std.testing.expectEqual(app.AgentMode.normal, m.mode);
}

test "model overlay Enter picks the selected name" {
    engine.g_models = "grok-4, gpt-5.5";
    engine.g_model_name = "grok-4";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
        engine.g_model_fn = null;
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    m.overlay_sel = 1;
    _ = handle(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("gpt-5.5", engine.g_model_name);
}

test "model overlay type-to-search picks the filtered name" {
    engine.g_models = "grok-4, gpt-5.5, deepseek-v4-pro";
    engine.g_model_name = "grok-4";
    defer {
        engine.g_models = "";
        engine.g_model_name = "";
        engine.g_model_fn = null;
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    _ = handle(&m, .{ .char = 'd' });
    _ = handle(&m, .{ .char = 'e' });
    _ = handle(&m, .{ .char = 'e' });
    try std.testing.expectEqualStrings("dee", m.overlay_filter);
    _ = handle(&m, .enter);
    try std.testing.expectEqual(app.Overlay.none, m.overlay);
    try std.testing.expectEqualStrings("deepseek-v4-pro", engine.g_model_name);
}

test "PgUp leaves follow; PgDn returns to the live tail" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_height = 24;
    try std.testing.expect(m.follow);
    _ = handle(&m, .page_up);
    try std.testing.expect(!m.follow);
    try std.testing.expect(m.scroll > 0);
    _ = handle(&m, .page_down);
    try std.testing.expect(m.follow);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
}

test "Cmd+Delete and Ctrl+U kill the draft, not the viewport" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_height = 24;
    try m.input.setValue("keep scrolling separate");
    m.input.cursor = m.input.getValue().len;
    _ = handle(&m, .delete_to_start);
    try std.testing.expectEqualStrings("", m.input.getValue());
    try std.testing.expect(m.follow);
    try m.input.setValue("word two");
    m.input.cursor = m.input.getValue().len;
    _ = handle(&m, .{ .ctrl = 'u' });
    try std.testing.expectEqualStrings("", m.input.getValue());
    try std.testing.expect(m.follow);
}

test "click on a folded tool row expands it" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.push(.tool, "⚙ bash");
    try m.push(.tool, "✓ bash");
    m.last_term_height = 24;
    m.last_term_width = 80;
    m.mid_origin = 1;
    m.mid_skip = 0;
    try std.testing.expect(m.history.items[1].folded);
    _ = handle(&m, .{ .mouse = .{ .btn = 0, .x = 4, .y = 3, .down = true } });
    try std.testing.expect(!m.history.items[1].folded);
}

test "empty Up scrolls transcript and keeps prompt focus" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_height = 24;
    try std.testing.expect(m.focus == .prompt);
    _ = handle(&m, .up);
    try std.testing.expect(!m.follow);
    try std.testing.expect(m.scroll > 0);
    try std.testing.expect(m.focus == .prompt);
    _ = handle(&m, .down);
    try std.testing.expect(m.follow);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
}

test "bracketed paste lands in the prompt as text" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.focus = .scrollback;
    _ = handle(&m, .paste_start);
    _ = handle(&m, .{ .char = 'h' });
    _ = handle(&m, .{ .char = 'i' });
    _ = handle(&m, .enter);
    _ = handle(&m, .{ .char = '!' });
    _ = handle(&m, .paste_end);
    try std.testing.expectEqualStrings("hi\n!", m.input.getValue());
    try std.testing.expect(m.focus == .prompt);
    try std.testing.expect(!m.pasting);
}

test "pasted image path becomes an attachment chip" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = handle(&m, .paste_start);
    for ("/tmp/pic.png") |c| _ = handle(&m, .{ .char = c });
    _ = handle(&m, .paste_end);
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
    try std.testing.expectEqualStrings("/tmp/pic.png", m.images.items[0]);
    try std.testing.expectEqualStrings("", m.input.getValue());
}

test "Ctrl+R walks prompt history" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.prompt_hist.append(try std.testing.allocator.dupe(u8, "older"));
    try m.prompt_hist.append(try std.testing.allocator.dupe(u8, "newer"));
    _ = handle(&m, .{ .ctrl = 'r' });
    try std.testing.expectEqualStrings("newer", m.input.getValue());
    _ = handle(&m, .up);
    try std.testing.expectEqualStrings("older", m.input.getValue());
}
