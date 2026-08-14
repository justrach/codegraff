//! Headless Ghostty-shaped pager. Agents drive this instead of a PTY.
//!
//! Same path the live app uses: `key.next` (CSI-u / SGR mouse / paste) →
//! `keys.handle` → `render` → `dump.visible`. No TTY, no Ghostty window.
//!
//!     var term: Term = undefined;
//!     term.init(alloc, 80, 24);
//!     defer term.deinit();
//!     _ = term.typeText("/help");
//!     _ = term.enter();
//!     const vis = try term.screen(); // glyphs a user would see
//!     _ = try term.clickText("Called");
//!
//! Ghostty wire bytes go through `feed`:
//!   click  ESC [ < 0 ; COL ; ROW M     (1-based cells)
//!   hover  ESC [ < 35 ; COL ; ROW M
//!   paste  ESC [ 200 ~  …  ESC [ 201 ~
//!   CSI-u  ESC [ unicode ; mods u      (Ctrl+P is ESC [ 112 ; 5 u)

const std = @import("std");
const app = @import("app.zig");
const dump = @import("dump.zig");
const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const render_mod = @import("render.zig");
const theme_mod = @import("theme.zig");

const Model = app.Model;
const Effect = app.Effect;
const Key = key_mod.Key;

pub const Hit = struct { x: u16, y: u16 };

pub const Term = struct {
    alloc: std.mem.Allocator,
    model: Model = undefined,
    cols: usize = 80,
    rows: usize = 24,
    now_ms: u64 = 0,
    last_effect: Effect = .stay,

    pub fn init(self: *Term, alloc: std.mem.Allocator, cols: usize, rows: usize) void {
        self.alloc = alloc;
        self.cols = if (cols < 40) 80 else cols;
        self.rows = if (rows < 12) 24 else rows;
        self.now_ms = 0;
        self.last_effect = .stay;
        self.model.setup(alloc);
    }

    pub fn deinit(self: *Term) void {
        self.model.deinit();
    }

    /// Raw Ghostty/xterm bytes. Incomplete CSI is left unconsumed (same as the live loop).
    pub fn feed(self: *Term, bytes: []const u8) Effect {
        var i: usize = 0;
        var last: Effect = .stay;
        while (key_mod.next(bytes, &i)) |k| {
            last = keys.handle(&self.model, k);
            if (last != .stay) break;
        }
        self.last_effect = last;
        return last;
    }

    pub fn press(self: *Term, k: Key) Effect {
        const last = keys.handle(&self.model, k);
        self.last_effect = last;
        return last;
    }

    pub fn typeText(self: *Term, s: []const u8) Effect {
        return self.feed(s);
    }

    pub fn enter(self: *Term) Effect {
        return self.feed("\r");
    }

    /// 1-based cell, left-button down — the SGR Ghostty sends for a click.
    pub fn clickAt(self: *Term, x: u16, y: u16) Effect {
        return self.sgr(0, x, y, true);
    }

    /// 1-based cell, any-motion (btn 35) — hover for image chips.
    pub fn hoverAt(self: *Term, x: u16, y: u16) Effect {
        return self.sgr(35, x, y, true);
    }

    fn sgr(self: *Term, btn: u16, x: u16, y: u16, down: bool) Effect {
        var buf: [40]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
            btn,
            if (x == 0) 1 else x,
            if (y == 0) 1 else y,
            @as(u8, if (down) 'M' else 'm'),
        }) catch return .stay;
        return self.feed(seq);
    }

    /// Paint, strip SGR, return the glyphs. Caller frees.
    pub fn screen(self: *Term) ![]u8 {
        const frame = try render_mod.render(&self.model, self.alloc, self.cols, self.rows, self.now_ms);
        defer self.alloc.free(frame);
        return dump.visible(self.alloc, frame);
    }

    /// `screen` with ` 12|` row prefixes so an agent can pick click coordinates.
    pub fn annotated(self: *Term) ![]u8 {
        const vis = try self.screen();
        defer self.alloc.free(vis);
        var out = std.array_list.Managed(u8).init(self.alloc);
        var y: u16 = 1;
        var it = std.mem.splitScalar(u8, vis, '\n');
        while (it.next()) |ln| : (y += 1) {
            var nbuf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&nbuf, "{d:3}|", .{y}) catch unreachable;
            try out.appendSlice(num);
            try out.appendSlice(ln);
            try out.append('\n');
        }
        return out.toOwnedSlice();
    }

    pub fn layout(self: *Term) ![]u8 {
        const frame = try render_mod.render(&self.model, self.alloc, self.cols, self.rows, self.now_ms);
        defer self.alloc.free(frame);
        return dump.layout(self.alloc, &self.model);
    }

    pub fn find(self: *Term, needle: []const u8) !?Hit {
        const vis = try self.screen();
        defer self.alloc.free(vis);
        return locate(vis, needle);
    }

    pub fn clickText(self: *Term, needle: []const u8) !bool {
        const hit = try self.find(needle) orelse return false;
        _ = self.clickAt(hit.x, hit.y);
        return true;
    }

    pub fn hoverText(self: *Term, needle: []const u8) !bool {
        const hit = try self.find(needle) orelse return false;
        _ = self.hoverAt(hit.x, hit.y);
        return true;
    }
};

/// 1-based cell of the middle glyph of the first `needle` on the dump.
pub fn locate(vis: []const u8, needle: []const u8) ?Hit {
    if (needle.len == 0) return null;
    var y: u16 = 1;
    var it = std.mem.splitScalar(u8, vis, '\n');
    while (it.next()) |ln| : (y += 1) {
        if (std.mem.indexOf(u8, ln, needle)) |at| {
            const prefix = theme_mod.visibleLen(ln[0..at]);
            const w = theme_mod.visibleLen(needle);
            const x: u16 = @intCast(prefix + 1 + w / 2);
            return .{ .x = if (x == 0) 1 else x, .y = y };
        }
    }
    return null;
}

test "typeText lands in the composer dump" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("hello");
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "›") != null);
}

test "clickText on Called expands the folded tools" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.assistant, "working");
    try term.model.push(.tool, "⚙ bash");
    try term.model.push(.tool, "✓ bash");
    const before = try term.screen();
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "Called") != null);
    try std.testing.expect(try term.clickText("Called"));
    try std.testing.expect(!term.model.history.items[1].folded);
    const after = try term.screen();
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "Called") == null);
}

test "feed Ghostty SGR click matches clickAt" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.assistant, "working");
    try term.model.push(.tool, "⚙ bash");
    try term.model.push(.tool, "✓ bash");
    const hit = try term.find("Called") orelse return error.NoCalled;
    var buf: [40]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[<0;{d};{d}M", .{ hit.x, hit.y });
    _ = term.feed(seq);
    try std.testing.expect(!term.model.history.items[0].folded);
}

test "type /help then enter opens the help overlay" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("/help");
    _ = term.enter();
    try std.testing.expectEqual(app.Overlay.help, term.model.overlay);
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "/quit") != null);
}

test "hoverText on an image chip opens the preview" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.user, "@[/tmp/shot.png] look");
    try std.testing.expect(try term.hoverText("[Image #1]"));
    try std.testing.expectEqual(app.Overlay.image, term.model.overlay);
    try std.testing.expectEqualStrings("/tmp/shot.png", term.model.preview_path);
}

test "annotated dump prefixes 1-based rows" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("abc");
    const ann = try term.annotated();
    defer std.testing.allocator.free(ann);
    try std.testing.expect(std.mem.indexOf(u8, ann, "  1|") != null);
    try std.testing.expect(std.mem.indexOf(u8, ann, "abc") != null);
}
