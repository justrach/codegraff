//! Frame-level tests for render.zig.
//!
//! Split out of render.zig to keep it under the line ceiling. These drive the
//! PUBLIC `render` entry point and read the composed frame back, so they live
//! just as well next door; the two tests that reach for render.zig's private
//! line helpers stayed behind with them.

const std = @import("std");

const app = @import("app.zig");
const chrome = @import("chrome.zig");
const dump_mod = @import("dump.zig");
const engine = @import("engine.zig");
const scrollback = @import("scrollback.zig");
const selection = @import("selection.zig");
const welcome = @import("welcome.zig");
const Model = app.Model;

const render = @import("render.zig").render;

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

test "click on a painted fold header expands the tools" {
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
        if (std.mem.indexOf(u8, ln, "Ran bash") != null) {
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

test "visible dump of a fixture frame shows chips, the fold header, composer, no CSI" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] look");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    const frame = try render(&m, std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(frame);
    const vis = try dump_mod.visible(std.testing.allocator, frame);
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "[Image #1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "Ran bash") != null);
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
    // The overlay body is built from many small pieces now that it is framed
    // (panel.zig), so it wants the arena every other chrome builder gets.
    var oarena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer oarena.deinit();
    const dbg = try chrome.overlay(&m, oarena.allocator(), 80);
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
    var oarena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer oarena.deinit();
    const text = try chrome.overlay(&m, oarena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, text, "Observability") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "overlay       debug") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mid-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "images") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pending") != null);
}

test "a wheel notch reports a scroll hint; anything else about the frame refuses one" {
    const keys = @import("keys.zig");
    const a = std.testing.allocator;
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try m.push(.user, "how do I frobnicate the widget?");
    var i: usize = 0;
    while (i < 60) : (i += 1)
        try m.pushFmt(.assistant, "explanation line {d}, long enough to fill the transcript", .{i});

    // A first frame has nothing to compare against, and an idle one has not moved.
    for (0..2) |_| {
        a.free(try render(&m, a, 80, 24, 0));
        try std.testing.expect(m.paint_hint == null);
    }

    // One wheel notch. The band slides by exactly the three content lines
    // keys.zig moved the viewport, and keeps its geometry — which is the whole
    // claim paint.zig acts on. `top` clears the sticky header: those rows are
    // chrome occluding the viewport, and a hardware scroll must not move them.
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 64, .x = 1, .y = 5, .down = true } });
    a.free(try render(&m, a, 80, 24, 0));
    const h = m.paint_hint orelse return error.NoScrollHint;
    try std.testing.expectEqual(@as(isize, -3), h.delta);
    try std.testing.expectEqual(m.mid_origin + m.sticky_rows, h.top);
    try std.testing.expectEqual(@as(usize, 2), m.sticky_rows);
    try std.testing.expect(h.len >= 2 and h.top + h.len <= 24);

    // A resize on the same frame as a scroll: every row below rewraps, so the
    // band is not the same band and nothing about it may be claimed to slide.
    keys.scrollBy(&m, 3);
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);

    // A live drag-selection band is anchored to SCREEN rows, so its inverse
    // video does not travel with the content a hardware scroll would move.
    a.free(try render(&m, a, 79, 24, 0));
    m.sel.active = true;
    keys.scrollBy(&m, 3);
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);
    m.sel.active = false;

    // Scrolling all the way to the top clamps: the viewport stops moving, and
    // a band that did not move is not a scroll.
    m.scroll = 1_000_000;
    a.free(try render(&m, a, 79, 24, 0));
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);

    // An overlay replaces the whole viewport — no band at all, so no hint even
    // though the frame changed completely.
    m.openOverlay(.help);
    a.free(try render(&m, a, 79, 24, 0));
    try std.testing.expect(m.paint_hint == null);
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
