//! Synthetic process-boundary regressions for clipboard failures (#883).
const std = @import("std");
const native = @import("clipboard_native.zig");
const clip = @import("vision_clipboard.zig");
const paste = @import("vision_paste.zig");
const runner = @import("process_runner.zig");

const Reply = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: u8 = 0,
    truncated: bool = false,
    timed_out: bool = false,
    cancelled: bool = false,
    stderr_truncated: bool = false,
    missing: bool = false,
    file: ?[]const u8 = null,
};

fn check(comptime replies: []const Reply, expected: clip.GrabAttempt) !void {
    const Mock = struct {
        var calls: usize = 0;
        var path_buf: [1024]u8 = undefined;
        var path_len: usize = 0;

        fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdout_cap: usize, stderr_cap: usize, deadline_ms: u64) !runner.CappedRun {
            try std.testing.expectEqual(@as(usize, 7), argv.len);
            try std.testing.expectEqualStrings("clipboard-failure-test", argv[6]);
            try std.testing.expectEqual(@as(usize, 64), stdout_cap);
            try std.testing.expectEqual(@as(usize, 1024), stderr_cap);
            try std.testing.expectEqual(@as(u64, 5000), deadline_ms);
            try std.testing.expect(calls < replies.len);
            if (calls == 0) {
                try std.testing.expect(argv[5].len <= path_buf.len);
                path_len = argv[5].len;
                @memcpy(path_buf[0..path_len], argv[5]);
            } else {
                try std.testing.expectEqualStrings(path_buf[0..path_len], argv[5]);
            }
            const reply = replies[calls];
            calls += 1;
            if (reply.file) |bytes| {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = argv[5], .data = bytes });
            }
            if (reply.missing) return error.FileNotFound;
            const stdout = try gpa.dupe(u8, reply.stdout);
            errdefer gpa.free(stdout);
            const stderr = try gpa.dupe(u8, reply.stderr);
            return .{
                .term = .{ .exited = reply.exit_code },
                .stdout = stdout,
                .stderr = stderr,
                .stdout_truncated = reply.truncated,
                .stderr_truncated = reply.stderr_truncated,
                .timed_out = reply.timed_out,
                .cancelled = reply.cancelled,
            };
        }
    };
    Mock.calls = 0;
    Mock.path_len = 0;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const path = try std.fs.path.join(gpa, &.{ root_buf[0..root_len], "clipboard.png" });
    const got = native.grabWithRunner(io, gpa, "clipboard-failure-test", path, Mock.run);
    defer if (got == .ok) got.ok.release(io, gpa);
    try std.testing.expectEqual(replies.len, Mock.calls);
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(got));
    switch (expected) {
        .failed => |kind| {
            try std.testing.expectEqual(kind, got.failed);
            if (kind == .access) {
                const message = paste.pasteMessage(.{ .failed = got.failed });
                try std.testing.expect(std.mem.indexOf(u8, message, "Automation") == null);
                try std.testing.expect(std.mem.indexOf(u8, message, "synthetic helper error") == null);
            }
        },
        .empty => {},
        .ok => {
            try std.testing.expect(got.ok.owned);
            try std.testing.expectEqual(clip.Flavor.png, got.ok.flavor);
            try std.testing.expectEqualStrings(Mock.path_buf[0..Mock.path_len], got.ok.path);
            try std.testing.expect(clip.looksLikePng(io, got.ok.path));
        },
    }
    if (got != .ok) {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, Mock.path_buf[0..Mock.path_len], .{}));
    }
}

test "#883 missing clipboard executable is unavailable" {
    try check(&.{.{ .missing = true }}, .{ .failed = .unavailable });
}

test "#883 clipboard timeout takes precedence over helper reply" {
    try check(&.{.{ .stdout = "ok:png", .timed_out = true, .file = "partial" }}, .{ .failed = .timeout });
}

test "#883 clipboard changed twice exhausts retry and removes partial file" {
    try check(&.{ .{ .stdout = "changed", .file = "partial" }, .{ .stdout = "changed", .file = "partial again" } }, .{ .failed = .changed });
}

test "#883 clipboard changed then PNG succeeds and retains owned file" {
    try check(&.{ .{ .stdout = "changed", .file = "partial" }, .{ .stdout = "ok:png", .file = clip.png_magic } }, .{ .ok = .{ .path = "", .flavor = .png, .owned = true } });
}

test "#883 unknown clipboard reply is extraction failure" {
    try check(&.{.{ .stdout = "unexpected" }}, .{ .failed = .extract });
}

test "#883 truncated clipboard reply is extraction failure" {
    try check(&.{.{ .stdout = "ok:png", .truncated = true, .file = clip.png_magic }}, .{ .failed = .extract });
}

test "#883 invalid clipboard flavor is extraction failure" {
    try check(&.{.{ .stdout = "ok:invalid", .file = clip.png_magic }}, .{ .failed = .extract });
}

test "#883 successful clipboard reply without file is extraction failure" {
    try check(&.{.{ .stdout = "ok:png" }}, .{ .failed = .extract });
}

test "#883 successful clipboard reply with bad file is extraction failure" {
    try check(&.{.{ .stdout = "ok:png", .file = "not a PNG" }}, .{ .failed = .extract });
}

test "#883 generic clipboard failure is access without Automation advice" {
    try check(&.{.{ .exit_code = 1, .stderr = "synthetic helper error", .file = "partial" }}, .{ .failed = .access });
}

test "#883 explicit Apple Event denial is denied" {
    try check(&.{.{ .exit_code = 1, .stderr = "synthetic helper error (-1743)\n" }}, .{ .failed = .denied });
}

test "#883 clipboard retry cannot accept stale output" {
    try check(&.{ .{ .stdout = "changed", .file = clip.png_magic }, .{ .stdout = "ok:png" } }, .{ .failed = .extract });
}

test "#883 truncated denial and cancellation never imply permission failure" {
    try check(&.{.{ .exit_code = 1, .stderr = "error (-1743)", .stderr_truncated = true }}, .{ .failed = .access });
    try check(&.{.{ .stdout = "ok:png", .cancelled = true, .file = clip.png_magic }}, .{ .failed = .access });
}

test "#883 empty clipboard removes partial file" {
    try check(&.{.{ .stdout = "empty", .file = "partial" }}, .empty);
}
