//! Clipboard tool argv. Offline tuiguard probes inherit private copy/paste
//! commands via GRAFF_CLIPBOARD_COPY / GRAFF_CLIPBOARD_PASTE so parallel
//! children do not share the host pasteboard (#836). Direct runs leave those
//! unset and keep the native pbcopy/xclip path.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const copy_env = "GRAFF_CLIPBOARD_COPY";
pub const paste_env = "GRAFF_CLIPBOARD_PASTE";

pub fn envCopy() ?[]const u8 {
    const z = std.c.getenv("GRAFF_CLIPBOARD_COPY") orelse return null;
    const v = std.mem.span(z);
    return if (v.len == 0) null else v;
}

/// Fill `buf` with the copy argv. An explicit override (the env value, or a
/// test-supplied path) wins; otherwise the platform native tool.
pub fn fillCopyArgv(buf: *[4][]const u8, override: ?[]const u8) ?[]const []const u8 {
    if (override) |p| {
        if (p.len > 0) {
            buf[0] = p;
            return buf[0..1];
        }
    }
    switch (builtin.os.tag) {
        .macos => {
            buf[0] = "pbcopy";
            return buf[0..1];
        },
        .linux => {
            buf[0] = "xclip";
            buf[1] = "-selection";
            buf[2] = "clipboard";
            return buf[0..3];
        },
        else => return null,
    }
}

pub fn copyArgv(buf: *[4][]const u8) ?[]const []const u8 {
    return fillCopyArgv(buf, envCopy());
}

/// Write `text` to the resolved copy command's stdin. True on exit 0.
pub fn writeText(text: []const u8) bool {
    if (text.len == 0) return false;
    var store: [4][]const u8 = undefined;
    const argv = copyArgv(&store) orelse return false;
    const io = Io.Threaded.global_single_threaded.io();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    if (child.stdin) |*s| {
        var wbuf: [4096]u8 = undefined;
        var w = s.writerStreaming(io, &wbuf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        s.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

test "an override copy command is a single inherited argv (#836)" {
    var buf: [4][]const u8 = undefined;
    const got = fillCopyArgv(&buf, "/tmp/probe-copy") orelse return error.NoArgv;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("/tmp/probe-copy", got[0]);
}

test "an empty override falls through to the native clipboard tool (#836)" {
    var over_buf: [4][]const u8 = undefined;
    var native_buf: [4][]const u8 = undefined;
    const got = fillCopyArgv(&over_buf, "") orelse return error.NoNative;
    const native = fillCopyArgv(&native_buf, null) orelse return error.NoNative;
    try std.testing.expectEqual(native.len, got.len);
    try std.testing.expectEqualStrings(native[0], got[0]);
    switch (builtin.os.tag) {
        .macos => try std.testing.expectEqualStrings("pbcopy", native[0]),
        .linux => {
            try std.testing.expectEqualStrings("xclip", native[0]);
            try std.testing.expectEqualStrings("clipboard", native[2]);
        },
        else => {},
    }
}

test "null override is the native tool, never an empty argv (#836)" {
    var buf: [4][]const u8 = undefined;
    if (fillCopyArgv(&buf, null)) |got| {
        try std.testing.expect(got.len > 0);
        try std.testing.expect(got[0].len > 0);
    }
}
