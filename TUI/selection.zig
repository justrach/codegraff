//! In-app drag selection (#529). Mouse tracking (?1000/?1003/?1006) swallows
//! the terminal's own selection gesture, so the TUI owns it: drag paints an
//! inverse-video band over the composed frame, release copies the covered text
//! to the system clipboard, and any other input drops the band.
//!
//! Granularity is grok's: whole rows, with column bounds on the FIRST and LAST
//! row only. Character precision inside a styled, wrapped row would have to
//! agree with every row builder in scrollback.zig/markdown.zig; row bands agree
//! with the rendered frame by construction — the band and the copied text come
//! out of the same pass over the same bytes.
//!
//! What the band COVERS and what it CAPTURES differ on purpose: the band is a
//! rectangle, but a screen row of nothing but layout padding is not text (see
//! `Capture`), so a drag that overshoots into the empty screen below the
//! transcript copies the transcript, not the emptiness.
//!
//! Presentation state only. This renders the engine's transcript; it does not
//! fork engine behaviour, and nothing here reaches a provider.

const std = @import("std");
const builtin = @import("builtin");

const app = @import("app.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const osc52 = @import("osc52.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// Anchor/head live in SCREEN coordinates: the band belongs to the frame it was
/// drawn over, and it is cleared by the next non-drag input, so it can never
/// drift onto content that scrolled underneath it.
pub const Sel = struct {
    /// A drag has happened — the band paints and `Model.sel_text` is live.
    active: bool = false,
    /// Button is down inside the transcript; motion may still turn it into a drag.
    pressed: bool = false,
    a_row: usize = 0,
    a_col: usize = 0,
    h_row: usize = 0,
    h_col: usize = 0,
    /// Tool group the press expanded/collapsed. Reverted the instant motion
    /// proves the gesture was a drag, so selecting text never folds a group.
    undo_idx: ?usize = null,
    /// Release seen; the copy runs in the next paint. A terminal delivers a
    /// whole flick of the mouse in one read, and run.zig drains every event in
    /// that read before rendering — copying at release time would then ship the
    /// text of a frame the last motion never reached.
    copy_pending: bool = false,
    /// Rows of the last capture that actually carried text. The toast counts
    /// these, not the newlines in `sel_text`: collapsed blank runs are spacing,
    /// and calling them "lines copied" would inflate the number the user reads.
    text_rows: usize = 0,
    /// setToast BORROWS its slice — the copy toast has to outlive this call, so
    /// it is formatted into model-owned storage. Wide enough for the longest
    /// shape: a six-figure line count plus the OSC 52 note.
    toast_buf: [64]u8 = undefined,
};

pub const Range = struct { r0: usize, c0: usize, r1: usize, c1: usize };

/// True when the event belonged to the drag gesture and nothing else should see
/// it. A press is only RECORDED: a click keeps its existing meaning (tool-group
/// expand, composer focus) until motion proves otherwise.
pub fn mouse(self: *Model, ev: key_mod.Mouse) bool {
    // SGR and X10 agree on 32 = motion with the left button held.
    if (ev.btn == 32 and ev.down) {
        extend(self, ev);
        return true;
    }
    // Release: SGR reports the button with a final 'm', X10 reports button 3.
    if (!ev.down and (ev.btn == 0 or ev.btn == 3)) return finish(self);
    if (ev.down and ev.btn == 0) begin(self, ev);
    return false;
}

fn begin(self: *Model, ev: key_mod.Mouse) void {
    clear(self);
    // A press with an overlay up means "close it" (keys.zig) — the frame the
    // band would be measured against is gone by the next motion.
    if (self.overlay != .none) return;
    const p = point(self, ev, false) orelse return;
    self.sel.pressed = true;
    self.sel.a_row = p.row;
    self.sel.a_col = p.col;
    self.sel.h_row = p.row;
    self.sel.h_col = p.col;
}

fn extend(self: *Model, ev: key_mod.Mouse) void {
    if (!self.sel.pressed) return;
    const p = point(self, ev, true) orelse return;
    if (self.sel.undo_idx) |i| {
        self.toggleToolGroup(i);
        self.sel.undo_idx = null;
    }
    self.sel.h_row = p.row;
    self.sel.h_col = p.col;
    self.sel.active = true;
}

/// Mouse-up arms the copy. The band itself KEEPS painting: the user sees
/// exactly what landed on the clipboard until the next keystroke or click.
fn finish(self: *Model) bool {
    if (!self.sel.pressed) return true; // a release we never anchored
    self.sel.pressed = false;
    self.sel.undo_idx = null;
    if (self.sel.active) self.sel.copy_pending = true;
    return true;
}

/// Runs inside the paint that captured the text, so the clipboard and the band
/// can never disagree about which frame was selected. A band over nothing but
/// padding captures no text: the clipboard is left exactly as the user had it
/// and no toast claims a copy that never happened.
fn commit(self: *Model) void {
    self.sel.copy_pending = false;
    const text = self.sel_text;
    if (text.len == 0) {
        clear(self);
        return;
    }
    const lines = self.sel.text_rows;
    // Two channels, always both attempted, because they reach different
    // machines. The local tool writes the clipboard of the host graff runs on;
    // OSC 52 writes the clipboard of the TERMINAL, which over SSH is the only
    // one the user can paste from. Neither is a fallback for the other — the
    // local tool is what a clipboard manager sees, and OSC 52 is what survives
    // the hop — so the emission is not gated on the local attempt failing.
    const local = copyText(text);
    const remote = armOsc52(self, text);
    if (!local and !remote) {
        self.setToast("copy failed");
        return;
    }
    // What the toast has to be honest about: which channel actually carried
    // it. "copied" with no local clipboard would be a lie on a plain terminal;
    // "(OSC 52)" tells an SSH user their laptop has it. A selection past the
    // cap is the one case that copies locally and NOT to the terminal.
    const note: []const u8 = if (!local) " (OSC 52)" else if (!remote) " (too big for OSC 52)" else "";
    const s = std.fmt.bufPrint(&self.sel.toast_buf, "{d} line{s} copied{s}", .{
        lines,
        if (lines == 1) "" else "s",
        note,
    }) catch "copied";
    self.setToast(s);
}

/// Hand the run loop the escape to write. Presentation state, not a frame: a
/// frame gets repainted and a clipboard write must happen exactly once, so it
/// travels on its own one-shot slot (app.Model.osc_pending). Returns false
/// when the payload is past the cap and nothing will be emitted.
fn armOsc52(self: *Model, text: []const u8) bool {
    const seq = (osc52.sequence(self.alloc, text) catch return false) orelse return false;
    if (self.osc_pending.len > 0) self.alloc.free(self.osc_pending);
    self.osc_pending = seq;
    return true;
}

/// The one-shot the run loop owes the tty, handed over and cleared. Returns an
/// empty slice when nothing is owed; the caller frees what it takes.
pub fn takeOsc52(self: *Model) []const u8 {
    const seq = self.osc_pending;
    self.osc_pending = "";
    return seq;
}

pub fn clear(self: *Model) void {
    self.sel.active = false;
    self.sel.pressed = false;
    self.sel.undo_idx = null;
    self.sel.copy_pending = false;
    if (self.sel_text.len > 0) {
        self.alloc.free(self.sel_text);
        self.sel_text = "";
    }
}

const Point = struct { row: usize, col: usize };

/// Screen cell under the pointer, restricted to the transcript viewport. A
/// press outside it anchors nothing (`clamp = false`); a drag that runs off the
/// edge keeps selecting the edge row (`clamp = true`).
fn point(self: *const Model, ev: key_mod.Mouse, clamp: bool) ?Point {
    if (self.prompt_origin <= self.mid_origin) return null;
    const last_row = self.prompt_origin - 1;
    const last_col = if (self.last_term_width > 0) self.last_term_width - 1 else 0;
    var y: usize = if (ev.y > 0) ev.y - 1 else 0;
    var x: usize = if (ev.x > 0) ev.x - 1 else 0;
    if (y < self.mid_origin or y > last_row) {
        if (!clamp) return null;
        y = std.math.clamp(y, self.mid_origin, last_row);
    }
    if (x > last_col) x = last_col;
    return .{ .row = y, .col = x };
}

/// Normalized band: [r0,c0] inclusive to [r1,c1) exclusive, so the cell under
/// the pointer is part of the selection.
pub fn ordered(self: *const Model) ?Range {
    if (!self.sel.active) return null;
    const s = self.sel;
    const fwd = s.a_row < s.h_row or (s.a_row == s.h_row and s.a_col <= s.h_col);
    return .{
        .r0 = if (fwd) s.a_row else s.h_row,
        .c0 = if (fwd) s.a_col else s.h_col,
        .r1 = if (fwd) s.h_row else s.a_row,
        .c1 = (if (fwd) s.h_col else s.a_col) + 1,
    };
}

/// What the band COVERS and what it CAPTURES are deliberately different. The
/// band is a rectangle over the frame, so it swallows the blank cells the
/// layout uses for spacing; the capture is the text under it. A row with no
/// glyphs contributes nothing, the blank rows at either end of the drag fall
/// off, and a run of blank rows between two text rows collapses to a single
/// empty line — paragraph separation survives, screens of padding do not.
const Capture = struct {
    text: *std.array_list.Managed(u8),
    /// Rows that carried text. Blank rows, kept or dropped, never count.
    rows: usize = 0,
    /// A blank run is pending. It only becomes an empty line once a later row
    /// proves it was INTERIOR, which is what drops the trailing blanks.
    gap: bool = false,

    fn push(self: *Capture, line: []const u8) !void {
        if (line.len == 0) {
            self.gap = self.rows > 0; // leading blanks never open the capture
            return;
        }
        if (self.rows > 0) try self.text.append('\n');
        if (self.gap) {
            try self.text.append('\n');
            self.gap = false;
        }
        try self.text.appendSlice(line);
        self.rows += 1;
    }
};

/// Post-pass over the COMPOSED frame: the row builders in scrollback.zig stay
/// untouched, and the captured text is the same bytes the band covers.
pub fn paint(self: *Model, a: std.mem.Allocator, frame: []const u8, width: usize) ![]const u8 {
    const r = ordered(self) orelse return frame;
    var out = std.array_list.Managed(u8).init(a);
    var text = std.array_list.Managed(u8).init(a);
    var line = std.array_list.Managed(u8).init(a);
    var cap: Capture = .{ .text = &text };
    var row: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |ln| : (row += 1) {
        if (row > 0) try out.append('\n');
        const c0 = if (row == r.r0) r.c0 else 0;
        const c1 = @min(if (row == r.r1) r.c1 else width, width);
        if (row < r.r0 or row > r.r1 or c1 <= c0) {
            try out.appendSlice(ln);
            continue;
        }
        line.clearRetainingCapacity();
        try band(&out, &line, ln, c0, c1);
        // Every row, column-bounded ends included, loses its trailing blanks —
        // a row of nothing but them is then empty, and contributes nothing.
        try cap.push(std.mem.trimEnd(u8, line.items, " \t"));
    }
    setText(self, text.items);
    self.sel.text_rows = cap.rows;
    if (self.sel.copy_pending) commit(self);
    return out.items;
}

fn setText(self: *Model, s: []const u8) void {
    const owned = self.alloc.dupe(u8, s) catch return;
    if (self.sel_text.len > 0) self.alloc.free(self.sel_text);
    self.sel_text = owned;
}

/// One row: verbatim up to `c0`, inverse video across [c0,c1), verbatim after.
/// SGR inside the band is dropped so the highlight is uniform (a stray `0m`
/// would otherwise cancel it mid-band) and re-emitted at the far edge, or the
/// rest of the row would paint in whatever style the band swallowed.
///
/// `text` is this ROW's capture buffer, emptied by the caller — the glyphs the
/// band covers, and nothing the band merely pads over.
fn band(out: *std.array_list.Managed(u8), text: *std.array_list.Managed(u8), ln: []const u8, c0: usize, c1: usize) !void {
    var sgr: theme_mod.Sgr = .{};
    var i: usize = 0;
    var col: usize = 0;
    while (i < ln.len and col < c0) {
        if (ln[i] == 0x1b) {
            const e = theme_mod.skipEsc(ln, i);
            sgr.note(ln[i..e]);
            try out.appendSlice(ln[i..e]);
            i = e;
            continue;
        }
        const c = cpAt(ln, i);
        if (col + c.w > c0) break; // a wide glyph never straddles the edge
        try out.appendSlice(ln[i .. i + c.n]);
        col += c.w;
        i += c.n;
    }
    try pad(out, c0 -| col);
    col = @max(col, c0);
    try out.appendSlice("\x1b[7m");
    while (i < ln.len and col < c1) {
        if (ln[i] == 0x1b) {
            const e = theme_mod.skipEsc(ln, i);
            sgr.note(ln[i..e]);
            i = e;
            continue;
        }
        const c = cpAt(ln, i);
        if (col + c.w > c1) break;
        try out.appendSlice(ln[i .. i + c.n]);
        try text.appendSlice(ln[i .. i + c.n]);
        col += c.w;
        i += c.n;
    }
    // The band covers blank cells too, exactly like a terminal's own selection.
    // Those pad columns are painted, never captured.
    try pad(out, c1 -| col);
    try out.appendSlice("\x1b[27m");
    var buf: [theme_mod.Sgr.max_render]u8 = undefined;
    try out.appendSlice(sgr.render(&buf));
    if (i < ln.len) try out.appendSlice(ln[i..]);
}

fn pad(out: *std.array_list.Managed(u8), n: usize) !void {
    var left = n;
    while (left > 0) : (left -= 1) try out.append(' ');
}

const Cp = struct { w: usize, n: usize };

/// Columns and bytes of the codepoint at `i` — theme_mod.charWidth plus the
/// VS16 promotion, so the band measures the same cells visibleLen does.
fn cpAt(s: []const u8, i: usize) Cp {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .w = 1, .n = 1 };
    const n = @min(@as(usize, len), s.len - i);
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .w = 1, .n = n };
    const w: usize = theme_mod.charWidth(cp);
    if (w == 1 and i + n + 3 <= s.len and std.mem.eql(u8, s[i + n .. i + n + 3], "\u{FE0F}")) return .{ .w = 2, .n = n };
    return .{ .w = w, .n = n };
}

/// The session's clipboard callback when there is one (/copy's path), else the
/// platform tool directly — the TUI also runs without a live session.
pub fn copyText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (engine.g_copy_fn) |f| return f(engine.g_turn_ctx, text);
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        else => return false,
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    if (child.stdin) |*s| {
        var wbuf: [4096]u8 = undefined;
        var w = s.writerStreaming(io, &wbuf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        s.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

// ---------------------------------------------------------------- tests

const keys = @import("keys.zig");
const render_mod = @import("render.zig");

var copied: [4096]u8 = undefined;
var copied_len: usize = 0;

fn fakeCopy(_: ?*anyopaque, text: []const u8) bool {
    copied_len = @min(text.len, copied.len);
    @memcpy(copied[0..copied_len], text[0..copied_len]);
    return true;
}

fn press(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 0, .x = x, .y = y, .down = true } });
}

fn drag(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 32, .x = x, .y = y, .down = true } });
}

fn release(m: *Model, x: u16, y: u16) void {
    _ = keys.handle(m, .{ .mouse = .{ .btn = 0, .x = x, .y = y, .down = false } });
}

fn frameOf(m: *Model) ![]const u8 {
    return render_mod.render(m, std.testing.allocator, 80, 24, 0);
}

test "a drag paints an inverse band and copies the covered rows (#529)" {
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    copied_len = 0;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.assistant, "SELECTME alpha line");
    try m.push(.assistant, "SELECTME beta line");
    const first = try frameOf(&m);
    std.testing.allocator.free(first);
    // Find the painted row of the first entry, then drag across both.
    const top = m.mid_origin + m.sticky_rows;
    press(&m, 1, @intCast(top + 1));
    drag(&m, 40, @intCast(top + 2));
    const dragging = try frameOf(&m);
    defer std.testing.allocator.free(dragging);
    try std.testing.expect(std.mem.indexOf(u8, dragging, "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, dragging, "\x1b[27m") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.sel_text, "SELECTME alpha") != null);
    release(&m, 40, @intCast(top + 2));
    // The band survives the release so the user sees what was copied...
    const after = try frameOf(&m);
    defer std.testing.allocator.free(after);
    try std.testing.expect(m.sel.active);
    try std.testing.expect(std.mem.indexOf(u8, after, "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied[0..copied_len], "SELECTME alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.toast, "copied") != null);
    // The capture never opens or closes on the transcript's blank spacing rows,
    // and the toast counts the rows that carried text.
    try std.testing.expect(!std.mem.startsWith(u8, m.sel_text, "\n"));
    try std.testing.expect(!std.mem.endsWith(u8, m.sel_text, "\n"));
    var cnt: [8]u8 = undefined;
    const head = try std.fmt.bufPrint(&cnt, "{d} line", .{m.sel.text_rows});
    try std.testing.expect(std.mem.startsWith(u8, m.toast, head));
    // ...and the next ordinary keystroke drops it.
    _ = keys.handle(&m, .{ .char = 'x' });
    try std.testing.expect(!m.sel.active);
    const clean = try frameOf(&m);
    defer std.testing.allocator.free(clean);
    try std.testing.expect(std.mem.indexOf(u8, clean, "\x1b[7m") == null);
}

test "click on a folded tool row still expands it, and paints no band" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    m.last_term_height = 24;
    m.last_term_width = 80;
    m.mid_origin = 1;
    m.mid_skip = 0;
    m.prompt_origin = 20;
    try std.testing.expect(m.history.items[1].folded);
    press(&m, 4, 3);
    release(&m, 4, 3);
    try std.testing.expect(!m.history.items[1].folded);
    try std.testing.expect(!m.sel.active);
    try std.testing.expect(m.sel_text.len == 0);
}

test "click on blank padding selects and toggles nothing (#519)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    m.last_term_height = 24;
    m.last_term_width = 80;
    m.mid_origin = 0;
    m.mid_skip = 0;
    m.prompt_origin = 20;
    try std.testing.expect(m.history.items[1].folded);
    press(&m, 2, 15);
    try std.testing.expect(m.history.items[1].folded);
    try std.testing.expectEqual(app.Focus.scrollback, m.focus);
}

test "a drag that starts on a tool group leaves the group as it was" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "hi");
    try m.pushTool(.{ .name = "bash" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    m.last_term_height = 24;
    m.last_term_width = 80;
    m.mid_origin = 1;
    m.prompt_origin = 20;
    try std.testing.expect(m.history.items[1].folded);
    press(&m, 4, 3);
    drag(&m, 30, 5);
    try std.testing.expect(m.history.items[1].folded); // the expand was undone
    try std.testing.expect(m.sel.active);
}

test "a press outside the transcript never anchors a band" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 80;
    m.mid_origin = 2;
    m.prompt_origin = 20;
    press(&m, 5, 21); // composer row
    drag(&m, 40, 10);
    try std.testing.expect(!m.sel.active);
    try std.testing.expectEqual(app.Focus.prompt, m.focus);
}

test "the wheel scrolls and drops the band instead of extending it" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 80;
    m.last_term_height = 24;
    m.mid_origin = 1;
    m.prompt_origin = 20;
    press(&m, 2, 3);
    drag(&m, 40, 6);
    try std.testing.expect(m.sel.active);
    _ = keys.handle(&m, .{ .mouse = .{ .btn = 64, .x = 40, .y = 6, .down = true } });
    try std.testing.expect(!m.sel.active);
    try std.testing.expect(!m.follow);
}

test "a drag over blank rows leaves the clipboard and the toast alone" {
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    // Seeded, not zeroed: the contract is that the user's clipboard SURVIVES a
    // drag that found no text, not merely that nothing new was appended.
    copied_len = @min("KEEPME".len, copied.len);
    @memcpy(copied[0..copied_len], "KEEPME");
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.last_term_width = 80;
    m.mid_origin = 1;
    m.prompt_origin = 20;
    press(&m, 4, 5);
    drag(&m, 40, 8);
    release(&m, 40, 8);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try paint(&m, arena.allocator(), "\n\n\n\n\n   \n\n\n\n", 80);
    try std.testing.expectEqualStrings("KEEPME", copied[0..copied_len]);
    try std.testing.expectEqualStrings("", m.toast);
    try std.testing.expect(!m.sel.active);
}

test "a drag whose motion and release arrive in ONE read still copies" {
    // Terminals batch mouse reports, and run.zig drains every event in a read
    // before it renders — so the copy has to be taken from the paint that
    // follows, not from whatever text the previous frame happened to hold.
    engine.g_copy_fn = fakeCopy;
    defer engine.g_copy_fn = null;
    copied_len = 0;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.assistant, "BATCHED alpha");
    try m.push(.assistant, "BATCHED beta");
    const first = try frameOf(&m);
    std.testing.allocator.free(first);
    const top = m.mid_origin + m.sticky_rows;
    press(&m, 1, @intCast(top + 1));
    drag(&m, 60, @intCast(top + 2));
    release(&m, 60, @intCast(top + 2));
    try std.testing.expectEqual(@as(usize, 0), copied_len); // nothing yet...
    const frame = try frameOf(&m);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, copied[0..copied_len], "BATCHED alpha") != null);
    try std.testing.expectEqualStrings(m.sel_text, copied[0..copied_len]);
}
