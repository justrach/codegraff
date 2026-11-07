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
///
/// A request that continued a stored Interaction reports only its new steps as
/// `total_input_tokens`. The whole prompt the model read is in
/// `model_invocation_token_counts` (and `raw_prompt_token`), with the part read
/// from cache beside it; Google documents the continued history as input, so
/// both the context meter and the cost read the whole prompt (see promptUsage).
pub fn recordUsage(self: *@import("agent.zig").Agent, u: std.json.ObjectMap, fallback: u64) void {
    const ctx = @import("agent_context.zig");
    const p = promptUsage(u);
    const out_tokens = ctx.usageInt(u, "total_output_tokens") +| ctx.usageInt(u, "total_thought_tokens");
    const total = @max(ctx.usageInt(u, "total_tokens"), p.prompt +| out_tokens);
    if (total > 0) ctx.replaceContextTokens(self, @intCast(total)) else ctx.floorContextTokens(self, fallback);
    self.last_usage_includes_output = total > 0;
    if (p.cached > 0) self.last_cache_read = @intCast(p.cached);
    self.recordCost(@max(p.prompt - p.cached, 0), p.cached, 0, out_tokens);
}

pub const PromptUsage = struct { prompt: i64, cached: i64 };

/// The prompt the model read and how much of it came from cache. Per-invocation
/// counts are the full prompt even on a continued Interaction, where the flat
/// `total_input_tokens` / `total_cached_tokens` cover only the new steps.
pub fn promptUsage(u: std.json.ObjectMap) PromptUsage {
    const ctx = @import("agent_context.zig");
    var inv_prompt: i64 = 0;
    var inv_cached: i64 = 0;
    if (u.get("model_invocation_token_counts")) |mi| if (mi == .array) for (mi.array.items) |inv| {
        if (inv != .object) continue;
        inv_prompt +|= modalitySum(inv.object.get("prompt_tokens_details"));
        inv_cached +|= modalitySum(inv.object.get("cache_tokens_details"));
    };
    const prompt = @max(@max(ctx.usageInt(u, "total_input_tokens"), ctx.usageInt(u, "raw_prompt_token")), inv_prompt);
    const cached = @min(@max(ctx.usageInt(u, "total_cached_tokens"), inv_cached), prompt);
    return .{ .prompt = prompt, .cached = cached };
}

fn modalitySum(v: ?Value) i64 {
    const list = v orelse return 0;
    if (list != .array) return 0;
    var n: i64 = 0;
    for (list.array.items) |d| {
        if (d != .object) continue;
        if (d.object.get("tokens")) |t| if (t == .integer and t.integer > 0) {
            n +|= t.integer;
        };
    }
    return n;
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

/// `{"type":"model_output","content":[{"type":"text","text":"…"}]}` — an
/// assistant text turn graff writes itself (an interrupt marker, a review
/// reply), in the shape the endpoint echoes back.
pub fn modelOutput(arena: Allocator, text: []const u8) !Value {
    var part: std.json.ObjectMap = .empty;
    try part.put(arena, "type", .{ .string = "text" });
    try part.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
    var content = std.json.Array.init(arena);
    try content.append(.{ .object = part });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "type", .{ .string = "model_output" });
    try obj.put(arena, "content", .{ .array = content });
    return .{ .object = obj };
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
    // The stored Interaction now holds these steps too (interactions_chain.zig).
    try @import("interactions_chain.zig").record(self, root, steps.array.items);
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
        if (self.yielded) |message| return message;
        if (self.completed) |result| return result;
        return null;
    }
    return final_text;
}

/// Role-shaped messages in Interactions history, rewritten as steps. The
/// prompt, image prompts, adopted conversations and compaction summaries are
/// built as `{"role":…,"content":…}` for every wire. The endpoint reads a
/// role-shaped list as the turn list it no longer accepts ("use step_list
/// input format instead of turn_list") and refuses a mix ("The 'type'
/// parameter is required"), so every request failed on its first message.
/// A user message becomes a user_input step and assistant text a model_output
/// step; content parts keep only the text and image shapes this wire takes.
pub fn normalizeHistory(a: Allocator, history: *std.json.Array) void {
    var kept: usize = 0;
    for (history.items) |item| {
        const normalized = normalize: {
            if (item != .object or item.object.get("type") != null) break :normalize item;
            const role = item.object.get("role") orelse break :normalize item;
            const content = item.object.get("content") orelse break :normalize item;
            if (role != .string) break :normalize item;
            const user = std.mem.eql(u8, role.string, "user");
            if (!user and !std.mem.eql(u8, role.string, "assistant")) break :normalize item;
            if (content == .string and std.mem.trim(u8, content.string, " \t\r\n").len == 0) continue;
            break :normalize roleStep(a, user, content, item.object.get(@import("session_wake.zig").origin_key)) catch item;
        };
        history.items[kept] = normalized;
        kept += 1;
    }
    history.shrinkRetainingCapacity(kept);
}

fn roleStep(a: Allocator, user: bool, content: Value, origin: ?Value) !Value {
    var parts = std.json.Array.init(a);
    switch (content) {
        .string => |s| try parts.append(try textPart(a, s)),
        .array => |blocks| for (blocks.items) |block| {
            if (block != .object) continue;
            const kind = stepType(block);
            if (std.mem.eql(u8, kind, "image") and block.object.get("data") != null) {
                try parts.append(block);
            } else if (block.object.get("text")) |t| {
                if (t == .string and t.string.len > 0) try parts.append(try textPart(a, t.string));
            }
        },
        else => {},
    }
    if (parts.items.len == 0) try parts.append(try textPart(a, "(no content)"));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = if (user) "user_input" else "model_output" });
    // A lone text part stays a plain string, the shape userInput writes.
    const lone_text = user and parts.items.len == 1 and std.mem.eql(u8, stepType(parts.items[0]), "text");
    try obj.put(a, "content", if (lone_text) parts.items[0].object.get("text").? else .{ .array = parts });
    if (origin) |o| try obj.put(a, @import("session_wake.zig").origin_key, o);
    return .{ .object = obj };
}

fn textPart(a: Allocator, text: []const u8) !Value {
    var part: std.json.ObjectMap = .empty;
    try part.put(a, "type", .{ .string = "text" });
    try part.put(a, "text", .{ .string = text });
    return .{ .object = part };
}

test "normalizeHistory turns role messages into steps and leaves steps alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSlice(Value, arena,
        \\[{"role":"user","content":"fix fib"},
        \\ {"type":"thought","signature":"OPAQUE"},
        \\ {"role":"assistant","content":"summary so far"},
        \\ {"role":"user","content":[{"type":"input_text","text":"look"},{"type":"image","data":"AAAA","mime_type":"image/png"},{"type":"tool_result"}]},
        \\ {"role":"user","content":[]}]
    , .{});
    var history = parsed.value.array;
    normalizeHistory(arena, &history);
    const h = history.items;
    try std.testing.expectEqualStrings("user_input", h[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("fix fib", h[0].object.get("content").?.string);
    try std.testing.expect(h[0].object.get("role") == null);
    try std.testing.expectEqualStrings("OPAQUE", h[1].object.get("signature").?.string);
    try std.testing.expectEqualStrings("model_output", h[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("summary so far", h[2].object.get("content").?.array.items[0].object.get("text").?.string);
    const mixed = h[3].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), mixed.len);
    try std.testing.expectEqualStrings("look", mixed[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("image", mixed[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("(no content)", h[4].object.get("content").?.string);
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

test "a continued Interaction is metered on the whole prompt it read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Shape returned for a follow-up on a stored Interaction: the flat totals
    // cover only the new step, the invocation counts the whole prompt.
    const chained = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"total_input_tokens":134,"total_cached_tokens":114,"raw_prompt_token":38383,
        \\ "model_invocation_token_counts":[{"prompt_tokens_details":[{"modality":"text","tokens":38383}],
        \\  "cache_tokens_details":[{"modality":"text","tokens":32768}]}]}
    , .{});
    const p = promptUsage(chained.object);
    try std.testing.expectEqual(@as(i64, 38383), p.prompt);
    try std.testing.expectEqual(@as(i64, 32768), p.cached);
    // A stateless request without invocation detail falls back to the totals.
    const flat = try std.json.parseFromSliceLeaky(Value, arena, "{\"total_input_tokens\":500,\"total_cached_tokens\":200}", .{});
    const q = promptUsage(flat.object);
    try std.testing.expectEqual(@as(i64, 500), q.prompt);
    try std.testing.expectEqual(@as(i64, 200), q.cached);
}

test "chat-shaped text turns become steps before they reach the wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const messages = @import("messages.zig");
    var history = std.json.Array.init(a);
    try history.append(try messages.textMessage(a, "user", "Is 391 prime?"));
    try history.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"thought\",\"signature\":\"S\"}", .{}));
    try history.append(try messages.textMessage(a, "assistant", "No: 17 x 23."));
    try history.append(try messages.textMessage(a, "assistant", "  "));
    try history.append(try @import("session_wake.zig").message(a, "[a note]"));
    normalizeHistory(a, &history);
    try std.testing.expectEqual(@as(usize, 4), history.items.len); // the blank turn is dropped
    try std.testing.expectEqualStrings("user_input", history.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("Is 391 prime?", history.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("thought", history.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("model_output", history.items[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("No: 17 x 23.", history.items[2].object.get("content").?.array.items[0].object.get("text").?.string);
    // A wake note keeps its origin tag (it is stripped on the wire, not here).
    try std.testing.expect(history.items[3].object.get(@import("session_wake.zig").origin_key) != null);
    // Idempotent: a second pass leaves the converted history alone.
    const before = history.items.ptr;
    normalizeHistory(a, &history);
    try std.testing.expectEqual(before, history.items.ptr);
}
