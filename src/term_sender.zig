//! Name whoever sends graff SIGTERM. A client that sees only "exited
//! unexpectedly (killed by signal 15)" plus graff's last stderr lines cannot
//! tell an outside `kill`/`pkill` from its own shutdown. The handler writes one
//! stderr line with the sender's pid and process name, restores the default
//! action, and re-raises, so the exit status is still signal 15.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

pub fn install() void {
    if (comptime !supported) return;
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handle },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.RESETHAND,
    };
    posix.sigaction(.TERM, &act, null);
}

fn handle(sig: posix.SIG, info: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const pid: i32 = if (comptime builtin.os.tag == .linux) info.fields.common.first.piduid.pid else info.pid;
    var name_buf: [64]u8 = undefined;
    var line_buf: [160]u8 = undefined;
    const line = note(&line_buf, pid, senderName(pid, &name_buf));
    _ = posix.system.write(2, line.ptr, line.len);
    posix.raise(sig) catch {};
}

/// Async-signal-safe: one syscall-backed lookup, no allocation.
fn senderName(pid: i32, buf: []u8) []const u8 {
    if (pid <= 0) return "";
    if (comptime builtin.os.tag == .macos) {
        const n = proc_name(pid, buf.ptr, @intCast(buf.len));
        return if (n > 0) buf[0..@min(@as(usize, @intCast(n)), buf.len)] else "";
    }
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch return "";
    const fd = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(fd) != .SUCCESS) return "";
    defer _ = std.os.linux.close(@intCast(fd));
    const n = std.os.linux.read(@intCast(fd), buf.ptr, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS) return "";
    return std.mem.trimEnd(u8, buf[0..n], "\n");
}

pub fn note(buf: []u8, pid: i32, name: []const u8) []const u8 {
    if (pid <= 0) return "graff: stopped by SIGTERM (sender unknown)\n";
    if (name.len == 0) return std.fmt.bufPrint(buf, "graff: stopped by SIGTERM from pid {d}\n", .{pid}) catch "graff: stopped by SIGTERM\n";
    return std.fmt.bufPrint(buf, "graff: stopped by SIGTERM from pid {d} ({s})\n", .{ pid, name }) catch "graff: stopped by SIGTERM\n";
}

test "the SIGTERM note names the sender when it can" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("graff: stopped by SIGTERM from pid 4242 (pkill)\n", note(&buf, 4242, "pkill"));
    try std.testing.expectEqualStrings("graff: stopped by SIGTERM from pid 7\n", note(&buf, 7, ""));
    try std.testing.expectEqualStrings("graff: stopped by SIGTERM (sender unknown)\n", note(&buf, 0, "x"));
}
