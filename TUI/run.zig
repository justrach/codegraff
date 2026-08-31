//! Fullscreen loop on term.zig + ANSI. No zigzag, no OpenTUI-via-TS.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const app = @import("app.zig");
const bgop = @import("bgop.zig");
const engine = @import("engine.zig");
const key_mod = @import("key.zig");
const keys = @import("keys.zig");
const pacing = @import("pacing.zig");
const paint_mod = @import("paint.zig");
const render_mod = @import("render.zig");
const restore_mod = @import("restore.zig");
const stall = @import("run_stall.zig");
const turn = @import("turn.zig");
const tty = @import("tty.zig");
const traj = @import("traj.zig");
const Model = app.Model;

// 1000/1003/1006: click + hover + wheel as buttons 64/65 (not arrows).
// 2004: bracketed paste. 7l: no autowrap into the prompt.
// >11u: kitty disambiguate + event types + all-keys (Cmd+Delete / Super latch).
// >4;2m: xterm modifyOtherKeys so Super+Backspace also arrives as CSI 27;9;127~.
pub const enable_seq = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m";

/// How long the screen may go without a full row-by-row rewrite. Short enough
/// that nobody sits looking at damage, long enough to cost nothing: the frame
/// is unchanged, so the repaint is the same bytes into a synchronized swap.
pub const heal_interval_ms: u64 = 3000;

/// Every seam the frontend is handed, declared with the engine that owns
/// them (engine.RunOpts). Re-exported here because `run` is its only caller.
pub const RunOpts = engine.RunOpts;

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    opts: RunOpts,
) !void {
    // Local-only pacing instrumentation. Off unless asked for, never uploaded:
    // the pty storm test needs a way to count frames from outside the process.
    pacing.stats_on = environ_map.get("GRAFF_TUI_PAINT_STATS") != null;
    pacing.resetStats();
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
    engine.g_resume_fn = opts.resume_fn;
    engine.g_state_fn = opts.state_fn;
    engine.g_idle_wake_fn = opts.idle_wake_fn;
    engine.g_peer_fn = opts.peer_fn;
    engine.g_model_name = opts.model_name;
    engine.g_model_provider = opts.model_provider;
    engine.g_model_entries = opts.model_entries;
    engine.g_cwd = opts.cwd;

    var m: Model = undefined;
    m.setup(gpa);
    defer m.deinit();
    defer if (opts.state_fn) |f| f(opts.turn_ctx, .{
        .session_name = m.session_name orelse "",
        .goal = m.goal orelse "",
        .strict = m.strict,
        .ultracode = m.ultracode,
    });
    for (opts.initial_history) |item| m.push(if (item.role == .user) .user else .assistant, item.text) catch {};
    m.turns = m.userTurnCount();
    if (opts.session_name.len > 0) m.session_name = gpa.dupe(u8, opts.session_name) catch null;
    if (opts.initial_goal.len > 0) m.goal = gpa.dupe(u8, opts.initial_goal) catch null;
    m.strict = opts.initial_strict;
    m.ultracode = opts.initial_ultracode;
    if (opts.yolo) m.mode = .always_approve;

    const claimed = restore_mod.takeClaim();
    var raw = claimed orelse (tty.enterRaw() orelse return error.NotATty);
    if (claimed != null) _ = tty.enterRaw(); // boot may have put the line discipline back
    if (claimed == null) restore_mod.arm(raw, enable_seq);
    defer restore_mod.disarm();
    defer tty.restore(raw);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    w.writeAll(enable_seq) catch {};
    w.writeAll("\x1b]11;?\x07") catch {}; // background query -> auto light/dark (key.zig bg_report)
    w.flush() catch {};
    // Registered BEFORE the restore below, so LIFO puts the line on the normal
    // screen after the alt screen is gone. No-op unless GRAFF_TUI_PAINT_STATS.
    defer pacing.report(w);
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

    // Sized for a momentum storm, not a keystroke: a trackpad fling is ~13
    // bytes of SGR per report and the loop now drains every one the tty holds
    // into a single tick (see the drain below).
    var inbuf: [16 * 1024]u8 = undefined;
    var pending_len: usize = 0;
    var last_frame_ms: u64 = 0;
    // When the last byte of input arrived — the rate side of the storm test.
    var last_input_ms: u64 = 0;
    var esc_stall: u8 = 0;
    var esc_live = false; // operation state latched when a lone ESC arrives
    var zero_reads: u8 = 0;
    // Clock for the bracketed-paste latch only: refreshed by bytes that could
    // plausibly BE paste content, never by mouse-motion noise (see below).
    var last_paste_ms: u64 = 0;
    var stash_ms: u64 = 0;
    var arm_ms: u64 = 0;
    var last_hash: u64 = 0;
    var last_heal_ms: u64 = 0;
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
        if (m.pending == null) turn.maybeJobWake(&m);
        // Background engine ops (/compact, !cmd, @-file list) land here too —
        // the same poll that keeps a turn from freezing the loop (#533).
        bgop.finish(&m);
        pacing.ticks += 1;
        // At most ONE composed frame per tick, and while input keeps arriving,
        // at most one per frame budget (pacing.zig). The storm signal is a
        // backlog OR a stream still landing inside the storm window — a check
        // for queued bytes alone misses momentum entirely, because on a loop
        // this fast every report is read the instant it arrives and finds the
        // queue empty behind it. Quiet, the frame is composed on the spot, so a
        // single flick pays nothing. A skipped tick falls straight through to
        // the drain below, so the frame that does land shows the LATEST scroll
        // position — the intermediate ones are never painted at all. A hover
        // sweep is the same shape as a momentum flick and rides the same lane.
        const more_pending = tty.poll(0);
        const painted = pacing.shouldPaint(m.now_ms, last_frame_ms, last_input_ms, more_pending);
        if (!painted) {
            pacing.frames_skipped += 1;
        } else {
            last_frame_ms = m.now_ms;
            pacing.frames += 1;
            frame_blk: {
                const cols = @max(tty.cols(), @as(usize, 40));
                const rows = @max(tty.rows(), @as(usize, 12));
                const frame = render_mod.render(&m, gpa, cols, rows, m.now_ms) catch break :frame_blk;
                defer gpa.free(frame);
                // A copy landed inside that render (selection.zig commits the
                // clipboard from the pass that captured it). OSC 52 asks the
                // TERMINAL for its clipboard, which is the only one an SSH user
                // can paste from — and it goes out HERE, outside the frame,
                // because the frame gets repainted and a clipboard write must
                // happen exactly once.
                const osc = @import("selection.zig").takeOsc52(&m);
                if (osc.len > 0) {
                    w.writeAll(osc) catch {};
                    w.flush() catch {};
                    m.alloc.free(osc); // minted by the model's own allocator
                }
                const hash = std.hash.Wyhash.hash(0, frame);
                // The diff painter trusts `prev` to be what is on screen. Two
                // things can make that a lie without changing a single byte of
                // the frame: a resize the loop never sees (SIGWINCH between
                // tty.cols() and the paint, or one that ends on the dimensions
                // it started from — the terminal still reflowed), and any async
                // writer over the same tty (a kitty image delete redrawing
                // late). Neither moves the hash, so neither would ever be
                // repaired. A resize EVENT forces the full clear-and-lay-down;
                // the heartbeat forces a cheaper every-row rewrite of the frame
                // we already believe is up, which under ?2026 is byte-identical
                // output into a synchronized swap — visually a no-op.
                const resized = restore_mod.takeResized();
                const heal = resized or m.now_ms -| last_heal_ms >= heal_interval_ms;
                if (hash != last_hash or heal) {
                    const has_gfx = std.mem.indexOf(u8, frame, "\x1b_G") != null;
                    // The theme bg is painted per ROW, not baked into the
                    // frame, and blank rows are byte-identical across
                    // themes/widths — the diff path skips them, stranding
                    // old-bg rows after /theme or the startup OSC-11 polarity
                    // flip, and stale columns after a width-only resize. Both
                    // must force a full paint.
                    const full = prev.len == 0 or rows != prev_rows or cols != prev_cols or m.theme_id != prev_theme or saw_gfx or has_gfx or resized;
                    // Kitty images sit above the cell grid and survive \x1b[K /
                    // dirty paints — delete before every redraw that might have
                    // shown one. ?2026 synchronized output: the terminal
                    // buffers everything between begin/end and swaps
                    // atomically, so a diff paint can never show a half-updated
                    // frame (grok-build does the same). Terminals without it
                    // ignore the pair — strictly no worse.
                    // Scrolling the transcript moves CELLS, not the kitty
                    // images that sit above the cell grid — and the self-heal
                    // exists precisely to rewrite rows a scroll would skip.
                    // Both take the whole-screen paths, so neither may reach
                    // the scroll fast path; `full` already folds in graphics,
                    // resize and theme.
                    const hint = if (full or heal) null else m.paint_hint;
                    w.writeAll("\x1b[?2026h") catch {};
                    if (saw_gfx or has_gfx) w.writeAll("\x1b_Ga=d,d=A,q=2\x1b\\") catch {};
                    paint_mod.paint(w, frame, rows, cols, if (full) &.{} else prev, m.theme().bg, heal, hint) catch {};
                    w.writeAll("\x1b[?2026l") catch {};
                    w.flush() catch {};
                    pacing.paints += 1;
                    if (prev.len != 0) gpa.free(prev);
                    prev = gpa.dupe(u8, frame) catch &.{};
                    prev_rows = rows;
                    prev_cols = cols;
                    prev_theme = m.theme_id;
                    last_hash = hash;
                    saw_gfx = has_gfx;
                    // Only a paint that rewrote EVERY row resets the heartbeat.
                    if (full or heal) last_heal_ms = m.now_ms;
                }
            }
        }

        // Short wait while an unfinished escape sequence is pending: if
        // nothing follows, the lone ESC was a real Escape keypress (#94).
        var wait: i32 = if (pending_len > 0) 25 else if (m.pending != null or m.bg != null) 50 else 200;
        // A deferred frame is a debt: come back for it when the budget is up,
        // through the poll timeout the loop already has. Only when a frame is
        // owed AND no escape head is pending, so an idle loop keeps its long
        // cheap waits and #94's stall clock keeps its 25ms tick exactly.
        if (!painted and pending_len == 0) wait = pacing.waitCap(m.now_ms, last_frame_ms, wait);
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
                    key_mod.abandonSequence(inbuf[0..pending_len], .dropped);
                    stash_ms = m.now_ms;
                    arm_ms = m.now_ms;
                    pending_len = 0;
                    esc_stall = 0;
                }
            }
            if (pending_len > 0) {
                esc_stall +|= 1;
                switch (stall.stallVerdict(inbuf[0..pending_len], esc_stall, .{
                    .operation_live = esc_live or m.pending != null or m.bg != null,
                    .in_paste = key_mod.inPaste(),
                })) {
                    .wait => {},
                    .escape_key => {
                        // Keep the ESC. If the next read is this sequence's
                        // body after all, the two rejoin and it parses as the
                        // arrow / mouse report / OSC reply it always was
                        // instead of spraying `[<35;80;24M` into the composer
                        // (#530).
                        key_mod.abandonSequence(inbuf[0..pending_len], .escape);
                        stash_ms = m.now_ms;
                        arm_ms = m.now_ms;
                        pending_len = 0;
                        esc_stall = 0;
                        if (keys.handle(&m, .escape) == .quit) m.running = false;
                    },
                    .escape_pair => {
                        // A genuine double Escape is still two Escape keys;
                        // only an unfinished legacy Alt CSI reaches here.
                        key_mod.abandonSequence(inbuf[0..pending_len], .none);
                        pending_len = 0;
                        esc_stall = 0;
                        if (keys.handle(&m, .escape) == .quit) m.running = false;
                        if (m.running and keys.handle(&m, .escape) == .quit) m.running = false;
                    },
                    .drop => {
                        // A sequence the terminal never finished, waited out.
                        // Carry the head so a late tail can still rejoin it,
                        // and tell key.zig to expect orphan debris otherwise.
                        key_mod.abandonSequence(inbuf[0..pending_len], .dropped);
                        stash_ms = m.now_ms;
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
            key_mod.abandonSequence(inbuf[0..pending_len], .dropped);
            stash_ms = m.now_ms;
            arm_ms = m.now_ms;
            esc_live = false;
        }
        pending_len = stall.clearFullWedge(pending_len, inbuf.len);
        var filled = pending_len;
        const got = tty.readStdin(inbuf[filled..]);
        pacing.reads += 1;
        if (got == 0) {
            // poll says readable but read gives nothing: hangup or transient
            // error. Three in a row means the TTY is gone.
            zero_reads += 1;
            if (zero_reads >= 3) m.running = false;
            continue;
        }
        zero_reads = 0;
        filled += got;
        last_input_ms = m.now_ms;
        // Take EVERYTHING the tty already holds into THIS tick before any
        // dispatch. Trackpad momentum arrives a few reports at a time, and
        // servicing one read per frame is exactly what makes the scroll trail
        // the fingers and then jump when the backlog drains. Bounded twice — by
        // the buffer, and by the frame budget, so a flood that never stops
        // still yields a frame every ~8ms instead of never.
        while (filled < inbuf.len and tty.poll(0)) {
            if (pacing.drainExpired(nowMs(io), m.now_ms)) break;
            const more = tty.readStdin(inbuf[filled..]);
            pacing.reads += 1;
            if (more == 0) break;
            filled += more;
        }
        traj.note(io, m.now_ms, inbuf[pending_len..filled]);
        // ?1003h is on for image-chip hover, so a pointer merely RESTING over
        // the terminal emits a motion report roughly twice a second. Counting
        // those as paste activity postponed the idle sweep above forever: a
        // wedged paste never released while the mouse sat still anywhere over
        // the window. Only bytes that could be paste content run the clock —
        // and a wheel storm is likewise all mouse reports, so it cannot hold a
        // broken paste open either.
        if (!stall.onlyMouseReports(inbuf[pending_len..filled])) last_paste_ms = m.now_ms;
        // A genuine Escape's exact carry is short; a non-lone head actually
        // dropped after its stall budget keeps its framing for the full arm
        // interval. Either kind is still one-shot on the first new read.
        if (stall.escapeCarryExpired(m.now_ms, stash_ms)) key_mod.expireOrphanHead();
        if (stall.armExpired(m.now_ms, arm_ms)) key_mod.armOrphan(false);
        const n = key_mod.joinOrphanHead(&inbuf, filled);
        // Everything this tick drained is applied as ONE batch, with runs of
        // consecutive wheel reports folded into a single accumulated delta
        // (pacing.zig). Order is preserved and a keystroke BREAKS the run at
        // its exact position, so typing is never starved behind a flood — and
        // because only one frame follows the whole batch, no intermediate
        // scroll position is ever painted.
        var batch: pacing.Batch = .{};
        var i: usize = 0;
        var drained = false;
        while (!drained) {
            const arrived: ?key_mod.Key = key_mod.next(inbuf[0..n], &i);
            if (arrived) |k| {
                pacing.events += 1;
                if (pacing.wheelNotch(k) != null) pacing.wheel_events += 1;
                if (batch.push(k) == .ok) continue;
            } else drained = true;
            for (batch.items()) |item| {
                if (item == .wheel) pacing.wheel_batches += 1;
                const effect = keys.handleBatchItem(&m, item);
                switch (effect) {
                    .stay => {},
                    .quit => {
                        m.running = false;
                        drained = true;
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
            batch.reset();
            // The batch filled mid-stream: the event that did not fit opens the
            // next one, so nothing is dropped and nothing is reordered.
            if (!drained) {
                if (arrived) |k| _ = batch.push(k);
            }
        }
        if (i < n) {
            const rest = n - i;
            std.mem.copyForwards(u8, inbuf[0..rest], inbuf[i..n]);
            pending_len = rest;
        } else pending_len = 0;
        // Capture operation state before it can complete between polls. Keep
        // that bounded grace when a lone ESC grows into a legacy Alt prefix.
        if (pending_len == 0) esc_live = false else if (!esc_live and (m.pending != null or m.bg != null)) esc_live = true;
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
            paint_mod.paint(w, frame, rows, cols, &.{}, m.theme().bg, true, null) catch {};
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
            if (opts.emergency_fn) |f| f(opts.turn_ctx);
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
