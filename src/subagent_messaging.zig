//! Parent-facing feedback admission; no borrowed Agent pointer crosses threads.
const std = @import("std");
const tools = @import("tools.zig");
const subagent = @import("subagent.zig");

fn refused(gpa: std.mem.Allocator, reason: []const u8) !tools.ToolOutput {
    return .{ .text = try std.fmt.allocPrint(gpa, "Feedback was not queued: {s}", .{reason}), .is_error = true };
}

pub fn send(ctx: tools.ToolCtx, input: std.json.Value) !tools.ToolOutput {
    if (ctx.from_sub) return refused(ctx.gpa, "only the parent can message background subagents");
    const id = tools.intField(input, "id") orelse return tools.missingArg(ctx.gpa, "id");
    const message = tools.strField(input, "message") orelse return tools.missingArg(ctx.gpa, "message");
    if (id <= 0 or id > std.math.maxInt(u32)) return refused(ctx.gpa, "invalid agent id");
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(ctx.io);
    defer registry.mutex.unlock(ctx.io);
    for (registry.list.items) |job| {
        if (job.id != id) continue;
        if (job.done) return refused(ctx.gpa, "agent has already finished; start a new subagent for follow-up work");
        // Allocate the acknowledgement before enqueue so OOM cannot accept a
        // message and then fail to return its receipt.
        const ack = try std.fmt.allocPrint(ctx.gpa, "[agent {d}: feedback queued]\nThe current tool continues. Feedback is applied at a model-step boundary; use agent_output for the final report.", .{id});
        job.feedback.enqueue(job.ctx.gpa, ctx.io, message) catch |err| {
            ctx.gpa.free(ack);
            return refused(ctx.gpa, switch (err) {
                error.AgentFinished => "agent has already finished; start a new subagent for follow-up work",
                error.EmptyMessage => "message must not be blank",
                error.MessageTooLarge => "message exceeds 16 KiB",
                error.InvalidUtf8 => "message must be valid UTF-8",
                error.InboxFull => "agent's feedback queue is full; wait for it to process existing feedback",
                else => @errorName(err),
            });
        };
        return .{ .text = ack };
    }
    return refused(ctx.gpa, "agent is not live in this process; agent_output can inspect a retained result, but feedback requires a live background agent");
}
