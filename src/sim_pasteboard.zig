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
//! cannot be checked. A command that also opens Simulator cannot treat its
//! currently closed state as isolation. graff leaves the setting and the
//! clipboard alone: saving and restoring the clipboard would roll back something
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

/// Recognize the ordinary Launch Services spellings in compound commands.
/// A script or binary that opens Simulator internally is outside this check.
fn opensSimulator(cmd: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, cmd, "\n;&|()");
    while (segments.next()) |segment| {
        var opening = false;
        var words = std.mem.tokenizeAny(u8, segment, " \t\r'\"");
        while (words.next()) |word| {
            const base = std.fs.path.basename(word);
            if (std.mem.eql(u8, base, "open")) opening = true;
            if (opening and (std.ascii.eqlIgnoreCase(base, "Simulator") or
                std.ascii.eqlIgnoreCase(base, "Simulator.app") or
                std.ascii.eqlIgnoreCase(word, "com.apple.iphonesimulator"))) return true;
        }
    }
    return false;
}

const Preflight = enum { read_pref, isolated, unknown };

fn preflight(status: ?u8, opens_gui: bool) Preflight {
    if (status == 0 or (status == 1 and opens_gui)) return .read_pref;
    return if (status == 1) .isolated else .unknown;
}

/// Whether the Simulator app would copy a device's pasteboard to the Mac's.
fn host(gpa: Allocator, io: Io, run: sim_ledger.Runner, opens_gui: bool) Host {
    const app = run(gpa, io, &.{ "pgrep", "-x", "Simulator" });
    gpa.free(app.stdout);
    switch (preflight(app.code, opens_gui)) {
        .isolated => return .isolated,
        .unknown => return .unknown,
        .read_pref => {},
    }
    const pref = run(gpa, io, &.{ "defaults", "read", "com.apple.iphonesimulator", "PasteboardAutomaticSync" });
    defer gpa.free(pref.stdout);
    // An unset key is the default: on.
    if (pref.code == 0 and std.mem.eql(u8, std.mem.trim(u8, pref.stdout, " \t\r\n"), "0")) return .isolated;
    return .shared;
}

pub const shared_text = "simulator command not run: the Simulator app is open with Edit > Automatically Sync Pasteboard on, so a test that copies text would replace the clipboard on this Mac, and nothing restores it. Nothing was run. Ask the user to quit the Simulator app (xcodebuild runs simulator tests without it) or turn that menu item off, then run it again. Do not change the setting or the clipboard yourself.";
pub const unknown_text = "simulator command not run: graff could not check whether the Simulator app would copy the test's pasteboard to this Mac's clipboard. Nothing was run. Ask the user to quit the Simulator app, then run it again.";
pub const launch_text = "simulator command not run: it opens the Simulator app and runs tests or writes the simulator pasteboard with automatic sync enabled or unset. Run the test headlessly without opening Simulator, or have the user confirm automatic sync is off. Do not change the setting or the clipboard yourself.";

/// The refusal for `cmd`, or null when it may run.
pub fn refusal(gpa: Allocator, io: Io, cmd: []const u8) ?[]const u8 {
    return refusalWith(gpa, io, cmd, enabled, hostRun);
}

test "#1801: Simulator preflight matches the shared Lean decision table" {
    const table = @embedFile("test_fixtures/simulator_pasteboard.tsv");
    var rows = std.mem.tokenizeScalar(u8, table, '\n');
    for ([_]?u8{ 0, 1, null }, [_][]const u8{ "running", "stopped", "unknown" }) |status, label| {
        for ([_]bool{ false, true }, [_][]const u8{ "closed-command", "opens-gui" }) |opens_gui, command| {
            const decision = switch (preflight(status, opens_gui)) {
                .read_pref => "read-pref",
                .isolated => "isolated",
                .unknown => "unknown",
            };
            var buf: [64]u8 = undefined;
            try std.testing.expectEqualStrings(
                rows.next() orelse return error.MissingFixtureRow,
                try std.fmt.bufPrint(&buf, "{s}\t{s}\t{s}", .{ label, command, decision }),
            );
        }
    }
    try std.testing.expectEqual(null, rows.next());
}

pub fn refusalWith(gpa: Allocator, io: Io, cmd: []const u8, on: bool, run: sim_ledger.Runner) ?[]const u8 {
    if (!on or !writesPasteboard(cmd)) return null;
    const opens_gui = opensSimulator(cmd);
    return switch (host(gpa, io, run, opens_gui)) {
        .isolated => null,
        .shared => if (opens_gui) launch_text else shared_text,
        .unknown => unknown_text,
    };
}

test "#1801: a compound test command cannot open Simulator after checking that it is closed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    Fake.app = 1;
    Fake.pref = 1;
    for ([_][]const u8{
        "open -a Simulator && xcodebuild test",
        "/usr/bin/open -b com.apple.iphonesimulator; xcrun simctl pbcopy booted",
        "open -a '/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app' && xcodebuild test",
    }) |cmd| try std.testing.expectEqualStrings(launch_text, refusalWith(gpa, io, cmd, true, Fake.run).?);
    try std.testing.expect(refusalWith(gpa, io, "xcodebuild test", true, Fake.run) == null);
    Fake.pref = 0;
    Fake.pref_out = "0\n";
    try std.testing.expect(refusalWith(gpa, io, "open -a Simulator && xcodebuild test", true, Fake.run) == null);
}

test "#1801: Bash refuses a compound GUI launch before it starts either command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const saved_enabled = enabled;
    const saved_ledger = sim_ledger.g;
    defer enabled = saved_enabled;
    defer sim_ledger.g = saved_ledger;
    enabled = true;
    sim_ledger.g = .{ .run = Fake.run };
    Fake.app = 1;
    Fake.pref = 1;
    const input = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"command":"open() { printf 'unexpected open'; }; xcodebuild() { printf 'unexpected test'; }; open -a Simulator && xcodebuild test"}
    , .{});
    defer input.deinit();
    const ctx: @import("tools.zig").ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = undefined,
        .provider = undefined,
        .registry = null,
        .from_sub = true,
        .approvals = null,
        .tracer = null,
    };
    const out = try @import("exec_bash.zig").exec(ctx, .{ .id = "c", .name = "bash", .input = input.value });
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expectEqualStrings(launch_text, out.text);
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
