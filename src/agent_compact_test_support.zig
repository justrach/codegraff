//! Shared builders for agent_compact_test.zig's subagent-task-pin tests
//! (#B3), plus a compact()-wiring test of its own (G2). Kept out of
//! agent_compact_test.zig to stay under its 600-line cap. It carries a
//! `test` block despite not being referenced from src/main.zig's test{}
//! block: any file reached through a *used* @import (agent_compact_test.zig
//! calls the builders below) is fully analyzed, and `zig test` collects test
//! declarations from every analyzed file, not just ones a main.zig `_ = x;`
//! line names directly - verified empirically by adding a deliberately
//! failing probe test here and confirming `zig build test` reported it.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const textMessage = @import("messages.zig").textMessage;
const compact = @import("agent_compact.zig");

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
    // compactPrelude reports the token figure compact() prints, so the estimate
    // path has to be reachable: system prompt, tool json, provider context and
    // the two meter anchors it reads.
    agent.sys_override = null;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.strict = false;
    agent.tools_anthropic = "";
    agent.tools_openai = "";
    agent.tools_responses = "";
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.provider = .{ .id = "test", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "m", .context = 100_000 };
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

// G2: compact() has exactly one call to pinChildTask, made through
// compactPrelude - the extracted pure prelude (early-empty-return + pin)
// that runs before compact() needs a live Io for its summarization request.
// A plain unit test cannot reach compact() itself, but it CAN drive
// compactPrelude directly, and that is a real proof of the wiring: delete
// the `pinChildTask(self);` line inside compactPrelude and this test goes
// red, whereas pinChildTask's own isolated tests above do not notice.
test "compactPrelude actually pins a subagent's task - the wiring compact() depends on (G2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = subAgent(a, true);
    agent.messages = try msg1(a, "user", "TASK X");
    // The prelude returns the token figure compact() prints, so the call
    // cannot be dropped without losing that number - which is what stops the
    // pin being orphaned by a plausible-looking tidy-up (G2).
    try std.testing.expect(compact.compactPrelude(&agent) != null);
    try std.testing.expectEqualStrings("TASK X", agent.task_prompt.?);

    var empty = subAgent(a, true);
    empty.messages = std.json.Array.init(a);
    try std.testing.expect(compact.compactPrelude(&empty) == null);
}
