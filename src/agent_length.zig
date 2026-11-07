//! Output limits are a continuation boundary, not successful completion.
//! The allowance belongs to runTurn's stack: tools, compaction and empty
//! completions cannot refill it, and the next user turn starts fresh.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const Kind = @import("provider.zig").Provider.Kind;
const messages = @import("messages.zig");
const args = @import("tool_call_args.zig");

pub const max_continuations: u8 = 4;
pub const note = "Your previous response reached its output limit and is partial. Continue from where it stopped; do not repeat completed work. Write long artifacts incrementally to files in small, complete tool calls instead of a long reply. Re-issue any truncated tool call with complete arguments.";
pub const exhausted_message = "output-length continuation limit reached; work is partial and has been preserved. Send a new message or resume to continue";

fn str(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

pub fn limited(kind: Kind, root: std.json.ObjectMap) bool {
    return switch (kind) {
        .anthropic => std.mem.eql(u8, str(root, "stop_reason"), "max_tokens"),
        .openai => @import("agent_chat_step.zig").limited(root),
        .responses => blk: {
            // Do not retry content filters or an interrupted stream merely
            // because they too are marked incomplete.
            const details = root.get("incomplete_details") orelse break :blk false;
            break :blk details == .object and std.mem.eql(u8, str(details.object, "reason"), "max_output_tokens");
        },
        .interactions => false,
    };
}

/// Raw JSON replies do not pass through the stream assembler's cut markers.
/// An empty argument string is only a valid empty call on a completed reply.
/// A Responses item explicitly marked incomplete is never executable.
pub fn callCut(gpa: std.mem.Allocator, response_limited: bool, object: std.json.ObjectMap, raw: []const u8) bool {
    return std.mem.eql(u8, str(object, "status"), "incomplete") or
        (response_limited and !args.isObjectString(gpa, raw));
}

/// Preserve terminal metadata when Responses SSE is reduced to output items.
/// Called for each terminal event, then copied onto the assembled response.
pub const ResponsesTerminal = struct {
    details: ?std.json.Value = null,

    pub fn record(state: *ResponsesTerminal, allocator: std.mem.Allocator, response: std.json.ObjectMap) !void {
        state.details = if (response.get("incomplete_details")) |d| try @import("util.zig").dupeJsonValue(allocator, d) else null;
    }

    pub fn apply(state: ResponsesTerminal, allocator: std.mem.Allocator, response: *std.json.ObjectMap) !void {
        if (state.details) |d| try response.put(allocator, "incomplete_details", d);
    }
};

fn reasoningOnly(kind: Kind, root: std.json.ObjectMap) bool {
    const empty = @import("agent_empty_completion.zig");
    if (kind == .responses) {
        const output = root.get("output") orelse return false;
        return output == .array and empty.reasonedWithoutAnswer(output.array.items);
    }
    if (kind == .anthropic) return empty.reasonedWithoutAnswer(&.{.{ .object = root }});
    if (kind == .openai) {
        const choices = root.get("choices") orelse return false;
        if (choices != .array or choices.array.items.len == 0 or choices.array.items[0] != .object) return false;
        const message = choices.array.items[0].object.get("message") orelse return false;
        return empty.reasonedWithoutAnswer(&.{message});
    }
    return false;
}

pub const State = struct {
    continuations: u8 = 0,

    pub fn step(state: *State, self: *Agent, root: std.json.ObjectMap) !?[]const u8 {
        const done = try @import("agent_steps.zig").stepForWire(self, root);
        return state.afterStep(self, root, done);
    }

    pub fn afterStep(state: *State, self: *Agent, root: std.json.ObjectMap, done: ?[]const u8) !?[]const u8 {
        if (!limited(self.provider.kind, root) or self.completed != null) return done;
        if (done) |text| {
            if (@import("tool_call_repair.zig").isLoopStop(text) or std.mem.eql(u8, text, @import("agent_eval_control.zig").verifier_hard_stop)) return done;
        }
        if (Agent.esc_cancel.load(.acquire) or @import("acp_engine.zig").cancel_flag.load(.acquire)) return error.Interrupted;
        if (self.run_budget) |budget| {
            if (budget.tool_exhausted.load(.acquire)) return error.ToolBudgetExhausted;
            // A child must retain the root's landing reservation too.
            if (!budget.canAfford(if (self.depth > 0) 2 else 1)) return error.RunBudgetExhausted;
        }
        if (state.continuations >= max_continuations) {
            try self.sayApiError("{s}", .{exhausted_message});
            return error.OutputLengthExceeded;
        }
        var body: []const u8 = note;
        // Keep the length allowance separate from empty-completion retries.
        // Chat's non-replayable empty reply is excluded by stepOpenAI; still
        // use its reasoning to break the reasoning-budget loop.
        if (done) |text| if (std.mem.trim(u8, text, " \t\r\n").len == 0 and reasoningOnly(self.provider.kind, root)) {
            body = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ note, @import("agent_empty_completion.zig").reasoning_budget_note });
        };
        try self.messages.append(try messages.userNote(self.arena, self.provider.kind, body));
        state.continuations += 1;
        try self.say("[output limit — continuing ({d}/{d})]\n", .{ state.continuations, max_continuations });
        if (self.tracer) |tr| tr.note("length_continuation", "partial output retained; incremental file-writing continuation granted");
        return null;
    }
};

test {
    _ = @import("agent_length_tests.zig");
}
