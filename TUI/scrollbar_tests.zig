//! The scroll gutter and the OSC 52 clipboard channel, driven through the REAL
//! model — render.zig composing frames, keys.zig moving the viewport,
//! selection.zig capturing a drag — rather than through hand-written frames.
//!
//! Both features are post-passes over a composed frame, and both are only
//! honest if the composer, the painter and the capture agree about which rows
//! they own. That agreement is what these tests hold.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const glyphs = @import("glyphs.zig");
const keys = @import("keys.zig");
const osc52 = @import("osc52.zig");
const paint_mod = @import("paint.zig");
const render_mod = @import("render.zig");
const scrollbar = @import("scrollbar.zig");
const selection = @import("selection.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

const testing = std.testing;
const W: usize = 60;
const H: usize = 20;

fn longTranscript(m: *Model) !void {
    var buf: [64]u8 = undefined;
    for (0..40) |i| {
        const s = try std.fmt.bufPrint(&buf, "transcript row {d} with a little body text", .{i});
        try m.push(.assistant, s);
    }
}

fn frameAt(m: *Model, now_ms: u64) ![]const u8 {
    return render_mod.render(m, testing.allocator, W, H, now_ms);
}

/// Rows carrying the thumb, and the column it landed on.
const Marks = struct { rows: std.array_list.Managed(usize), col: usize };

fn marks(a: std.mem.Allocator, frame: []const u8) !Marks {
    var out = Marks{ .rows = std.array_list.Managed(usize).init(a), .col = 0 };
    var row: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |ln| : (row += 1) {
        const at = std.mem.indexOf(u8, ln, glyphs.scroll_thumb) orelse continue;
        try out.rows.append(row);
        out.col = theme_mod.visibleLen(ln[0..at]);
    }
    return out;
}

test "scrolling a real transcript raises a thumb inside the viewport" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try longTranscript(&m);

    // Parked at the tail, nothing has scrolled yet: no gutter.
    const tail = try frameAt(&m, 1_000);
    defer a.free(tail);
    try testing.expect(std.mem.indexOf(u8, tail, glyphs.scroll_thumb) == null);

    // Scroll up. The thumb has to be inside the band, on the LAST column, and
    // the same number of rows the geometry says.
    keys.scrollBy(&m, 9);
    const up = try frameAt(&m, 1_000);
    defer a.free(up);
    const got = try marks(ar, up);
    try testing.expect(got.rows.items.len > 0);
    try testing.expectEqual(W - 1, got.col);
    const t = scrollbar.current(&m).?;
    try testing.expectEqual(t.len, got.rows.items.len);
    try testing.expectEqual(m.band.top + t.top, got.rows.items[0]);
    try testing.expect(got.rows.items[got.rows.items.len - 1] < m.band.top + m.band.len);
    // Contiguous — a gutter with a hole in it is a bug, not a style.
    for (got.rows.items, 0..) |r, i| try testing.expectEqual(got.rows.items[0] + i, r);
    // Every marked row still measures exactly the terminal width, so the
    // painter's full/short branch sees what it expects.
    var it = std.mem.splitScalar(u8, up, '\n');
    var row: usize = 0;
    while (it.next()) |ln| : (row += 1) {
        if (std.mem.indexOf(u8, ln, glyphs.scroll_thumb) == null) continue;
        try testing.expectEqual(W, theme_mod.visibleLen(ln));
    }
}

test "the thumb travels down the track as the viewport approaches the tail" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try longTranscript(&m);
    const far = try frameAt(&m, 1_000); // lays down the band
    a.free(far);

    keys.scrollBy(&m, 30);
    const high = try frameAt(&m, 1_000);
    defer a.free(high);
    keys.scrollBy(&m, -20);
    const low = try frameAt(&m, 1_000);
    defer a.free(low);

    const h = try marks(ar, high);
    const l = try marks(ar, low);
    try testing.expect(h.rows.items.len > 0 and l.rows.items.len > 0);
    // Scrolled back TOWARD the tail: the thumb moved down, never up.
    try testing.expect(l.rows.items[0] > h.rows.items[0]);
}

test "back at the tail the gutter fades, and the row repaints clean" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try longTranscript(&m);
    const before = try frameAt(&m, 1_000);
    defer a.free(before);
    try testing.expect(std.mem.indexOf(u8, before, glyphs.scroll_thumb) == null);

    keys.scrollBy(&m, 8);
    const banded = try frameAt(&m, 1_000);
    defer a.free(banded);
    try testing.expect(std.mem.indexOf(u8, banded, glyphs.scroll_thumb) != null);

    // Back to the tail. Inside the fade window it lingers...
    keys.scrollBy(&m, -8);
    const lingering = try frameAt(&m, 1_000);
    defer a.free(lingering);
    try testing.expect(std.mem.indexOf(u8, lingering, glyphs.scroll_thumb) != null);
    // ...and past it the frame is byte-for-byte the one before any of this.
    const clean = try frameAt(&m, 1_000 + scrollbar.fade_ms);
    defer a.free(clean);
    try testing.expect(std.mem.indexOf(u8, clean, glyphs.scroll_thumb) == null);
    try testing.expectEqualStrings(before, clean);

    // The painter's side of the promise: a diff paint from the gutter frame to
    // the clean one rewrites exactly the rows the thumb was on, and a FORCED
    // full repaint of the clean frame carries no thumb either — so the two
    // paths agree about what the screen shows.
    const diff = try paintTo(ar, clean, banded, false);
    try testing.expect(std.mem.indexOf(u8, diff, glyphs.scroll_thumb) == null);
    const had = try marks(ar, banded);
    var buf: [16]u8 = undefined;
    for (had.rows.items) |r| {
        const cup = try std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{r + 1});
        try testing.expect(std.mem.indexOf(u8, diff, cup) != null);
    }
    const full = try paintTo(ar, clean, clean, true);
    try testing.expect(std.mem.indexOf(u8, full, glyphs.scroll_thumb) == null);
}

fn paintTo(a: std.mem.Allocator, frame: []const u8, prev: []const u8, force: bool) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    try paint_mod.paint(&aw.writer, frame, H, W, prev, "\x1b[48;2;20;20;20m", force, null);
    return aw.toOwnedSlice();
}

test "a live drag hides the gutter — the band owns those rows" {
    const a = testing.allocator;
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try longTranscript(&m);
    const first = try frameAt(&m, 1_000);
    a.free(first);
    keys.scrollBy(&m, 8);
    const scrolled = try frameAt(&m, 1_000);
    defer a.free(scrolled);
    try testing.expect(std.mem.indexOf(u8, scrolled, glyphs.scroll_thumb) != null);
    // Press and drag inside the transcript: the thumb goes, the band arrives.
    const top = m.mid_origin + m.sticky_rows;
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 0, .x = 1, .y = @intCast(top + 2), .down = true } });
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 32, .x = 30, .y = @intCast(top + 4), .down = true } });
    const dragging = try frameAt(&m, 1_000);
    defer a.free(dragging);
    try testing.expect(std.mem.indexOf(u8, dragging, "\x1b[7m") != null);
    try testing.expect(std.mem.indexOf(u8, dragging, glyphs.scroll_thumb) == null);
    // ...and the capture is text, with no gutter glyph smuggled into it.
    try testing.expect(std.mem.indexOf(u8, m.sel_text, glyphs.scroll_thumb) == null);
}

// ---------------------------------------------------------------- OSC 52

var copied: [4096]u8 = undefined;
var copied_len: usize = 0;
var copy_ok: bool = true;

fn fakeCopy(_: ?*anyopaque, text: []const u8) bool {
    if (!copy_ok) return false;
    copied_len = @min(text.len, copied.len);
    @memcpy(copied[0..copied_len], text[0..copied_len]);
    return true;
}

fn expectPayload(seq: []const u8, want: []const u8) !void {
    try testing.expect(std.mem.startsWith(u8, seq, osc52.prefix));
    try testing.expect(std.mem.endsWith(u8, seq, osc52.terminator));
    const body = seq[osc52.prefix.len .. seq.len - osc52.terminator.len];
    const enc = std.base64.standard.Encoder;
    const b64 = try testing.allocator.alloc(u8, enc.calcSize(want.len));
    defer testing.allocator.free(b64);
    _ = enc.encode(b64, want);
    try testing.expectEqualStrings(b64, body);
}

test "a drag-copy arms OSC 52 with the exact base64 of the captured rows" {
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    copy_ok = true;
    copied_len = 0;
    const a = testing.allocator;
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try m.push(.assistant, "OSCME alpha line");
    try m.push(.assistant, "OSCME beta line");
    const first = try frameAt(&m, 0);
    a.free(first);
    const top = m.mid_origin + m.sticky_rows;
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 0, .x = 1, .y = @intCast(top + 1), .down = true } });
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 32, .x = 40, .y = @intCast(top + 2), .down = true } });
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 0, .x = 40, .y = @intCast(top + 2), .down = false } });
    const after = try frameAt(&m, 0);
    defer a.free(after);
    // The escape is NOT in the frame: a frame is repainted, a clipboard write
    // happens once.
    try testing.expect(std.mem.indexOf(u8, after, osc52.prefix) == null);
    const seq = selection.takeOsc52(&m);
    defer a.free(seq);
    try testing.expect(seq.len > 0);
    try expectPayload(seq, m.sel_text);
    try testing.expect(std.mem.indexOf(u8, m.sel_text, "OSCME alpha") != null);
    // Both channels carried it, so the toast says so without qualification.
    try testing.expectEqualStrings(m.sel_text, copied[0..copied_len]);
    try testing.expect(std.mem.indexOf(u8, m.toast, "copied") != null);
    try testing.expect(std.mem.indexOf(u8, m.toast, "OSC 52") == null);
    // Taking it clears it: the next paint owes the terminal nothing.
    try testing.expectEqual(@as(usize, 0), selection.takeOsc52(&m).len);
}

test "with no local clipboard the copy still succeeds, via OSC 52" {
    // The SSH case: pbcopy/xclip are absent or fail, and the only channel that
    // reaches the user's machine is the escape.
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    copy_ok = false;
    defer copy_ok = true;
    const a = testing.allocator;
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    try m.push(.assistant, "REMOTE alpha line");
    try m.push(.assistant, "REMOTE beta line");
    const first = try frameAt(&m, 0);
    a.free(first);
    const top = m.mid_origin + m.sticky_rows;
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 0, .x = 1, .y = @intCast(top + 1), .down = true } });
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 32, .x = 40, .y = @intCast(top + 2), .down = true } });
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 0, .x = 40, .y = @intCast(top + 2), .down = false } });
    const after = try frameAt(&m, 0);
    defer a.free(after);
    const seq = selection.takeOsc52(&m);
    defer a.free(seq);
    try expectPayload(seq, m.sel_text);
    try testing.expect(std.mem.indexOf(u8, m.toast, "copied (OSC 52)") != null);
}

test "past the cap the local copy still lands and the toast says why not" {
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    copy_ok = true;
    copied_len = 0;
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var m: Model = undefined;
    m.setup(a);
    defer m.deinit();
    // A frame far larger than the cap, with the band over all of it. Going
    // through selection.paint means the capture is the real one, not a string
    // handed to the encoder.
    const row = try ar.alloc(u8, 120);
    @memset(row, 'y');
    const rows = (osc52.max_bytes / row.len) + 40;
    var frame = std.array_list.Managed(u8).init(ar);
    for (0..rows) |i| {
        if (i > 0) try frame.append('\n');
        try frame.appendSlice(row);
    }
    m.last_term_width = row.len;
    m.sel = .{ .active = true, .copy_pending = true, .a_row = 0, .a_col = 0, .h_row = rows - 1, .h_col = row.len - 1 };
    _ = try selection.paint(&m, ar, frame.items, row.len);
    try testing.expect(m.sel_text.len > osc52.max_bytes);
    try testing.expectEqual(@as(usize, 0), selection.takeOsc52(&m).len);
    try testing.expect(std.mem.indexOf(u8, m.toast, "copied") != null);
    try testing.expect(std.mem.indexOf(u8, m.toast, "too big for OSC 52") != null);
    // The local clipboard is unaffected by the cap — it took the whole thing.
    try testing.expect(copied_len > 0);
}
