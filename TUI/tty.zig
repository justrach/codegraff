//! Minimal raw-mode + size + stdin poll for the fullscreen TUI.
//! Kept inside TUI/ so we do not share src/term.zig across modules.

const std = @import("std");
const builtin = @import("builtin");

pub const RawState = if (builtin.os.tag == .windows) struct { dummy: u8 = 0 } else std.posix.termios;

pub fn enterRaw() ?RawState {
    if (builtin.os.tag == .windows) return .{};
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
    if (builtin.os.tag == .windows) return;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, state) catch {};
}

pub fn poll(timeout_ms: i32) bool {
    if (builtin.os.tag == .windows) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

pub fn readStdin(buf: []u8) usize {
    if (builtin.os.tag == .windows) return 0;
    return std.posix.read(std.posix.STDIN_FILENO, buf) catch 0;
}

test "raw mode surrenders ^V and ^S to the app, not the line discipline (#523)" {
    const src = @embedFile("tty.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "IEXTEN = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "IXON = false") != null);
}

pub fn cols() usize {
    if (builtin.os.tag == .windows) return 80;
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (std.posix.errno(rc) != .SUCCESS) return 80;
    const c = wsz.col;
    if (c == 0) return 80;
    if (c > 400) return 400;
    return c;
}

pub fn rows() usize {
    if (builtin.os.tag == .windows) return 24;
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (std.posix.errno(rc) != .SUCCESS) return 24;
    const r = wsz.row;
    if (r == 0) return 24;
    if (r > 200) return 200;
    return r;
}
