//! Experimental capability-backed host for Graff's shared chat step.
//! No sockets, files, processes or threads: the embedding host supplies model
//! and tool I/O, while Zig owns history, call validation and loop progression.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const chat = @import("agent_chat_step.zig");
const args = @import("tool_call_args.zig");
const ToolCall = @import("tools.zig").ToolCall;

pub const HostCall = *const fn (kind: u32, request: []const u8) anyerror![]const u8;
pub const Result = struct { text: []const u8, modelCalls: u32, toolCalls: u32 };
const ToolResult = struct { text: []const u8, is_error: bool };

pub const Agent = struct {
    gpa: Allocator,
    arena: Allocator,
    messages: std.json.Array,
    model: []const u8,
    tools: Value,
    max_steps: u32,
    host_call: HostCall,
    cancelled: *bool,
    model_calls: u32 = 0,
    tool_calls: u32 = 0,

    pub fn init(a: Allocator, config: Value, host_call: HostCall, cancelled: *bool) !Agent {
        if (config != .object) return error.InvalidConfig;
        const model = string(config, "model") orelse return error.InvalidModel;
        if (model.len == 0 or model.len > 256) return error.InvalidModel;
        const tools = config.object.get("tools") orelse Value{ .array = std.json.Array.init(a) };
        if (tools != .array or tools.array.items.len > 64) return error.InvalidTools;
        for (tools.array.items, 0..) |tool, i| {
            const function = field(tool, "function") orelse return error.InvalidTools;
            const name = string(function, "name") orelse return error.InvalidTools;
            const typ = string(tool, "type") orelse return error.InvalidTools;
            if (!std.mem.eql(u8, typ, "function") or name.len == 0 or name.len > 128) return error.InvalidTools;
            const parameters = field(function, "parameters") orelse return error.InvalidTools;
            if (parameters != .object) return error.InvalidTools;
            for (tools.array.items[0..i]) |prior| {
                if (std.mem.eql(u8, string(field(prior, "function").?, "name").?, name)) return error.DuplicateTool;
            }
        }
        var max_steps: u32 = 16;
        if (config.object.get("maxSteps")) |v| {
            if (v != .integer or v.integer < 1 or v.integer > 64) return error.InvalidStepLimit;
            max_steps = @intCast(v.integer);
        }
        var messages = std.json.Array.init(a);
        if (config.object.get("instructions")) |v| {
            if (v != .string) return error.InvalidInstructions;
            if (v.string.len > 0) try messages.append(try @import("messages.zig").textMessage(a, "system", v.string));
        }
        return .{ .gpa = a, .arena = a, .messages = messages, .model = model, .tools = tools, .max_steps = max_steps, .host_call = host_call, .cancelled = cancelled };
    }

    pub fn prompt(self: *Agent, text: []const u8) !Result {
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidPrompt;
        const models_before = self.model_calls;
        const tools_before = self.tool_calls;
        try self.messages.append(try @import("messages.zig").textMessage(self.arena, "user", text));
        for (0..self.max_steps) |_| {
            try self.checkCancelled();
            const request = try std.json.Stringify.valueAlloc(self.arena, .{
                .model = self.model,
                .messages = self.messages.items,
                .tools = self.tools,
                .stream = false,
            }, .{});
            self.model_calls += 1;
            const raw = try self.host_call(1, request);
            try self.checkCancelled();
            const root = try std.json.parseFromSliceLeaky(Value, self.arena, raw, .{ .allocate = .alloc_always });
            if (root != .object or root.object.contains("error")) return error.ModelError;
            // A bounded first slice: never call a partial completion successful.
            // Native length continuations remain in Agent.runTurn; until those
            // are host-independent, report this boundary rather than fake parity.
            if (chat.limited(root.object)) return error.OutputLengthExceeded;
            const choices = root.object.get("choices") orelse return error.InvalidModelResponse;
            if (choices != .array or choices.array.items.len == 0) return error.InvalidModelResponse;
            const choice = choices.array.items[0];
            const finish = string(choice, "finish_reason") orelse return error.IncompleteResponse;
            const message = field(choice, "message") orelse return error.InvalidModelResponse;
            const role = string(message, "role") orelse return error.InvalidModelResponse;
            if (!std.mem.eql(u8, role, "assistant")) return error.InvalidModelResponse;
            if (!std.mem.eql(u8, finish, "stop") and !std.mem.eql(u8, finish, "tool_calls")) return error.IncompleteResponse;
            if (std.mem.eql(u8, finish, "tool_calls")) {
                const calls = field(message, "tool_calls") orelse return error.InvalidModelResponse;
                if (calls != .array or calls.array.items.len == 0) return error.InvalidModelResponse;
            }
            const done = try chat.step(Host, self, root.object);
            if (done) |final_text| {
                if (std.mem.trim(u8, final_text, " \t\r\n").len == 0) return error.EmptyCompletion;
                return .{ .text = final_text, .modelCalls = self.model_calls - models_before, .toolCalls = self.tool_calls - tools_before };
            }
        }
        return error.StepLimitExceeded;
    }

    pub fn scratchAlloc(self: *Agent) Allocator {
        return self.arena;
    }

    pub fn pairContextMeterWithCurrentLocal(_: *Agent) void {}

    pub fn checkCancelled(self: *Agent) !void {
        if (self.cancelled.*) return error.Interrupted;
    }

    fn declared(self: *Agent, name: []const u8) bool {
        for (self.tools.array.items) |tool| {
            const function = field(tool, "function").?;
            if (std.mem.eql(u8, string(function, "name").?, name)) return true;
        }
        return false;
    }

    pub fn runTools(self: *Agent, calls: []const ToolCall) ![]ToolResult {
        if (calls.len > 32 or self.tool_calls + calls.len > 128) return error.ToolLimitExceeded;
        // Validate the entire batch before any effect, including call identity.
        for (calls, 0..) |call, i| {
            if (call.id.len == 0 or call.id.len > 256) return error.InvalidCallId;
            for (calls[0..i]) |prior| if (std.mem.eql(u8, call.id, prior.id)) return error.DuplicateCallId;
        }
        const results = try self.arena.alloc(ToolResult, calls.len);
        for (calls, results) |call, *result| {
            try self.checkCancelled();
            if (!call.args_ok) {
                result.* = .{ .text = if (call.cut) args.cut_exec_message else args.invalid_exec_message, .is_error = true };
                continue;
            }
            if (!self.declared(call.name)) {
                result.* = .{ .text = "tool is not registered by this host", .is_error = true };
                continue;
            }
            const request = try std.json.Stringify.valueAlloc(self.arena, .{ .id = call.id, .name = call.name, .input = call.input }, .{});
            self.tool_calls += 1;
            const raw = try self.host_call(2, request);
            try self.checkCancelled();
            const value = try std.json.parseFromSliceLeaky(Value, self.arena, raw, .{ .allocate = .alloc_always });
            const text = string(value, "text") orelse return error.InvalidToolResult;
            const is_error = field(value, "is_error") orelse return error.InvalidToolResult;
            if (is_error != .bool) return error.InvalidToolResult;
            result.* = .{ .text = text, .is_error = is_error.bool };
        }
        return results;
    }
};

fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}

fn string(value: Value, key: []const u8) ?[]const u8 {
    const v = field(value, key) orelse return null;
    return if (v == .string) v.string else null;
}

const Host = struct {
    pub fn apiError(_: *Agent, _: []const u8) !void {}
    pub fn repair(_: *Agent, _: *Value, _: bool) !void {}
    pub fn surfaceText(_: *Agent, _: []const u8) !void {}
    pub fn afterTools(_: *Agent, _: []const ToolCall, stuck: bool) !?[]const u8 {
        if (stuck) return error.BrokenCallLoop;
        return null;
    }
    pub fn stopped(_: *Agent, _: []const u8) !void {
        return error.IncompleteResponse;
    }
};
