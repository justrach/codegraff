//! One bounded nudge when the user named a source file and the model
//! answered without touching the tree. The in-house 5/6 miss was this shape:
//! one call, "I'll read SPEC.md…", no edit, tests still fail.
//!
//! Shared by `-p` and the REPL (no oneshot-only skip). At most one extra
//! model call, and only when tools_used is still empty.

const std = @import("std");

const Agent = @import("agent.zig").Agent;
const messages_mod = @import("messages.zig");

pub const max_nudges: u8 = 1;

pub const nudge_text =
    "You named a source file and have not used a tool. Read the named path " ++
    "and edit it before answering — do not describe a fix you have not applied.";

const source_needles = [_][]const u8{ ".py", ".zig", ".js", ".ts", "SPEC.md" };

/// True when `text` names a source path (not a greeting.txt-style data file).
pub fn hasNamedSource(text: []const u8) bool {
    for (source_needles) |n| {
        if (std.mem.indexOf(u8, text, n) != null) return true;
    }
    return false;
}

pub fn shouldNudge(tools_used: u64, nudges: u8, prompt: []const u8) bool {
    if (nudges >= max_nudges) return false;
    if (tools_used != 0) return false;
    return hasNamedSource(prompt);
}

fn lastUserText(self: *Agent) []const u8 {
    var i = self.messages.items.len;
    while (i > 0) {
        i -= 1;
        const msg = self.messages.items[i];
        if (msg != .object) continue;
        const role = msg.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        const content = msg.object.get("content") orelse continue;
        if (content == .string) return content.string;
    }
    return "";
}

/// Append the nudge and ask the caller to `continue` the turn loop.
pub fn handle(self: *Agent, _: []const u8) !bool {
    if (!shouldNudge(self.tools_used.count(), self.named_work_nudges, lastUserText(self)))
        return false;
    self.named_work_nudges += 1;
    try self.messages.append(try messages_mod.textMessage(self.arena, "user", nudge_text));
    return true;
}

test "hasNamedSource sees SPEC and .py, ignores greeting.txt and pong" {
    try std.testing.expect(hasNamedSource("Read SPEC.md and affinity.py"));
    try std.testing.expect(hasNamedSource("Fix fib.py"));
    try std.testing.expect(hasNamedSource("edit stall_notice.py"));
    try std.testing.expect(!hasNamedSource("Reply with exactly: pong"));
    try std.testing.expect(!hasNamedSource("Create hello.txt then rename it"));
}

test "shouldNudge is once, and only when no tools have run" {
    try std.testing.expect(shouldNudge(0, 0, "Fix fib.py"));
    try std.testing.expect(!shouldNudge(1, 0, "Fix fib.py"));
    try std.testing.expect(!shouldNudge(0, 1, "Fix fib.py"));
    try std.testing.expect(!shouldNudge(0, 0, "Reply with exactly: pong"));
}
