//! Overlay key routing + activation (palette, theme, model, effort, settings,
//! rewind, @-file picker, /jump). Split from keys.zig for the line budget.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const dispatch = @import("dispatch.zig");
const engine = @import("engine.zig");
const files_mod = @import("files.zig");
const theme_mod = @import("theme.zig");
const Key = @import("key.zig").Key;
const Model = app.Model;
const Effect = app.Effect;

pub fn key(self: *Model, k: Key) Effect {
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
    if (k == .enter) return activate(self);
    if (self.overlay == .model or self.overlay == .effort or self.overlay == .file) {
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

/// Load the session file list once, then open the @-picker.
pub fn openFiles(self: *Model) void {
    if (self.files_cache == null) {
        if (engine.g_files_fn) |f| self.files_cache = f(engine.g_turn_ctx, self.alloc);
    }
    self.openOverlay(.file);
}

fn activate(self: *Model) Effect {
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
