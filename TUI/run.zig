//! Fullscreen loop on term.zig + ANSI. No zigzag, no OpenTUI-via-TS.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const app = @import("app.zig");
const bgop = @import("bgop.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const render_mod = @import("render.zig");
const restore_mod = @import("restore.zig");
const stall = @import("run_stall.zig");
const theme_mod = @import("theme.zig");
const turn = @import("turn.zig");
const tty = @import("tty.zig");
const traj = @import("traj.zig");
const Model = app.Model;

// 1000/1003/1006: click + hover + wheel as buttons 64/65 (not arrows).
// 2004: bracketed paste. 7l: no autowrap into the prompt.
// >11u: kitty disambiguate + event types + all-keys (Cmd+Delete / Super latch).
// >4;2m: xterm modifyOtherKeys so Super+Backspace also arrives as CSI 27;9;127~.
pub const enable_seq = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m";

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
    compact_fn: ?engine.CompactFn = null,
    history_fn: ?engine.HistoryFn = null,
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
    engine.g_compact_fn = opts.compact_fn;
    engine.g_history_fn = opts.history_fn;
    engine.g_model_name = opts.model_name;
    engine.g_models = opts.models;
    engine.g_cwd = opts.cwd;

    var m: Model = undefined;
    m.setup(gpa);
    defer m.deinit();
    if (opts.yolo) m.mode = .always_approve;

    var raw = tty.enterRaw() orelse return error.NotATty;
    restore_mod.arm(raw, enable_seq);
    defer restore_mod.disarm();
    defer tty.restore(raw);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    w.writeAll(enable_seq) catch {};
    w.writeAll("\x1b]11;?\x07") catch {}; // background query -> auto light/dark (key.zig bg_report)
    w.flush() catch {};
    // Nothing may write to the real terminal around the frame painter: park
    // fd 2 on .graff/tui-stderr.log so std.debug.print from any thread (a
    // subagent's status card, a worker line) cannot scroll the alt screen and
    // bleed stale rows through the diff paint. Every exit path unparks it.
    restore_mod.muteStderr();
    traj.open(io);
    defer {
        restore_mod.unmuteStderr();
        w.writeAll(restore_mod.seq) catch {};
        w.flush() catch {};
    }

    var inbuf: [4096]u8 = undefined;
    var pending_len: usize = 0;
    var esc_stall: u8 = 0;
    var zero_reads: u8 = 0;
    // Clock for the bracketed-paste latch only: refreshed by bytes that could
    // plausibly BE paste content, never by mouse-motion noise (see below).
    var last_paste_ms: u64 = 0;
    var stash_ms: u64 = 0;
    var arm_ms: u64 = 0;
    var last_hash: u64 = 0;
    var saw_gfx: bool = false;
    var prev: []u8 = &.{};
    var prev_rows: usize = 0;
    var prev_cols: usize = 0;
    var prev_theme = m.theme_id;
    defer if (prev.len != 0) gpa.free(prev);
    while (m.running and !m.quit_requested) {
        m.now_ms = nowMs(io);
        if (restore_mod.takeResumed()) {
            // SIGTSTP took the terminal back to the shell and SIGCONT handed
            // it over again: the alt screen is blank, so the diff baseline
            // would leave the frame half-drawn. Force a full repaint.
            last_hash = 0;
            if (prev.len != 0) gpa.free(prev);
            prev = &.{};
        }
        if (m.pending) |job| {
            if (job.done.load(.acquire)) {
                turn.finishJob(&m);
                if (turn.drainSteer(&m) == .quit) break;
            }
        }
        // Background engine ops (/compact, !cmd, @-file list) land here too —
        // the same poll that keeps a turn from freezing the loop (#533).
        bgop.finish(&m);
        const cols = @max(tty.cols(), @as(usize, 40));
        const rows = @max(tty.rows(), @as(usize, 12));
        const frame = render_mod.render(&m, gpa, cols, rows, m.now_ms) catch "tui: render error";
        defer gpa.free(frame);
        const hash = std.hash.Wyhash.hash(0, frame);
        if (hash != last_hash) {
            const has_gfx = std.mem.indexOf(u8, frame, "\x1b_G") != null;
            // The theme bg is painted per ROW, not baked into the frame, and
            // blank rows are byte-identical across themes/widths — the diff
            // path skips them, stranding old-bg rows after /theme or the
            // startup OSC-11 polarity flip, and stale columns after a
            // width-only resize. Both must force a full paint.
            const full = prev.len == 0 or rows != prev_rows or cols != prev_cols or m.theme_id != prev_theme or saw_gfx or has_gfx;
            // Kitty images sit above the cell grid and survive \x1b[K / dirty
            // paints — delete before every redraw that might have shown one.
            // ?2026 synchronized output: the terminal buffers everything
            // between begin/end and swaps atomically, so a diff paint can
            // never show a half-updated frame (grok-build does the same).
            // Terminals without it ignore the pair — strictly no worse.
            w.writeAll("\x1b[?2026h") catch {};
            if (saw_gfx or has_gfx) w.writeAll("\x1b_Ga=d,d=A,q=2\x1b\\") catch {};
            paint(w, frame, rows, cols, if (full) &.{} else prev, m.theme().bg) catch {};
            w.writeAll("\x1b[?2026l") catch {};
            w.flush() catch {};
            if (prev.len != 0) gpa.free(prev);
            prev = gpa.dupe(u8, frame) catch &.{};
            prev_rows = rows;
            prev_cols = cols;
            prev_theme = m.theme_id;
            last_hash = hash;
            saw_gfx = has_gfx;
        }

        // Short wait while an unfinished escape sequence is pending: if
        // nothing follows, the lone ESC was a real Escape keypress (#94).
        const wait: i32 = if (pending_len > 0) 25 else if (m.pending != null or m.bg != null) 50 else 200;
        if (!tty.poll(wait)) {
            if (key_mod.inPaste() and m.now_ms -| last_paste_ms >= stall.paste_idle_ms) {
                // A `CSI 200~` whose `CSI 201~` never arrives latches the
                // composer into literal mode for the rest of the session:
                // Enter only inserts a newline, and Escape, Tab and every
                // slash command are swallowed. Close it out once the terminal
                // has been quiet far longer than any paste keeps streaming
                // (#532/#536/#548).
                closePaste(&m);
                last_paste_ms = m.now_ms;
                if (pending_len > 0) {
                    // Whatever was stuck mid-sequence belongs to the paste
                    // window this sweep just declared broken — debris, by
                    // definition. Handing it back to the stall path let it be
                    // re-classified as a KEY: a lone pending ESC (the head of
                    // the `CSI 201~` that never came) became the Escape key the
                    // instant the sweep cleared `in_paste`, cancelling a live
                    // turn and wiping the composer with no user keypress at
                    // all. Carry it for a late tail, arm the sweeper for a
                    // headless one, and never let it become a keystroke.
                    key_mod.stashOrphanHead(inbuf[0..pending_len]);
                    stash_ms = m.now_ms;
                    key_mod.armOrphan(true);
                    arm_ms = m.now_ms;
                    pending_len = 0;
                    esc_stall = 0;
                }
            }
            if (pending_len > 0) {
                esc_stall +|= 1;
                switch (stall.stallVerdict(inbuf[0..pending_len], esc_stall, .{
                    .turn_live = m.pending != null,
                    .in_paste = key_mod.inPaste(),
                })) {
                    .wait => {},
                    .escape_key => {
                        // Keep the ESC. If the next read is this sequence's
                        // body after all, the two rejoin and it parses as the
                        // arrow / mouse report / OSC reply it always was
                        // instead of spraying `[<35;80;24M` into the composer
                        // (#530).
                        key_mod.stashOrphanHead(inbuf[0..pending_len]);
                        stash_ms = m.now_ms;
                        pending_len = 0;
                        esc_stall = 0;
                        if (keys.handle(&m, .escape) == .quit) m.running = false;
                    },
                    .drop => {
                        // A sequence the terminal never finished, waited out.
                        // Carry the head so a late tail can still rejoin it,
                        // and tell key.zig to expect orphan debris otherwise.
                        key_mod.stashOrphanHead(inbuf[0..pending_len]);
                        stash_ms = m.now_ms;
                        key_mod.armOrphan(true);
                        arm_ms = m.now_ms;
                        pending_len = 0;
                        esc_stall = 0;
                        closePaste(&m);
                    },
                }
            }
            continue;
        }
        esc_stall = 0;
        if (pending_len == inbuf.len) {
            // A stuck head has filled the whole buffer: that is a parser
            // wedge, not a dead tty. Drop it rather than letting the
            // zero-length read below masquerade as a hangup and kill the
            // TUI mid-session (#517).
            pending_len = 0;
        }
        const got = tty.readStdin(inbuf[pending_len..]);
        if (got > 0) traj.note(io, m.now_ms, inbuf[pending_len .. pending_len + got]);
        if (got == 0) {
            // poll says readable but read gives nothing: hangup or transient
            // error. Three in a row means the TTY is gone.
            zero_reads += 1;
            if (zero_reads >= 3) m.running = false;
            continue;
        }
        zero_reads = 0;
        // ?1003h is on for image-chip hover, so a pointer merely RESTING over
        // the terminal emits a motion report roughly twice a second. Counting
        // those as paste activity postponed the idle sweep above forever: a
        // wedged paste never released while the mouse sat still anywhere over
        // the window. Only bytes that could be paste content run the clock.
        if (!stall.onlyMouseReports(inbuf[pending_len .. pending_len + got])) last_paste_ms = m.now_ms;
        // Spends any head the stall path carried: it is glued back on only
        // when these bytes really complete it (key_orphan.zig), and only while
        // the join can still plausibly be link jitter rather than a human
        // resuming typing. The debris ARM is bounded on the same principle —
        // left latched it ate the first token of whatever was typed next, at
        // any later time.
        if (stall.carryExpired(m.now_ms, stash_ms)) key_mod.stashOrphanHead("");
        if (stall.armExpired(m.now_ms, arm_ms)) key_mod.armOrphan(false);
        const n = key_mod.joinOrphanHead(&inbuf, pending_len + got);
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
    // Quitting with a turn still live: cancel FIRST — Ctrl+Q (nav.zig) and the
    // palette's /quit never did — then wait for the thread here, with the alt
    // screen still up and a frame explaining the wait, instead of joining from
    // Model.deinit after the terminal has already been handed back (#534).
    if (m.pending != null or m.bg != null) {
        turn.cancelTurn(&m);
        bgop.cancel(&m);
        m.push(.system, "■ stopping…") catch {};
        const cols = @max(tty.cols(), @as(usize, 40));
        const rows = @max(tty.rows(), @as(usize, 12));
        if (render_mod.render(&m, gpa, cols, rows, m.now_ms)) |frame| {
            defer gpa.free(frame);
            paint(w, frame, rows, cols, &.{}, m.theme().bg) catch {};
            w.flush() catch {};
        } else |_| {}
        const start = m.now_ms;
        var forced = false;
        while (!forced and (turn.quitStep(&m, m.now_ms -| start) == .wait or
            bgop.quitStep(&m, m.now_ms -| start) == .wait))
        {
            if (tty.poll(50)) {
                const got = tty.readStdin(&inbuf);
                // A second Ctrl+C / Esc during the wait means "go now".
                for (inbuf[0..got]) |b| {
                    if (b == 0x03 or b == 0x1b) forced = true;
                }
            }
            m.now_ms = nowMs(io);
        }
        const elapsed = if (forced) turn.quit_drain_ms else m.now_ms -| start;
        const stuck = turn.quitStep(&m, elapsed) == .abandon or bgop.quitStep(&m, elapsed) == .abandon;
        if (!stuck) {
            turn.finishJob(&m);
            bgop.finish(&m);
        } else {
            turn.abandonJob(&m);
            bgop.abandon(&m);
            // The threads are still writing into the job and the op, so the
            // process must not outlive the restore: put the terminal back with
            // the same bytes the defers would have written, then leave.
            w.flush() catch {};
            restore_mod.emergency();
            std.process.exit(0);
        }
    }
    if (prev.len != 0) {
        const vis = @import("dump.zig").visible(gpa, prev) catch prev;
        defer if (vis.ptr != prev.ptr) gpa.free(vis);
        traj.snap(io, m.now_ms, vis);
    }
}

fn nowMs(io: Io) u64 {
    return @intCast(@divTrunc(@max(@as(i128, 0), Io.Timestamp.now(io, .real).nanoseconds), 1_000_000));
}

/// Close a bracketed paste we can no longer finish. The parser latch and the
/// model flag are both cleared through the SAME event the terminal would have
/// sent, so there is exactly one teardown path (image attach, focus restore).
fn closePaste(m: *Model) void {
    if (!key_mod.inPaste()) return;
    key_mod.endPaste();
    _ = keys.handle(m, .paste_end);
}

fn parkToShell(io: Io, w: *Io.Writer, raw: *tty.RawState) void {
    restore_mod.unmuteStderr(); // the shell we hand over to owns the real terminal
    w.writeAll(restore_mod.seq) catch {};
    w.flush() catch {};
    tty.restore(raw.*);
    if (builtin.os.tag != .windows) {
        std.posix.raise(std.posix.SIG.TSTP) catch {};
    }
    raw.* = tty.enterRaw() orelse raw.*;
    w.writeAll(enable_seq) catch {};
    w.writeAll("\x1b]11;?\x07") catch {}; // background query -> auto light/dark (key.zig bg_report)
    w.flush() catch {};
    restore_mod.muteStderr(); // fullscreen again: stderr goes back to the log
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
        // Erase below the last painted row too: if anything ever scrolled the
        // alt screen (a resize race, a foreign write before stderr was
        // parked), no stale row survives a full repaint.
        try w.writeAll("\x1b[J");
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
        const vis = theme_mod.visibleLen(ln);
        if (vis < cols) {
            try fillRow(w, ln, cols);
        } else {
            // Row is exactly full: the cursor is ON the last column and EL
            // erases it inclusive — that ate the composer's right border.
            continue;
        }
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

test "run loop enables click+hover tracking and bracketed paste" {
    const src = @embedFile("run.zig");
    const mouse_on = [_]u8{ '?', '1', '0', '0', '0', 'h' };
    const sgr_on = [_]u8{ '?', '1', '0', '0', '6', 'h' };
    const paste_on = [_]u8{ '?', '2', '0', '0', '4', 'h' };
    // 1003 (motion) is back ON for image-chip hover previews. The v0.0.255
    // leak (raw SGR typed into the thinking line) stays pinned by key.zig's
    // flood/orphan tests; the restore seq must pop it so the shell never
    // inherits motion tracking.
    const hover_on = [_]u8{ '?', '1', '0', '0', '3', 'h' };
    const hover_off = [_]u8{ '?', '1', '0', '0', '3', 'l' };
    const kitty_on = [_]u8{ '>', '1', '1', 'u' };
    const wrap_off = [_]u8{ '?', '7', 'l' };
    try std.testing.expect(std.mem.indexOf(u8, src, &mouse_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &sgr_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &paste_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &hover_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_mod.seq, &hover_off) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &[_]u8{ '?', '1', '0', '0', '7', 'h' }) == null);
    try std.testing.expect(std.mem.indexOf(u8, src, &kitty_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, &wrap_off) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "a=d,d=A") != null);
    // #517: a buffer-filling parser wedge must be cleared before the read,
    // or the zero-length read reads as a hangup and kills the TUI.
    try std.testing.expect(std.mem.indexOf(u8, src, "pending_len == inbuf.len") != null);
    // The idle paste sweep must DISCARD whatever was stuck mid-sequence before
    // the stall path below can see it. Leaving it there let a lone pending ESC
    // become the Escape KEY the instant `in_paste` cleared, cancelling a live
    // turn and wiping the composer with no keypress at all.
    const sweep_at = std.mem.indexOf(u8, src, "closePaste(&m);").?;
    const stall_at = std.mem.indexOfPos(u8, src, sweep_at, "esc_stall +|= 1").?;
    const sweep_block = src[sweep_at..stall_at];
    try std.testing.expect(std.mem.indexOf(u8, sweep_block, "pending_len = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sweep_block, "armOrphan(true)") != null);
    // Both unbounded holds are bounded: a resting mouse must not keep the paste
    // latch alive, and the debris arm must go stale on its own clock.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!stall.onlyMouseReports(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (stall.armExpired(") != null);
}

// The stall-verdict / carry-window / arm-window battery lives beside the
// policy it pins, in run_stall.zig.

fn paintToBuf(a: std.mem.Allocator, frame: []const u8, rows: usize, cols: usize, prev: []const u8) ![]u8 {
    var aw = Io.Writer.Allocating.init(a);
    errdefer aw.deinit();
    try paint(&aw.writer, frame, rows, cols, prev, "\x1b[48;2;20;20;20m");
    return aw.toOwnedSlice();
}

test "paint keeps a full row's last glyph but still erases every shorter row" {
    const a = std.testing.allocator;
    // Row 0 is exactly 10 columns: ESC[K sits ON the last cell and would eat
    // the composer's right border, so a full row gets neither pad nor erase.
    // Row 1 is short and must get both.
    const out = try paintToBuf(a, "╭────────╮\nshort", 2, 10, "XXXXXXXXXX\nold row!!");
    defer a.free(out);
    const border = std.mem.indexOf(u8, out, "╭────────╮").?;
    const short = std.mem.indexOf(u8, out, "short").?;
    const erase = std.mem.indexOfPos(u8, out, border, "\x1b[K");
    try std.testing.expect(erase != null and erase.? > short);
    try std.testing.expect(std.mem.indexOfPos(u8, out, short, "     ") != null);
}

test "paint erases a row whose glyphs are ambiguous width" {
    const a = std.testing.allocator;
    // "  ✓ bash finished ok" draws 20 cells. When visibleLen claimed 21 it
    // measured full at cols=21, so paint skipped the pad AND the erase and the
    // 21st cell kept the previous frame. Both must still happen.
    const frame = "  \u{2713} bash finished ok";
    try std.testing.expectEqual(@as(usize, 20), theme_mod.visibleLen(frame));
    const out = try paintToBuf(a, frame, 1, 21, "RESIDUE RESIDUE RESIDU");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[K") != null);
}

test "rowChanged only flags the line that actually moved" {
    const prev = "top\nmiddle\nbottom";
    const next = "top\nmiddle\nBOTTOM";
    try std.testing.expect(!rowChanged(prev, next, 0));
    try std.testing.expect(!rowChanged(prev, next, 1));
    try std.testing.expect(rowChanged(prev, next, 2));
    try std.testing.expect(!rowChanged(prev, prev, 2));
}
