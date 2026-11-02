//! Apps that tool commands launch open behind the user's work (#832).
//!
//! On macOS a verification command that runs `open` (a URL, a built app,
//! `open -a Simulator`) brought that app to the front and took keyboard
//! focus from whatever the user was doing, and every later step took it
//! again. Tool children (tool_env.zig) get a directory first on PATH whose
//! `open` adds `-g`, Launch Services' "do not bring the application to the
//! foreground". The app still launches and its windows still open, behind
//! the active app.
//!
//! Foreground is an explicit opt-in. `GRAFF_GUI_FOREGROUND=1` on one command
//! (`GRAFF_GUI_FOREGROUND=1 open ...`) lets that command activate; set in
//! graff's own environment it turns the shim off for the session.
//!
//! Not covered: an app that activates itself once running, `osascript`
//! `activate`, `/usr/bin/open` by its full path, and synthesized input
//! (events posted to the HID event tap move the user's own pointer and keys
//! whatever app is in front).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Map = std.process.Environ.Map;

pub const foreground_env = "GRAFF_GUI_FOREGROUND";
pub const shim_subdir = ".codegraff/shims/background-gui";
pub const real_open = "/usr/bin/open";

/// The shim's text, launching `target` (the real `open`).
pub fn script(buf: []u8, target: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\#!/bin/sh
        \\# graff (#832): apps launched from tool commands open in the background.
        \\# GRAFF_GUI_FOREGROUND=1 on a command lets it bring the app to the front.
        \\if [ "${{GRAFF_GUI_FOREGROUND:-}}" = 1 ]; then exec '{s}' "$@"; fi
        \\exec '{s}' -g "$@"
        \\
    , .{ target, target });
}

fn foregroundAsked(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

/// The shim directory for `home`, or null where it does not apply: not
/// macOS, no home, or foreground asked for in graff's own environment.
pub fn dir(buf: []u8, os: std.Target.Os.Tag, home: ?[]const u8, foreground: ?[]const u8) ?[]const u8 {
    if (os != .macos or foregroundAsked(foreground)) return null;
    const h = std.mem.trimEnd(u8, home orelse return null, "/");
    if (h.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ shim_subdir, .{h}) catch null;
}

/// Put the shim directory first on the tool environment's PATH.
pub fn applyTo(m: *Map, os: std.Target.Os.Tag) std.mem.Allocator.Error!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = dir(&buf, os, m.get("HOME"), m.get(foreground_env)) orelse return;
    const path = m.get("PATH") orelse "";
    if (std.mem.startsWith(u8, path, d) and (path.len == d.len or path[d.len] == ':')) return;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(m.allocator);
    try joined.appendSlice(m.allocator, d);
    if (path.len != 0) {
        try joined.append(m.allocator, ':');
        try joined.appendSlice(m.allocator, path);
    }
    try m.put("PATH", joined.items);
}

/// Write the shim under `home` unless it is already there. Best effort: if
/// it cannot be written, `open` on PATH is the real one, as before.
pub fn install(io: Io, home: []const u8, target: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = dir(&buf, builtin.os.tag, home, null) orelse return;
    var text_buf: [2 * std.fs.max_path_bytes + 512]u8 = undefined;
    const text = script(&text_buf, target) catch return;
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, d) catch return;
    var shim_dir = cwd.openDir(io, d, .{}) catch return;
    defer shim_dir.close(io);
    var have_buf: [text_buf.len]u8 = undefined;
    if (shim_dir.readFile(io, "open", &have_buf)) |have| {
        if (std.mem.eql(u8, have, text)) return;
    } else |_| {}
    // A concurrent graff may be writing the same bytes: stage, then rename.
    var tmp_buf: [32]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "open.{d}.tmp", .{@import("proc_identity.zig").selfPid()}) catch return;
    shim_dir.writeFile(io, .{ .sub_path = tmp, .data = text }) catch return;
    // File modes are POSIX's: Windows has none (and no shim, `dir` above).
    if (builtin.os.tag != .windows) shim_dir.setFilePermissions(io, tmp, .fromMode(0o755), .{}) catch {};
    shim_dir.rename(tmp, shim_dir, "open", io) catch shim_dir.deleteFile(io, tmp) catch {};
}

const testing = std.testing;

test "#832: the background-launch shim applies on macOS only, and not when foreground is asked for" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/Users/u/" ++ shim_subdir, dir(&buf, .macos, "/Users/u/", null).?);
    try testing.expect(dir(&buf, .linux, "/home/u", null) == null);
    try testing.expect(dir(&buf, .macos, null, null) == null);
    try testing.expect(dir(&buf, .macos, "/Users/u", "1") == null);
    try testing.expect(dir(&buf, .macos, "/Users/u", "0") != null);
}

test "#832: PATH gets the shim once, in front" {
    var m = Map.init(testing.allocator);
    defer m.deinit();
    try m.put("HOME", "/Users/u");
    try m.put("PATH", "/usr/bin:/bin");
    try applyTo(&m, .macos);
    try applyTo(&m, .macos);
    try testing.expectEqualStrings("/Users/u/" ++ shim_subdir ++ ":/usr/bin:/bin", m.get("PATH").?);
    var linux = Map.init(testing.allocator);
    defer linux.deinit();
    try linux.put("HOME", "/home/u");
    try linux.put("PATH", "/usr/bin");
    try applyTo(&linux, .linux);
    try testing.expectEqualStrings("/usr/bin", linux.get("PATH").?);
}

test "#832: `open` in a tool shell launches in the background unless the command opts in" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    // A stand-in for /usr/bin/open that only reports its arguments.
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-open", .data = "#!/bin/sh\necho \"open $*\"\n" });
    try tmp.dir.setFilePermissions(io, "fake-open", .fromMode(0o755), .{});
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/fake-open", .{home});
    install(io, home, target);

    var parent = Map.init(gpa);
    defer parent.deinit();
    try parent.put("HOME", home);
    try parent.put("PATH", "/usr/bin:/bin");
    var env = try @import("tool_env.zig").build(gpa, &parent);
    defer env.deinit();
    const jobs = @import("jobs.zig");
    var opts = jobs.toolRunOptions(null);
    opts.environ_map = &env;
    // Never the real `open`: anything but the shim is reported, not run.
    const guard = "p=$(command -v open); case \"$p\" in \"$HOME\"/.codegraff/*) ;; *) echo \"unshimmed $p\"; exit 1 ;; esac; ";
    for ([_][2][]const u8{
        .{ "open https://example.invalid/page", "open -g https://example.invalid/page\n" },
        .{ "GRAFF_GUI_FOREGROUND=1 open -a Simulator", "open -a Simulator\n" },
    }) |case| {
        const cmd = try std.mem.concat(gpa, u8, &.{ guard, case[0] });
        defer gpa.free(cmd);
        const sh = jobs.shellArgv(cmd);
        const run = try jobs.runCappedWithOptions(gpa, io, &sh, 4096, 4096, 10_000, opts);
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        try testing.expectEqualStrings(case[1], run.stdout);
    }
}
