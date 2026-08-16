//! One-level spawn gate. Children cannot spawn children.
const std = @import("std");

pub fn allowed(from_sub: bool) bool {
    return !from_sub;
}

test "spec/prompt_cache: sub never spawns" {
    try std.testing.expect(allowed(false));
    try std.testing.expect(!allowed(true));
}
