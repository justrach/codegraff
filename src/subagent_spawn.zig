//! Spawn admission: children cannot spawn children, cleanup is not a
//! child task, and live fan-out is capped (#1135).
const std = @import("std");

pub const max_live: u32 = 8;

pub fn allowed(from_sub: bool) bool {
    return !from_sub;
}

/// Description/prompt looks like "clean up the tree" or "fix what that
/// agent created" — finish is not archive; do not launch a fix-it child.
/// Bare "cleanup" in a prompt is not enough (a helper named cleanup() is work).
pub fn isCleanupTask(description: []const u8, prompt: []const u8) bool {
    return hasAny(description, &.{ "clean up", "cleanup", "cleaning up" }) or
        hasAny(prompt, &.{
            "clean up the worktree",
            "cleanup the worktree",
            "cleaning up the worktree",
            "archive the worktree",
            "remove the worktree",
            "delete the worktree",
            "fix the issue that",
            "fix what the other",
            "clean up after",
            "fix the issue created",
        });
}

pub fn refuse(from_sub: bool, description: []const u8, prompt: []const u8, live: u32) ?[]const u8 {
    if (!allowed(from_sub)) return "subagents cannot spawn subagents — do this work yourself";
    if (isCleanupTask(description, prompt))
        return "finish is not archive — do not spawn a child to clean up a worktree; keep dirty or unique-commit trees, and only remove an empty clean tree";
    if (live >= max_live)
        return "too many agents already running — finish or collect existing children before spawning more";
    return null;
}

fn hasAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (indexOfIgnoreCase(text, n) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "spec/prompt_cache: sub never spawns" {
    try std.testing.expect(allowed(false));
    try std.testing.expect(!allowed(true));
}

test "#1135 refuse: nested spawn, cleanup phrase, and live cap" {
    try std.testing.expect(refuse(true, "review", "read src/main.zig", 0) != null);
    try std.testing.expect(refuse(false, "clean up", "remove leftover files", 0) != null);
    try std.testing.expect(refuse(false, "fix leftover", "clean up the worktree after the child", 1) != null);
    try std.testing.expect(refuse(false, "fix issue", "fix the issue that the other agent created", 0) != null);
    try std.testing.expect(refuse(false, "review", "read the diff", max_live) != null);
    try std.testing.expect(refuse(false, "review", "read the diff", max_live - 1) == null);
    try std.testing.expect(!isCleanupTask("review patch", "read src/foo.zig and report defects"));
}

test "#1135 cleanup detector is case-insensitive and ignores ordinary review" {
    try std.testing.expect(isCleanupTask("Cleaning Up", "archive leftovers"));
    try std.testing.expect(isCleanupTask("worker", "CLEANUP the worktree after the child"));
    try std.testing.expect(!isCleanupTask("implementer", "add a cleanup() helper on the test tmpDir"));
}
