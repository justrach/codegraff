//! Spawn admission: children cannot spawn children, cleanup is not a
//! child task, and live fan-out is capped (#1135).
const std = @import("std");

pub const max_live: u32 = 8;

pub fn allowed(from_sub: bool) bool {
    return !from_sub;
}

/// Description/prompt asks for "clean up the tree" or "fix what that agent
/// created" — finish is not archive; do not launch a fix-it child.
/// A cleanup word alone is not that request (#1704): a cleanup() helper is
/// work, and "Review cleanup changes" is a review. The description counts
/// when it leads with the cleanup verb or pairs it with a worktree, and a
/// prompt that keeps the child read-only overrides a description-only match.
pub fn isCleanupTask(description: []const u8, prompt: []const u8) bool {
    if (requestsAny(prompt, &.{
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
    })) return true;
    return describesCleanup(description) and !hasAny(prompt, &read_only_phrases);
}

const cleanup_words = [_][]const u8{ "clean up", "cleanup", "cleaning up", "clean-up" };
const read_only_verbs = [_][]const u8{ "review", "audit", "inspect", "read", "check", "verify", "explain", "summarize", "summarise", "analyze", "analyse", "investigate", "look" };
const read_only_phrases = [_][]const u8{ "read-only", "read only", "readonly", "do not modify", "don't modify", "without modifying", "do not edit", "don't edit", "no edits" };

fn describesCleanup(description: []const u8) bool {
    const d = std.mem.trim(u8, description, " \t\r\n");
    for (cleanup_words) |w| if (startsWithWord(d, w)) return true;
    for (read_only_verbs) |v| if (startsWithWord(d, v)) return false;
    return hasAny(d, &cleanup_words) and hasAny(d, &.{ "worktree", "leftover" });
}

/// A phrase that is not negated: "do not remove the worktree" asks for nothing.
fn requestsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        var from: usize = 0;
        while (indexOfIgnoreCasePos(text, from, n)) |at| : (from = at + 1) {
            if (!negated(text[0..at])) return true;
        }
    }
    return false;
}

fn negated(before: []const u8) bool {
    const head = std.mem.trimEnd(u8, before, " \t\r\n");
    const word = head[if (std.mem.lastIndexOfAny(u8, head, " \t\r\n")) |i| i + 1 else 0..];
    for ([_][]const u8{ "not", "never", "no", "without" }) |w| if (std.ascii.eqlIgnoreCase(word, w)) return true;
    return std.ascii.endsWithIgnoreCase(word, "n't");
}

fn startsWithWord(text: []const u8, prefix: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(text, prefix)) return false;
    return text.len == prefix.len or !std.ascii.isAlphanumeric(text[prefix.len]);
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
    return indexOfIgnoreCasePos(hay, 0, needle);
}

fn indexOfIgnoreCasePos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i: usize = start;
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

test "#1704 a read-only review that mentions cleanup is not a cleanup child" {
    const review = "Perform a read-only code review. Do not modify files, branches, or worktrees. Return findings only.";
    try std.testing.expect(refuse(false, "Review cleanup changes", review, 0) == null);
    try std.testing.expect(refuse(false, "Review cleanup changes", "read the diff and report defects", 0) == null);
    try std.testing.expect(refuse(false, "Fix cleanup() leak in parser", "free the arena in parser.zig", 0) == null);
    try std.testing.expect(refuse(false, "Review worktree cleanup PR", review, 0) == null);
    try std.testing.expect(refuse(false, "review", "Read-only. Do not remove the worktree; never clean up the worktree.", 0) == null);
    // Real worktree cleanup, removal, or archive still refuses.
    try std.testing.expect(refuse(false, "Cleanup", "remove the stale tree", 0) != null);
    try std.testing.expect(refuse(false, "Clean up worktree", "remove it once it is merged", 0) != null);
    try std.testing.expect(refuse(false, "Worktree cleanup", "drop the leftover branch", 0) != null);
    try std.testing.expect(refuse(false, "review", "read-only check, then remove the worktree", 0) != null);
    try std.testing.expect(refuse(false, "Review and archive", "archive the worktree after reading it", 0) != null);
}
