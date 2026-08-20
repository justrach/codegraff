//! Lexical half of the PathConfine kernel.
//!
//! Freestanding: no `Io`, no live `/proc`, no symlink probe. Same predicate
//! Lean (`lean-proofs/Graff/PathConfine.lean`) and `spec/ref/path_confine.py`
//! export. The Zig file-tool path (`harness_policy.confinedPath`) is the
//! same function plus a separate symlink walk that stays off this surface.

const std = @import("std");

/// True when `path` is a relative path with no `..` component. Empty,
/// absolute (`/`-prefixed), and any `..` segment are jail-breaks. Backslash
/// is treated as a separator so `foo\..\bar` fails the same way as `foo/../bar`.
pub fn confined(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

test "confined: empty, absolute, and parent segments fail" {
    try std.testing.expect(!confined(""));
    try std.testing.expect(!confined("/etc/passwd"));
    try std.testing.expect(!confined("../outside"));
    try std.testing.expect(!confined("a/../../b"));
    try std.testing.expect(confined("src/main.zig"));
    try std.testing.expect(confined("a/./b"));
    try std.testing.expect(confined("..hidden"));
}
