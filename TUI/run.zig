//! Fullscreen loop on term.zig + ANSI. No zigzag, no OpenTUI-via-TS.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const app = @import("app.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const render_mod = @import("render.zig");
const restore_mod = @import("restore.zig");
const theme_mod = @import("theme.zig");
const turn = @import("turn.zig");
const tty = @import("tty.zig");
const Model = app.Model;

// 1000/1003/1006: click + hover + wheel as buttons 64/65 (not arrows).
// 2004: bracketed paste. 7l: no autowrap into the prompt.
// >11u: kitty disambiguate + event types + all-keys (Cmd+Delete / Super latch).
// >4;2m: xterm modifyOtherKeys so Super+Backspace also arrives as CSI 27;9;127~.
const enable_seq = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m";

pub const RunOpts = struct {
    turn_ctx: ?*anyopaque = null,
    turn_fn: ?engine.TurnFn = null,
    model_fn: ?engine.ModelFn = null,
    cancel_fn: ?engine.CancelFn = null,
    model_name: []const u8 = "",
    models: []const u8 = "",
    cwd: []const u8 = ".",
    yolo: bool = false,
    hud_fn: ?engine.HudFn = null,
    paste_fn: ?engine.PasteFn = null,
    bash_fn: ?engine.BashFn = null,
    files_fn: ?engine.FilesFn = null,
    copy_fn: ?engine.CopyFn = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    opts: RunOpts,
) !void {
    _ = environ_map;
    engine.g_turn_ctx = opts.turn_ctx;
    engine.g_turn_fn = opts.turn_fn;
    engine.g_model_fn = opts.model_fn;
    engine.g_cancel_fn = opts.cancel_fn;
    engine.g_hud_fn = opts.hud_fn;
    engine.g_paste_fn = opts.paste_fn;
    engine.g_bash_fn = opts.bash_fn;
    engine.g_files_fn = opts.files_fn;
    engine.g_copy_fn = opts.copy_fn;
    engine.g_model_name = opts.model_name;
    engine.g_models = opts.models;
    engine.g_cwd = opts.cwd;

    var m: Model = undefined;
    m.setup(gpa);
    defer m.deinit();
    if (opts.yolo) m.mode = .always_approve;

    var raw = tty.enterRaw() orelse return error.NotATty;
    restore_mod.arm(raw);
    defer restore_mod.disarm();
    defer tty.restore(raw);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    w.writeAll(enable_seq) catch {};
    w.flush() catch {};
    defer {
        w.writeAll(restore_mod.seq) catch {};
        w.flush() catch {};
    }

    var inbuf: [4096]u8 = undefined;
    var pending_len: usize = 0;
    var esc_stall: u8 = 0;
    var zero_reads: u8 = 0;
    var last_hash: u64 = 0;
    var saw_gfx: bool = false;
    var prev: []u8 = &.{};
    var prev_rows: usize = 0;
    defer if (prev.len != 0) gpa.free(prev);
    while (m.running and !m.quit_requested) {
        m.now_ms = @intCast(@divTrunc(@max(@as(i128, 0), Io.Timestamp.now(io, .real).nanoseconds), 1_000_000));
        if (m.pending) |job| {
            if (job.done.load(.acquire)) {
                turn.finishJob(&m);
                if (turn.drainSteer(&m) == .quit) break;
            }
        }
        const cols = @max(tty.cols(), @as(usize, 40));
        const rows = @max(tty.rows(), @as(usize, 12));
        const frame = render_mod.render(&m, gpa, cols, rows, m.now_ms) catch "tui: render error";
        defer gpa.free(frame);
        const hash = std.hash.Wyhash.hash(0, frame);
        if (hash != last_hash) {
            const has_gfx = std.mem.indexOf(u8, frame, "\x1b_G") != null;
            const full = prev.len == 0 or rows != prev_rows or saw_gfx or has_gfx;
            // Kitty images sit above the cell grid and survive \x1b[K / dirty
            // paints — delete before every redraw that might have shown one.
            if (saw_gfx or has_gfx) w.writeAll("\x1b_Ga=d,d=A,q=2\x1b\\") catch {};
            paint(w, frame, rows, cols, if (full) &.{} else prev, m.theme().bg) catch {};
            if (prev.len != 0) gpa.free(prev);
            prev = gpa.dupe(u8, frame) catch &.{};
            prev_rows = rows;
            last_hash = hash;
            saw_gfx = has_gfx;
        }

        // Short wait while an unfinished escape sequence is pending: if
        // nothing follows, the lone ESC was a real Escape keypress (#94).
        const wait: i32 = if (pending_len > 0) 25 else if (m.pending != null) 50 else 200;
        if (!tty.poll(wait)) {
            if (pending_len > 0) {
                esc_stall += 1;
                if (esc_stall >= 2) {
                    if (inbuf[0] == 0x1b and keys.handle(&m, .escape) == .quit) m.running = false;
                    pending_len = 0;
                    esc_stall = 0;
                }
            }
            continue;
        }
        esc_stall = 0;
        const got = tty.readStdin(inbuf[pending_len..]);
        if (got == 0) {
            // poll says readable but read gives nothing: hangup or transient
            // error. Three in a row means the TTY is gone.
            zero_reads += 1;
            if (zero_reads >= 3) m.running = false;
            continue;
        }
        zero_reads = 0;
        const n = pending_len + got;
        var i: usize = 0;
        while (key_mod.next(inbuf[0..n], &i)) |k| {
            switch (keys.handle(&m, k)) {
                .stay => {},
                .quit => {
                    m.running = false;
                    break;
                },
                .background => {
                    parkToShell(io, w, &raw);
                    // Full repaint after fg — the diff baseline is stale.
                    last_hash = 0;
                    if (prev.len != 0) gpa.free(prev);
                    prev = &.{};
                },
            }
        }
        if (i < n) {
            const rest = n - i;
            std.mem.copyForwards(u8, inbuf[0..rest], inbuf[i..n]);
            pending_len = rest;
        } else pending_len = 0;
    }
}

fn parkToShell(io: Io, w: *Io.Writer, raw: *tty.RawState) void {
    w.writeAll(restore_mod.seq) catch {};
    w.flush() catch {};
    tty.restore(raw.*);
    if (builtin.os.tag != .windows) {
        std.posix.raise(std.posix.SIG.TSTP) catch {};
    }
    raw.* = tty.enterRaw() orelse raw.*;
    w.writeAll(enable_seq) catch {};
    w.flush() catch {};
    _ = io;
}

/// Rewrite only rows that changed so a drag-select on older transcript survives
/// a live token / thinking tick. Empty `prev` forces a full home+repaint.
fn paint(w: *Io.Writer, frame: []const u8, rows: usize, cols: usize, prev: []const u8, bg: []const u8) !void {
    if (prev.len == 0) {
        try w.writeAll(bg);
        try w.writeAll("\x1b[2J\x1b[H");
        var row: usize = 0;
        var it = std.mem.splitScalar(u8, frame, '\n');
        while (it.next()) |ln| {
            if (row >= rows) break;
            try w.writeAll(bg);
            try w.writeAll(ln);
            try fillRow(w, ln, cols);
            try w.writeAll(bg);
            try w.writeAll("\x1b[K");
            if (row + 1 < rows) try w.writeAll("\r\n");
            row += 1;
        }
        while (row < rows) {
            try w.writeAll(bg);
            try w.writeAll("\x1b[K");
            if (row + 1 < rows) try w.writeAll("\r\n");
            row += 1;
        }
        try w.flush();
        return;
    }
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        if (!rowChanged(prev, frame, row)) continue;
        try w.print("\x1b[{d};1H", .{row + 1});
        try w.writeAll(bg);
        const ln = nthLine(frame, row);
        try w.writeAll(ln);
        try fillRow(w, ln, cols);
        try w.writeAll(bg);
        try w.writeAll("\x1b[K");
    }
    try w.flush();
}

fn fillRow(w: *Io.Writer, ln: []const u8, cols: usize) !void {
    const vis = theme_mod.visibleLen(ln);
    if (vis >= cols) return;
    var n = cols - vis;
    while (n > 0) : (n -= 1) try w.writeByte(' ');
}

fn nthLine(s: []const u8, row: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    var i: usize = 0;
    while (it.next()) |ln| : (i += 1) {
        if (i == row) return ln;
    }
    return "";
}

fn rowChanged(prev: []const u8, frame: []const u8, row: usize) bool {
    return !std.mem.eql(u8, nthLine(prev, row), nthLine(frame, row));
}

test "run loop enables click tracking and bracketed paste" {
    const src = @embedFile("run.zig");
    const mouse_on = [_]u8{ '?', '1', '0', '0', '0', 'h' };
    const sgr_on = [_]u8{ '?', '1', '0', '0', '6', 'h' };
    const paste_on = [_]u8{ '?', '2', '0', '0', '4', 'h' };
    const hover_on = [_]u8{ '?', '1', '0', '0', '3', 'h' };
    const kitty_on = [_]u8{ '>', '1', '1', 'u' };
    const wrap_off = [_]u8{ '?', '7', 'l' };
    try std.testing.expect(std.mem.indexOf(u8, src, &mouse_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &sgr_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &paste_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &hover_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &[_]u8{ '?', '1', '0', '0', '7', 'h' }) == null);
    try std.testing.expect(std.mem.indexOf(u8, src, &kitty_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &wrap_off) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "a=d,d=A") != null);
}

test "rowChanged only flags the line that actually moved" {
    const prev = "top\nmiddle\nbottom";
    const next = "top\nmiddle\nBOTTOM";
    try std.testing.expect(!rowChanged(prev, next, 0));
    try std.testing.expect(!rowChanged(prev, next, 1));
    try std.testing.expect(rowChanged(prev, next, 2));
    try std.testing.expect(!rowChanged(prev, prev, 2));
}
