//! A simulator test must not write the Mac's clipboard (#1801).
//!
//! The Simulator app copies a booted device's pasteboard to the host's
//! (Edit > Automatically Sync Pasteboard, `PasteboardAutomaticSync`, on by
//! default). A test that copies text, or `simctl pbcopy`, then replaces
//! whatever the person last copied, and finishing the test or shutting the
//! device down does not bring it back. Devices booted without the app open
//! (how `xcodebuild test` runs them) are not synced.
//!
//! So a shell command that runs simulator tests or writes a simulator's
//! pasteboard is refused while the app is open with sync on, or when that
//! cannot be checked. graff never changes the setting and never reads or
//! restores the clipboard itself: a save/restore would roll back something
//! the person copied during the run. `GRAFF_ALLOW_SIM_PASTEBOARD=1` turns the
//! check off.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sim_ledger = @import("sim_ledger.zig");

pub const allow_env = "GRAFF_ALLOW_SIM_PASTEBOARD";

/// Set by `init` (macOS, not allowed by env).
pub var enabled = false;

pub fn init(environ_map: anytype) void {
    if (builtin.os.tag != .macos) return;
    if (environ_map.get(allow_env)) |v| if (!std.mem.eql(u8, v, "0")) return;
    enabled = true;
}

/// Whether a command runs simulator tests or writes a simulator pasteboard.
/// A project's own run script is not recognized: only these spellings.
pub fn writesPasteboard(cmd: []const u8) bool {
    var xcodebuild = false;
    var simctl = false;
    var words = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|()'\"");
    while (words.next()) |word| {
        const base = if (std.mem.lastIndexOfScalar(u8, word, '/')) |i| word[i + 1 ..] else word;
        if (std.mem.eql(u8, base, "xcodebuild")) xcodebuild = true;
        if (std.mem.eql(u8, base, "simctl")) simctl = true;
        if (std.mem.eql(u8, base, "xctest")) return true;
        if (xcodebuild and (std.mem.eql(u8, word, "test") or std.mem.eql(u8, word, "test-without-building"))) return true;
        if (simctl and (std.mem.eql(u8, word, "pbcopy") or std.mem.eql(u8, word, "pbsync"))) return true;
    }
    return false;
}

pub const Host = enum { isolated, shared, unknown };

/// Whether the Simulator app would copy a device's pasteboard to the Mac's.
pub fn host(gpa: Allocator, io: Io, run: sim_ledger.Runner) Host {
    const app = run(gpa, io, &.{ "pgrep", "-x", "Simulator" });
    gpa.free(app.stdout);
    if (app.code == 1) return .isolated;
    if (app.code != 0) return .unknown;
    const pref = run(gpa, io, &.{ "defaults", "read", "com.apple.iphonesimulator", "PasteboardAutomaticSync" });
    defer gpa.free(pref.stdout);
    // An unset key is the default: on.
    if (pref.code == 0 and std.mem.eql(u8, std.mem.trim(u8, pref.stdout, " \t\r\n"), "0")) return .isolated;
    return .shared;
}

pub const shared_text = "simulator command not run: the Simulator app is open with Edit > Automatically Sync Pasteboard on, so a test that copies text would replace the clipboard on this Mac, and nothing restores it. Nothing was run. Ask the user to quit the Simulator app (xcodebuild runs simulator tests without it) or turn that menu item off, then run it again. Do not change the setting or the clipboard yourself.";
pub const unknown_text = "simulator command not run: graff could not check whether the Simulator app would copy the test's pasteboard to this Mac's clipboard. Nothing was run. Ask the user to quit the Simulator app, then run it again.";

/// The refusal for `cmd`, or null when it may run.
pub fn refusal(gpa: Allocator, io: Io, cmd: []const u8) ?[]const u8 {
    return refusalWith(gpa, io, cmd, enabled, hostRun);
}

pub fn refusalWith(gpa: Allocator, io: Io, cmd: []const u8, on: bool, run: sim_ledger.Runner) ?[]const u8 {
    if (!on or !writesPasteboard(cmd)) return null;
    return switch (host(gpa, io, run)) {
        .isolated => null,
        .shared => shared_text,
        .unknown => unknown_text,
    };
}

fn hostRun(gpa: Allocator, io: Io, argv: []const []const u8) sim_ledger.Run {
    return sim_ledger.g.run(gpa, io, argv);
}

test "#1801: simulator tests and pasteboard writes are recognized, other simulator work is not" {
    for ([_][]const u8{
        "xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' test",
        "cd apps/ios && /usr/bin/xcodebuild test-without-building -xctestrun x.xctestrun",
        "echo hi | xcrun simctl pbcopy booted",
        "xcrun simctl pbsync booted host",
        "xcrun xctest Foo.xctest",
    }) |cmd| try std.testing.expect(writesPasteboard(cmd));
    for ([_][]const u8{
        "xcodebuild -scheme App build",
        "xcrun simctl list devices booted -j",
        "xcrun simctl pbpaste booted",
        "swift test",
        "zig build test",
        "grep -r test xcodebuild.log",
    }) |cmd| try std.testing.expect(!writesPasteboard(cmd));
}

const Fake = struct {
    var app: ?u8 = 0;
    var pref: ?u8 = 0;
    var pref_out: []const u8 = "1\n";
    fn run(gpa: Allocator, _: Io, argv: []const []const u8) sim_ledger.Run {
        if (std.mem.eql(u8, argv[0], "pgrep")) return .{ .code = app, .stdout = gpa.dupe(u8, "") catch &.{} };
        return .{ .code = pref, .stdout = gpa.dupe(u8, pref_out) catch &.{} };
    }
};

test "#1801: refused while the app is open with sync on or unset; runs when it is closed or sync is off" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cmd = "xcodebuild -scheme App test";
    Fake.app = 0;
    Fake.pref = 0;
    Fake.pref_out = "1\n";
    try std.testing.expectEqualStrings(shared_text, refusalWith(gpa, io, cmd, true, Fake.run).?);
    Fake.pref = 1; // key never set: the default is on
    try std.testing.expectEqualStrings(shared_text, refusalWith(gpa, io, cmd, true, Fake.run).?);
    Fake.pref = 0;
    Fake.pref_out = "0\n";
    try std.testing.expect(refusalWith(gpa, io, cmd, true, Fake.run) == null);
    Fake.app = 1; // the app is not running
    Fake.pref_out = "1\n";
    try std.testing.expect(refusalWith(gpa, io, cmd, true, Fake.run) == null);
    Fake.app = null; // pgrep itself failed
    try std.testing.expectEqualStrings(unknown_text, refusalWith(gpa, io, cmd, true, Fake.run).?);
    Fake.app = 0;
    try std.testing.expect(refusalWith(gpa, io, cmd, false, Fake.run) == null);
    try std.testing.expect(refusalWith(gpa, io, "xcodebuild build", true, Fake.run) == null);
}
