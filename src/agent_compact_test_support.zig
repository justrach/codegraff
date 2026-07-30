//! Shared builders for agent_compact_test.zig's subagent-task-pin tests
//! (#B3). Kept out of agent_compact_test.zig to stay under its 600-line cap;
//! this file has no `test` blocks of its own so it needs no main.zig hook.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const textMessage = @import("messages.zig").textMessage;

/// A subagent-or-root Agent with just enough fields set for handoffMessage /
/// pinChildTask to run without touching uninitialized memory.
pub fn subAgent(a: std.mem.Allocator, sub: bool) Agent {
    var agent: Agent = undefined;
    agent.arena = a;
    agent.sub = sub;
    agent.review_mode = false;
    agent.todos = .empty;
    agent.goal = null;
    agent.task_prompt = null;
    return agent;
}

/// A one-message std.json.Array, the shape a fresh subagent history starts as.
pub fn msg1(a: std.mem.Allocator, role: []const u8, text: []const u8) !std.json.Array {
    return std.json.Array.fromOwnedSlice(a, try a.dupe(Value, &.{try textMessage(a, role, text)}));
}

/// An anthropic user message carrying a single tool_result block - the
/// response half of a tool call, and NOT a clean user turn.
pub fn toolResultMsg(a: std.mem.Allocator, content: []const u8) !Value {
    const s = try std.fmt.allocPrint(a, "{{\"role\":\"user\",\"content\":[{{\"type\":\"tool_result\",\"content\":\"{s}\"}}]}}", .{content});
    return std.json.parseFromSliceLeaky(Value, a, s, .{});
}

/// A subagent-shaped history: one clean user turn at index 0, followed by
/// `n` assistant/tool_result pairs - i.e. no other clean user turn anywhere.
pub fn paddedSubHistory(a: std.mem.Allocator, n: usize, pad: []const u8) !std.json.Array {
    var out = try msg1(a, "user", "AUDIT src/foo.zig");
    for (0..n) |_| try out.appendSlice(&.{ try textMessage(a, "assistant", pad), try toolResultMsg(a, "result") });
    return out;
}
