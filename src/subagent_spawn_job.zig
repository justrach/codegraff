//! Background job ownership and registration.
const std = @import("std");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const Provider = @import("provider.zig").Provider;
const Isolation = @import("fleet.zig").Isolation;
const main_mod = @import("main.zig");
const vision_ask = @import("vision_ask.zig");
const subagent = @import("subagent.zig");
const AgentJob = subagent.AgentJob;
const ledger = @import("subagent_ledger.zig");
pub fn spawnSubBackground(ctx: ToolCtx, label: []const u8, prompt: []const u8, sys_override: ?[]const u8, niche: []const u8, isolation: Isolation, isolation_fallback: bool, pin: ?Provider, effort: ?main_mod.ReasoningEffort, ask: vision_ask.Ask) !ToolOutput {
    const gpa = ctx.gpa;
    const label_c = try gpa.dupe(u8, label);
    errdefer gpa.free(label_c);
    const prompt_c = try gpa.dupe(u8, prompt);
    errdefer gpa.free(prompt_c);
    const sys_c: ?[]u8 = if (sys_override) |s| try gpa.dupe(u8, s) else null;
    errdefer if (sys_c) |s| gpa.free(s);
    const niche_c = try gpa.dupe(u8, niche);
    errdefer gpa.free(niche_c);

    const owned = try gpa.create(@import("subagent_owned.zig").Owned);
    owned.* = .init(gpa);
    errdefer {
        owned.arena.deinit();
        gpa.destroy(owned);
    }
    const owned_ctx = try owned.context(ctx);
    const state = ctx.retained_worker;
    const owned_pin = if (pin) |p| try owned.provider(p) else null;
    const owner = if (ctx.interactive_children) try owned.arena.allocator().dupe(u8, ctx.session_name) else null;
    const job = try gpa.create(AgentJob);
    job.* = .{
        .id = 0,
        .label = label_c,
        .prompt = prompt_c,
        .sys_override = sys_c,
        .niche = niche_c,
        .isolation = isolation,
        .isolation_fallback = isolation_fallback,
        .pin = owned_pin,
        .effort = effort,
        .owned = owned,
        .owner = owner,
        .ask = ask.rebased(prompt_c), // the caller's arena dies with this call
        .ctx = owned_ctx,
    };

    subagent.g_agent_jobs.mutex.lockUncancelable(ctx.io);
    job.id = subagent.g_agent_jobs.next_id;
    subagent.g_agent_jobs.next_id += 1;
    const receipt = (if (state) |saved| std.fmt.allocPrint(
        gpa,
        "[agent {d} started: {s}] [task_id {s}]\nIt runs in the background across turns. Do not poll. agent_output(id {d}, wait_ms>0) waits for completion. agent_message queues feedback; subagent_resume continues the retained conversation after completion.",
        .{ job.id, job.label, saved.record.id, job.id },
    ) else std.fmt.allocPrint(gpa, "[agent {d} started: {s}]\nIt runs in the background across turns. Do not poll. agent_output(id {d}, wait_ms>0) waits for completion.", .{ job.id, job.label, job.id })) catch |err| {
        subagent.g_agent_jobs.mutex.unlock(ctx.io);
        gpa.destroy(job);
        return err;
    };
    subagent.g_agent_jobs.list.append(gpa, job) catch |err| {
        subagent.g_agent_jobs.mutex.unlock(ctx.io);
        gpa.free(receipt);
        gpa.destroy(job);
        return err;
    };
    subagent.g_agent_jobs.mutex.unlock(ctx.io);
    subagent.admitNext(gpa, ctx.io);
    ledger.remember(gpa, ctx.io, job.id, job.label);
    @import("subagent_interactive.zig").request(ctx);
    return .{ .text = receipt };
}
