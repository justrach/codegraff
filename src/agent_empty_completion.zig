//! Degenerate-completion policy for Agent.runTurn.
//!
//! 1. Empty / whitespace-only completions (no tool calls) used to end the
//!    turn silently. Rewind and re-ask, bounded.
//! 2. Lean `-p` text-only first completions (DeepSeek flash SWE): the model
//!    describes a patch and stops. That is not done — bounce once with a
//!    user note. Do not steal Pi's four-tool catalog (ADR 0024 / 0047).
//!
//! Split from agent.zig (600-line goal); wired only in runTurn.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const no_local_tools = @import("no_local_tools.zig");
const messages = @import("messages.zig");

/// Retries allowed per turn for consecutive degenerate completions.
pub const max_consecutive: u8 = 2;

/// True when `final_text` is a degenerate completion worth one more ask.
/// `retries` = attempts already spent on this turn. Whitespace-only text is
/// still degenerate: no real final answer is pure whitespace.
pub fn shouldRetry(final_text: []const u8, retries: u8) bool {
    if (retries >= max_consecutive) return false;
    return std.mem.trim(u8, final_text, " \t\r\n").len == 0;
}

/// Lean `-p` described a fix and never called a tool. One bounce.
pub const bounce_note = "You described a change but did not call any tool. Inspect and edit the files with read_file / edit_file / write_file; do not claim the tree is already updated.";

pub fn shouldBounce(unattended: bool, lean: bool, text_only: bool, review: bool, sub: bool, tool_calls: u64, model_calls: u64, final_text: []const u8) bool {
    if (!unattended or !lean or text_only or review or sub) return false;
    if (tool_calls != 0 or model_calls != 1) return false;
    return std.mem.trim(u8, final_text, " \t\r\n").len > 0;
}

/// Handle a degenerate completion inside runTurn. Returns true when the
/// caller should `continue` the loop.
pub fn handle(self: *Agent, final_text: []const u8, hist_len: usize) !bool {
    if (shouldRetry(final_text, self.empty_completion_retries)) {
        self.empty_completion_retries += 1;
        self.closeCodexWs();
        self.messages.shrinkRetainingCapacity(@min(hist_len, self.messages.items.len));
        try self.say("[model returned an empty completion — retrying ({d}/{d})]\n", .{ self.empty_completion_retries, max_consecutive });
        return true;
    }
    if (!shouldBounce(main_mod.unattended, no_local_tools.lean, self.text_only, self.review_mode, self.sub, self.tool_calls_this_turn, self.model_calls_this_turn, final_text))
        return false;
    try self.messages.append(try messages.textMessage(self.arena, "user", bounce_note));
    try self.say("[described a change with no tool call — asking once more]\n", .{});
    if (self.tracer) |tr| tr.note("fake_done", "lean -p text-only; bounced");
    return true;
}

test "retry empty completions up to the cap" {
    try std.testing.expect(shouldRetry("", 0));
    try std.testing.expect(shouldRetry("", 1));
    try std.testing.expect(!shouldRetry("", max_consecutive));
    try std.testing.expect(!shouldRetry("", max_consecutive + 1));
}

test "whitespace-only completions are degenerate, real text never is" {
    try std.testing.expect(shouldRetry(" \r\n\t", 0));
    try std.testing.expect(!shouldRetry("done", 0));
    try std.testing.expect(!shouldRetry("<|eos|>", 0));
}

test "lean -p text-only first completion bounces once" {
    try std.testing.expect(shouldBounce(true, true, false, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, false, 0, 2, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, false, 1, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(false, true, false, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, false, false, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, true, false, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, true, false, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, true, 0, 1, "I fixed validated.py"));
    try std.testing.expect(!shouldBounce(true, true, false, false, false, 0, 1, "   "));
}

test "bounce note names the file tools" {
    try std.testing.expect(std.mem.indexOf(u8, bounce_note, "edit_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, bounce_note, "write_file") != null);
}
