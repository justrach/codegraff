//! Explicit continuation of a retained child; queue-only messages never run it.
const std = @import("std");
const tools = @import("tools.zig");
const subagent = @import("subagent.zig");
const retained = @import("subagent_retained.zig");
const Provider = @import("provider.zig").Provider;
const Isolation = @import("fleet.zig").Isolation;
const Effort = @import("main.zig").ReasoningEffort;

pub fn foreground(ctx: tools.ToolCtx, label: []const u8, prompt: []const u8, system: ?[]const u8, niche: []const u8, isolation: Isolation, fallback: bool, pin: ?Provider, effort: ?Effort) !subagent.SubRun {
    const state = try retained.create(ctx, label);
    defer state.deinit(ctx.gpa, ctx.io);
    var child = ctx;
    child.retained_worker = state;
    var run = try subagent.runSub(child, "subagent", label, prompt, system, niche, isolation, fallback, pin, effort);
    errdefer ctx.gpa.free(run.output.text);
    const text = try std.fmt.allocPrint(ctx.gpa, "{s}\n\n[task_id {s}: retained worker; agent_message queues, subagent_resume continues]", .{ run.output.text, state.record.id });
    ctx.gpa.free(run.output.text);
    run.output.text = text;
    return run;
}

pub fn refuse(ctx: tools.ToolCtx, reason: []const u8) !tools.ToolOutput {
    return .{ .text = try std.fmt.allocPrint(ctx.gpa, "Worker follow-up refused: {s}", .{reason}), .is_error = true };
}
pub fn queued(ctx: tools.ToolCtx, id: []const u8, message: []const u8) !tools.ToolOutput {
    const state = retained.load(ctx, id) catch |err| return refuse(ctx, @errorName(err));
    defer state.deinit(ctx.gpa, ctx.io);
    const ack = try ctx.gpa.dupe(u8, "Feedback retained without starting a turn. Use subagent_resume with this task_id to continue.");
    errdefer ctx.gpa.free(ack);
    retained.enqueue(state, message) catch |err| {
        const out = try refuse(ctx, @errorName(err));
        ctx.gpa.free(ack);
        return out;
    };
    try retained.write(ctx.io, state);
    return .{ .text = ack };
}
pub fn exec(ctx: tools.ToolCtx, input: std.json.Value) !tools.ToolOutput {
    if (ctx.from_sub) return refuse(ctx, "only the owning parent can resume or forget workers");
    const id = tools.strField(input, "task_id") orelse return tools.missingArg(ctx.gpa, "task_id");
    const action = tools.strField(input, "action") orelse "resume";
    if (!std.mem.eql(u8, action, "resume") and !std.mem.eql(u8, action, "forget")) return refuse(ctx, "unknown action");
    const state = retained.load(ctx, id) catch |err| return refuse(ctx, @errorName(err));
    var transferred = false;
    defer if (!transferred) state.deinit(ctx.gpa, ctx.io);
    if (std.mem.eql(u8, action, "forget")) {
        state.record.deleted = true;
        state.record.messages = &.{};
        state.record.pending = &.{};
        try retained.write(ctx.io, state);
        return .{ .text = try ctx.gpa.dupe(u8, "Worker forgotten. Its workspace was not deleted.") };
    }
    const message = tools.strField(input, "message") orelse return tools.missingArg(ctx.gpa, "message");
    if (std.mem.trim(u8, message, " \t\r\n").len == 0 or message.len > @import("subagent_feedback.zig").max_message_bytes or !std.unicode.utf8ValidateSlice(message)) return refuse(ctx, "message must be valid UTF-8, nonempty and at most 16 KiB");
    if (!retained.budgetAllowed(state.record, ctx)) return refuse(ctx, "retained deadline or finite run budget is unavailable; exhausted limits cannot be renewed");
    const provider = providerFor(state.record, ctx) catch |err| return refuse(ctx, switch (err) {
        error.RetainedWorkerProviderUnavailable => "original provider is unavailable; no provider switch was authorized",
        error.RetainedWorkerProtocolChanged => "original provider protocol is unavailable; cannot reinterpret saved history",
    });
    var child = ctx;
    child.retained_worker = state;
    child.agent_cwd = state.record.cwd;
    if (state.record.deadline_ms) |deadline| child.loop_deadline_ms = if (ctx.loop_deadline_ms) |current| @min(current, deadline) else deadline;
    // Shared means this existing retained workspace, never the parent's cwd.
    const out = try subagent.spawnSubBackground(child, state.record.label, message, state.record.system_prompt, "", .shared_cwd, false, provider, state.record.reasoning, @import("vision_ask.zig").forPrompt(message));
    transferred = true;
    return out;
}

/// Restore the retained model on an authorized existing provider credential.
pub fn providerFor(record: retained.Record, ctx: tools.ToolCtx) error{ RetainedWorkerProviderUnavailable, RetainedWorkerProtocolChanged }!Provider {
    var provider = ctx.provider;
    if (!std.mem.eql(u8, provider.id, record.provider)) {
        provider = ctx.subagent_provider orelse return error.RetainedWorkerProviderUnavailable;
        if (!std.mem.eql(u8, provider.id, record.provider)) return error.RetainedWorkerProviderUnavailable;
    }
    // The parent may now use another model with a different wire format.
    // Validate the saved protocol against the saved model, not the parent.
    provider = provider.withModel(record.model);
    if (record.protocol) |kind| if (kind != provider.kind) return error.RetainedWorkerProtocolChanged;
    provider.context = record.context;
    return provider;
}
