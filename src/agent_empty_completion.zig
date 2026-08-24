//! Degenerate-completion policy for Agent.runTurn. A provider completion can
//! arrive with no text, no tool calls, and no non-"stop" finish reason —
//! observed live on the chat wire as `content: null`, no `tool_calls`
//! (mid-task, right after a successful write_file). The step functions then
//! return "" and the turn ends silently: the session sits there looking dead.
//! Instead, rewind the history the step function just appended and re-ask,
//! bounded per turn so a wedged provider can't spin up unbounded spend.
//! Split from agent.zig (600-line goal); wired only in runTurn.

const std = @import("std");
const Agent = @import("agent.zig").Agent;

/// Retries allowed per turn for consecutive degenerate completions.
pub const max_consecutive: u8 = 2;

/// True when `final_text` is a degenerate completion worth one more ask.
/// `retries` = attempts already spent on this turn. Whitespace-only text is
/// still degenerate: no real final answer is pure whitespace.
pub fn shouldRetry(final_text: []const u8, retries: u8) bool {
    if (retries >= max_consecutive) return false;
    return std.mem.trim(u8, final_text, " \t\r\n").len == 0;
}

/// Handle a degenerate completion inside runTurn: spend one bounded retry by
/// rewinding the history the step function just appended (clamped — an
/// in-request compaction may already have shrunk it) and re-opening the WS
/// chain, whose watermark is keyed to the dropped messages. Returns true when
/// the caller should `continue` the loop.
pub fn handle(self: *Agent, final_text: []const u8, hist_len: usize) !bool {
    if (!shouldRetry(final_text, self.empty_completion_retries)) return false;
    self.empty_completion_retries += 1;
    self.closeCodexWs();
    self.messages.shrinkRetainingCapacity(@min(hist_len, self.messages.items.len));
    try self.say("[model returned an empty completion — retrying ({d}/{d})]\n", .{ self.empty_completion_retries, max_consecutive });
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
