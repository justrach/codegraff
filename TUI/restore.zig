//! Terminal-state restoration that must survive abnormal exits.
//! The kitty keyboard pop and alt-screen exit live here so SIGTERM/SIGHUP
//! (or an abort, a crash, or a job-control stop) cannot strand the shell in
//! raw fullscreen mode with the kitty protocol still pushed, the cursor
//! hidden, and mouse tracking on.

const std = @import("std");
const builtin = @import("builtin");
const tty = @import("tty.zig");

/// Inverse of run.zig's enable string: modifyOtherKeys off, kitty pop,
/// autowrap on, mouse off (1006/1003/1000), bracketed paste off, cursor
/// visible. The alt-screen exit stays last so everything lands on the
/// primary screen.
pub const seq = "\x1b[?2026l\x1b[>4;0m\x1b[<u\x1b[?7h\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[?1049l";

/// Every signal that ends the process with the terminal still ours. The first
/// `first_fault` are the polite ones (a human or an init system asking us to
/// go); the rest are crashes. SEGV/BUS/ILL/FPE/TRAP are the ones that matter
/// in a shipped build: ReleaseFast has runtime_safety off, so std's own
/// segfault handler is never installed and nothing else would put the shell
/// back (#535, #547).
pub const fatal = [_]std.posix.SIG{ .TERM, .HUP, .INT, .QUIT, .ABRT, .SEGV, .BUS, .ILL, .FPE, .TRAP };

/// Index in `fatal` where the crash signals start. Those hand the signal back
/// to whoever held it before us — in Debug/ReleaseSafe that is Zig's stack
/// trace dumper, and blind-defaulting to SIG_DFL would delete dev diagnostics.
const first_fault = 4;

/// Job control. SIGTSTP's default action stops the process, which with the
/// alt screen up and termios raw hands the user a dead-looking shell (#549).
pub const stop_signals = [_]std.posix.SIG{.TSTP};

var armed = std.atomic.Value(bool).init(false);
var saved: tty.RawState = undefined;
var prev_fatal: [fatal.len]std.posix.Sigaction = undefined;
var prev_saved = false;
/// run.zig's fullscreen enable string, so the SIGTSTP handler can put the
/// screen back after the shell hands the terminal over on SIGCONT.
var enable: []const u8 = "";
/// Set by the stop handler once the process is continued: the paint diff
/// baseline is stale after a suspend, so run.zig must repaint in full.
var resumed = std.atomic.Value(bool).init(false);

/// Remember the pre-raw termios and hook fatal signals. Test builds skip the
/// signal hooks so the test runner's dispositions stay untouched.
pub fn arm(orig: tty.RawState, enable_seq: []const u8) void {
    saved = orig;
    enable = enable_seq;
    armed.store(true, .release);
    if (builtin.os.tag == .windows or builtin.is_test) return;
    installFatalHandlers();
    installStopHandlers();
}

pub fn disarm() void {
    armed.store(false, .release);
}

/// True exactly once per resume from SIGTSTP — run.zig drops its diff
/// baseline so the first frame after `fg` is a full repaint.
pub fn takeResumed() bool {
    return resumed.swap(false, .acq_rel);
}

fn installFatalHandlers() void {
    if (builtin.os.tag == .windows) return;
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = onFatal },
        .mask = std.posix.sigemptyset(),
        // A stack-overflow SEGV has no room left on the faulting stack: without
        // ONSTACK the handler re-faults and the terminal is stranded anyway.
        .flags = std.posix.SA.ONSTACK,
    };
    for (fatal, 0..) |sig, i| std.posix.sigaction(sig, &sa, &prev_fatal[i]);
    prev_saved = true;
}

fn installStopHandlers() void {
    if (builtin.os.tag == .windows) return;
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.ONSTACK,
    };
    for (stop_signals) |sig| std.posix.sigaction(sig, &sa, null);
}

/// Async-signal-safe: one raw write + tcsetattr, nothing else.
pub fn emergency() void {
    if (builtin.os.tag == .windows) return;
    if (!armed.swap(false, .acq_rel)) return;
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, seq.ptr, seq.len);
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};
}

/// Root-level panic hook: `pub const panic = restore.Panic;`. The terminal is
/// put back BEFORE std prints the message and the stack trace, so a crashed
/// session shows its diagnostic on the primary screen instead of having it
/// written into an alt screen the restore sequence then discards (#535).
pub fn onPanic(msg: []const u8, ra: ?usize) noreturn {
    emergency();
    std.debug.defaultPanic(msg, ra);
}

pub const Panic = std.debug.FullPanic(onPanic);

fn onFatal(sig: std.posix.SIG) callconv(.c) void {
    emergency();
    var dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (fatal, 0..) |s, i| {
        if (s != sig) continue;
        if (i >= first_fault and prev_saved) {
            std.posix.sigaction(sig, &prev_fatal[i], null);
        } else {
            std.posix.sigaction(sig, &dfl, null);
        }
        std.posix.raise(sig) catch {};
        return;
    }
    std.posix.sigaction(sig, &dfl, null);
    std.posix.raise(sig) catch {};
}

/// Restore the shell, stop for real, then take the terminal back on resume.
/// `raise` returns once SIGCONT arrives, so the whole suspend/continue cycle
/// is this one handler — no SIGCONT hook needed.
fn onStop(sig: std.posix.SIG) callconv(.c) void {
    // Only a suspend that interrupted the fullscreen TUI gets the screen back:
    // the handlers outlive run(), and re-entering raw mode after the TUI is
    // gone would hijack the shell we just handed over.
    const was_fullscreen = armed.load(.acquire);
    emergency();
    var dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    // The kernel blocks the delivered signal for the handler's duration, so a
    // bare raise() only marks it PENDING: it would deliver on handler RETURN —
    // AFTER installStopHandlers() below re-armed us — and re-enter this
    // handler forever (a measured 12 MB/s restore/enable flood at 99% CPU,
    // never reaching state T). Unblock it so the raise stops the process HERE.
    var only_stop = std.posix.sigemptyset();
    std.posix.sigaddset(&only_stop, sig);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &only_stop, null);
    std.posix.raise(sig) catch {};
    // --- genuinely continued here (SIGCONT) ---
    installStopHandlers();
    if (!was_fullscreen) return;
    if (tty.enterRaw()) |_| {}
    if (enable.len > 0) _ = std.posix.system.write(std.posix.STDOUT_FILENO, enable.ptr, enable.len);
    armed.store(true, .release);
    resumed.store(true, .release);
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
    arm(if (builtin.os.tag == .windows) .{} else undefined, "");
    try std.testing.expect(armed.load(.acquire));
    disarm();
    try std.testing.expect(!armed.load(.acquire));
}

test "crash signals are hooked, and they hand the signal back, not to SIG_DFL (#535/#547)" {
    for ([_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .TRAP }) |want| {
        var found = false;
        for (fatal, 0..) |sig, i| {
            if (sig != want) continue;
            found = true;
            // Every crash signal must sit at or after first_fault, or onFatal
            // would SIG_DFL over Zig's stack-trace dumper in a safety build.
            try std.testing.expect(i >= first_fault);
        }
        try std.testing.expect(found);
    }
    // The polite half keeps the plain default-and-re-raise behavior.
    try std.testing.expectEqual(std.posix.SIG.TERM, fatal[0]);
    try std.testing.expect(first_fault < fatal.len);
    // Ctrl+Z / `kill -TSTP` must never stop us on a raw alt screen (#549).
    try std.testing.expectEqual(@as(usize, 1), stop_signals.len);
    try std.testing.expectEqual(std.posix.SIG.TSTP, stop_signals[0]);
}

test "resumed latch fires exactly once per continue" {
    resumed.store(true, .release);
    try std.testing.expect(takeResumed());
    try std.testing.expect(!takeResumed());
}
