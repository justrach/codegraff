//! Esc-cancel handling: escWatchTask polls stdin from the pool while the
//! root awaits tool futures (postStream only watches stdin during a live
//! HTTP stream, so a long tool join used to be Esc-deaf); escPressed is
//! the non-blocking stdin scanner shared by both paths — it also captures
//! steering text typed ahead into main_mod.g_steer_buf/main_mod.g_steer_queue and toggles
//! the live Thinking-block fold on a mouse click. sleepInterruptible lets
//! a retry backoff be cancelled the same way. Split out of the Agent
//! struct (#123, 600-line goal).
//!
//! Agent.esc_cancel/Agent.esc_watch_done are struct-level `pub var`s that stay
//! declared directly inside the Agent struct in main.zig — aliasing a
//! `var` with `const x = mod.x;` would freeze a copy of its value instead
//! of sharing the live storage, silently breaking cross-file state
//! sharing. Reached here as `Agent.Agent.esc_cancel`/`Agent.Agent.esc_watch_done`.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const repl_glue = @import("repl_glue.zig");
const Agent = agent_mod.Agent;

const terminal = @import("term.zig");
const tty = terminal.tty;

pub fn escWatchTask() void {
    while (!Agent.esc_watch_done.load(.acquire)) {
        if (tty.poll(100) and escPressed(false)) {
            Agent.esc_cancel.store(true, .release);
            return;
        }
    }
}

/// Non-blocking scan of stdin (terminal must be in VMIN=0 raw mode). A
/// lone Esc cancels the turn (returns true); CSI sequences (arrows:
/// ESC[…/ESC O…) are swallowed and don't cancel. Printable bytes are
/// captured into the steering buffer and echoed when `echo` (main thread
/// only — the esc watch task runs on the pool and must not race tool
/// output); Enter flushes the line to main_mod.g_steer_queue, which the REPL
/// drains as follow-up turns after the current one finishes. A second
/// Enter on an empty line (double-enter) with a non-empty queue
/// force-interrupts the current turn so the queue drains immediately.
pub fn escPressed(echo: bool) bool {
    var buf: [256]u8 = undefined;
    var n = tty.readStdin(&buf);
    var esc_found = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = buf[i];
        if (c == 0x1b) {
            if (i + 1 < n and buf[i + 1] == '[') {
                // CSI escape sequence (arrows, Home/End, Delete, DSR reply,
                // mouse, etc.). Consume through the final byte (0x40..0x7e) so
                // bytes like "[A" never get captured as steering prompt text. A
                // CSI run can straddle a VMIN=0 read boundary — e.g. the
                // \x1b[<row>;<col>R cursor-position reply to our \x1b[6n, or a
                // burst of SGR mouse-wheel reports if click-to-fold reporting is
                // re-enabled. If the final byte hasn't landed yet, poll briefly and
                // pull the tail into the same buffer so its trailing digits/';'/
                // final byte don't leak in as steer text.
                var j = i + 2;
                while (true) {
                    while (j < n) : (j += 1) {
                        if (buf[j] >= 0x40 and buf[j] <= 0x7e) break;
                    }
                    if (j < n or n >= buf.len or !tty.poll(50)) break;
                    const more = tty.readStdin(buf[n..]);
                    if (more == 0) break;
                    n += more;
                }
                // SGR mouse report (ESC [ < btn ; col ; row, M=press/m=release):
                // a plain left-button press (btn 0) on the live Thinking block
                // toggles its fold — the clickable control for #92. Other mouse
                // events fall through and are swallowed like any CSI sequence.
                if (j < n and buf[j] == 'M' and i + 2 < n and buf[i + 2] == '<') {
                    var mk = i + 3;
                    var btn: usize = 0;
                    var got = false;
                    while (mk < j and buf[mk] >= '0' and buf[mk] <= '9') : (mk += 1) {
                        btn = btn * 10 + (buf[mk] - '0');
                        got = true;
                    }
                    if (got and btn == 0 and main_mod.g_thinking_open) main_mod.g_thinking_fold_request = true;
                }
                i = if (j < n) j else n - 1;
                continue;
            } else if (i + 1 < n and buf[i + 1] == 'O') {
                // SS3 escape sequence (common for function/cursor keys):
                // ESC O <final>. Swallow the whole sequence.
                i = @min(i + 2, n - 1);
                continue;
            } else if (i + 1 >= n) {
                // ESC is the LAST byte of this chunk — it may be the truncated
                // head of a split CSI/SS3/DSR sequence (e.g. a delayed
                // `\x1b[<row>;<col>R` cursor-position reply to our `\x1b[6n`)
                // read across two VMIN=0 reads, NOT a real Esc keypress (#94).
                // Briefly wait for a continuation before concluding it's an Esc.
                if (tty.poll(50)) {
                    var more: [64]u8 = undefined;
                    if (tty.readStdin(&more) > 0) {
                        i = n; // a sequence/alt-chord followed — not a lone Esc
                        continue;
                    }
                }
                // Nothing followed within the grace window: a genuine lone Esc.
                esc_found = true;
                main_mod.g_force_interrupt = false;
            } else {
                // ESC + a non-CSI/SS3 byte in the same chunk: a real Esc.
                esc_found = true;
                main_mod.g_force_interrupt = false;
            }
            continue;
        } else if (c == '\n' or c == '\r') {
            if (main_mod.g_steer_buf.items.len > 0) {
                // Flush the typed line to the queue as a regular
                // follow-up (runs after the current turn finishes).
                // Under steerLock so concurrent drainers serialize; skip an empty
                // flush (another arm drained it first) or one byte-identical to the
                // tail, so one submit can't enqueue as N copies each re-steered with
                // its own harness note (#129).
                repl_glue.steerLock();
                if (main_mod.g_steer_buf.toOwnedSlice(std.heap.page_allocator)) |dup| {
                    if (repl_glue.steerFlushRedundant(main_mod.g_steer_queue.items, dup)) {
                        std.heap.page_allocator.free(dup);
                    } else {
                        main_mod.g_steer_queue.append(std.heap.page_allocator, .{ .text = dup, .force = false }) catch std.heap.page_allocator.free(dup);
                    }
                } else |_| main_mod.g_steer_buf.clearRetainingCapacity();
                repl_glue.steerUnlock();
                if (echo and main_mod.g_steer_echoed) {
                    var qbuf: [64]u8 = undefined;
                    const qmsg = std.fmt.bufPrint(&qbuf, "  \x1b[2m[queued · {d} waiting]\x1b[0m\n", .{main_mod.g_steer_queue.items.len}) catch "\n";
                    repl_glue.steerEcho(qmsg);
                }
            } else if (main_mod.g_steer_queue.items.len > 0) {
                // Double-enter (empty line + queue non-empty): force —
                // promote the first queued item and interrupt the
                // current turn so the queue drains starting now.
                main_mod.g_steer_queue.items[0].force = true;
                esc_found = true;
                main_mod.g_force_interrupt = true;
                if (echo) {
                    if (main_mod.g_steer_echoed) repl_glue.steerEcho("\n");
                    repl_glue.steerEcho("\x1b[33m↳ force › interrupting…\x1b[0m\n");
                }
            }
            main_mod.g_steer_echoed = false;
            main_mod.g_steer_visible.store(false, .release);
            continue;
        } else if (c == 0x7f or c == 0x08) { // backspace / Ctrl-H
            if (main_mod.g_steer_buf.items.len > 0) {
                _ = main_mod.g_steer_buf.pop();
                if (echo) repl_glue.steerEcho("\x08 \x08");
            }
            continue;
        } else if (c == 0x14) { // Ctrl-T: fold/unfold the live Thinking block (#92)
            main_mod.g_thinking_fold_request = true;
            continue;
        } else if (c < 0x20) {
            continue; // other control bytes: ignore
        }
        main_mod.g_steer_buf.append(std.heap.page_allocator, c) catch continue;
        if (echo) {
            if (!main_mod.g_steer_echoed) {
                main_mod.g_steer_visible.store(true, .release);
                repl_glue.steerEcho("\n\x1b[36m↳ steer ›\x1b[0m ");
                main_mod.g_steer_echoed = true;
            }
            repl_glue.steerEcho(buf[i .. i + 1]);
        }
    }
    return esc_found;
}

/// Process any bytes queued on stdin (terminal must be in VMIN=0 raw
/// mode) so typed-ahead steering text is preserved instead of leaking into
/// the next prompt or being blindly discarded. Returns true if Esc/force
/// was seen while draining.
pub fn drainSteerStdin(echo: bool) bool {
    var esc_found = false;
    while (true) {
        if (!tty.poll(0)) return esc_found;
        if (escPressed(echo)) esc_found = true;
    }
}

pub fn drainStdin() void {
    _ = drainSteerStdin(false);
}

/// Put stdin into raw non-blocking no-echo mode (VMIN=0) for Esc
/// watching. Returns the termios to restore, or null off-tty.
pub fn rawNonblockStdin() ?tty.RawState {
    return tty.enterRaw(false);
}

/// Sleep `ms` watching stdin for Esc (when the root is on a TTY), so the
/// user can cancel a retry backoff instead of waiting it out.
pub fn sleepInterruptible(self: *Agent, ms: u64) error{Interrupted}!void {
    const watch = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig_tio: ?tty.RawState = if (watch) rawNonblockStdin() else null;
    defer if (orig_tio) |o| tty.restore(o);
    var left = ms;
    while (left > 0) {
        const chunk = @min(left, 100);
        self.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch {};
        left -= chunk;
        if (orig_tio != null and escPressed(true)) return error.Interrupted;
    }
}

/// The `data: {...}` payload of one SSE line, or null for anything else
/// (event: lines, keep-alive blanks, [DONE]).
pub fn ssePayload(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \r");
    if (!std.mem.startsWith(u8, line, "data:")) return null;
    const payload = std.mem.trim(u8, line["data:".len..], " ");
    if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) return null;
    return payload;
}

pub fn sseIndex(obj: std.json.ObjectMap) ?usize {
    const ix = obj.get("index") orelse return null;
    if (ix != .integer or ix.integer < 0) return null;
    return @intCast(ix.integer);
}
