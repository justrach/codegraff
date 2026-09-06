//! run.zig runtime-loop contract tests.

const std = @import("std");

const restore_mod = @import("restore.zig");
const run = @import("run.zig");
const stall = @import("run_stall.zig");
const heal_interval_ms = run.heal_interval_ms;

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
    try std.testing.expect(std.mem.indexOf(u8, src, "imgproto.clear_all") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "imgproto.sync(") != null);
    // The idle paste sweep must DISCARD whatever was stuck mid-sequence before
    // the stall path below can see it. Leaving it there let a lone pending ESC
    // become the Escape KEY the instant `in_paste` cleared, cancelling a live
    // turn and wiping the composer with no keypress at all.
    const sweep_at = std.mem.indexOf(u8, src, "closePaste(&m);").?;
    const stall_at = std.mem.indexOfPos(u8, src, sweep_at, "esc_stall +|= 1").?;
    const sweep_block = src[sweep_at..stall_at];
    try std.testing.expect(std.mem.indexOf(u8, sweep_block, "pending_len = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sweep_block, ".dropped") != null);
    // Both unbounded holds are bounded: a resting mouse must not keep the paste
    // latch alive, and the debris arm must go stale on its own clock.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!stall.onlyMouseReports(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (stall.armExpired(") != null);
    const drop_at = std.mem.indexOf(u8, src, ".drop => {").?;
    try std.testing.expect(std.mem.indexOfPos(u8, src, drop_at, "key_mod.abandonSequence(") != null);
}

// The stall-verdict / carry-window / arm-window battery lives beside the
// policy it pins, in run_stall.zig; the frame painter's own battery (residue,
// glyph torture, row-style isolation, the self-heal) lives in paint.zig.

test "one tick drains the whole tty, coalesces the wheel, and paints once" {
    const src = @embedFile("run.zig");
    // (a) Every byte the tty already holds joins THIS tick before dispatch —
    // one read per frame is what made momentum scrolling lag and then jump.
    const read_at = std.mem.indexOf(u8, src, "const got = tty.readStdin(").?;
    const dispatch_at = std.mem.indexOfPos(u8, src, read_at, "batch.next(inbuf[0..n]").?;
    const drain = src[read_at..dispatch_at];
    try std.testing.expect(std.mem.indexOf(u8, drain, "while (filled < inbuf.len and tty.poll(0))") != null);
    // ...bounded, or an endless flood would be drained and never painted.
    try std.testing.expect(std.mem.indexOf(u8, drain, "pacing.drainExpired(") != null);
    // (b) The batch is applied as one unit and the wheel run goes through the
    // same door a single report does.
    try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"input_batch.zig\").Decoder") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "keys.handleBatchItem(&m, item)") != null);
    // (c) The frame is gated on the budget, and the gate sits BEFORE the render
    // — gating only the paint would still pay for composing every frame.
    const gate_at = std.mem.indexOf(u8, src, "pacing.shouldPaint(").?;
    try std.testing.expect(gate_at < std.mem.indexOf(u8, src, "render_mod.render(&m, gpa, cols, rows").?);
    // ...and the storm signal is a non-blocking poll OR the arrival RATE, so a
    // fast loop that reads each report the instant it lands still paces, and a
    // quiet one never waits on the budget for a single flick.
    try std.testing.expect(std.mem.indexOf(u8, src, "const more_pending = tty.poll(0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "last_input_ms = m.now_ms;") != null);
    // A deferred frame comes back through the poll timeout the loop already
    // has, and only when one is actually owed.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!painted and pending_len == 0) wait = pacing.waitCap(") != null);
}

test "a wheel storm cannot be mistaken for paste activity" {
    // The drained buffer is handed to onlyMouseReports whole: a storm is all
    // complete SGR reports, so it never refreshes the paste clock, and a read
    // carrying one real keystroke still does.
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    while (n + 10 <= 400) : (n += 10) @memcpy(buf[n .. n + 10], "\x1b[<65;4;4M");
    try std.testing.expect(stall.onlyMouseReports(buf[0..n]));
    buf[n] = 'k';
    try std.testing.expect(!stall.onlyMouseReports(buf[0 .. n + 1]));
}

test "the loop self-heals: a resize EVENT and a periodic sweep force a repaint" {
    const src = @embedFile("run.zig");
    // A SIGWINCH that starts and ends on the same dimensions is invisible to a
    // dimension comparison, and one that lands between tty.cols() and the
    // paint leaves the diff baseline describing a screen the terminal has
    // already reflowed. Both are covered by the EVENT.
    try std.testing.expect(std.mem.indexOf(u8, src, "restore_mod.takeResized()") != null);
    // ...and anything else that writes over us (an async kitty image delete,
    // a terminal-side redraw) is repaired on the heartbeat, which must be able
    // to run even when the frame hash has not moved.
    try std.testing.expect(std.mem.indexOf(u8, src, "hash != last_hash or heal") != null);
    try std.testing.expect(heal_interval_ms > 0);
    // ...and the self-heal must never be served by the scroll fast path, whose
    // whole point is to SKIP rows that are already correct — which is exactly
    // the set of rows a heal exists to rewrite. Same for `full`, which folds in
    // kitty graphics (pixels do not move when cells scroll), resize and theme.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (full or heal or gfx.on or want_gfx) null else m.paint_hint") != null);
    // Theme bg is painted per row, not baked into the frame. Blank rows are
    // byte-identical across themes, so a diff paint would strand the old
    // canvas — /theme and the startup OSC-11 flip both force a full paint.
    try std.testing.expect(std.mem.indexOf(u8, src, "m.theme_id != prev_theme") != null);
}
