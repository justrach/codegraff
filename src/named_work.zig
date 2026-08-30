//! One bounded nudge when the user named a source file and the model
//! answered without touching the tree. The in-house 5/6 miss was this shape:
//! one call, "I'll read SPEC.md…", no edit, tests still fail.
//!
//! Shared by `-p` and the REPL (no oneshot-only skip). At most one extra
//! model call, and only when tools_used is still empty.

const std = @import("std");
const Value = std.json.Value;

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

fn valueNamesSource(v: Value) bool {
    switch (v) {
        .string => |s| return hasNamedSource(s),
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (valueNamesSource(e.value_ptr.*)) return true;
            }
            return false;
        },
        .array => |a| {
            for (a.items) |item| {
                if (valueNamesSource(item)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Walk every string in history. Responses items often have no `role=user`
/// / `content` string, so looking at only the last user message misses the
/// named path and the nudge never fires.
pub fn conversationNamesSource(messages: []const Value) bool {
    for (messages) |m| {
        if (valueNamesSource(m)) return true;
    }
    return false;
}

/// Append the nudge and ask the caller to `continue` the turn loop.
pub fn handle(self: *Agent, _: []const u8) !bool {
    if (self.named_work_nudges >= max_nudges) return false;
    if (self.tools_used.count() != 0) return false;
    if (!conversationNamesSource(self.messages.items)) return false;
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

test "conversationNamesSource sees Responses input_text, not role=user" {
    const raw =
        \\{"type":"message","content":[{"type":"input_text","text":"Fix atomic_write.py"}]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const msgs = [_]Value{parsed.value};
    try std.testing.expect(conversationNamesSource(&msgs));
    const pong = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"role\":\"user\",\"content\":\"pong\"}", .{});
    defer pong.deinit();
    const pongs = [_]Value{pong.value};
    try std.testing.expect(!conversationNamesSource(&pongs));
}
