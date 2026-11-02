//! Simulator devices a session boots are shut down when it ends (#407).
//!
//! Agents verify iOS work with ad-hoc shell commands (`xcrun simctl boot`,
//! `xcodebuild test`, a project's run script). A device booted that way
//! outlives the command and the session: stopping the command's process
//! group does not shut a CoreSimulator device down. Finished runs left
//! devices booted with their apps running and the Simulator app open, and
//! parallel verification tasks piled them up.
//!
//! A shell command that looks like simulator work (`relevant`) is bracketed
//! by two snapshots of the booted devices. A device booted after the command
//! that was not booted before it is this session's: graff records it under
//! `~/.codegraff/simulators/<udid>/` with a lease naming this process. When
//! the session ends (`release`, from the job reaper), each recorded device
//! with no live lease left is shut down and its record removed.
//!
//! - A device that was already booted is never recorded, so the user's own
//!   devices are never shut down.
//! - Another live graff session that runs simulator commands while a
//!   recorded device is booted takes a lease on it too. The device stays up
//!   until the last of them ends.
//! - A session that died without releasing leaves a dead lease; the next
//!   session to end shuts that device down.
//! - The Simulator app is quit only when this session started it and no
//!   device is booted any more.
//! - `GRAFF_KEEP_SIMULATORS=1` turns all of this off.
//!
//! A snapshot cannot tell who booted a device. One the user boots while a
//! bracketed command runs is attributed to that command, and a command that
//! does not look like simulator work is not bracketed.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc_identity = @import("proc_identity.zig");

pub const keep_env = "GRAFF_KEEP_SIMULATORS";
pub const records_subdir = ".codegraff/simulators";
const booted_by = "booted-by";
const lease_prefix = "lease-";

/// A CoreSimulator UDID: a UUID, used as a directory name and an argument,
/// so anything else is rejected.
pub const Udid = [36]u8;

pub fn parseUdid(text: []const u8) ?Udid {
    if (text.len != 36) return null;
    for (text, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return null;
        if (!dash and !std.ascii.isHex(c)) return null;
    }
    return text[0..36].*;
}

/// One host command's outcome. `code` is null when it did not run or did not
/// exit normally. `stdout` is gpa-owned.
pub const Run = struct { code: ?u8, stdout: []const u8 };
pub const Runner = *const fn (gpa: Allocator, io: Io, argv: []const []const u8) Run;
pub const Liveness = *const fn (io: Io, rec: proc_identity.Record) bool;

fn hostRun(gpa: Allocator, io: Io, argv: []const []const u8) Run {
    const run = @import("process_runner.zig").runCapped(gpa, io, argv, 1 << 20, 4096, 60_000) catch
        return .{ .code = null, .stdout = &.{} };
    gpa.free(run.stderr);
    const code: ?u8 = switch (run.term) {
        .exited => |c| if (run.timed_out or run.cancelled) null else c,
        else => null,
    };
    return .{ .code = code, .stdout = run.stdout };
}

fn isLive(io: Io, rec: proc_identity.Record) bool {
    return proc_identity.stateOf(io, rec) == .held;
}

/// Whether a shell command looks like simulator work. Bracketing costs two
/// `simctl` runs, so ordinary commands are not.
pub fn relevant(cmd: []const u8) bool {
    for ([_][]const u8{ "simctl", "simulator", "xcodebuild" }) |needle| {
        if (@import("util.zig").indexOfIgnoreCase(cmd, needle) != null) return true;
    }
    // Whole words only: "ios" is in "scenarios".
    var words = std.mem.tokenizeAny(u8, cmd, " \t\r\n/._-:=,;'\"()[]{}|&<>$`");
    while (words.next()) |word| {
        for ([_][]const u8{ "ios", "iphone", "ipad", "watchos", "tvos", "visionos", "xros" }) |w| {
            if (std.ascii.eqlIgnoreCase(word, w)) return true;
        }
    }
    return false;
}

pub const Gui = enum { running, stopped, unknown };

/// What `before` saw, handed back to `after`.
pub const Bracket = struct { gui: Gui };

pub const Ledger = struct {
    /// Absolute records directory; empty turns the ledger off.
    root: []const u8 = "",
    run: Runner = hostRun,
    live: Liveness = isLive,
    self: proc_identity.Record = .{},
    mutex: Io.Mutex = .init,
    /// Devices seen booted before a bracketed command: never this session's.
    foreign: std.ArrayList(Udid) = .empty,
    /// A bracketed command was still running when its tool call returned.
    pending: bool = false,
    pending_gui: Gui = .unknown,
    gui_started: bool = false,

    fn enabled(l: *const Ledger) bool {
        return l.root.len != 0; // `init` sets it on macOS only
    }

    /// Snapshot before a shell command. Null when the command is not
    /// simulator work or the snapshot failed: nothing is attributed then.
    pub fn before(l: *Ledger, gpa: Allocator, io: Io, cmd: []const u8) ?Bracket {
        if (!l.enabled() or !relevant(cmd)) return null;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const booted = l.snapshot(gpa, io) orelse return null;
        defer gpa.free(booted);
        for (booted) |u| {
            // A device a graff session booted: this one now uses it as well.
            if (l.recorded(io, u)) l.lease(io, u) else l.addForeign(gpa, u);
        }
        return .{ .gui = l.gui(gpa, io) };
    }

    /// Snapshot after the command; record the devices it booted. `finished`
    /// is false when the command is still running in the background.
    pub fn after(l: *Ledger, gpa: Allocator, io: Io, bracket: Bracket, finished: bool) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.attribute(gpa, io);
        if (bracket.gui == .stopped and l.gui(gpa, io) == .running) l.gui_started = true;
        if (!finished) {
            l.pending = true;
            if (bracket.gui == .stopped) l.pending_gui = .stopped;
        }
    }

    fn attribute(l: *Ledger, gpa: Allocator, io: Io) void {
        const booted = l.snapshot(gpa, io) orelse return;
        defer gpa.free(booted);
        for (booted) |u| {
            if (l.isForeign(u) or l.recorded(io, u)) continue;
            l.record(io, u);
        }
    }

    /// Session end: shut down every recorded device no live session holds.
    /// Returns how many devices were shut down.
    pub fn release(l: *Ledger, gpa: Allocator, io: Io) usize {
        if (!l.enabled()) return 0;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        defer {
            l.foreign.clearAndFree(gpa);
            l.pending = false;
            l.pending_gui = .unknown;
            l.gui_started = false;
        }
        if (l.pending) {
            // A command that outlived its tool call may have booted more.
            l.attribute(gpa, io);
            if (l.pending_gui == .stopped and l.gui(gpa, io) == .running) l.gui_started = true;
        }
        var shut: usize = 0;
        const records = l.listRecords(gpa, io);
        defer gpa.free(records);
        if (records.len != 0) {
            const booted = l.snapshot(gpa, io);
            defer if (booted) |b| gpa.free(b);
            for (records) |u| {
                l.unlease(io, u);
                if (l.heldByOther(io, u)) continue;
                const up = if (booted) |b| contains(b, u) else true;
                if (up) {
                    // Without a snapshot the device may still be up: keep its
                    // record so a later session retries.
                    if (booted == null) continue;
                    const r = l.run(gpa, io, &.{ "xcrun", "simctl", "shutdown", &u });
                    gpa.free(r.stdout);
                    if (r.code != 0) continue;
                    shut += 1;
                }
                l.forget(io, u);
            }
        }
        if (l.gui_started) {
            const left = l.snapshot(gpa, io);
            defer if (left) |b| gpa.free(b);
            if (left != null and left.?.len == 0) {
                const r = l.run(gpa, io, &.{ "pkill", "-x", "Simulator" });
                gpa.free(r.stdout);
            }
        }
        return shut;
    }

    fn snapshot(l: *Ledger, gpa: Allocator, io: Io) ?[]Udid {
        const r = l.run(gpa, io, &.{ "xcrun", "simctl", "list", "devices", "booted", "-j" });
        defer gpa.free(r.stdout);
        if (r.code != 0) return null;
        return parseBooted(gpa, r.stdout) catch null;
    }

    fn gui(l: *Ledger, gpa: Allocator, io: Io) Gui {
        const r = l.run(gpa, io, &.{ "pgrep", "-x", "Simulator" });
        gpa.free(r.stdout);
        return if (r.code == 0) .running else if (r.code == 1) .stopped else .unknown;
    }

    fn addForeign(l: *Ledger, gpa: Allocator, u: Udid) void {
        if (l.isForeign(u)) return;
        l.foreign.append(gpa, u) catch {};
    }

    fn isForeign(l: *const Ledger, u: Udid) bool {
        return contains(l.foreign.items, u);
    }

    fn rootDir(l: *const Ledger, io: Io) ?Io.Dir {
        return Io.Dir.cwd().openDir(io, l.root, .{ .iterate = true }) catch null;
    }

    fn recorded(l: *const Ledger, io: Io, u: Udid) bool {
        var root = l.rootDir(io) orelse return false;
        defer root.close(io);
        var dir = root.openDir(io, &u, .{}) catch return false;
        dir.close(io);
        return true;
    }

    fn stamp(l: *const Ledger, buf: *[proc_identity.record_max]u8) []const u8 {
        return proc_identity.formatRecord(buf, l.self);
    }

    fn leaseName(l: *const Ledger, buf: *[32]u8) []const u8 {
        return std.fmt.bufPrint(buf, lease_prefix ++ "{d}", .{l.self.pid}) catch unreachable;
    }

    fn record(l: *Ledger, io: Io, u: Udid) void {
        Io.Dir.cwd().createDirPath(io, l.root) catch return;
        var root = l.rootDir(io) orelse return;
        defer root.close(io);
        root.createDirPath(io, &u) catch return;
        var dir = root.openDir(io, &u, .{}) catch return;
        defer dir.close(io);
        var buf: [proc_identity.record_max]u8 = undefined;
        dir.writeFile(io, .{ .sub_path = booted_by, .data = l.stamp(&buf) }) catch {};
        l.leaseIn(io, dir);
    }

    fn lease(l: *Ledger, io: Io, u: Udid) void {
        var root = l.rootDir(io) orelse return;
        defer root.close(io);
        var dir = root.openDir(io, &u, .{}) catch return;
        defer dir.close(io);
        l.leaseIn(io, dir);
    }

    fn leaseIn(l: *Ledger, io: Io, dir: Io.Dir) void {
        var name_buf: [32]u8 = undefined;
        var buf: [proc_identity.record_max]u8 = undefined;
        dir.writeFile(io, .{ .sub_path = l.leaseName(&name_buf), .data = l.stamp(&buf) }) catch {};
    }

    fn unlease(l: *Ledger, io: Io, u: Udid) void {
        var root = l.rootDir(io) orelse return;
        defer root.close(io);
        var dir = root.openDir(io, &u, .{}) catch return;
        defer dir.close(io);
        var name_buf: [32]u8 = undefined;
        dir.deleteFile(io, l.leaseName(&name_buf)) catch {};
    }

    /// A lease from a live process other than this one.
    fn heldByOther(l: *Ledger, io: Io, u: Udid) bool {
        var root = l.rootDir(io) orelse return false;
        defer root.close(io);
        var dir = root.openDir(io, &u, .{ .iterate = true }) catch return false;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return true) |entry| {
            if (!std.mem.startsWith(u8, entry.name, lease_prefix)) continue;
            const rec = proc_identity.readOwnerFile(io, dir, entry.name) orelse continue;
            if (rec.pid == l.self.pid) continue;
            if (l.live(io, rec)) return true;
        }
        return false;
    }

    fn forget(l: *Ledger, io: Io, u: Udid) void {
        var root = l.rootDir(io) orelse return;
        defer root.close(io);
        root.deleteTree(io, &u) catch {};
    }

    pub fn listRecords(l: *Ledger, gpa: Allocator, io: Io) []const Udid {
        var out: std.ArrayList(Udid) = .empty;
        var root = l.rootDir(io) orelse return out.toOwnedSlice(gpa) catch &.{};
        defer root.close(io);
        var it = root.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const u = parseUdid(entry.name) orelse continue;
            out.append(gpa, u) catch break;
        }
        return out.toOwnedSlice(gpa) catch &.{};
    }

    pub fn deinit(l: *Ledger, gpa: Allocator) void {
        l.foreign.deinit(gpa);
    }
};

fn contains(list: []const Udid, u: Udid) bool {
    for (list) |item| if (std.mem.eql(u8, &item, &u)) return true;
    return false;
}

/// The booted devices in `xcrun simctl list devices booted -j` output.
pub fn parseBooted(gpa: Allocator, text: []const u8) ![]Udid {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadSimctlList;
    const devices = parsed.value.object.get("devices") orelse return error.BadSimctlList;
    if (devices != .object) return error.BadSimctlList;
    var out: std.ArrayList(Udid) = .empty;
    errdefer out.deinit(gpa);
    var runtimes = devices.object.iterator();
    while (runtimes.next()) |runtime| {
        if (runtime.value_ptr.* != .array) continue;
        for (runtime.value_ptr.array.items) |device| {
            if (device != .object) continue;
            const state = device.object.get("state") orelse continue;
            if (state != .string or !std.mem.eql(u8, state.string, "Booted")) continue;
            const udid = device.object.get("udid") orelse continue;
            if (udid != .string) continue;
            try out.append(gpa, parseUdid(udid.string) orelse continue);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The process's ledger, on once startup knows HOME (`init`).
pub var g: Ledger = .{};

pub fn init(arena: Allocator, io: Io, home: []const u8, environ_map: anytype) void {
    if (builtin.os.tag != .macos or home.len == 0) return;
    if (environ_map.get(keep_env)) |v| if (!std.mem.eql(u8, v, "0")) return;
    g.root = std.fmt.allocPrint(arena, "{s}/" ++ records_subdir, .{std.mem.trimEnd(u8, home, "/")}) catch return;
    g.self = proc_identity.selfRecord(io);
}

test {
    _ = @import("sim_ledger_tests.zig");
}
