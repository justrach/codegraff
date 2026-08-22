//! Minimal raw-mode + size + stdin poll for the fullscreen TUI.
//! Kept inside TUI/ so we do not share src/term.zig across modules.
//! Windows console APIs are duplicated here (not `@import("../src/win_api.zig")`)
//! because a file may belong to only one Zig 0.17 module.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Windows console leaf used only on that OS. Mirrors src/win_api.zig's UTF-8
/// + VT bits so the fullscreen TUI can switch CP 65001 (#607) without sharing
/// the file with the harness module.
const w = if (is_windows) struct {
    const HANDLE = *anyopaque;
    const BOOL = i32;
    const DWORD = u32;
    const UINT = u32;
    const WORD = u16;
    const SHORT = i16;
    const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5;
    const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
    const CP_UTF8: UINT = 65001;
    const COORD = extern struct { X: SHORT, Y: SHORT };
    const SMALL_RECT = extern struct { Left: SHORT, Top: SHORT, Right: SHORT, Bottom: SHORT };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };
    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) UINT;
    extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
} else struct {};

pub const RawState = if (is_windows) struct {
    output_cp: u32 = 0,
    input_cp: u32 = 0,
} else std.posix.termios;

pub fn enterRaw() ?RawState {
    if (is_windows) {
        const h = w.GetStdHandle(w.STD_OUTPUT_HANDLE);
        var mode: u32 = 0;
        if (w.GetConsoleMode(h, &mode) != 0) {
            _ = w.SetConsoleMode(h, mode | w.ENABLE_VIRTUAL_TERMINAL_PROCESSING | w.ENABLE_PROCESSED_OUTPUT);
        }
        // #607: zigzag UTF-8s its Windows platform layer; this path never did,
        // so PowerShell 5.1 decoded box-drawing as CP437. Restore the prior CPs
        // on the way out so the parent shell keeps its OEM page.
        const orig: RawState = .{
            .output_cp = w.GetConsoleOutputCP(),
            .input_cp = w.GetConsoleCP(),
        };
        _ = w.SetConsoleOutputCP(w.CP_UTF8);
        _ = w.SetConsoleCP(w.CP_UTF8);
        return orig;
    }
    const fd = std.posix.STDIN_FILENO;
    const orig = std.posix.tcgetattr(fd) catch return null;
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false; // ^V (0x16) reaches us, not the tty's lnext (#523)
    raw.iflag.IXON = false; // ^S/^Q are keys, not XOFF/XON flow control (#523)
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch return null;
    return orig;
}

pub fn restore(state: RawState) void {
    if (is_windows) {
        if (state.output_cp != 0) _ = w.SetConsoleOutputCP(state.output_cp);
        if (state.input_cp != 0) _ = w.SetConsoleCP(state.input_cp);
        return;
    }
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, state) catch {};
}

pub fn poll(timeout_ms: i32) bool {
    if (is_windows) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

pub fn readStdin(buf: []u8) usize {
    if (is_windows) return 0;
    return std.posix.read(std.posix.STDIN_FILENO, buf) catch 0;
}

test "raw mode surrenders ^V and ^S to the app, not the line discipline (#523)" {
    const src = @embedFile("tty.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "IEXTEN = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "IXON = false") != null);
}

test "Windows enterRaw switches the console to UTF-8 and restore puts the CPs back (#607)" {
    const src = @embedFile("tty.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "CP_UTF8: UINT = 65001") != null);
    const enter_at = std.mem.indexOf(u8, src, "pub fn enterRaw() ?RawState {").?;
    const enter = src[enter_at..std.mem.indexOf(u8, src, "pub fn restore(").?];
    try std.testing.expect(std.mem.indexOf(u8, enter, "SetConsoleOutputCP(w.CP_UTF8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "SetConsoleCP(w.CP_UTF8)") != null);
    const restore_at = std.mem.indexOf(u8, src, "pub fn restore(state: RawState) void {").?;
    const rest = src[restore_at..std.mem.indexOf(u8, src, "pub fn poll(").?];
    try std.testing.expect(std.mem.indexOf(u8, rest, "SetConsoleOutputCP(state.output_cp)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "SetConsoleCP(state.input_cp)") != null);
}

fn consoleSize() ?struct { cols: usize, rows: usize } {
    if (is_windows) {
        var info: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (w.GetConsoleScreenBufferInfo(w.GetStdHandle(w.STD_OUTPUT_HANDLE), &info) == 0) return null;
        const width = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const height = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        return .{
            .cols = if (width <= 0) 80 else @intCast(width),
            .rows = if (height <= 0) 24 else @intCast(height),
        };
    }
    return null;
}

pub fn cols() usize {
    if (is_windows) {
        const c = (consoleSize() orelse return 80).cols;
        if (c == 0) return 80;
        if (c > 400) return 400;
        return c;
    }
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (std.posix.errno(rc) != .SUCCESS) return 80;
    const c = wsz.col;
    if (c == 0) return 80;
    if (c > 400) return 400;
    return c;
}

pub fn rows() usize {
    if (is_windows) {
        const r = (consoleSize() orelse return 24).rows;
        if (r == 0) return 24;
        if (r > 200) return 200;
        return r;
    }
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (std.posix.errno(rc) != .SUCCESS) return 24;
    const r = wsz.row;
    if (r == 0) return 24;
    if (r > 200) return 200;
    return r;
}
