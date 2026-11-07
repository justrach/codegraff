//! Native capabilities around the shared chat step. REPL and ACP both use this
//! adapter through Agent.stepOpenAI; the Worker supplies a capability-only host.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const ToolCall = @import("tools.zig").ToolCall;
const steps = @import("agent_steps.zig");
const repair_calls = @import("tool_call_repair.zig");
const eval_control = @import("agent_eval_control.zig");

pub fn apiError(self: *Agent, message: []const u8) !void {
    try self.sayApiError("{s}", .{message});
}

pub fn repair(self: *Agent, message: *std.json.Value, limited: bool) !void {
    // Never reconstruct executable arguments from a reply cut mid-output.
    if (limited) return;
    if (@import("effort_route.zig").mimoRoute(self.provider.id, self.provider.model))
        _ = try repair_calls.repairCalls(self.arena, self.scratchAlloc(), message, self.toolsJson());
    if (@import("additional_tools.zig").active(self.provider))
        _ = try repair_calls.retypeArgs(self.arena, self.scratchAlloc(), message, self.toolsJson());
    _ = try repair_calls.recoverInlineCalls(self.arena, self.scratchAlloc(), message, self.toolsJson());
}

pub fn surfaceText(self: *Agent, text: []const u8) !void {
    try steps.surfaceUnstreamedText(self, text);
}

pub fn afterTools(self: *Agent, calls: []const ToolCall, stuck: bool) !?[]const u8 {
    try @import("turn_checkpoint.zig").afterToolBatch(self);
    if (stuck) {
        try self.say("{s}\n", .{repair_calls.loop_stop_text});
        return repair_calls.loop_stop_text;
    }
    if (eval_control.shouldStopAfterBatch(calls, self.eval_repair_pending)) {
        if (try steps.grantRepairTurn(self)) return null;
        return eval_control.verifier_hard_stop;
    }
    if (self.yielded) |handoff| return handoff;
    if (self.completed) |result| return result;
    return null;
}

pub fn stopped(self: *Agent, reason: []const u8) !void {
    try self.say("[stopped: {s}]\n", .{reason});
}
