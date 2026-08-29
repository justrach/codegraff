//! Grok Build key bindings. Returns Effect — no zigzag Cmd.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const click = @import("click.zig");
const dispatch = @import("dispatch.zig");
const hover = @import("hover.zig");
const layout_cache = @import("layout_cache.zig");
const selection = @import("selection.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const theme_mod = @import("theme.zig");
const turn = @import("turn.zig");
const Key = key_mod.Key;
const Model = app.Model;
const Effect = app.Effect;

pub fn handle(self: *Model, k: Key) Effect {
    if (k == .ignore) return .stay;
    // Anything that is not part of the drag gesture drops the selection band
    // (#529). The OSC-11 polarity reply is the terminal talking, not the user.
    if (k != .mouse and k != .bg_report) {
        selection.clear(self);
        // A key can only arrive with the button up: a gutter drag whose
        // release went missing must not keep the pointer captured (click.zig).
        self.click.gutter = false;
    }
    if (@import("nav.zig").handle(self, k)) |e| return e;
    // Job-control wins overlays so Ctrl+C always does something.
    if (isCtrl(k, 'c')) return ctrlC(self);
    if (k == .undo or isCtrl(k, 'z')) {
        if (self.input.undo()) self.setToast("undone");
        return .stay;
    }
    if (k == .bg_report) {
        // Startup OSC 11 reply: adopt the terminal's polarity unless the user
        // explicitly picked a theme. Fixed palettes, 1-bit decision (grok).
        if (!self.theme_explicit) {
            const want: @import("theme.zig").Id = if (@import("theme.zig").classifyLight(k.bg_report[0], k.bg_report[1], k.bg_report[2])) .day else .night;
            self.theme_id = want;
        }
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
        key_mod.endPaste(); // the two latches must never drift apart
        const v = std.mem.trim(u8, self.input.getValue(), " \t\r\n");
        if (@import("image.zig").attachDropped(self, v)) {
            self.input.setValue("") catch {};
        }
        return .stay;
    }
    if (self.pasting) {
        switch (k) {
            .enter, .shift_enter => self.input.handle(.{ .char = '\n' }),
            .char => |c| self.input.handle(.{ .char = c }),
            .codepoint => self.input.handle(k),
            // In-band escape hatch. A paste whose `CSI 201~` never arrived
            // latches this branch forever, and it swallows Enter, Tab, the
            // slash menu and every overlay — indistinguishable from a hung
            // TUI. Escape breaks the latch instead of vanishing (#536/#548).
            .escape => {
                self.pasting = false;
                key_mod.endPaste();
                self.setToast("paste ended");
            },
            else => {},
        }
        return .stay;
    }

    if (self.overlay != .none) return @import("overlays.zig").key(self, k);
    if (slashOpen(self) and slashKey(self, k)) return .stay;
    if (isChar(k, '@') and self.focus == .prompt and !slashOpen(self)) {
        // Grok-style file mention: keep the typed @, open the fuzzy picker.
        self.input.handle(.{ .char = '@' });
        @import("overlays.zig").openFiles(self);
        return .stay;
    }

    if (isCtrl(k, 'd')) return ctrlD(self);
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
    if (k == .backspace and std.mem.trim(u8, self.input.getValue(), " \t").len == 0) {
        if (@import("image.zig").dropLast(self)) {
            self.setToast("image detached");
            return .stay;
        }
    }
    if ((k == .delete_to_start or isCtrl(k, 'u')) and self.images.items.len > 0) {
        @import("image.zig").clearAll(self);
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
    // The content slid out from under a pointer that never moved: the hovered
    // row now names a different entry, so the affordance is dropped and the
    // next motion report re-arms it.
    hover.scrolled(self);
    // Every door into the viewport comes through here — wheel, arrows, page
    // keys — so this is the one place the scrollbar's fade clock has to be
    // wound (scrollbar.zig). A tail-parked viewport shows the gutter for a
    // moment after the last movement and then lets it go.
    self.scroll_seen_ms = @max(self.now_ms, 1);
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
        if (k == .char or k == .codepoint or k == .ctrl) {
            self.focus = .prompt;
            return promptKey(self, k);
        }
    }
    return .stay;
}

/// Apply `notches` of wheel scroll. One report and a whole coalesced momentum
/// run go through the SAME door (pacing.zig folds consecutive reports into one
/// delta), so a storm can never mean something a single report does not.
pub fn wheelScroll(self: *Model, notches: i32) Effect {
    if (notches == 0) return .stay;
    // An open picker or the completion menu owns the wheel: one notch is one
    // ITEM there, never a scroll of the transcript underneath. A folded batch
    // carries N notches, so replay it one item at a time.
    var n = @abs(notches);
    if (@import("overlays.zig").wheel(self, notches > 0)) {
        while (n > 1) : (n -= 1) _ = @import("overlays.zig").wheel(self, notches > 0);
        return .stay;
    }
    // The band is anchored to screen rows, so scrolling it would slide it onto
    // other content — drop it and scroll.
    selection.clear(self);
    // An open picker or the completion menu owns the wheel: one notch is one
    // ITEM there, never a scroll of the transcript underneath. A coalesced run
    // steps once per notch, so a flick lands where the same notches typed
    // slowly would.
    const overlays = @import("overlays.zig");
    const up = notches > 0;
    if (overlays.wheel(self, up)) {
        var left: u32 = @as(u32, @intCast(@abs(notches))) -| 1;
        while (left > 0) : (left -= 1) _ = overlays.wheel(self, up);
        return .stay;
    }
    scrollBy(self, notches *| @import("pacing.zig").lines_per_notch);
    return .stay;
}

fn mouseKey(self: *Model, ev: key_mod.Mouse) Effect {
    if (@import("pacing.zig").wheelNotch(.{ .mouse = ev })) |n| return wheelScroll(self, n);
    // Pure motion under ?1003h: track the row so the frame can announce that it
    // is clickable. Never consumed — the image-chip preview reads it too.
    _ = hover.mouse(self, ev);
    // The scroll gutter owns its column BEFORE the selection can anchor there:
    // a press on the thumb is a scrollbar gesture and never a drag-copy.
    if (click.gutterGesture(self, ev)) return .stay;
    // A drag or its release belongs to the selection; a press only ANCHORS one
    // and falls through, so a plain click keeps its meaning (#529).
    if (selection.mouse(self, ev)) return .stay;
    if (@import("image.zig").mouse(self, ev)) return .stay;
    if (!ev.down or ev.btn != 0) return .stay;
    // An open list answers the press on its own row (click.zig). It declines
    // everything else, including the backdrop around a panel and every overlay
    // that has no rows to pick — those keep the dismissal below.
    if (click.press(self, ev)) |e| return e;
    if (self.overlay != .none) {
        self.closeOverlay();
        return .stay;
    }
    const y: usize = if (ev.y > 0) ev.y - 1 else 0;
    const x: usize = if (ev.x > 0) ev.x - 1 else 0;
    // Two presses on one cell inside the window. The FIRST is always today's
    // click, unchanged; the second replaces it rather than repeating it.
    const dbl = hover.press(self, y, x);
    if (y >= self.prompt_origin) {
        self.focus = .prompt;
        return .stay;
    }
    if (y < self.mid_origin) return .stay;
    // Sticky-header chrome occludes the top content rows — a click there must
    // not toggle whatever is hidden underneath it. A DOUBLE click on the pin
    // scrolls the prompt it is pinning back onto the screen.
    if (y < self.mid_origin + self.sticky_rows) {
        if (dbl) hover.jumpToSticky(self);
        return .stay;
    }
    const vis = y - self.mid_origin + self.mid_skip;
    self.focus = .scrollback;
    // A click on blank padding maps to no entry — it must not select or
    // toggle anything (#519).
    const i = layout_cache.indexAtVisual(self, vis, @import("inset.zig").wrapWidth(self)) orelse return .stay;
    self.selected = i;
    if (self.history.items[i].kind == .tool and !dbl) {
        // A double click is ONE net toggle of the whole group: the first press
        // already toggled it, so toggling again would only put it back and the
        // gesture would look like it did nothing at all.
        self.toggleToolGroup(i);
        // Remembered so the fold can be put back if this press turns out to be
        // the start of a drag — selecting text must not restructure the view.
        self.sel.undo_idx = i;
    }
    return .stay;
}

fn slashOpen(self: *const Model) bool {
    const v = self.input.getValue();
    return self.focus == .prompt and v.len > 0 and v[0] == '/';
}

fn slashKey(self: *Model, k: Key) bool {
    if (k == .down) {
        // Clamp to the filtered list so the highlight and the Enter target
        // can never diverge onto an invisible command (#522).
        var idx: [catalog.items.len]usize = undefined;
        const n = catalog.filter(self.input.getValue(), &idx);
        if (n > 0 and self.slash_sel + 1 < n) self.slash_sel += 1;
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
    const empty = std.mem.trim(u8, self.input.getValue(), " \t\r\n").len == 0;
    // A draft in the composer outranks every interrupt. While a turn or
    // background op runs, the composer is the STEER channel — pressing Esc to
    // fix your wording must not abort the work in flight (observed live:
    // "✗ interrupted (esc)" right after steering text landed). Same armed
    // two-press flow as the idle path below: first Esc arms, second clears.
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
    if (self.bg != null) {
        // A background engine op (/compact, !cmd) is exactly as interruptible
        // as a turn now that it no longer blocks this thread (#533).
        @import("bgop.zig").cancel(self);
        self.setToast("cancelled");
        return .stay;
    }
    if (self.pending != null) {
        turn.cancelTurn(self);
        self.setToast("cancelled");
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

/// The line REPL advertises "ctrl-d quits" but the fullscreen TUI swallowed it
/// silently (#549). Empty composer quits, exactly like Ctrl+Q; with a draft in
/// hand it stays ignored, so a stray ^D can never throw work away.
fn ctrlD(self: *Model) Effect {
    if (std.mem.trim(u8, self.input.getValue(), " \t\r\n").len > 0) return .stay;
    return .quit;
}

fn ctrlC(self: *Model) Effect {
    if (self.bg) |op| {
        if (!op.cancelled) {
            @import("bgop.zig").cancel(self);
            self.setToast("cancelled — Ctrl+C again to quit");
            return .stay;
        }
    }
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

test {
    // The tests live next door (this file is at the line ceiling). Without this
    // reference they compile for nobody and silently never run.
    _ = @import("keys_tests.zig");
}
