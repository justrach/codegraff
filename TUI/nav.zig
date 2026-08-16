//! Grok-style turn jump, line scroll, new-session, quit.

const std = @import("std");
const app = @import("app.zig");
const key_mod = @import("key.zig");
const Key = key_mod.Key;
const Model = app.Model;
const Effect = app.Effect;

pub fn handle(self: *Model, k: Key) ?Effect {
    if (isCtrl(k, 'q')) return .quit;
    if (isCtrl(k, 'n')) {
        ctrlN(self);
        return .stay;
    }
    if (isCtrl(k, 'j')) {
        scrollLine(self, -1);
        return .stay;
    }
    if (isCtrl(k, 'k')) {
        scrollLine(self, 1);
        return .stay;
    }
    if (k == .prev_turn) {
        jumpTurn(self, -1);
        return .stay;
    }
    if (k == .next_turn) {
        jumpTurn(self, 1);
        return .stay;
    }
    return null;
}

fn scrollLine(self: *Model, delta: i32) void {
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

fn isCtrl(k: Key, c: u8) bool {
    return k == .ctrl and k.ctrl == c;
}

fn ctrlN(self: *Model) void {
    if (self.new_arm_until_ms != 0 and self.now_ms <= self.new_arm_until_ms) {
        self.newSession();
        self.new_arm_until_ms = 0;
        self.setToast("new session");
        return;
    }
    self.new_arm_until_ms = self.now_ms + 1000;
    self.setToast("press Ctrl+N again to start a new session");
}

/// Land the viewport on history entry `idx` (used by /jump).
pub fn jumpTo(self: *Model, idx: usize) void {
    self.selected = idx;
    self.focus = .scrollback;
    self.follow = false;
    const sb = @import("scrollback.zig");
    const width = if (self.last_term_width == 0) 80 else self.last_term_width;
    const total = sb.totalVisualLines(self, width);
    const at = sb.visualOfIndex(self, idx, width) orelse return;
    // prompt_origin - mid_origin includes the image-card rows render subtracts
    // from the transcript, and the sticky header occludes the top two viewport
    // rows — without both corrections /jump parked the target off-screen or
    // exactly under the pinned chrome (audit: the jumped-to turn was ALWAYS
    // hidden, with the PREVIOUS prompt pinned above it).
    const gross = if (self.prompt_origin > self.mid_origin) self.prompt_origin - self.mid_origin else 8;
    const view_h = gross -| self.preview_rows;
    if (total <= view_h) {
        self.scroll = 0;
        return;
    }
    const max_scroll = total - view_h;
    // Land the target at the row below the sticky slot (row 2) so it is the
    // first fully visible line; at the extremes fall back to the edges.
    const want = at -| 2;
    self.scroll = if (want >= max_scroll) 0 else max_scroll - want;
}

fn jumpTurn(self: *Model, dir: i32) void {
    if (self.history.items.len == 0) return;
    var i = self.selected;
    if (dir > 0) {
        i += 1;
        while (i < self.history.items.len) : (i += 1) {
            if (self.history.items[i].kind == .user) {
                self.selected = i;
                break;
            }
        }
    } else {
        while (i > 0) {
            i -= 1;
            if (self.history.items[i].kind == .user) {
                self.selected = i;
                break;
            }
        }
    }
    self.focus = .scrollback;
    self.follow = false;
}

test "Ctrl+N twice clears the session" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    m.now_ms = 10;
    _ = handle(&m, .{ .ctrl = 'n' });
    try std.testing.expect(m.history.items.len == 1);
    m.now_ms = 20;
    _ = handle(&m, .{ .ctrl = 'n' });
    try std.testing.expectEqual(@as(usize, 0), m.history.items.len);
}

test "Shift+arrows jump between user turns" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "one");
    try m.push(.assistant, "a");
    try m.push(.user, "two");
    m.selected = 2;
    _ = handle(&m, .prev_turn);
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    _ = handle(&m, .next_turn);
    try std.testing.expectEqual(@as(usize, 2), m.selected);
}

test "wheel keeps prompt focus" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.focus = .prompt;
    _ = @import("keys.zig").handle(&m, .{ .mouse = .{ .btn = 64, .x = 2, .y = 2, .down = true } });
    try std.testing.expect(m.focus == .prompt);
    try std.testing.expect(!m.follow);
    try std.testing.expect(m.scroll > 0);
}
