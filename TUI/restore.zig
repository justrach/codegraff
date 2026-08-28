//! Terminal-state restoration that must survive abnormal exits.
//! The kitty keyboard pop and alt-screen exit live here so SIGTERM/SIGHUP
//! (or an abort, a crash, or a job-control stop) cannot strand the shell in
//! raw fullscreen mode with the kitty protocol still pushed, the cursor
//! hidden, and mouse tracking on.

const std = @import("std");
const builtin = @import("builtin");
const tty = @import("tty.zig");

/// Inverse of run.zig's enable string: synchronized update closed, scroll
/// margins dropped, modifyOtherKeys off, kitty pop, autowrap on, mouse off
/// (1006/1003/1000), bracketed paste off, cursor visible. The alt-screen exit
/// stays last so everything lands on the primary screen.
///
/// The first two are not inverses of anything in the enable string — they undo
/// state a paint sets and clears WITHIN itself (scrollpaint.zig brackets a
/// DECSTBM region exactly as run.zig brackets ?2026). A crash lands between the
/// two halves often enough to matter, and margins left set turn every later
/// newline in the user's shell into a scroll inside a window that is gone.
pub const seq = "\x1b[?2026l\x1b[r\x1b[>4;0m\x1b[<u\x1b[?7h\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[?1049l";

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

/// Window-size changes. SIGWINCH's default disposition is "ignore", so without
/// a handler the loop only ever learns about a resize by comparing the
/// dimensions it read on two successive iterations — which misses a resize
/// that lands between the size read and the paint, and misses one that ends on
/// the size it started from even though the terminal reflowed the screen in
/// between. Both leave the diff painter's baseline describing a screen that no
/// longer exists, and no frame byte changes, so nothing would ever repair it.
pub const size_signals = [_]std.posix.SIG{.WINCH};

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
/// Set by the window-size handler: run.zig turns it into a forced full
/// repaint, so a reflowed or cleared screen is never left half-drawn.
var resized = std.atomic.Value(bool).init(false);

/// Remember the pre-raw termios and hook fatal signals. Test builds skip the
/// signal hooks so the test runner's dispositions stay untouched.
pub fn arm(orig: tty.RawState, enable_seq: []const u8) void {
    saved = orig;
    enable = enable_seq;
    armed.store(true, .release);
    if (builtin.os.tag == .windows or builtin.is_test) return;
    installFatalHandlers();
    installStopHandlers();
    installSizeHandlers();
}

pub fn disarm() void {
    armed.store(false, .release);
}

/// True while a fatal-signal restore is hooked — `run` uses this so an
/// early `claimScreen` (alt-screen before keys/MCP/prompt) is not armed
/// twice, which would save already-raw termios and strand the shell.
pub fn isArmed() bool {
    return armed.load(.acquire);
}

/// Early alt-screen claim so leftover boot happens *inside* the pager.
/// `run` takes ownership via `takeClaim`; `releaseIfOwned` (shutdown
/// teardown + fatal signals already hooked by `arm`) restores if we never
/// get there. No libc `atexit`: Zig exits via syscall and skips C exits.
var claim_owned = std.atomic.Value(bool).init(false);
var claim_raw: tty.RawState = undefined;

pub fn claimScreen(enable_seq: []const u8) bool {
    if (builtin.is_test) return false;
    if (claim_owned.load(.acquire) or armed.load(.acquire)) return true;
    const raw = tty.enterRaw() orelse return false;
    claim_raw = raw;
    arm(raw, enable_seq);
    if (builtin.os.tag != .windows) {
        // Alt-screen only. Kitty/mouse/paste are a stack — run() writes
        // the full enable_seq once when the loop actually starts.
        const first = "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J";
        _ = std.posix.system.write(std.posix.STDOUT_FILENO, first.ptr, first.len);
    }
    muteStderr();
    claim_owned.store(true, .release);
    return true;
}

/// Hand the claimed raw state to `run`. After this, `releaseIfOwned` no-ops
/// — `run` owns restore. Null when nothing was claimed (off-TTY, or `run` first).
pub fn takeClaim() ?tty.RawState {
    if (!claim_owned.swap(false, .acq_rel)) return null;
    return claim_raw;
}

/// Teardown / error-return path after an early claim that never reached `run`.
/// First call wins; later stamps are a single atomic load.
pub fn releaseIfOwned() void {
    if (!claim_owned.load(.acquire)) return;
    emergency();
    claim_owned.store(false, .release);
}

/// True exactly once per resume from SIGTSTP — run.zig drops its diff
/// baseline so the first frame after `fg` is a full repaint.
pub fn takeResumed() bool {
    return resumed.swap(false, .acq_rel);
}

/// True once per window-size change since the last call.
pub fn takeResized() bool {
    return resized.swap(false, .acq_rel);
}

fn installSizeHandlers() void {
    if (builtin.os.tag == .windows) return;
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = onWinch },
        .mask = std.posix.sigemptyset(),
        // std.posix.poll/read both retry on EINTR, so an arriving SIGWINCH
        // costs the loop nothing beyond one restarted wait — the latch is
        // read on the next pass, at most one idle timeout later.
        .flags = std.posix.SA.ONSTACK,
    };
    for (size_signals) |sig| std.posix.sigaction(sig, &sa, null);
}

/// Async-signal-safe: one relaxed store, nothing else.
fn onWinch(_: std.posix.SIG) callconv(.c) void {
    resized.store(true, .release);
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

/// While the fullscreen TUI owns the screen, NOTHING may write to the real
/// terminal around the frame painter — but std.debug.print (subagent status
/// cards, worker lines, debug notices, any pool thread) goes straight to fd 2
/// and scrolls the alt screen out from under the diff painter: stale rows
/// "bleed through". So the TUI parks fd 2 on .graff/tui-stderr.log for its
/// whole lifetime and every exit path — quit, crash, suspend — puts it back
/// so panic traces and shell prompts land on the real terminal again.
/// (Child processes spawned BEFORE the mute keep their inherited fd 2; MCP
/// servers boot pre-TUI and are the remaining, far rarer leak.)
var real_stderr: std.posix.fd_t = -1;

pub fn muteStderr() void {
    if (builtin.os.tag == .windows or builtin.is_test) return;
    if (real_stderr != -1) return;
    _ = std.posix.system.mkdir(".graff", 0o755);
    const log = std.posix.openat(
        std.posix.AT.FDCWD,
        ".graff/tui-stderr.log",
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch return;
    // The raw syscall layer returns usize on Linux and c_int through libc,
    // so success is judged by errno, not by the sign of the return.
    const saved_rc = std.posix.system.dup(std.posix.STDERR_FILENO);
    if (std.posix.errno(saved_rc) != .SUCCESS) {
        _ = std.posix.system.close(log);
        return;
    }
    real_stderr = @intCast(saved_rc);
    const swap_rc = std.posix.system.dup2(log, std.posix.STDERR_FILENO);
    if (std.posix.errno(swap_rc) != .SUCCESS) {
        _ = std.posix.system.close(real_stderr);
        real_stderr = -1;
    }
    _ = std.posix.system.close(log);
}

/// Async-signal-safe (dup2/close only), so the crash and stop paths may call it.
pub fn unmuteStderr() void {
    if (builtin.os.tag == .windows) return;
    if (real_stderr == -1) return;
    _ = std.posix.system.dup2(real_stderr, std.posix.STDERR_FILENO);
    _ = std.posix.system.close(real_stderr);
    real_stderr = -1;
}

/// Async-signal-safe: raw write + tcsetattr + the stderr un-park, nothing else.
pub fn emergency() void {
    if (builtin.os.tag == .windows) return;
    unmuteStderr(); // diagnostics after this point must reach the real terminal
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
    muteStderr(); // fullscreen again: stderr back to the log (open/dup2 are async-signal-safe)
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
    try std.testing.expect(isArmed());
    disarm();
    try std.testing.expect(!armed.load(.acquire));
}

test "takeClaim is empty until a claim is owned" {
    try std.testing.expect(takeClaim() == null);
}

test "takeClaim hands the raw state over exactly once" {
    claim_raw = if (builtin.os.tag == .windows) .{} else undefined;
    claim_owned.store(true, .release);
    try std.testing.expect(takeClaim() != null);
    try std.testing.expect(takeClaim() == null);
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

test "stderr is parked for the TUI's whole lifetime and unparked on every exit path" {
    const run_src = @embedFile("run.zig");
    // Early claim (ADR 0042) is taken here so run does not re-arm over raw termios.
    try std.testing.expect(std.mem.indexOf(u8, run_src, "takeClaim()") != null);
    // Parked right after the fullscreen enable, before the first frame...
    const enable_at = std.mem.indexOf(u8, run_src, "w.writeAll(enable_seq) catch {};").?;
    const mute_at = std.mem.indexOfPos(u8, run_src, enable_at, "restore_mod.muteStderr();").?;
    // ...and unparked in the run loop's exit defer, before the restore bytes.
    const defer_unmute = std.mem.indexOfPos(u8, run_src, mute_at, "restore_mod.unmuteStderr();").?;
    const defer_restore = std.mem.indexOfPos(u8, run_src, defer_unmute, "w.writeAll(restore_mod.seq) catch {};").?;
    try std.testing.expect(defer_unmute < defer_restore);
    // The shell hand-over (Ctrl+Z park) unparks before stopping and re-parks after.
    const park_at = std.mem.indexOf(u8, run_src, "fn parkToShell").?;
    try std.testing.expect(std.mem.indexOfPos(u8, run_src, park_at, "unmuteStderr()") != null);
    try std.testing.expect(std.mem.indexOfPos(u8, run_src, park_at, "muteStderr()") != null);
    // Crash/stop paths: emergency() unparks FIRST, so panic traces reach the
    // real terminal; the SIGCONT re-entry re-parks.
    const self_src = @embedFile("restore.zig");
    const emergency_at = std.mem.indexOf(u8, self_src, "pub fn emergency() void {").?;
    const unmute_in_emergency = std.mem.indexOfPos(u8, self_src, emergency_at, "unmuteStderr();").?;
    const write_in_emergency = std.mem.indexOfPos(u8, self_src, emergency_at, "std.posix.system.write").?;
    try std.testing.expect(unmute_in_emergency < write_in_emergency);
    const cont_at = std.mem.indexOf(u8, self_src, "genuinely continued here").?;
    try std.testing.expect(std.mem.indexOfPos(u8, self_src, cont_at, "muteStderr();") != null);
}

test "resumed latch fires exactly once per continue" {
    resumed.store(true, .release);
    try std.testing.expect(takeResumed());
    try std.testing.expect(!takeResumed());
}

test "the window-size latch fires once per resize and starts down" {
    // The painter's diff baseline is only as good as the claim that nothing
    // else touched the screen; a resize breaks that claim without changing a
    // single byte of the frame, so the loop needs an EVENT, not a comparison.
    try std.testing.expect(!takeResized());
    onWinch(.WINCH);
    try std.testing.expect(takeResized());
    try std.testing.expect(!takeResized());
    try std.testing.expectEqual(@as(usize, 1), size_signals.len);
    try std.testing.expectEqual(std.posix.SIG.WINCH, size_signals[0]);
}
