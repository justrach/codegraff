const std = @import("std");
const stop = @import("job_registry_stop.zig");
const Probe = @import("proc_identity.zig").Probe;
const Fake = struct {
    live: Probe = .{ .id = 77 },
    pgid: ?i32 = 42,
    own: ?i32 = 99,
    signals: usize = 0,
    sleeps: usize = 0,
    fail_signal: ?stop.Signal = null,
    fail_sleep: bool = false,
    gone: ?bool = false,
    group_gone_at: usize = 999,
    change_at: usize = 999,
    changed: Probe = .{ .id = 78 },
    pub fn probe(self: *Fake, _: i32) Probe {
        return if (self.sleeps >= self.change_at) self.changed else self.live;
    }
    pub fn group(self: *Fake, _: i32) ?i32 {
        return self.pgid;
    }
    pub fn ownGroup(self: *Fake) ?i32 {
        return self.own;
    }
    pub fn signal(self: *Fake, _: i32, sig: stop.Signal) !void {
        self.signals += 1;
        if (self.fail_signal == sig) return error.PermissionDenied;
    }
    pub fn groupGone(self: *Fake, _: i32) ?bool {
        return if (self.sleeps >= self.group_gone_at) true else self.gone;
    }
    pub fn sleep(self: *Fake) !void {
        if (self.fail_sleep) return error.Canceled;
        self.sleeps += 1;
    }
};

test "stopped group may contain only zombies but never live or unknown members" {
    try std.testing.expectEqual(@as(?bool, true), stop.noLiveMembers("42 Z\n43 S\n", 42));
    try std.testing.expectEqual(@as(?bool, false), stop.noLiveMembers("42 Z\n42 S+\n", 42));
    try std.testing.expectEqual(@as(?bool, null), stop.noLiveMembers(" \n", 42));
    try std.testing.expectEqual(@as(?bool, null), stop.noLiveMembers("42\n", 42));
}

test "stop rejects zero identity and unsafe pids without signals" {
    var f: Fake = .{};
    for ([_]i32{ -42, 0, 1 }) |pid| try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(pid, 77, &f));
    try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 0, &f));
    try std.testing.expectEqual(@as(usize, 0), f.signals);
}
test "stop rejects mismatched unknown and zero live identities" {
    for ([_]Probe{ .{ .id = 78 }, .unknown, .{ .id = 0 } }, 0..) |live, i| {
        var f: Fake = .{ .live = live };
        try std.testing.expectEqual(if (i == 0) stop.Result.gone else stop.Result.unverifiable, stop.stop(42, 77, &f));
        try std.testing.expectEqual(@as(usize, 0), f.signals);
    }
}
test "stop rejects own group nonleader and unavailable group" {
    for ([_]?i32{ 99, null, 41 }) |group| {
        var f: Fake = .{ .pgid = group };
        try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &f));
        try std.testing.expectEqual(@as(usize, 0), f.signals);
    }
    var f: Fake = .{ .own = 42 };
    try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &f));
    try std.testing.expectEqual(@as(usize, 0), f.signals);
}
test "stop does not escalate after reuse unknown or leader exit" {
    for ([_]Probe{ .{ .id = 78 }, .unknown, .gone }) |changed| {
        var f: Fake = .{ .change_at = 20, .changed = changed };
        try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &f));
        try std.testing.expectEqual(@as(usize, 1), f.signals);
    }
}
test "stop waits for descendants after leader exit without another signal" {
    var f: Fake = .{ .change_at = 1, .changed = .gone, .group_gone_at = 3 };
    try std.testing.expectEqual(stop.Result.stopped, stop.stop(42, 77, &f));
    try std.testing.expectEqual(@as(usize, 1), f.signals);
    try std.testing.expectEqual(@as(usize, 3), f.sleeps);
}

test "stop reports TERM and KILL failures without success" {
    for ([_]stop.Signal{ .term, .kill }, 1..) |sig, count| {
        var f: Fake = .{ .fail_signal = sig };
        try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &f));
        try std.testing.expectEqual(count, f.signals);
    }
}
test "stop requires confirmed group exit and honors probe and sleep errors" {
    var success: Fake = .{ .gone = true };
    try std.testing.expectEqual(stop.Result.stopped, stop.stop(42, 77, &success));
    var unknown_group: Fake = .{ .gone = null };
    try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &unknown_group));
    var canceled: Fake = .{ .fail_sleep = true };
    try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &canceled));
    try std.testing.expectEqual(@as(usize, 1), canceled.signals);
    var survives: Fake = .{};
    try std.testing.expectEqual(stop.Result.unverifiable, stop.stop(42, 77, &survives));
    try std.testing.expectEqual(@as(usize, 2), survives.signals);
}
