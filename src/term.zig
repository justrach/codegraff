//! Terminal primitives (std/builtin leaf, no main import): the cross-platform
//! raw-mode / stdin-poll `tty` layer, terminal size (termCols/termRows), the
//! streamed-reasoning row counter, and the stdin-ready polls. Split out of
//! main.zig (600-line goal). main aliases the rest back so call sites stay
//! unqualified.
//!
//! The Windows console/pipe shim moved to win_api.zig (#429) and is re-exported
//! below: hooks.zig wants one call out of it (PeekNamedPipe) and must not have
//! to import the terminal cluster to get it.

const std = @import("std");
const builtin = @import("builtin");

pub const win = @import("win_api.zig");

/// Cross-platform terminal control. POSIX uses termios + ioctl(TIOCGWINSZ) +
/// poll; Windows uses the console API (Get/SetConsoleMode, screen-buffer info,
/// WaitForSingleObject + ReadConsoleInput). The TUI's raw-mode, window-size,
/// and non-blocking stdin paths all go through here so the harness builds and
/// runs the same on both. ENABLE_VIRTUAL_TERMINAL_INPUT makes Windows deliver
/// arrow/function keys as the VT escape sequences the POSIX parser understands.
pub const tty = struct {
    const is_windows = builtin.os.tag == .windows;

    /// Saved terminal state for restore(): termios on POSIX, the prior console
    /// input-mode word on Windows.
    pub const RawState = if (is_windows) struct { in_mode: u32 } else std.posix.termios;

    /// POSIX job control can move a process group out of the foreground between
    /// a readiness check and the actual read/tcsetattr. A background terminal
    /// read normally stops the whole group with SIGTTIN (issue #271), while a
    /// terminal-mode change may do the same with SIGTTOU. Block only around the
    /// syscall; POSIX then returns EIO instead of suspending Graff. The mask is
    /// per-thread and restored immediately.
    const JobControlGuard = if (is_windows) struct {
        fn init(comptime _: enum { input, output }) @This() {
            return .{};
        }
        fn deinit(_: *@This()) void {}
    } else struct {
        old: std.posix.sigset_t,

        fn init(comptime operation: enum { input, output }) @This() {
            var set = std.posix.sigemptyset();
            std.posix.sigaddset(&set, if (operation == .input) .TTIN else .TTOU);
            var old: std.posix.sigset_t = undefined;
            std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, &old);
            return .{ .old = old };
        }

        fn deinit(self: *@This()) void {
            std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.old, null);
        }
    };

    /// Who owns the controlling terminal. A tty read issued from a BACKGROUND
    /// process group is what raises SIGTTIN, so #396's prompt asks this before
    /// it ever blocks. Anything unknowable answers "we do" — the pre-#396
    /// behaviour — so a platform without the call, or a stdin that is not a
    /// terminal, can never make Graff give up by mistake.
    /// (std.posix.tcgetpgrp exists but resolves through std.c, which carries no
    /// tcgetpgrp/getpgrp on Darwin — so each family declares its own: raw
    /// syscalls on Linux, where a build may not link libc at all, and the libc
    /// symbols everywhere else.)
    const Foreground = if (is_windows) struct {
        fn owned() bool {
            return true;
        }
    } else if (builtin.os.tag == .linux) struct {
        fn owned() bool {
            var fg: std.posix.pid_t = undefined;
            const rc = std.os.linux.tcgetpgrp(std.posix.STDIN_FILENO, &fg);
            if (@as(isize, @bitCast(rc)) < 0) return true; // not a terminal
            const own: std.posix.pid_t = @intCast(@as(u32, @truncate(std.os.linux.getpgid(0))));
            return fg == own;
        }
    } else struct {
        extern "c" fn tcgetpgrp(fd: std.posix.fd_t) std.posix.pid_t;
        extern "c" fn getpgrp() std.posix.pid_t;

        fn owned() bool {
            const fg = tcgetpgrp(std.posix.STDIN_FILENO);
            if (fg < 0) return true; // no controlling terminal / not a tty
            return fg == getpgrp();
        }
    };

    /// Terminal-reader lifecycle (#396), kept as pure state so the ordering
    /// invariant — a run that has COMPLETED never blocks on the tty again — is
    /// unit-testable with no terminal in sight. The syscalls stay in the
    /// wrappers below; this only tracks how deep raw mode is and whether the
    /// terminal has been handed back.
    pub const Lifecycle = struct {
        /// Nested raw-mode entries (a picker opened from the line editor).
        raw_depth: u8 = 0,
        /// The run finished and the terminal went back: no further blocking
        /// read may be issued.
        released: bool = false,

        /// A raw-mode entry succeeded. True for the OUTERMOST one, whose saved
        /// terminal state is the one a release has to put back.
        pub fn entered(self: *Lifecycle) bool {
            self.raw_depth +|= 1;
            return self.raw_depth == 1;
        }

        /// A restore ran. True once raw mode is fully off again.
        pub fn restored(self: *Lifecycle) bool {
            self.raw_depth -|= 1;
            return self.raw_depth == 0;
        }

        /// End of the run. True when raw mode is STILL on and the caller has to
        /// put the terminal back — the leftover-process case in #396, where
        /// teardown never reached the line editor's `defer restore`.
        pub fn release(self: *Lifecycle) bool {
            const still_raw = self.raw_depth > 0;
            self.raw_depth = 0;
            self.released = true;
            return still_raw;
        }

        /// May a blocking read on the controlling terminal still be issued?
        pub fn mayBlock(self: Lifecycle) bool {
            return !self.released;
        }

        /// Re-arm for a fresh interactive session in the same process. Release
        /// latches the reader shut; it is not a one-way door for the process.
        pub fn rearm(self: *Lifecycle) void {
            self.released = false;
        }
    };

    /// Process-wide reader state. Driven from the main thread only — the Esc
    /// watch task on the pool touches poll/readStdin, never this.
    var life: Lifecycle = .{};
    /// What the OUTERMOST enterRaw() captured, so a release can undo raw mode
    /// from anywhere (including a path that never reached the editor's defer).
    var raw_outer: ?RawState = null;

    /// One-time: let the Windows console interpret ANSI/VT escapes and decode
    /// stdout as UTF-8 (CP 65001). No-op elsewhere. Call once from main before
    /// any styled output. PowerShell 5.1/conhost otherwise treat box-drawing
    /// as CP437 (#607); zigzag already did this in its raw-mode path.
    pub fn enableVtOutput() void {
        if (!is_windows) return;
        const h = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        var mode: u32 = 0;
        if (win.GetConsoleMode(h, &mode) != 0) {
            _ = win.SetConsoleMode(h, mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.ENABLE_PROCESSED_OUTPUT);
        }
        _ = win.SetConsoleOutputCP(win.CP_UTF8);
        _ = win.SetConsoleCP(win.CP_UTF8);
    }

    /// Terminal width in columns; 80 on any failure.
    fn cols() usize {
        if (is_windows) {
            var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (win.GetConsoleScreenBufferInfo(win.GetStdHandle(win.STD_OUTPUT_HANDLE), &info) == 0) return 80;
            const w = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
            return if (w <= 0) 80 else @intCast(w);
        }
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.col == 0) return 80;
        return ws.col;
    }

    /// Terminal height in rows; 24 on any failure.
    fn rows() usize {
        if (is_windows) {
            var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (win.GetConsoleScreenBufferInfo(win.GetStdHandle(win.STD_OUTPUT_HANDLE), &info) == 0) return 24;
            const h = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
            return if (h <= 0) 24 else @intCast(h);
        }
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.row == 0) return 24;
        return ws.row;
    }

    /// Enter raw mode on stdin. blocking=true → reads block for >=1 byte and
    /// Ctrl-C arrives as a byte (line editor, pickers); blocking=false → VMIN=0
    /// non-blocking and Ctrl-C still raises SIGINT (the Esc watcher). Returns
    /// the prior state for restore(), or null when off-tty.
    pub fn enterRaw(blocking: bool) ?RawState {
        if (is_windows) {
            const h = win.GetStdHandle(win.STD_INPUT_HANDLE);
            var mode: u32 = 0;
            if (win.GetConsoleMode(h, &mode) == 0) return null;
            var raw = mode & ~@as(u32, win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT);
            raw |= win.ENABLE_VIRTUAL_TERMINAL_INPUT;
            if (blocking) raw &= ~@as(u32, win.ENABLE_PROCESSED_INPUT) else raw |= win.ENABLE_PROCESSED_INPUT;
            if (win.SetConsoleMode(h, raw) == 0) return null;
            if (life.entered()) raw_outer = .{ .in_mode = mode };
            return .{ .in_mode = mode };
        }
        const fd = std.posix.STDIN_FILENO;
        const orig = std.posix.tcgetattr(fd) catch return null;
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        if (blocking) {
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false; // so Ctrl-V (0x16) reaches us, not the tty's lnext
        }
        raw.cc[@intFromEnum(std.posix.V.MIN)] = if (blocking) 1 else 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        var job_control = JobControlGuard.init(.output);
        defer job_control.deinit();
        std.posix.tcsetattr(fd, .NOW, raw) catch return null;
        if (life.entered()) raw_outer = orig;
        return orig;
    }

    /// Restore the mode captured by enterRaw().
    pub fn restore(state: RawState) void {
        if (life.restored()) raw_outer = null;
        if (is_windows) {
            _ = win.SetConsoleMode(win.GetStdHandle(win.STD_INPUT_HANDLE), state.in_mode);
            return;
        }
        var job_control = JobControlGuard.init(.output);
        defer job_control.deinit();
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, state) catch {};
    }

    /// True if stdin has input ready within timeout_ms (0 = instant poll,
    /// negative = block indefinitely).
    pub fn poll(timeout_ms: i32) bool {
        if (is_windows) {
            const h = win.GetStdHandle(win.STD_INPUT_HANDLE);
            var n: u32 = 0;
            if (win.GetNumberOfConsoleInputEvents(h, &n) != 0 and n > 0) return true;
            const ms: u32 = if (timeout_ms < 0) win.INFINITE else @intCast(timeout_ms);
            if (win.WaitForSingleObject(h, ms) != win.WAIT_OBJECT_0) return false;
            return win.GetNumberOfConsoleInputEvents(h, &n) != 0 and n > 0;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, timeout_ms) catch return false;
        return n > 0;
    }

    /// Non-blocking read of pending raw stdin bytes (terminal already in raw
    /// mode); returns the byte count. On Windows it drains queued console
    /// records and emits the ASCII byte of each key-down (Esc->0x1b,
    /// Enter->0x0d, Backspace, printables); arrow/modifier/non-key events yield
    /// nothing, so it never blocks — matching the POSIX VMIN=0 read the Esc
    /// watcher relies on.
    pub fn readStdin(buf: []u8) usize {
        if (is_windows) {
            const h = win.GetStdHandle(win.STD_INPUT_HANDLE);
            var avail: u32 = 0;
            if (win.GetNumberOfConsoleInputEvents(h, &avail) == 0 or avail == 0) return 0;
            var recs: [64]win.INPUT_RECORD = undefined;
            const want: u32 = @intCast(@min(recs.len, @as(usize, avail)));
            var got: u32 = 0;
            if (win.ReadConsoleInputW(h, &recs, want, &got) == 0) return 0;
            var out: usize = 0;
            var i: u32 = 0;
            while (i < got and out < buf.len) : (i += 1) {
                const rec = recs[i];
                if (rec.EventType != win.KEY_EVENT or rec.KeyEvent.bKeyDown == 0) continue;
                const ch = rec.KeyEvent.UnicodeChar;
                if (ch == 0 or ch > 0x7f) continue; // arrows/fn/modifiers + non-ASCII
                buf[out] = @intCast(ch);
                out += 1;
            }
            return out;
        }
        var job_control = JobControlGuard.init(.input);
        defer job_control.deinit();
        return std.posix.read(std.posix.STDIN_FILENO, buf) catch 0;
    }

    /// Hand the controlling terminal back at the end of a run (#396): undo a raw
    /// mode still in force and latch the reader shut, so nothing that runs after
    /// completion can block on the tty. Idempotent; safe off a terminal.
    pub fn releaseTerminal() void {
        const still_raw = life.release();
        const saved = raw_outer;
        raw_outer = null;
        if (still_raw) if (saved) |state| restore(state);
    }

    /// True while this process group owns the controlling terminal.
    pub fn isForeground() bool {
        return Foreground.owned();
    }

    /// Outcome of a blocking read on the controlling terminal.
    pub const BlockingRead = union(enum) {
        bytes: usize,
        eof,
        /// The read must not happen: this process is no longer the terminal's
        /// foreground group, or the run already released the terminal. Do NOT
        /// retry — retrying is what left a completed Graff stopped ("suspended
        /// (tty input)") on a shared tty in #396.
        background,
    };

    /// Blocking terminal read that can never be stopped by SIGTTIN: the signal
    /// stays blocked around the syscall (#271's guard), so a read that runs from
    /// the background fails with EIO and is REPORTED instead of suspending us.
    pub fn readBlocking(buf: []u8) BlockingRead {
        if (!life.mayBlock()) return .background;
        if (is_windows) {
            while (poll(-1)) {
                const got = readStdin(buf);
                if (got > 0) return .{ .bytes = got };
            }
            return .eof;
        }
        if (!isForeground()) return .background;
        var job_control = JobControlGuard.init(.input);
        defer job_control.deinit();
        const n = std.posix.read(std.posix.STDIN_FILENO, buf) catch |err| switch (err) {
            error.InputOutput => return .background, // EIO: the read ran from the background
            else => return .eof,
        };
        return if (n == 0) .eof else .{ .bytes = n };
    }

    /// Prompt idle cadence. Two consecutive misses (~1s) is the grace before a
    /// backgrounded prompt gives up, so a terminal handed over for a moment (a
    /// shell mid-tcsetpgrp) never reads as abandoned.
    const foreground_poll_ms: i32 = 500;
    const background_grace: u8 = 2;

    /// Wait for terminal input without ever blocking in a read this process is
    /// not allowed to make. False means STOP READING: either input is waiting
    /// while we sit in the background (the SIGTTIN case — the kernel would stop
    /// us) or the terminal was released/abandoned.
    pub fn waitForegroundInput() bool {
        var missed: u8 = 0;
        while (life.mayBlock()) {
            if (poll(foreground_poll_ms)) return true;
            if (isForeground()) {
                missed = 0;
                continue;
            }
            missed +|= 1;
            if (missed >= background_grace) return false;
        }
        return false;
    }

    pub const PromptByte = union(enum) { byte: u8, eof, background };

    /// Bytes the guarded read pulled off the terminal but the editor has not
    /// consumed yet: one syscall per keystroke would be fine, one per byte of a
    /// paste would not. Survives across readLine/picker calls exactly the way
    /// the reader's own buffer used to, so typed-ahead still carries over.
    var queued: [256]u8 = undefined;
    var queued_len: usize = 0;
    var queued_pos: usize = 0;

    /// Terminal bytes already read and waiting. The editor's "is this a bare
    /// Esc?" checks must count these as well as the reader's own buffer.
    pub fn pendingBytes() usize {
        return queued_len - queued_pos;
    }

    /// One byte of terminal input, job-control aware (#396). Every blocking
    /// read the line editor and the pickers make goes through here, so none of
    /// them can be the read the kernel stops with SIGTTIN. Order: our own
    /// queue, then whatever the reader still holds, then a guarded read that
    /// only happens while this process still owns the terminal.
    pub fn promptByte(in: *std.Io.Reader) PromptByte {
        if (queued_pos < queued_len) {
            defer queued_pos += 1;
            return .{ .byte = queued[queued_pos] };
        }
        if (in.buffered().len > 0) return if (in.takeByte()) |b| .{ .byte = b } else |_| .eof;
        if (!waitForegroundInput()) return .background;
        queued_len = 0;
        queued_pos = 0;
        switch (readBlocking(queued[0..])) {
            .bytes => |n| {
                queued_len = n;
                queued_pos = 1;
                return .{ .byte = queued[0] };
            },
            .eof => return .eof,
            .background => return .background,
        }
    }

    /// stderr with SIGTTOU blocked: the note explaining a background exit must
    /// not itself stop Graff on a terminal with TOSTOP set.
    pub fn noteFromBackground(msg: []const u8) void {
        var job_control = JobControlGuard.init(.output);
        defer job_control.deinit();
        std.debug.print("{s}", .{msg});
    }
};

/// Terminal column count; 80 on any failure.
pub fn termCols() usize {
    return tty.cols();
}

/// Terminal row count; 24 on any failure.
pub fn termRows() usize {
    return tty.rows();
}

/// Advance (rows, col) as `chunk` of plain text is printed in a `cols`-wide
/// terminal: hard newlines and soft wraps each start a new row, and UTF-8
/// continuation bytes share a glyph cell so they do not advance the column.
/// Sizes the live "Thinking" block so it can be collapsed in place (#75).
pub fn advanceThinkingRows(rows: *usize, col: *usize, cols: usize, chunk: []const u8) void {
    for (chunk) |b| {
        if (b == '\n') {
            rows.* += 1;
            col.* = 0;
            continue;
        }
        if (b & 0xC0 == 0x80) continue; // UTF-8 continuation byte
        col.* += 1;
        if (cols != 0 and col.* >= cols) {
            rows.* += 1;
            col.* = 0;
        }
    }
}

test "advanceThinkingRows counts hard newlines and soft wraps" {
    var rows: usize = 1;
    var col: usize = 0;
    advanceThinkingRows(&rows, &col, 80, "hello");
    try std.testing.expectEqual(@as(usize, 1), rows);
    try std.testing.expectEqual(@as(usize, 5), col);
    advanceThinkingRows(&rows, &col, 80, "\nworld\n");
    try std.testing.expectEqual(@as(usize, 3), rows);
    try std.testing.expectEqual(@as(usize, 0), col);
    var r2: usize = 1;
    var c2: usize = 0;
    advanceThinkingRows(&r2, &c2, 10, "0123456789012345678901234");
    try std.testing.expectEqual(@as(usize, 3), r2);
    try std.testing.expectEqual(@as(usize, 5), c2);
}

pub fn inputPending() bool {
    return tty.poll(50);
}

/// Like inputPending but with a configurable poll timeout (ms). Used by the
/// ultracode wave to tick at a slower, calmer cadence than the 50ms default.
pub fn inputPendingTimed(timeout_ms: i32) bool {
    return tty.poll(timeout_ms);
}

test "#396 lifecycle: a completed run releases raw mode and latches the reader shut" {
    var life: tty.Lifecycle = .{};
    try std.testing.expect(life.mayBlock());
    try std.testing.expect(life.entered()); // the line editor
    try std.testing.expect(!life.entered()); // a picker opened from inside it
    try std.testing.expect(!life.restored()); // picker closed; the editor is still raw
    // The run ends with the editor still in raw mode — exactly the leftover
    // process in #396. Release both reports the terminal needs putting back and
    // stops any later blocking read from being issued.
    try std.testing.expect(life.release());
    try std.testing.expect(!life.mayBlock());
    // Idempotent: teardown may release twice (mainloop defer + explicit call)
    // and the second one must not claim there is raw mode left to undo.
    try std.testing.expect(!life.release());
    try std.testing.expect(!life.mayBlock());
    life.rearm();
    try std.testing.expect(life.mayBlock());
}

test "#396 lifecycle: a terminal already restored needs no release-time restore" {
    var life: tty.Lifecycle = .{};
    _ = life.entered();
    try std.testing.expect(life.restored());
    try std.testing.expect(!life.release()); // nothing raw left to undo
    try std.testing.expect(!life.mayBlock()); // but the reader is still shut
}

test "#396 firewall: the idle prompt read is job-control aware and gives the tty back first" {
    // The property is about the CALL SITE — that the ONE read which sits idle
    // after a completed run can never be the bare blocking read the kernel
    // stops with SIGTTIN — so it is pinned as source text (the #376 pattern).
    const src = @embedFile("readline.zig");
    const guarded = std.mem.indexOf(u8, src, "switch (tty.promptByte(in))").?;
    const arm = std.mem.indexOf(u8, src[guarded..], ".background => {").? + guarded;
    const window = src[arm..@min(src.len, arm + 700)];
    // ORDER: hand the terminal back BEFORE the note and the session save, so a
    // process that has already lost the foreground stops holding raw mode at
    // once rather than after disk I/O.
    const release_at = std.mem.indexOf(u8, window, "tty.releaseTerminal();").?;
    const note_at = std.mem.indexOf(u8, window, "tty.noteFromBackground(").?;
    const save_at = std.mem.indexOf(u8, window, "saveSession(root").?;
    try std.testing.expect(release_at < note_at);
    try std.testing.expect(note_at < save_at);
    // And it must LEAVE, not loop back into another read of the same terminal.
    try std.testing.expect(std.mem.indexOf(u8, window[save_at..], "return null;") != null);
}

test "#396 firewall: both completion paths release the terminal" {
    // One-shot (`-p`, the headless --yolo path) releases at the end of the run,
    // after the answer is printed and the session saved. Since #429 it says so
    // as a typed event — the engine no longer touches the tty itself — so the
    // pin follows the emission, and a second pin holds the sink arm that turns
    // it back into a release. Both halves have to exist or the run never gives
    // the terminal back.
    const oneshot = @embedFile("session_run.zig");
    const answer_at = std.mem.indexOf(u8, oneshot, "session.saveSession(root, arena, root.session_name)").?;
    const release_at = std.mem.indexOf(u8, oneshot, ".emit(io, .run_finished);").?;
    try std.testing.expect(answer_at < release_at);
    const sink = @embedFile("session_render.zig");
    try std.testing.expect(std.mem.indexOf(u8, sink, ".run_finished => terminal.tty.releaseTerminal(),") != null);
    // The interactive loop releases on ANY exit, and its defer is registered
    // last so LIFO teardown runs it first — before flushSavesAtExit and the
    // slower telemetry/learning phases main() owns.
    const loop = @embedFile("mainloop.zig");
    const flush_at = std.mem.indexOf(u8, loop, "defer session.flushSavesAtExit();").?;
    const loop_release_at = std.mem.indexOf(u8, loop, "defer terminal.tty.releaseTerminal();").?;
    try std.testing.expect(flush_at < loop_release_at);
}

test "Windows VT enable also switches the console to UTF-8 (#607)" {
    try std.testing.expectEqual(@as(u32, 65001), win.CP_UTF8);
    const src = @embedFile("term.zig");
    const fn_at = std.mem.indexOf(u8, src, "pub fn enableVtOutput() void {").?;
    const window = src[fn_at..std.mem.indexOfPos(u8, src, fn_at, "fn cols()").?];
    try std.testing.expect(std.mem.indexOf(u8, window, "SetConsoleOutputCP(win.CP_UTF8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, window, "SetConsoleCP(win.CP_UTF8)") != null);
    const main_src = @embedFile("main.zig");
    try std.testing.expect(std.mem.indexOf(u8, main_src, "tty.enableVtOutput()") != null);
}
