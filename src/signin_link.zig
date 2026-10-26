//! A sign-in link the user can paste anywhere. Device logins print the
//! link and open a browser; on a terminal graff also puts the link on the
//! clipboard, so signing in from another browser or machine is one paste.
//! Over SSH the clipboard that matters is the user's own, so the link goes
//! to the terminal (OSC 52) rather than the remote machine's pasteboard.
//! Piped output (Harness, scripts) is left alone: the caller shows the link.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Copied = enum { clipboard, terminal, none };

/// Copy `url` when stdout is a terminal. Never fails the login.
pub fn copy(io: Io, url: []const u8) Copied {
    if (url.len == 0 or url.len > 4096) return .none;
    if (!(Io.File.stdout().isTty(io) catch false)) return .none;
    if (overSsh()) return if (osc52(io, url)) .terminal else .none;
    var buf: [3][]const u8 = undefined;
    const argv = copierArgv(builtin.os.tag, hasEnv("WAYLAND_DISPLAY"), hasEnv("DISPLAY"), &buf) orelse return .none;
    return if (pipeTo(io, argv, url)) .clipboard else .none;
}

/// The line that follows the link, or "" when nothing was copied. No `✓`:
/// Harness reads a `✓` line as the finished login.
pub fn note(copied: Copied) []const u8 {
    return switch (copied) {
        .clipboard => "  (copied to your clipboard)\n",
        .terminal => "  (sent to your terminal's clipboard)\n",
        .none => "",
    };
}

/// After the link line: copy it and say so.
pub fn offer(io: Io, out: *Io.Writer, url: []const u8) !void {
    try out.flush();
    try out.writeAll(note(copy(io, url)));
    try out.flush();
}

/// Open the browser unless the user can't see it (GRAFF_NO_BROWSER, SSH).
pub fn open(io: Io, url: []const u8) void {
    if (opensBrowser()) @import("oauth_helpers.zig").openBrowser(io, url);
}

pub fn opensBrowser() bool {
    return !@import("main.zig").g_no_browser and !overSsh();
}

/// Is graff running on a machine the user reached over SSH? A browser
/// opened there is one the user can't see.
pub fn overSsh() bool {
    return hasEnv("SSH_TTY") or hasEnv("SSH_CONNECTION");
}

fn hasEnv(name: [*:0]const u8) bool {
    const v = std.c.getenv(name) orelse return false;
    return std.mem.span(v).len > 0;
}

fn copierArgv(os: std.Target.Os.Tag, wayland: bool, x11: bool, buf: *[3][]const u8) ?[]const []const u8 {
    const parts: []const []const u8 = switch (os) {
        .macos => &.{"pbcopy"},
        .windows => &.{"clip.exe"},
        else => if (wayland) &.{"wl-copy"} else if (x11) &.{ "xclip", "-selection", "clipboard" } else return null,
    };
    @memcpy(buf[0..parts.len], parts);
    return buf[0..parts.len];
}

fn pipeTo(io: Io, argv: []const []const u8, text: []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore }) catch return false;
    {
        var wbuf: [512]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &wbuf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn osc52(io: Io, url: []const u8) bool {
    var enc: [std.base64.standard.Encoder.calcSize(4096)]u8 = undefined;
    var obuf: [64]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const w = &ow.interface;
    w.writeAll("\x1b]52;c;") catch return false;
    w.writeAll(std.base64.standard.Encoder.encode(&enc, url)) catch return false;
    w.writeAll("\x07") catch return false;
    w.flush() catch return false;
    return true;
}

test "copierArgv picks the platform's clipboard tool" {
    var buf: [3][]const u8 = undefined;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"pbcopy"}), copierArgv(.macos, false, false, &buf).?);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"clip.exe"}), copierArgv(.windows, false, false, &buf).?);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"wl-copy"}), copierArgv(.linux, true, true, &buf).?);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "xclip", "-selection", "clipboard" }), copierArgv(.linux, false, true, &buf).?);
    try std.testing.expect(copierArgv(.linux, false, false, &buf) == null);
}

test "note never claims a finished login" {
    for ([_]Copied{ .clipboard, .terminal, .none }) |c| {
        try std.testing.expect(std.mem.indexOf(u8, note(c), "\xe2\x9c\x93") == null);
    }
    try std.testing.expectEqualStrings("", note(.none));
}
