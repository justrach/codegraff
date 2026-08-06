//! #418 — usage attribution: a completed child's tokens are BILLABLE to the
//! run and INVISIBLE to the parent's context math.
//!
//! Two accounts exist and they must never be the same one:
//!
//!   * the BILL — `pricing.g_cost`, a process-wide `CostTally` every agent
//!     writes through `Agent.recordCost`. A child's spend belongs here: the
//!     `[usage]` footer, `/cost` and the `--json` `cost_usd` field all have to
//!     include the fleet, or a fan-out run under-reports what it just spent.
//!
//!   * the METER — `Agent.last_context_tokens` / `Agent.context_local_tokens`,
//!     per-agent fields the compaction gates read through
//!     `effectiveContextTokens` / `inputOverCompactThreshold`. Only the
//!     parent's OWN request may move these. A child's context is not in the
//!     parent's window; it never was.
//!
//! Cross the two and fleet-heavy runs compact early: eight workers that each
//! filled their own window would read as a parent five times over its wall,
//! and the parent would throw away history it still had room for.
//!
//! Both spawn paths are covered. `runSub` returns `SubRun{ output, usage }`
//! (subagent_run.zig): the FOREGROUND path (`execSubagent`) keeps `output`
//! only, and the BACKGROUND path (`agentJobPump` → `agent_output`) stores
//! `usage` on the job and renders it with `agentStatusText` — as TEXT the
//! model reads, never as a number the parent's meter adds.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const pricing = @import("pricing.zig");
const subagent = @import("subagent.zig");
const subagent_run = @import("subagent_run.zig");
const textMessage = @import("messages.zig").textMessage;
const util = @import("util.zig");

const parent_model = "claude-sonnet-4-6";
const child_model = "claude-haiku-4-5";
const parent_context: u64 = 100_000; // compactAt() = 80_000

/// One completed request's provider usage, in the anthropic wire shape
/// `recordUsage` reads.
const Sample = struct {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
};

fn usageResponse(a: std.mem.Allocator, s: Sample) !std.json.ObjectMap {
    var u: std.json.ObjectMap = .empty;
    try u.put(a, "input_tokens", .{ .integer = s.input });
    try u.put(a, "output_tokens", .{ .integer = s.output });
    try u.put(a, "cache_read_input_tokens", .{ .integer = s.cache_read });
    try u.put(a, "cache_creation_input_tokens", .{ .integer = s.cache_write });
    var root: std.json.ObjectMap = .empty;
    try root.put(a, "usage", .{ .object = u });
    return root;
}

/// Just enough Agent for the meter path: systemPrompt/toolsJson, the provider
/// window, and the two anchors contextEstimate pairs. Same `undefined`-plus-
/// explicit-fields shape agent_context.zig's own tests use.
fn blankAgent(a: std.mem.Allocator, io: std.Io, sub: bool, model: []const u8, context: u64) Agent {
    var agent: Agent = undefined;
    agent.io = io;
    agent.arena = a;
    agent.messages = std.json.Array.init(a);
    agent.provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = model, .context = context };
    agent.sub = sub;
    agent.review_mode = false;
    agent.strict = false;
    agent.ultracode_mode = false;
    agent.reasoning = .medium;
    agent.sys_override = null;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.sys_ultra = "";
    agent.sys_ultra_strict = "";
    agent.tools_anthropic = "";
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.last_cache_read = 0;
    agent.last_usage_includes_output = false;
    return agent;
}

/// A root mid-session: one user turn and the meter a finished turn leaves.
fn seedParent(a: std.mem.Allocator, io: std.Io) !Agent {
    var parent = blankAgent(a, io, false, parent_model, parent_context);
    try parent.messages.append(try textMessage(a, "user", "map this repo with eight workers, then land the change"));
    parent.recordUsage(try usageResponse(a, .{ .input = 12_000, .output = 800, .cache_read = 5_000, .cache_write = 0 }), 60_000);
    return parent;
}

const child_sample: Sample = .{ .input = 140_000, .output = 3_000, .cache_read = 20_000, .cache_write = 1_000 };

/// Run one worker to completion and build the hand-off `runSub` actually
/// returns (subagent_run.zig:385): duration, tool calls, and the child's OWN
/// meter reading — `agent.effectiveContextTokens()`, not the parent's.
fn finishChild(a: std.mem.Allocator, io: std.Io) !subagent_run.AgentUsage {
    var child = blankAgent(a, io, true, child_model, 200_000);
    try child.messages.append(try textMessage(a, "user", &util.repeatBytes("audit ", 2_000)));
    child.recordUsage(try usageResponse(a, child_sample), 12_000);
    return .{
        .duration_ms = 41_000,
        .tool_calls = 17,
        .context_tokens = child.effectiveContextTokens(),
        .cache_read_tokens = child.last_cache_read,
    };
}

test "#418: parent context is identical with and without an attributed child; only the bill differs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Two identical roots. `fleeted` spawns the workers; `lonely` runs the
    // same turn alone and is the control the meter is compared against.
    var lonely = try seedParent(a, io);
    var fleeted = try seedParent(a, io);
    try std.testing.expectEqual(lonely.last_context_tokens, fleeted.last_context_tokens);
    try std.testing.expectEqual(lonely.effectiveContextTokens(), fleeted.effectiveContextTokens());
    try std.testing.expect(!fleeted.inputOverCompactThreshold()); // the turn is nowhere near the wall

    const before_last = fleeted.last_context_tokens;
    const before_local = fleeted.context_local_tokens;
    const before_effective = fleeted.effectiveContextTokens();
    const cost_before = pricing.g_cost.snap(io);

    const fleet_size: u64 = 8;
    for (0..fleet_size) |i| {
        const usage = try finishChild(a, io);
        // Each worker ALONE ends past the parent's compaction threshold: this
        // is the fleet-heavy run #418 is about, and one leaked child would be
        // enough to trip the gate below.
        try std.testing.expect(usage.context_tokens > fleeted.provider.compactAt());

        // Background rollup (#276 P0-3): agentJobPump assigns `job.usage =
        // run.usage` and agent_output renders it. The child's context total is
        // REPORTED to the model as text…
        const status = try subagent.agentStatusText(gpa, @intCast(i + 1), true, false, usage, "report");
        defer gpa.free(status);
        try std.testing.expect(std.mem.indexOf(u8, status, "context token(s)") != null);
        // …and the foreground rollup (execSubagent) keeps `run.output` alone,
        // which is why neither reaches a parent field at all.
    }

    // The METER: not one field moved, and the control agrees.
    try std.testing.expectEqual(before_last, fleeted.last_context_tokens);
    try std.testing.expectEqual(before_local, fleeted.context_local_tokens);
    try std.testing.expectEqual(before_effective, fleeted.effectiveContextTokens());
    try std.testing.expectEqual(lonely.effectiveContextTokens(), fleeted.effectiveContextTokens());
    try std.testing.expectEqual(lonely.inputOverCompactThreshold(), fleeted.inputOverCompactThreshold());
    try std.testing.expect(!fleeted.inputOverCompactThreshold()); // no early compaction

    // The BILL: the run-wide tally moved by EXACTLY the children's usage.
    const cost_after = pricing.g_cost.snap(io);
    try std.testing.expectEqual(cost_before.api_calls + fleet_size, cost_after.api_calls);
    // recordUsage folds anthropic cache WRITES into uncached input; cache
    // READS bill on their own line.
    const billed_in: u64 = @intCast(child_sample.input + child_sample.cache_write);
    const billed_cache: u64 = @intCast(child_sample.cache_read);
    const billed_out: u64 = @intCast(child_sample.output);
    try std.testing.expectEqual(cost_before.in_tokens + fleet_size * billed_in, cost_after.in_tokens);
    try std.testing.expectEqual(cost_before.cache_tokens + fleet_size * billed_cache, cost_after.cache_tokens);
    try std.testing.expectEqual(cost_before.out_tokens + fleet_size * billed_out, cost_after.out_tokens);
    const per_child = pricing.usdFor(pricing.priceFor(child_model).?, child_sample.input + child_sample.cache_write, child_sample.cache_read, child_sample.output);
    try std.testing.expect(per_child > 0); // the assertion below is only worth anything if the model is priced
    try std.testing.expectApproxEqAbs(cost_before.usd + @as(f64, @floatFromInt(fleet_size)) * per_child, cost_after.usd, 1e-9);
}

test "#418: a child's context total reaches the parent as report bytes, never as context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = try seedParent(a, io);
    const before = parent.effectiveContextTokens();

    // A worker that filled almost half a 1M window. Its report is the only
    // thing that crosses into the parent — as a tool result the parent appends
    // to its own history, so the parent pays for the CHARACTERS and nothing else.
    const usage: subagent_run.AgentUsage = .{ .duration_ms = 612_000, .tool_calls = 143, .context_tokens = 480_000, .cache_read_tokens = 90_000 };
    const status = try subagent.agentStatusText(gpa, 1, true, false, usage, "found it: src/foo.zig:120 drops the errdefer");
    defer gpa.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "480000") != null); // the number is in the parent's context as digits…
    try parent.messages.append(try textMessage(a, "user", status));

    const after = parent.effectiveContextTokens();
    try std.testing.expect(after > before); // …the report is real input and is counted…
    try std.testing.expect(after - before < 200); // …at its own size, not at the child's 480k.
    try std.testing.expect(!parent.inputOverCompactThreshold());
}
