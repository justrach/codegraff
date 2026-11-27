//! The managed HTTP MCP service's lifecycle: `graff mcp install`, `graff mcp
//! service status|start|stop|uninstall` and `graff mcp uninstall` (#1928, ADR
//! 0357). Every verb runs the bundled installer script
//! (`scripts/install-mcp.py`, embedded gzipped) with python3, so launchd and
//! user-systemd handling, the managed-file check and the install lock live in
//! one place. `graff mcp status` stays the consumed servers' status (ADR 0280),
//! which is why these verbs sit under `service`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");

pub const usage =
    \\usage: graff mcp service [status|start|stop|uninstall] [--json]
    \\  status [--json]   installed? loaded (and its pid)? port, job file, answering?
    \\  stop              unload it; it stays off, across logins too, until start or install
    \\  start             load it again and wait until it answers
    \\  uninstall         unload it and delete its job file (also `graff mcp uninstall`);
    \\                    keeps the token, settings and client entries
    \\
;

const unsupported_text = "The managed MCP service runs on macOS launchd and Linux user systemd only.\nOn Windows, add graff to an MCP client with the command `graff mcp serve`.\n";

/// The installer prints a few lines; start and install wait up to 6 s for the
/// service to answer, well inside the deadline.
const deadline_ms: u64 = 30_000;

pub const Verb = enum { status, start, stop, uninstall };
pub const Parsed = struct { verb: Verb, json: bool = false };

/// Null asks for the usage. A bare `graff mcp service` is `status`, and only
/// `status` takes `--json`.
pub fn parse(args: []const []const u8) ?Parsed {
    var out: Parsed = .{ .verb = .status };
    var verb_seen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
        } else if (!verb_seen) {
            out.verb = std.meta.stringToEnum(Verb, arg) orelse return null;
            verb_seen = true;
        } else return null;
    }
    if (out.json and out.verb != .status) return null;
    return out;
}

/// `python3 -c <installer> --binary <graff> <tail…>`.
pub fn installerArgv(arena: Allocator, script: []const u8, exe: []const u8, tail: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "python3", "-c", script, "--binary", exe });
    try argv.appendSlice(arena, tail);
    return argv.items;
}

/// What the installer is asked to do for a parsed service command.
pub fn serviceTail(p: Parsed) []const []const u8 {
    return switch (p.verb) {
        .status => if (p.json) &.{ "--service", "status", "--json" } else &.{ "--service", "status" },
        .start => &.{ "--service", "start" },
        .stop => &.{ "--service", "stop" },
        .uninstall => &.{ "--service", "uninstall" },
    };
}

fn runInstaller(io: Io, arena: Allocator, environ_map: anytype, tail: []const []const u8) !process_runner.CappedRun {
    const exe = try std.process.executablePathAlloc(io, arena);
    const script = try @import("update_archive.zig").gunzip(arena, @embedFile("mcp_installer.gz"));
    const argv = try installerArgv(arena, script, exe, tail);
    return process_runner.runCappedWithOptions(arena, io, argv, 16384, 4096, deadline_ms, .{ .environ_map = environ_map });
}

fn unsupported(io: Io) noreturn {
    var buffer: [512]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    writer.interface.writeAll(unsupported_text) catch {};
    writer.interface.flush() catch {};
    std.process.exit(1);
}

/// `graff mcp install …`: the installer's whole report goes to stderr.
pub fn install(io: Io, arena: Allocator, environ_map: anytype, args: []const []const u8) !void {
    // Spawning the installer on Windows failed with a bare FileNotFound.
    if (builtin.os.tag == .windows) unsupported(io);
    const result = try runInstaller(io, arena, environ_map, args);
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    try writer.interface.writeAll(result.stdout);
    try writer.interface.writeAll(result.stderr);
    try writer.interface.flush();
    if (!process_runner.ranOk(result)) return error.McpInstallFailed;
}

/// `graff mcp service …` and `graff mcp uninstall`. The report goes to stdout
/// (status `--json` is for programs); the service manager's own error text
/// comes back on stderr, and any failure exits 1.
pub fn service(io: Io, arena: Allocator, environ_map: anytype, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &obuf);
    var ebuf: [4096]u8 = undefined;
    var err = Io.File.stderr().writerStreaming(io, &ebuf);
    if (args.len == 1 and (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        try out.interface.writeAll(usage);
        return out.interface.flush();
    }
    const p = parse(args) orelse {
        try err.interface.writeAll(usage);
        try err.interface.flush();
        std.process.exit(1);
    };
    if (builtin.os.tag == .windows) unsupported(io);
    const result = runInstaller(io, arena, environ_map, serviceTail(p)) catch |e| {
        try err.interface.print("graff mcp service: could not run python3 ({t}); the service controls need Python 3\n", .{e});
        try err.interface.flush();
        std.process.exit(1);
    };
    try out.interface.writeAll(result.stdout);
    try out.interface.flush();
    try err.interface.writeAll(result.stderr);
    if (result.timed_out) try err.interface.writeAll("graff mcp service: the service manager did not answer within 30 s\n");
    try err.interface.flush();
    if (!process_runner.ranOk(result)) std.process.exit(1);
}

const testing = std.testing;

test "graff mcp install: the bundled installer inflates to the whole script" {
    const script = try @import("update_archive.zig").gunzip(testing.allocator, @embedFile("mcp_installer.gz"));
    defer testing.allocator.free(script);
    // No line ending in the needle: a Windows checkout may have CRLF.
    try testing.expect(std.mem.startsWith(u8, script, "#!/usr/bin/env python3"));
    try testing.expect(std.mem.indexOf(u8, script, "'--binary', required=True") != null);
    // Every verb this module sends is one the script accepts.
    try testing.expect(std.mem.indexOf(u8, script, "'--service', choices=['status', 'start', 'stop', 'uninstall']") != null);
}

test "graff mcp service: verbs, the status default, and --json only on status" {
    try testing.expectEqual(Verb.status, parse(&.{}).?.verb);
    try testing.expect(parse(&.{"--json"}).?.json);
    try testing.expectEqual(Verb.stop, parse(&.{"stop"}).?.verb);
    try testing.expectEqual(Verb.start, parse(&.{"start"}).?.verb);
    try testing.expectEqual(Verb.uninstall, parse(&.{"uninstall"}).?.verb);
    const status_json = parse(&.{ "status", "--json" }).?;
    try testing.expect(status_json.json and status_json.verb == .status);
    try testing.expect(parse(&.{"restart"}) == null);
    try testing.expect(parse(&.{ "stop", "--json" }) == null);
    try testing.expect(parse(&.{ "stop", "now" }) == null);
}

test "graff mcp service: the installer gets exactly the parsed verb" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const argv = try installerArgv(a, "SCRIPT", "/bin/graff", serviceTail(parse(&.{ "status", "--json" }).?));
    const want = [_][]const u8{ "python3", "-c", "SCRIPT", "--binary", "/bin/graff", "--service", "status", "--json" };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, got| try testing.expectEqualStrings(w, got);
    // `graff mcp uninstall` reaches the same verb as `graff mcp service uninstall`.
    const tail = serviceTail(parse(&.{"uninstall"}).?);
    try testing.expectEqual(@as(usize, 2), tail.len);
    try testing.expectEqualStrings("uninstall", tail[1]);
}
