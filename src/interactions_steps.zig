//! Building and reading Google Interactions execution steps — the unit of
//! history on that wire, where the other three wires have messages or items.
//!
//! graff stores these verbatim in `Agent.messages`, so a step written here is
//! echoed back to the endpoint on the next turn exactly as it is built.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// `{"type":"user_input","content":"…"}`. The endpoint also accepts a content
/// ARRAY of parts (vision.zig builds that form); a plain string is the shape
/// for text-only input.
pub fn userInput(arena: Allocator, text: []const u8) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "type", .{ .string = "user_input" });
    try obj.put(arena, "content", .{ .string = try arena.dupe(u8, text) });
    return .{ .object = obj };
}

/// `{"type":"function_result","call_id":…,"name":…,"result":[{"type":"text",…}]}`.
/// All three fields are required: without `name` the endpoint answers a bare
/// "Invalid input received.", and `result` must be a LIST of parts, not a
/// string and not an object.
pub fn functionResult(arena: Allocator, call_id: []const u8, name: []const u8, text: []const u8) !Value {
    var part: std.json.ObjectMap = .empty;
    try part.put(arena, "type", .{ .string = "text" });
    try part.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
    var result = std.json.Array.init(arena);
    try result.append(.{ .object = part });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "type", .{ .string = "function_result" });
    try obj.put(arena, "call_id", .{ .string = try arena.dupe(u8, call_id) });
    try obj.put(arena, "name", .{ .string = try arena.dupe(u8, name) });
    try obj.put(arena, "result", .{ .array = result });
    return .{ .object = obj };
}

fn stepType(s: Value) []const u8 {
    if (s != .object) return "";
    const t = s.object.get("type") orelse return "";
    return if (t == .string) t.string else "";
}

/// The assistant's visible answer: the text parts of every model_output step.
/// A thought step carries only an opaque signature and contributes nothing.
pub fn assistantText(arena: Allocator, root: std.json.ObjectMap) ![]const u8 {
    const steps = root.get("steps") orelse return "";
    if (steps != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (steps.array.items) |s| {
        if (!std.mem.eql(u8, stepType(s), "model_output")) continue;
        const content = s.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            if (part.object.get("text")) |t| if (t == .string) try out.appendSlice(arena, t.string);
        }
    }
    return out.items;
}

/// Record one Interaction's usage. Interactions reports flat totals under its
/// own names; thinking is billed as output and is most of a Gemini turn's
/// output, so a tally that skipped it would understate every call.
/// `total_cached_tokens` is the cached PORTION of the input, matching how the
/// other wires report a cache read.
pub fn recordUsage(self: *@import("agent.zig").Agent, u: std.json.ObjectMap, fallback: u64) void {
    const ctx = @import("agent_context.zig");
    const in_tokens = ctx.usageInt(u, "total_input_tokens");
    const out_tokens = ctx.usageInt(u, "total_output_tokens") +| ctx.usageInt(u, "total_thought_tokens");
    const total = @max(ctx.usageInt(u, "total_tokens"), in_tokens +| out_tokens);
    if (total > 0) ctx.replaceContextTokens(self, @intCast(total)) else ctx.floorContextTokens(self, fallback);
    self.last_usage_includes_output = total > 0;
    const cached = ctx.usageInt(u, "total_cached_tokens");
    if (cached > 0) self.last_cache_read = @intCast(cached);
    self.recordCost(@max(in_tokens - cached, 0), cached, 0, out_tokens);
}

/// A function_result rebuilt out of band (vision/repl replay), where only the
/// call id is known. Interactions requires `name` and rejects the request
/// without it; the live turn path uses `functionResult` with the real name.
pub fn fallbackResult(arena: Allocator, call_id: []const u8, text: []const u8, is_error: bool) !Value {
    const body = if (is_error) try std.fmt.allocPrint(arena, "[error] {s}", .{text}) else text;
    return functionResult(arena, call_id, "tool", body);
}

/// One image as an Interactions content part: raw base64 plus its mime type.
/// `source` / `image_url` / `inline_data` are all rejected as unknown
/// parameters, and a remote URL has no proven inline form on this wire, so it
/// rides as text rather than being silently dropped.
pub fn imagePart(arena: Allocator, ib: *std.json.ObjectMap, img: anytype) !void {
    if (img.b64.len > 0) {
        try ib.put(arena, "type", .{ .string = "image" });
        try ib.put(arena, "data", .{ .string = img.b64 });
        try ib.put(arena, "mime_type", .{ .string = img.media_type });
    } else {
        try ib.put(arena, "type", .{ .string = "text" });
        try ib.put(arena, "text", .{ .string = try std.fmt.allocPrint(arena, "[image: {s}]", .{img.url}) });
    }
}

/// One turn on the Interactions wire: echo the model's steps into history,
/// dispatch any function_call steps, and answer with the visible text once the
/// model stops calling tools. Mirrors stepOpenAI / stepResponses.
pub fn step(self: *@import("agent.zig").Agent, root: std.json.ObjectMap) !?[]const u8 {
    const agent_steps = @import("agent_steps.zig");
    const steps = root.get("steps") orelse {
        try self.sayApiError("api error: interaction had no steps", .{});
        return error.ApiError;
    };
    if (steps != .array) {
        try self.sayApiError("api error: interaction steps were not a list", .{});
        return error.ApiError;
    }
    // Echo every step back verbatim next turn — the thought signature is opaque
    // and the endpoint validates it, so it must survive unedited.
    for (steps.array.items) |st| try self.messages.append(st);

    const final_text = try assistantText(self.arena, root);
    if (final_text.len > 0) try agent_steps.surfaceUnstreamedText(self, final_text);

    var calls: std.ArrayList(agent_steps.ToolCall) = .empty;
    defer calls.deinit(self.gpa);
    for (steps.array.items) |st| {
        if (!std.mem.eql(u8, stepType(st), "function_call")) continue;
        const name = if (st.object.get("name")) |n| (if (n == .string) n.string else "") else "";
        if (name.len == 0) continue; // can't dispatch a nameless call
        const id = if (st.object.get("id")) |x| (if (x == .string) x.string else "") else "";
        // Unlike every other wire, `arguments` is already a JSON object here —
        // there is no argument string to parse.
        const input: Value = if (st.object.get("arguments")) |a| (if (a == .object) a else .{ .object = .empty }) else .{ .object = .empty };
        try calls.append(self.gpa, .{ .id = id, .name = name, .input = input });
    }
    self.pairContextMeterWithCurrentLocal();

    if (calls.items.len > 0) {
        const results = try self.runTools(calls.items);
        for (calls.items, results) |call, r| {
            try self.messages.append(try functionResult(self.arena, call.id, call.name, r.text));
        }
        try @import("turn_checkpoint.zig").afterToolBatch(self);
        const eval_control = @import("agent_eval_control.zig");
        if (eval_control.shouldStopAfterBatch(calls.items, self.eval_repair_pending)) {
            if (try agent_steps.grantRepairTurn(self)) return null;
            return eval_control.verifier_hard_stop;
        }
        if (self.completed) |result| return result;
        return null;
    }
    return final_text;
}

test "userInput and functionResult build the shapes the endpoint requires" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const u = try userInput(arena, "hello");
    try std.testing.expectEqualStrings("user_input", u.object.get("type").?.string);
    try std.testing.expectEqualStrings("hello", u.object.get("content").?.string);

    const r = try functionResult(arena, "call_1", "bash", "out");
    try std.testing.expectEqualStrings("function_result", r.object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", r.object.get("call_id").?.string);
    // `name` is required: the endpoint rejects a result without it.
    try std.testing.expectEqualStrings("bash", r.object.get("name").?.string);
    // `result` is a LIST of parts, never a bare string or an object.
    const list = r.object.get("result").?;
    try std.testing.expect(list == .array);
    try std.testing.expectEqualStrings("text", list.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("out", list.array.items[0].object.get("text").?.string);
}

test "assistantText concatenates model_output text and ignores thoughts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSlice(Value, arena,
        \\{"steps":[{"type":"thought","signature":"OPAQUE"},
        \\ {"type":"model_output","content":[{"type":"text","text":"one "},{"type":"text","text":"two"}]}]}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("one two", try assistantText(arena, parsed.value.object));
}
