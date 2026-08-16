//! Compose one frame: top bar, welcome or scrollback, slash menu / overlay,
//! prompt box, status. Viewport math matches grok's "prompt pinned, history
//! scrolls".

const std = @import("std");

const app = @import("app.zig");
const chrome = @import("chrome.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const scrollback = @import("scrollback.zig");
const selection = @import("selection.zig");
const theme_mod = @import("theme.zig");
const welcome = @import("welcome.zig");
const Model = app.Model;

pub fn render(self: *Model, gpa: std.mem.Allocator, width: usize, height: usize, now_ms: u64) ![]const u8 {
    self.last_term_width = width;
    self.last_term_height = height;
    self.now_ms = now_ms;
    @import("turn.zig").drainEvents(self);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const top = try chrome.topBar(self, a, width);
    const image_card = if (self.overlay == .image)
        try chrome.overlay(self, a, width)
    else
        "";
    // The image overlay is a card ABOVE the composer, so `mid` stays the
    // transcript; every other overlay replaces it with its own body.
    const overlay_body = self.overlay != .none and self.overlay != .image;
    const mid = if (overlay_body)
        try chrome.overlay(self, a, width)
    else if (self.screen == .welcome and self.history.items.len == 0 and self.pending == null)
        // Anything in the transcript — including a live background op's
        // pending row — outranks the welcome pane: keeping it up hid a
        // running `!cmd`/@-list entirely and froze the paint loop (the
        // welcome frame is static, so the hash-diff suppressed every paint).
        try welcome.render(self, a, width)
    else
        try scrollback.render(self, a, width, now_ms);
    const slash = try chrome.slashMenu(self, a, width);
    const prompt = try chrome.promptBox(self, a, width);
    const status = try chrome.statusBar(self, a, width);

    var bottom = std.array_list.Managed(u8).init(a);
    if (slash.len > 0) {
        try bottom.appendSlice(slash);
        if (slash[slash.len - 1] != '\n') try bottom.append('\n');
    }
    try bottom.appendSlice(prompt);
    if (prompt.len == 0 or prompt[prompt.len - 1] != '\n') try bottom.append('\n');
    try bottom.appendSlice(status);

    const bottom_lines = countLines(bottom.items);
    const top_lines = countLines(top);
    // countLines counts a trailing '\n' as an extra line but the append below
    // adds no newline of its own — the off-by-one shifted the whole frame up
    // one row and broke composer clicks (prompt_origin pointed past the box).
    const card_lines = if (image_card.len == 0) 0 else countLines(image_card) - @intFromBool(image_card[image_card.len - 1] == '\n');
    self.preview_rows = card_lines;
    self.mid_origin = top_lines;
    self.prompt_origin = if (height > bottom_lines) height - bottom_lines else 0;
    const used = bottom_lines + top_lines + card_lines;
    const view_h: usize = if (height > used) height - used else 1;

    var mid_lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, mid, '\n');
    while (it.next()) |ln| try mid_lines.append(ln);
    if (mid_lines.items.len > 0 and mid_lines.items[mid_lines.items.len - 1].len == 0) _ = mid_lines.pop();

    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(top);
    if (top.len > 0 and top[top.len - 1] != '\n') try out.append('\n');

    const n = mid_lines.items.len;
    self.sticky_rows = 0;
    if (n <= view_h) {
        self.scroll = 0;
        self.mid_skip = 0;
        for (mid_lines.items) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
        }
        var pad: usize = view_h - n;
        while (pad > 0) : (pad -= 1) try out.append('\n');
    } else {
        const max_scroll = n - view_h;
        if (self.follow) self.scroll = 0;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const start = max_scroll - self.scroll;
        self.mid_skip = start;
        // grok sticky header (minimal single slot): once the last user prompt
        // scrolls past the viewport top, its first line stays pinned as row 0
        // with a blank separator row under it. The two chrome rows OCCLUDE the
        // two top content lines instead of shifting them, so the row↔line map
        // for everything below is unchanged and the bottom line stays put.
        var chrome_rows: usize = 0;
        // Only the transcript gets a pinned prompt. On an overlay screen `mid`
        // is the overlay's own body, and a long one (/help, /models) scrolls
        // too — ungated, this pinned a user prompt over its first two rows.
        if (!overlay_body and view_h >= 5) {
            if (scrollback.stickyUserAbove(self, start, width)) |utext| {
                const th = self.theme();
                var head = std.array_list.Managed(u8).init(a);
                try head.appendSlice(th.accent);
                try head.appendSlice(glyphs.prompt_mark ++ " ");
                try head.appendSlice(th.text);
                var one = utext;
                if (std.mem.indexOfScalar(u8, utext, '\n')) |nl| one = utext[0..nl];
                try head.appendSlice(one);
                const cols = if (width > 2) width - 2 else 1;
                try out.appendSlice(theme_mod.takeCols(head.items, cols));
                try out.appendSlice(theme_mod.reset);
                try out.append('\n');
                try out.append('\n');
                chrome_rows = 2;
                self.sticky_rows = 2;
            }
        }
        for (mid_lines.items[start + chrome_rows .. start + view_h]) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
        }
    }
    if (image_card.len > 0) {
        try out.appendSlice(image_card);
        if (image_card[image_card.len - 1] != '\n') try out.append('\n');
    }
    try out.appendSlice(bottom.items);
    // Selection is a post-pass over the finished frame: the row builders stay
    // unaware of it, and the band lands on screen rows exactly as the mouse
    // reported them (#529).
    return gpa.dupe(u8, try selection.paint(self, a, out.items, width));
}

fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    return std.mem.count(u8, s, "\n") + 1;
}

test "countLines" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("hi"));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
}

test "welcome frame has chrome, prompt, and no offline stub" {
    engine.g_model_name = "grok-4";
    engine.g_cwd = "/tmp/proj";
    defer {
        engine.g_model_name = "";
        engine.g_cwd = ".";
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "grok-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "›") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "offline") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Fullscreen") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "click") == null);
}

test "click on a painted Called row expands the tools" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.assistant, "Hey. I am in /Users/blackfloofie/codegraff on wip/shared-checkout-2026-08-14 and holding a long worktree path so this wraps");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    var row: usize = 0;
    var hit: ?usize = null;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |ln| : (row += 1) {
        if (std.mem.indexOf(u8, ln, "Called") != null) {
            hit = row;
            break;
        }
    }
    try std.testing.expect(hit != null);
    try std.testing.expect(m.history.items[1].folded);
    _ = @import("keys.zig").handle(&m, .{ .mouse = .{ .btn = 0, .x = 4, .y = @intCast(hit.? + 1), .down = true } });
    try std.testing.expect(!m.history.items[1].folded);
}

test "image overlay keeps the conversation and paints the Grok card" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.push(.assistant, "got it");
    m.preview_path = "/tmp/shot.png";
    m.preview_n = 1;
    m.openOverlay(.image);
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Image #1") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "got it") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "y copy path") != null);
}

test "visible dump of a fixture frame shows chips, Called, composer, no CSI" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    const dump_mod = @import("dump.zig");
    const vis = try dump_mod.visible(std.testing.allocator, frame);
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "[Image #1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "Called") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "›") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "\x1b") == null);
    const lay = try dump_mod.layout(std.testing.allocator, &m);
    defer std.testing.allocator.free(lay);
    try std.testing.expect(std.mem.indexOf(u8, lay, "overlay       none") != null);
    try std.testing.expect(std.mem.indexOf(u8, lay, "prompt-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, lay, "mid-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, lay, "images") != null);

    m.openOverlay(.debug);
    const dbg = try chrome.overlay(&m, std.testing.allocator, 80);
    defer std.testing.allocator.free(dbg);
    const lay_dbg = try dump_mod.layout(std.testing.allocator, &m);
    defer std.testing.allocator.free(lay_dbg);
    try std.testing.expect(std.mem.indexOf(u8, lay_dbg, "overlay       debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, dbg, "Observability") != null);
    if (std.c.getenv("GRAFF_TUI_DUMP")) |dir_z| {
        const dir = std.mem.span(dir_z);
        const io = std.Io.Threaded.global_single_threaded.io();
        var fb: [512]u8 = undefined;
        var lb: [512]u8 = undefined;
        const fp = std.fmt.bufPrint(&fb, "{s}/tui-frame.txt", .{dir}) catch return error.PathTooLong;
        const lp = std.fmt.bufPrint(&lb, "{s}/tui-layout.txt", .{dir}) catch return error.PathTooLong;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fp, .data = vis }) catch {};
        const both = try std.fmt.allocPrint(std.testing.allocator, "--- overlay none ---\n{s}\n--- overlay debug ---\n{s}\n--- debug overlay body ---\n{s}", .{ lay, lay_dbg, dbg });
        defer std.testing.allocator.free(both);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = both }) catch {};
    }
}

test "debug overlay keeps the observability HUD and adds layout" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.pushTool(.{ .name = "bash" });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    m.openOverlay(.debug);
    const text = try chrome.overlay(&m, std.testing.allocator, 80);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Observability") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "overlay       debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mid-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "images") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pending") != null);
}

test "the sticky header never pins a prompt over an overlay" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "SECRETPROMPT about widgets");
    var i: usize = 0;
    while (i < 40) : (i += 1) try m.push(.assistant, "filler assistant prose to make the transcript long");
    // It engages on the transcript...
    const transcript = try render(&m, std.testing.allocator, 80, 24, 0);
    std.testing.allocator.free(transcript);
    try std.testing.expectEqual(@as(usize, 2), m.sticky_rows);
    // ...and stands down once `mid` is an overlay body long enough to scroll:
    // ungated, the pin ate the overlay's own first two rows.
    m.openOverlay(.help);
    const overlay_frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(overlay_frame);
    try std.testing.expectEqual(@as(usize, 0), m.sticky_rows);
    try std.testing.expect(std.mem.indexOf(u8, overlay_frame, "SECRETPROMPT") == null);
    // The image overlay is a card, not a body: the transcript keeps its pin.
    m.closeOverlay();
    m.preview_path = "/tmp/shot.png";
    m.preview_n = 1;
    m.openOverlay(.image);
    const card_frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(card_frame);
    try std.testing.expectEqual(@as(usize, 2), m.sticky_rows);
}

test "sticky header pins the last scrolled-past user prompt with a blank separator" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "how do I frobnicate the widget?");
    var i: usize = 0;
    while (i < 40) : (i += 1) try m.push(.assistant, "a long explanation line that fills the scrollback with content");
    // follow-mode bottom: prompt is far above, so it pins.
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    var it = std.mem.splitScalar(u8, frame, '\n');
    var row: usize = 0;
    var pin_row: ?usize = null;
    while (it.next()) |ln| : (row += 1) {
        if (std.mem.indexOf(u8, ln, "\u{276F} ") != null and std.mem.indexOf(u8, ln, "frobnicate") != null) {
            pin_row = row;
            break;
        }
    }
    try std.testing.expect(pin_row != null);
    // scrolled fully back to the top, the prompt is inline: no pin.
    m.follow = false;
    m.scroll = 100000;
    const top_frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(top_frame);
    try std.testing.expect(std.mem.indexOf(u8, top_frame, "\u{276F} ") == null);
}
