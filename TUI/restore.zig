//! Terminal-state restoration that must survive abnormal exits.
//! The kitty keyboard pop and alt-screen exit live here so SIGTERM/SIGHUP
//! (or an abort) cannot strand the shell in raw fullscreen mode with the
//! kitty protocol still pushed, the cursor hidden, and mouse tracking on.

const std = @import("std");
const builtin = @import("builtin");
const tty = @import("tty.zig");

/// Inverse of run.zig's enable string: modifyOtherKeys off, kitty pop,
/// autowrap on, mouse off (1006/1003/1000), bracketed paste off, cursor
/// visible. The alt-screen exit stays last so everything lands on the
/// primary screen.
pub const seq = "\x1b[?2026l\x1b[>4;0m\x1b[<u\x1b[?7h\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[?1049l";

var armed = std.atomic.Value(bool).init(false);
var saved: tty.RawState = undefined;

/// Remember the pre-raw termios and hook fatal signals. Test builds skip the
/// signal hooks so the test runner's dispositions stay untouched.
pub fn arm(orig: tty.RawState) void {
    saved = orig;
    armed.store(true, .release);
    if (builtin.os.tag == .windows or builtin.is_test) return;
    installFatalHandlers();
}

pub fn disarm() void {
    armed.store(false, .release);
}

fn installFatalHandlers() void {
    if (builtin.os.tag == .windows) return;
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = onFatal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    const fatal = [_]std.posix.SIG{ .TERM, .HUP, .INT, .QUIT, .ABRT };
    for (fatal) |sig| std.posix.sigaction(sig, &sa, null);
}

/// Async-signal-safe: one raw write + tcsetattr, nothing else.
pub fn emergency() void {
    if (builtin.os.tag == .windows) return;
    if (!armed.swap(false, .acq_rel)) return;
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, seq.ptr, seq.len);
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};
}

fn onFatal(sig: std.posix.SIG) callconv(.c) void {
    emergency();
    var dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    std.posix.raise(sig) catch {};
}

test "restore pops kitty before leaving the alt screen, cursor back on" {
    const kitty_pop = std.mem.indexOf(u8, seq, "\x1b[<u").?;
    const alt_exit = std.mem.indexOf(u8, seq, "\x1b[?1049l").?;
    try std.testing.expect(kitty_pop < alt_exit);
    try std.testing.expect(std.mem.endsWith(u8, seq, "\x1b[?1049l"));
    try std.testing.expect(std.mem.indexOf(u8, seq, "\x1b[?25h") != null);
    try std.testing.expect(std.mem.indexOf(u8, seq, "\x1b[?2004l") != null);
}

test "arm and disarm toggle the emergency latch" {
    try std.testing.expect(!armed.load(.acquire));
    arm(if (builtin.os.tag == .windows) .{} else undefined);
    try std.testing.expect(armed.load(.acquire));
    disarm();
    try std.testing.expect(!armed.load(.acquire));
}
