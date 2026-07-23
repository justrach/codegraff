//! Terminal primitives (std/builtin leaf, no main import): the Windows console
//! API shim, the cross-platform raw-mode / stdin-poll `tty` layer, terminal
//! size (termCols/termRows), the streamed-reasoning row counter, and the
//! stdin-ready polls. Split out of main.zig (600-line goal). main re-exports
//! win (hooks.zig back-imports it) and aliases the rest back so call sites stay
//! unqualified.

const std = @import("std");
const builtin = @import("builtin");

pub const win = struct {
    const HANDLE = *anyopaque;
    const BOOL = i32;
    const DWORD = u32;
    const WORD = u16;
    const WCHAR = u16;
    const SHORT = i16;

    const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6; // (DWORD)-10
    const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5; // (DWORD)-11

    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
    const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

    const WAIT_OBJECT_0: DWORD = 0x0;
    const INFINITE: DWORD = 0xFFFFFFFF;
    const KEY_EVENT: WORD = 0x0001;

    const COORD = extern struct { X: SHORT, Y: SHORT };
    const SMALL_RECT = extern struct { Left: SHORT, Top: SHORT, Right: SHORT, Bottom: SHORT };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };
    const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: WORD,
        wVirtualKeyCode: WORD,
        wVirtualScanCode: WORD,
        UnicodeChar: WCHAR,
        dwControlKeyState: DWORD,
    };
    // EventType (WORD) + ABI padding + the 16-byte event union, modeled as its
    // largest relevant member (KEY_EVENT_RECORD), totals 20 bytes — the C size.
    const INPUT_RECORD = extern struct {
        EventType: WORD,
        KeyEvent: KEY_EVENT_RECORD,
    };

    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
    extern "kernel32" fn GetNumberOfConsoleInputEvents(hConsoleInput: HANDLE, lpNumberOfEvents: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: DWORD, lpRead: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: DWORD, lpBytesRead: ?*DWORD, lpTotalBytesAvail: ?*DWORD, lpBytesLeftThisMessage: ?*DWORD) callconv(.winapi) BOOL;
};

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

    /// One-time: let the Windows console interpret ANSI/VT escapes. No-op
    /// elsewhere. Call once from main before any styled output.
    pub fn enableVtOutput() void {
        if (!is_windows) return;
        const h = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        var mode: u32 = 0;
        if (win.GetConsoleMode(h, &mode) == 0) return;
        _ = win.SetConsoleMode(h, mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.ENABLE_PROCESSED_OUTPUT);
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
        return orig;
    }

    /// Restore the mode captured by enterRaw().
    pub fn restore(state: RawState) void {
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
