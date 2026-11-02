//! #1686: calibrate compaction state from the provider's own count. A Responses
//! request carrying a compaction item reports its input tokens; the state's
//! share replaces the bytes/16 estimate for that state
//! (context_tokens.learnState).
//!
//! A chained request (previous_response_id, the WebSocket delta) counts too:
//! OpenAI bills every earlier input token in the chain as input, so its
//! input_tokens covers the whole context, the same reading the context meter
//! already takes from it, and Codex's own occupancy uses every response's usage
//! the same way. Skipping it left a WebSocket session (chatgpt-new's default)
//! with no count until a compaction forced a full resend.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const context_tokens = @import("context_tokens.zig");

pub fn learn(self: *Agent, response: std.json.ObjectMap) void {
    const usage = response.get("usage") orelse return;
    if (usage != .object) return;
    const input = usage.object.get("input_tokens") orelse return;
    if (input != .integer or input.integer <= 0) return;
    const history: std.json.Value = .{ .array = self.messages };
    const bytes = context_tokens.compactionStateBytes(history);
    if (bytes == 0) return;
    context_tokens.learnState(bytes, @intCast(input.integer), self.fullRequestEstimateTokens());
}
