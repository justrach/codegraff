//! Content classifier for acceptance/verification checklist items (#844).
//! Kept tiny so goal_todo and goal_verify can share it without a cycle.

const std = @import("std");

const needles = [_][]const u8{
    "verif",    "validat",      "acceptance",
    "run test", "run the test", "run ci",
    "run eval", "test it",      "tests pass",
    "check ci", "prove it",     "regression",
};

pub fn isVerification(content: []const u8) bool {
    if (content.len == 0) return false;
    var buf: [256]u8 = undefined;
    const n = @min(content.len, buf.len);
    for (content[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const slice = buf[0..n];
    for (needles) |need| if (std.mem.indexOf(u8, slice, need) != null) return true;
    return false;
}
