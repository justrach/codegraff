//! Tests for sim_ledger.zig (#407) against a fake host: no real simulator,
//! `simctl`, `pgrep` or `pkill` is ever run.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proc_identity = @import("proc_identity.zig");
const sim = @import("sim_ledger.zig");
const Ledger = sim.Ledger;
const Udid = sim.Udid;
const Run = sim.Run;
const relevant = sim.relevant;
const parseBooted = sim.parseBooted;

const testing = std.testing;

const A = "AAAAAAAA-0000-4000-8000-00000000000A".*; // the user's own device
const B = "BBBBBBBB-0000-4000-8000-00000000000B".*;

/// The host as `simctl`, `pgrep` and `pkill` see it.
const Host = struct {
    var booted: [8]Udid = undefined;
    var n: usize = 0;
    var gui: bool = false;
    /// What the bracketed command does: booted on the first list after it starts.
    var boots: ?Udid = null;
    var opens_gui = false;
    var lists: usize = 0;
    var fail_list = false;
    var dead_pid: i32 = 0;
    var log_buf: [512]u8 = undefined;
    var log_len: usize = 0;

    fn reset(devices: []const Udid) void {
        @memcpy(booted[0..devices.len], devices);
        n = devices.len;
        gui = false;
        boots = null;
        opens_gui = false;
        lists = 0;
        fail_list = false;
        dead_pid = 0;
        log_len = 0;
    }

    fn log() []const u8 {
        return log_buf[0..log_len];
    }

    fn note(comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(log_buf[log_len..], fmt, args) catch return;
        log_len += s.len;
    }

    /// Each bracket lists twice (before, after): the command runs between.
    fn commandRuns() void {
        if (boots) |u| {
            booted[n] = u;
            n += 1;
            boots = null;
        }
        if (opens_gui) gui = true;
        opens_gui = false;
    }

    fn run(gpa: Allocator, io: Io, argv: []const []const u8) Run {
        _ = io;
        const empty: []const u8 = &.{};
        if (std.mem.eql(u8, argv[0], "pgrep")) return .{ .code = if (gui) 0 else 1, .stdout = empty };
        if (std.mem.eql(u8, argv[0], "pkill")) {
            gui = false;
            note("quit Simulator\n", .{});
            return .{ .code = 0, .stdout = empty };
        }
        if (std.mem.eql(u8, argv[2], "shutdown")) {
            for (booted[0..n], 0..) |u, i| if (std.mem.eql(u8, &u, argv[3])) {
                booted[i] = booted[n - 1];
                n -= 1;
                break;
            };
            note("shutdown {s}\n", .{argv[3][0..8]});
            return .{ .code = 0, .stdout = empty };
        }
        // list devices booted -j
        if (fail_list) return .{ .code = null, .stdout = &.{} };
        var aw: Io.Writer.Allocating = .init(gpa);
        aw.writer.writeAll("{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-18-0\":[") catch unreachable;
        for (booted[0..n], 0..) |u, i| aw.writer.print("{s}{{\"udid\":\"{s}\",\"state\":\"Booted\",\"name\":\"iPhone\"}}", .{ if (i == 0) "" else ",", &u }) catch unreachable;
        aw.writer.writeAll("],\"com.apple.CoreSimulator.SimRuntime.watchOS-11-0\":[{\"udid\":\"CCCCCCCC-0000-4000-8000-00000000000C\",\"state\":\"Shutdown\"}]}}") catch unreachable;
        lists += 1;
        return .{ .code = 0, .stdout = aw.toOwnedSlice() catch unreachable };
    }

    fn live(io: Io, rec: proc_identity.Record) bool {
        _ = io;
        return rec.pid != dead_pid;
    }
};

fn testLedger(root: []const u8, pid: i32) Ledger {
    return .{ .root = root, .run = Host.run, .live = Host.live, .self = .{ .pid = pid, .start_id = 1 } };
}

/// One bracketed shell command on `l`: snapshot, the command, snapshot.
fn bracketed(l: *Ledger, cmd: []const u8, finished: bool) void {
    const b = l.before(testing.allocator, testing.io, cmd) orelse return;
    Host.commandRuns();
    l.after(testing.allocator, testing.io, b, finished);
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    return buf[0..len];
}

test "#407: simulator work is recognized by the command, not every command" {
    for ([_][]const u8{ "xcrun simctl boot 'iPhone 16'", "open -a Simulator", "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'", "./apps/ios/build-sim.sh", "npx react-native run-ios", "npm run ios", "flutter run -d iPhone" }) |cmd|
        try testing.expect(relevant(cmd));
    for ([_][]const u8{ "zig build test", "cat scenarios.md", "git status", "ls bios/" }) |cmd|
        try testing.expect(!relevant(cmd));
}

test "#407: simctl's booted list parses to UDIDs, and only booted ones" {
    const text =
        \\{"devices":{"rt.iOS":[{"udid":"AAAAAAAA-0000-4000-8000-00000000000A","state":"Booted"},{"udid":"../../etc","state":"Booted"},{"udid":"BBBBBBBB-0000-4000-8000-00000000000B","state":"Shutdown"}],"rt.watch":[]}}
    ;
    const got = try parseBooted(testing.allocator, text);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings(&A, &got[0]);
}

test "#407: a finished run shuts down the device it booted and not the user's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var l = testLedger(try tmpRoot(&tmp, &buf), 101);
    defer l.deinit(testing.allocator);
    Host.reset(&.{A});
    Host.gui = true; // the user already has the Simulator app open
    Host.boots = B;
    bracketed(&l, "xcrun simctl boot BBBBBBBB-0000-4000-8000-00000000000B", true);
    bracketed(&l, "xcrun simctl install booted App.app && xcrun simctl launch booted com.example.app", true);
    try testing.expectEqual(@as(usize, 1), l.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("shutdown BBBBBBBB\n", Host.log());
    try testing.expectEqual(@as(usize, 1), Host.n);
    try testing.expectEqualStrings(&A, &Host.booted[0]);
    try testing.expect(Host.gui);
    const left = l.listRecords(testing.allocator, testing.io);
    defer testing.allocator.free(left);
    try testing.expectEqual(@as(usize, 0), left.len);
}

test "#407: the Simulator app a run opened is quit once no device is left" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var l = testLedger(try tmpRoot(&tmp, &buf), 101);
    defer l.deinit(testing.allocator);
    Host.reset(&.{});
    Host.boots = B;
    Host.opens_gui = true;
    bracketed(&l, "xcrun simctl boot B && open -a Simulator", true);
    try testing.expectEqual(@as(usize, 1), l.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("shutdown BBBBBBBB\nquit Simulator\n", Host.log());
    try testing.expect(!Host.gui);
}

test "#407: a device another live session uses stays up until the last one ends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var first = testLedger(root, 101);
    defer first.deinit(testing.allocator);
    var second = testLedger(root, 102);
    defer second.deinit(testing.allocator);
    Host.reset(&.{});
    Host.boots = B;
    bracketed(&first, "xcrun simctl boot B", true);
    bracketed(&second, "xcodebuild test -destination 'platform=iOS Simulator,id=B'", true);
    try testing.expectEqual(@as(usize, 0), first.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("", Host.log());
    try testing.expectEqual(@as(usize, 1), second.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("shutdown BBBBBBBB\n", Host.log());
}

test "#407: a dead session's device is shut down by the next session to end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var crashed = testLedger(root, 101);
    defer crashed.deinit(testing.allocator);
    Host.reset(&.{A});
    Host.boots = B;
    bracketed(&crashed, "xcrun simctl boot B", true);
    Host.dead_pid = 101; // it never released
    var later = testLedger(root, 103); // ran no simulator command at all
    defer later.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), later.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("shutdown BBBBBBBB\n", Host.log());
}

test "#407: without a snapshot before the command nothing is attributed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var l = testLedger(try tmpRoot(&tmp, &buf), 101);
    defer l.deinit(testing.allocator);
    Host.reset(&.{A});
    Host.fail_list = true;
    try testing.expect(l.before(testing.allocator, testing.io, "xcrun simctl boot B") == null);
    Host.fail_list = false;
    try testing.expectEqual(@as(usize, 0), l.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("", Host.log());
}

test "#407: a device a backgrounded command boots later is still the session's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var l = testLedger(try tmpRoot(&tmp, &buf), 101);
    defer l.deinit(testing.allocator);
    Host.reset(&.{A});
    const b = l.before(testing.allocator, testing.io, "xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 16'").?;
    l.after(testing.allocator, testing.io, b, false); // parked, nothing booted yet
    Host.booted[1] = B; // the parked job boots it later
    Host.n = 2;
    try testing.expectEqual(@as(usize, 1), l.release(testing.allocator, testing.io));
    try testing.expectEqualStrings("shutdown BBBBBBBB\n", Host.log());
}

test "#407: a shell command that boots a simulator has it shut down when the session's jobs are reaped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const saved = sim.g;
    defer sim.g = saved;
    sim.g = testLedger(try tmpRoot(&tmp, &buf), 101);
    defer sim.g.deinit(testing.allocator);
    Host.reset(&.{A});
    Host.boots = B; // the fake host boots B while the command runs
    const tools = @import("tools.zig");
    const input = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"command\":\"echo xcrun simctl boot\"}", .{});
    defer input.deinit();
    const ctx: tools.ToolCtx = .{ .gpa = testing.allocator, .io = testing.io, .client = undefined, .provider = undefined, .registry = null, .from_sub = true, .approvals = null, .tracer = null };
    // The before snapshot is the first list; the command "boots" B by the next.
    const saved_run = sim.g.run;
    sim.g.run = struct {
        fn run(gpa: Allocator, io: Io, argv: []const []const u8) Run {
            const r = Host.run(gpa, io, argv);
            if (Host.lists == 1) Host.commandRuns();
            return r;
        }
    }.run;
    defer sim.g.run = saved_run;
    const out = try @import("exec_bash.zig").exec(ctx, .{ .id = "c", .name = "bash", .input = input.value });
    defer testing.allocator.free(out.text);
    try testing.expect(!out.is_error);
    @import("jobs.zig").jobsReap(testing.allocator, testing.io);
    try testing.expectEqualStrings("shutdown BBBBBBBB\n", Host.log());
    try testing.expectEqual(@as(usize, 1), Host.n);
}
