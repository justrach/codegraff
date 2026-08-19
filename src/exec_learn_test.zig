//! learningArgv privacy-ceiling test, moved off exec.zig (600-line cap).

const std = @import("std");
const exec = @import("exec.zig");

test "internal learning respects the parent privacy ceiling" {
    var argv: [10][]const u8 = undefined;
    var len = exec.learningArgv(&argv, "graff", false);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "local", "learn", "run" }, argv[0..len]);
    len = exec.learningArgv(&argv, "graff", true);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "aggregate", "learn", "run", "--submit" }, argv[0..len]);
}
