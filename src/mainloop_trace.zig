//! Per-turn trajectory + recipe outcome recording, extracted from mainloop so
//! the oversized event loop keeps moving toward the repository's 600-LOC cap.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const pricing = @import("pricing.zig");
const recipe = @import("recipe.zig");
const scoring = @import("scoring.zig");
const telemetry = @import("telemetry.zig");
const trace = @import("trace.zig");
const util = @import("util.zig");

pub const Before = struct {
    model_calls: u64,
    cost: pricing.CostTally,
};

pub fn begin(root: *agent_mod.Agent, io: Io) Before {
    return .{
        .model_calls = if (root.run_budget) |budget| budget.used() else 0,
        .cost = pricing.g_cost.snap(io),
    };
}

pub fn record(
    root: *agent_mod.Agent,
    io: Io,
    arena: Allocator,
    task: []const u8,
    turn_id: u64,
    turn_started: Io.Timestamp,
    result: anyerror![]const u8,
    context_tokens: u64,
    before: Before,
    prev_turn_id: *u64,
    prev_prompt_fp: *[16]u8,
) void {
    const prompt = root.systemPrompt();
    const prompt_fp = scoring.promptFingerprint(prompt);
    const task_class = recipe.classifyTask(task);
    const current_recipe = recipe.snapshot(root.provider.id, root.provider.model, @tagName(root.reasoning), prompt, root.toolsJson(), task_class);
    const turn_ms: i64 = @intCast(@max(0, turn_started.untilNow(io, .awake).toMilliseconds()));
    const turn_ok = if (result) |_| true else |_| false;
    const turn_tools = root.tools_used.render(arena);
    const after = pricing.g_cost.snap(io);
    const outcome: recipe.Outcome = .{
        .success = turn_ok,
        .latency_ms = @intCast(@max(0, turn_ms)),
        .model_calls = (if (root.run_budget) |budget| budget.used() else before.model_calls) -| before.model_calls,
        .tool_errors = root.tools_used.errorCount(),
        .uncached_tokens = after.in_tokens -| before.cost.in_tokens,
        .cache_read_tokens = after.cache_tokens -| before.cost.cache_tokens,
        .cost_microusd = @intFromFloat(@max(0.0, after.usd - before.cost.usd) * 1_000_000.0),
    };
    const mutated = !std.mem.eql(u8, &prompt_fp, prev_prompt_fp);

    if (root.tracer) |tracer| tracer.write(.{
        .t = tracer.elapsedMs(),
        .ev = "recipe_outcome",
        .recipe_sha = &current_recipe.recipe_sha,
        .task_class = task_class,
        .provider = root.provider.id,
        .model = root.provider.model,
        .effort = @tagName(root.reasoning),
        .success = outcome.success,
        .latency_ms = outcome.latency_ms,
        .model_calls = outcome.model_calls,
        .tool_calls = root.tool_calls_this_turn,
        .tool_errors = outcome.tool_errors,
        .uncached_tokens = outcome.uncached_tokens,
        .cache_read_tokens = outcome.cache_read_tokens,
        .cache_permille = outcome.cachePermille(),
        .cost_microusd = outcome.cost_microusd,
    });

    if (trace.g_traj) |trajectory| {
        trajectory.capturePrompt(prompt_fp, prompt);
        trajectory.node(.{
            .id = turn_id,
            .parent = prev_turn_id.*,
            .kind = "turn",
            .label = root.provider.model,
            .t = trajectory.elapsedMs(),
            .ms = turn_ms,
            .prompt_sha = &prompt_fp,
            .prompt_mutated = mutated,
            .recipe_sha = &current_recipe.recipe_sha,
            .recipe_provider = root.provider.id,
            .recipe_model = root.provider.model,
            .recipe_effort = @tagName(root.reasoning),
            .recipe_toolset_sha = &current_recipe.toolset_sha,
            .task_class = task_class,
            .task = util.utf8Prefix(task, 160),
            .tools = turn_tools,
            .ok = turn_ok,
            .context_tokens = context_tokens,
            .model_calls = outcome.model_calls,
            .tool_errors = outcome.tool_errors,
            .uncached_tokens = outcome.uncached_tokens,
            .cache_read_tokens = outcome.cache_read_tokens,
            .cost_microusd = outcome.cost_microusd,
        });
        if (!turn_ok) {
            const detail: []const u8 = if (result) |_| "" else |err| switch (err) {
                error.ApiError => root.last_api_error orelse "api error",
                error.StreamStalled => root.last_api_error orelse "stream stalled — ended turn",
                error.StreamDropped => root.last_api_error orelse "stream dropped — ended turn",
                else => @errorName(err),
            };
            trajectory.node(.{ .kind = "turn_error", .parent = turn_id, .t = trajectory.elapsedMs(), .detail = detail });
        }
        if (telemetry.g_telem) |item| item.runEvent(&prompt_fp, mutated, turn_ok, turn_ms, turn_tools);
        prev_turn_id.* = turn_id;
        prev_prompt_fp.* = prompt_fp;
    }
}
