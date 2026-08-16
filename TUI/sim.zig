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
    inbuf: [4096]u8 = undefined,
    pending: usize = 0,

    pub fn init(self: *Term, alloc: std.mem.Allocator, cols: usize, rows: usize) void {
        self.alloc = alloc;
        self.cols = if (cols < 40) 80 else cols;
        self.rows = if (rows < 12) 24 else rows;
        self.now_ms = 0;
        self.last_effect = .stay;
        self.pending = 0;
        key_mod.resetInputState();
        self.model.setup(alloc);
    }

    pub fn deinit(self: *Term) void {
        self.model.deinit();
    }

    /// Raw Ghostty/xterm bytes. An incomplete sequence is CARRIED into the next
    /// feed, exactly like run.zig's pending buffer — dropping it here let a
    /// split CSI vanish, which is the one thing these harness tests exist to
    /// catch.
    pub fn feed(self: *Term, bytes: []const u8) Effect {
        const room = self.inbuf.len - self.pending;
        const take = @min(bytes.len, room);
        @memcpy(self.inbuf[self.pending .. self.pending + take], bytes[0..take]);
        const n = key_mod.joinOrphanHead(&self.inbuf, self.pending + take);
        var i: usize = 0;
        var last: Effect = .stay;
        while (key_mod.next(self.inbuf[0..n], &i)) |k| {
            last = keys.handle(&self.model, k);
            if (last != .stay) break;
        }
        self.pending = if (i < n) blk: {
            const rest = n - i;
            std.mem.copyForwards(u8, self.inbuf[0..rest], self.inbuf[i..n]);
            break :blk rest;
        } else 0;
        self.last_effect = last;
        return last;
    }

    /// The live loop gives up on a pending sequence that never finished: it
    /// carries the head for one more read, arms the debris sweeper, and — if
    /// the casualty was a bracketed-paste marker — synthesizes the paste_end
    /// the terminal never sent (run.zig's stall path).
    pub fn stallDropPending(self: *Term) void {
        if (self.pending == 0) return;
        key_mod.stashOrphanHead(self.inbuf[0..self.pending]);
        self.pending = 0;
        key_mod.armOrphan(true);
        if (key_mod.inPaste()) {
            key_mod.endPaste();
            _ = keys.handle(&self.model, .paste_end);
        }
    }

    /// run.zig's `paste_idle_ms` sweep: the terminal has gone quiet far longer
    /// than any paste keeps streaming, so the latch is force-closed. Anything
    /// still stuck mid-sequence belongs to the paste window this just declared
    /// broken — it is carried as DEBRIS and never handed back to the stall
    /// path, which would re-classify it as a key.
    pub fn idlePasteSweep(self: *Term) void {
        if (!key_mod.inPaste()) return;
        key_mod.endPaste();
        _ = keys.handle(&self.model, .paste_end);
        if (self.pending == 0) return;
        key_mod.stashOrphanHead(self.inbuf[0..self.pending]);
        self.pending = 0;
        key_mod.armOrphan(true);
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
    try term.model.pushTool(.{ .name = "bash" });
    try term.model.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
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
    try term.model.pushTool(.{ .name = "bash" });
    try term.model.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
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

test "a 1003 hover flood during a live turn never types itself into the frame" {
    const engine = @import("engine.zig");
    key_mod.armOrphan(false);
    defer key_mod.armOrphan(false);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.push(.user, "explain this");
    const job = try std.testing.allocator.create(engine.Job);
    defer std.testing.allocator.destroy(job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{},
        .threaded = false,
    };
    try term.model.push(.pending, "");
    term.model.pending = job;
    defer term.model.pending = null;

    // The exact bytes off the user's terminal: SGR motion reports under
    // ?1003h, arriving in ragged chunks while a slow frame paints, with the
    // loop giving up on the head that never finished.
    const flood = "\x1b[<39;7;32M\x1b[<39;4;32M\x1b[<39;3;33M\x1b[<39;1;33M";
    var cut: usize = 1;
    while (cut < flood.len) : (cut += 1) {
        _ = term.feed(flood[0..cut]);
        _ = term.feed(flood[cut..]);
        term.stallDropPending();
        _ = term.feed(flood);
    }
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 0), term.model.steer_queue.items.len);
    // A half-arrived report must not read as Escape either — that cancelled
    // the turn under the user.
    try std.testing.expect(!term.model.cancel_requested);
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "39;7;32M") == null);
    try std.testing.expect(std.mem.indexOf(u8, vis, ";32M") == null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "Enter:queue") != null);
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

test "a paste that never terminates does not wedge the composer (#536/#548)" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    // The terminator is lost in flight: `pasting` latches and swallows Enter,
    // Tab, the slash menu and every overlay — the 'TUI froze' report.
    _ = term.feed("\x1b[200~/help");
    try std.testing.expect(term.model.pasting);
    _ = term.press(.enter);
    try std.testing.expect(term.model.pasting);
    // Escape is the in-band hatch: it breaks the latch instead of vanishing.
    _ = term.press(.escape);
    try std.testing.expect(!term.model.pasting);
    try std.testing.expect(!key_mod.inPaste());
    // ...and the composer works again: Tab moves focus, Escape reaches esc().
    _ = term.press(.tab);
    try std.testing.expectEqual(app.Focus.scrollback, term.model.focus);
}

test "giving up on a split paste terminator closes the paste, tail and all (#532)" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.feed("\x1b[200~hello");
    _ = term.feed("\x1b[201");
    try std.testing.expect(key_mod.inPaste());
    term.stallDropPending(); // the loop waited the marker out
    try std.testing.expect(!key_mod.inPaste());
    try std.testing.expect(!term.model.pasting);
    // The late `~` rejoins its carried head instead of typing itself.
    _ = term.feed("~");
    try std.testing.expectEqualStrings("hello", term.model.input.getValue());
}

test "the idle paste sweep never fires a phantom Escape at a live turn" {
    const engine = @import("engine.zig");
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    defer key_mod.armOrphan(false);
    try term.model.push(.user, "!sleep 30");
    const job = try std.testing.allocator.create(engine.Job);
    defer std.testing.allocator.destroy(job);
    job.* = .{
        .gpa = std.testing.allocator,
        .history = &.{},
        .params = .{},
        .stream = .{},
        .threaded = false,
    };
    try term.model.push(.pending, "");
    term.model.pending = job;
    defer term.model.pending = null;

    // A paste opens, its terminator is cut in flight, and the ESC that opened
    // `CSI 201~` is left sitting in the pending buffer.
    _ = term.feed("\x1b[200~draft text");
    _ = term.feed("\x1b");
    try std.testing.expect(key_mod.inPaste());
    try std.testing.expectEqual(@as(usize, 1), term.pending);

    // Two seconds of quiet: the sweep closes the paste. The pending ESC must
    // go with it. Handing it back to the stall path re-classified it as the
    // Escape KEY the instant `in_paste` cleared, cancelling the live turn at
    // t=2.03s with no user keypress at all — and the same path wiped a
    // composer that had a draft in it.
    term.idlePasteSweep();
    try std.testing.expect(!key_mod.inPaste());
    try std.testing.expect(!term.model.pasting);
    try std.testing.expect(!term.model.cancel_requested);
    try std.testing.expectEqual(@as(usize, 0), term.pending);
    try std.testing.expectEqualStrings("draft text", term.model.input.getValue());

    // ...and the late terminator still rejoins its carried head rather than
    // typing `[201~` on the end of the draft.
    _ = term.feed("[201~");
    try std.testing.expectEqualStrings("draft text", term.model.input.getValue());
}
