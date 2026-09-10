//! Clipboard tool argv. Offline tuiguard probes inherit private copy/paste
//! commands via GRAFF_CLIPBOARD_COPY / GRAFF_CLIPBOARD_PASTE so parallel
//! children do not share the host pasteboard (#836). Direct runs leave those
//! unset and keep the native pbcopy/xclip path.
//!
//! The override is bound from `environ_map` at TUI start. Spawn uses the
//! session Io (same as `copyCb` on main) — a second Threaded Io does not
//! drive children in this process.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const copy_env = "GRAFF_CLIPBOARD_COPY";
pub const paste_env = "GRAFF_CLIPBOARD_PASTE";

/// Process-lifetime path from `bind`. The slice is owned by environ_map.
var bound_copy: ?[]const u8 = null;
var bound_io: ?Io = null;

pub fn bind(io: Io, environ_map: *const std.process.Environ.Map) void {
    bound_io = io;
    const v = environ_map.get(copy_env) orelse {
        bound_copy = null;
        return;
    };
    bound_copy = if (v.len == 0) null else v;
}

pub fn unbind() void {
    bound_copy = null;
    bound_io = null;
}

pub fn envCopy() ?[]const u8 {
    const v = bound_copy orelse return null;
    return if (v.len == 0) null else v;
}

/// Fill `buf` with the copy argv. An explicit override (the env value, or a
/// test-supplied path) wins; otherwise the platform native tool.
/// Overrides run as `/bin/sh <path>` so a probe script needs neither +x nor
/// a shebang, and spawn never PATH-searches the inherited path.
pub fn fillCopyArgv(buf: *[4][]const u8, override: ?[]const u8) ?[]const []const u8 {
    if (override) |p| {
        if (p.len > 0) {
            buf[0] = "/bin/sh";
            buf[1] = p;
            return buf[0..2];
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

fn runCopy(io: Io, argv: []const []const u8, text: []const u8) bool {
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

/// Write `text` on `io` to the resolved copy command's stdin. True on exit 0.
pub fn writeTextIo(io: Io, text: []const u8) bool {
    if (text.len == 0) return false;
    var store: [4][]const u8 = undefined;
    const argv = copyArgv(&store) orelse return false;
    return runCopy(io, argv, text);
}

/// Session copy: bound Io when the TUI has started, else `io` is required
/// via `writeTextIo`. False when nothing is bound and there is no fallback.
pub fn writeText(text: []const u8) bool {
    return writeTextIo(bound_io orelse return false, text);
}

test "an override copy command is inherited as /bin/sh plus the path (#836)" {
    var buf: [4][]const u8 = undefined;
    const got = fillCopyArgv(&buf, "/tmp/probe-copy") orelse return error.NoArgv;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/bin/sh", got[0]);
    try std.testing.expectEqualStrings("/tmp/probe-copy", got[1]);
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

test "bind reads GRAFF_CLIPBOARD_COPY from environ_map (#836)" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(copy_env, "/tmp/probe-copy");
    bind(std.testing.io, &env);
    defer unbind();
    try std.testing.expectEqualStrings("/tmp/probe-copy", envCopy() orelse return error.Unbound);
    var buf: [4][]const u8 = undefined;
    const got = copyArgv(&buf) orelse return error.NoArgv;
    try std.testing.expectEqualStrings("/tmp/probe-copy", got[1]);
}

test "writeText runs the bound copy command (#836)" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "clipboard", .data = "SENTINEL" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const clip = try std.fmt.allocPrint(gpa, "{s}/clipboard", .{path_buf[0..n]});
    defer gpa.free(clip);
    const script = try std.fmt.allocPrint(gpa, "cat > '{s}'\n", .{clip});
    defer gpa.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "copy", .data = script });
    const copy_path = try std.fmt.allocPrint(gpa, "{s}/copy", .{path_buf[0..n]});
    defer gpa.free(copy_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(copy_env, copy_path);
    bind(io, &env);
    defer unbind();

    try std.testing.expect(writeText("isolate-me"));
    const got = try tmp.dir.readFileAlloc(io, "clipboard", gpa, .limited(64));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("isolate-me", got);
}
