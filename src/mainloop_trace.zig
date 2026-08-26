//! Per-turn trajectory + recipe outcome recording, extracted from mainloop so
//! the oversized event loop keeps moving toward the repository's 600-LOC cap.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

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

/// Append the open revision of a root turn before the provider runs. The DGM
/// archive stays append-only and keeps its existing `kind:"turn"` vocabulary;
/// record() appends the closed revision with the same id when the turn ends.
pub fn recordLive(root: *agent_mod.Agent, task: []const u8, turn_id: u64, parent_turn_id: u64) void {
    const trajectory = trace.g_traj orelse return;
    if (turn_id == 0) return;
    const prompt = root.systemPrompt();
    const prompt_fp = scoring.promptFingerprint(prompt);
    const task_class = recipe.classifyTask(task);
    const current_recipe = recipe.snapshot(root.provider.id, root.provider.model, @tagName(root.reasoning), prompt, root.toolsJson(), task_class);
    trajectory.capturePrompt(prompt_fp, prompt);
    trajectory.node(.{
        .id = turn_id,
        .parent = parent_turn_id,
        .kind = "turn",
        .label = root.provider.model,
        .t = trajectory.elapsedMs(),
        .live = true,
        .prompt_sha = &prompt_fp,
        .recipe_sha = &current_recipe.recipe_sha,
        .recipe_provider = root.provider.id,
        .recipe_model = root.provider.model,
        .recipe_effort = @tagName(root.reasoning),
        .recipe_toolset_sha = &current_recipe.toolset_sha,
        .task_class = task_class,
        .task = util.utf8Prefix(task, 160),
    });
}

/// Shape of the turn's final assistant response: counts and block types
/// only, never a byte of the content itself (#270). An unrelated text-only
/// refusal and a turn where the model emitted nothing looked identical in
/// the trace afterwards — both recorded a successful API call, no tool
/// calls, and nothing else. Recording the shape separates "one text block of
/// 240 chars, no tools" from "no blocks at all" while staying privacy-safe.
pub const ResponseShape = struct {
    blocks: u32 = 0,
    text_len: u64 = 0,
    has_text: bool = false,
    has_tool_use: bool = false,
    has_thinking: bool = false,
    has_reasoning: bool = false,

    /// The set of block types present, joined in a fixed order so archived
    /// rows group: "", "text", "text+tool_use+thinking", … Longest possible
    /// value is 32 bytes.
    pub fn typeSet(self: ResponseShape, buf: *[40]u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        inline for (.{
            .{ self.has_text, "text" },
            .{ self.has_tool_use, "tool_use" },
            .{ self.has_thinking, "thinking" },
            .{ self.has_reasoning, "reasoning" },
        }) |entry| if (entry[0]) {
            if (w.buffered().len > 0) w.writeByte('+') catch {};
            w.writeAll(entry[1]) catch {};
        };
        return w.buffered();
    }
};

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// A bare Responses output item (no "role") that the model authored.
fn isModelItem(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "message") or
        std.mem.eql(u8, kind, "function_call") or
        std.mem.eql(u8, kind, "reasoning");
}

/// Shape of the final response = the trailing run of model-authored history
/// entries, i.e. everything appended after the last user turn or tool
/// result. All three wire formats land here, because the history holds
/// whatever that provider's step function appended: anthropic content
/// blocks, an openai message with content + tool_calls beside it, or bare
/// Responses output items (#270).
pub fn finalResponseShape(messages: []const Value) ResponseShape {
    var shape: ResponseShape = .{};
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i] != .object) break;
        const obj = messages[i].object;
        const role = jsonStr(obj, "role");
        const kind = jsonStr(obj, "type");
        if (role.len > 0) {
            if (!std.mem.eql(u8, role, "assistant")) break; // user turn / tool result
        } else if (!isModelItem(kind)) {
            // #602: a Responses history can END on tool results — a turn cut
            // after execution, attempt_completion's final call, a crash. Those
            // trailing `function_call_output` items are not the response; skip
            // them so the shape still describes the last model-authored run
            // instead of archiving `resp_blocks=0` for every tool-using turn.
            if (std.mem.eql(u8, kind, "function_call_output")) continue;
            break;
        }
        countEntry(&shape, obj, kind);
    }
    return shape;
}

fn countEntry(shape: *ResponseShape, obj: std.json.ObjectMap, kind: []const u8) void {
    // A bare Responses item is one block on its own; only "message" carries a
    // content array, which the shared block walk below handles.
    if (std.mem.eql(u8, kind, "function_call")) {
        shape.blocks += 1;
        shape.has_tool_use = true;
        return;
    }
    if (std.mem.eql(u8, kind, "reasoning")) {
        shape.blocks += 1;
        shape.has_reasoning = true;
        return;
    }
    if (obj.get("content")) |content| switch (content) {
        .array => for (content.array.items) |block| {
            if (block != .object) continue;
            shape.blocks += 1;
            const bt = jsonStr(block.object, "type");
            if (std.mem.eql(u8, bt, "text") or std.mem.eql(u8, bt, "output_text")) {
                shape.has_text = true;
                shape.text_len += jsonStr(block.object, "text").len;
            } else if (std.mem.eql(u8, bt, "tool_use")) {
                shape.has_tool_use = true;
            } else if (std.mem.eql(u8, bt, "thinking") or std.mem.eql(u8, bt, "redacted_thinking")) {
                shape.has_thinking = true;
            }
        },
        .string => if (content.string.len > 0) {
            shape.blocks += 1;
            shape.has_text = true;
            shape.text_len += content.string.len;
        },
        else => {}, // openai sends content:null next to tool_calls
    };
    // openai keeps calls and reasoning beside the content, not inside it.
    if (obj.get("tool_calls")) |tcs| if (tcs == .array and tcs.array.items.len > 0) {
        shape.blocks += @intCast(tcs.array.items.len);
        shape.has_tool_use = true;
    };
    for ([_][]const u8{ "reasoning_content", "reasoning" }) |key| {
        if (jsonStr(obj, key).len > 0) {
            shape.blocks += 1;
            shape.has_reasoning = true;
        }
    }
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
    // #270: the history still ends with this turn's response here — compaction
    // and the review-context restore both run after record() returns.
    const shape = finalResponseShape(root.messages.items);
    var shape_buf: [40]u8 = undefined;
    const shape_types = shape.typeSet(&shape_buf);

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
        // Shape only, no content (#270): tells a text-only response apart from
        // a turn that produced nothing.
        .resp_blocks = shape.blocks,
        .resp_types = shape_types,
        .resp_text_len = shape.text_len,
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
            .resp_blocks = shape.blocks,
            .resp_types = shape_types,
            .resp_text_len = shape.text_len,
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

/// Parse a history array and shape it. ResponseShape holds no pointers into
/// the tree, so the parse can be freed before the assertions.
fn testShape(json: []const u8) !ResponseShape {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    return finalResponseShape(parsed.value.array.items);
}

test "live turn revision reaches the DGM archive before an outcome (#602)" {
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var trajectory: trace.Trajectory = .{
        .io = io,
        .gpa = std.testing.allocator,
        .out = &aw.writer,
        .start = Io.Timestamp.now(io, .awake),
        .identity = .{ .run_id = "live-run", .pid = 9, .session_id = "session" },
    };
    defer trajectory.deinit();
    const previous = trace.g_traj;
    trace.g_traj = &trajectory;
    defer trace.g_traj = previous;

    var root: agent_mod.Agent = undefined;
    root.provider = .{ .id = "xai", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = "grok-test", .context = 100_000 };
    root.reasoning = .high;
    root.review_mode = false;
    root.sub = false;
    root.strict = false;
    root.ultracode_mode = false;
    root.sys_normal = "system prompt";
    root.tools_anthropic = "[]";
    recordLive(&root, "inspect the workspace", 4, 3);

    var lines = std.mem.tokenizeScalar(u8, aw.writer.buffered(), '\n');
    _ = lines.next(); // prompt dictionary record
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, lines.next().?, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("turn", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 4), obj.get("id").?.integer);
    try std.testing.expect(obj.get("live").?.bool);
    try std.testing.expect(obj.get("ok") == null);
}

test "#270: the turn record separates a text-only response from an empty turn" {
    var buf: [40]u8 = undefined;

    // The reported event: one text block, no tool calls, benign task. The
    // trace previously carried nothing that distinguished this from a turn
    // where the model emitted no blocks at all.
    const refusal_text = "你好，我无法给到相关内容。";
    const refusal = try testShape(
        \\[{"role":"user","content":"serve the two mockups"},
        \\ {"role":"assistant","content":[{"type":"text","text":"你好，我无法给到相关内容。"}]}]
    );
    try std.testing.expectEqual(@as(u32, 1), refusal.blocks);
    try std.testing.expectEqual(@as(u64, refusal_text.len), refusal.text_len);
    try std.testing.expectEqualStrings("text", refusal.typeSet(&buf));

    const empty = try testShape(
        \\[{"role":"user","content":"serve the two mockups"},
        \\ {"role":"assistant","content":[]}]
    );
    try std.testing.expectEqual(@as(u32, 0), empty.blocks);
    try std.testing.expectEqual(@as(u64, 0), empty.text_len);
    try std.testing.expectEqualStrings("", empty.typeSet(&buf));
}

test "#270: a tool-calling turn records tool_use, and only the FINAL response" {
    var buf: [40]u8 = undefined;

    const calling = try testShape(
        \\[{"role":"user","content":"serve the two mockups"},
        \\ {"role":"assistant","content":[{"type":"thinking","thinking":"…"},
        \\  {"type":"text","text":"serving"},
        \\  {"type":"tool_use","id":"t1","name":"bash","input":{}}]}]
    );
    try std.testing.expectEqual(@as(u32, 3), calling.blocks);
    try std.testing.expectEqual(@as(u64, "serving".len), calling.text_len);
    try std.testing.expectEqualStrings("text+tool_use+thinking", calling.typeSet(&buf));

    // The earlier tool-calling message is a previous step, not the response:
    // the scan stops at the intervening tool result.
    const after_tools = try testShape(
        \\[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"bash","input":{}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},
        \\ {"role":"assistant","content":[{"type":"text","text":"http://localhost:8080"}]}]
    );
    try std.testing.expectEqual(@as(u32, 1), after_tools.blocks);
    try std.testing.expectEqualStrings("text", after_tools.typeSet(&buf));
}

test "#270: openai and Responses histories shape the same way" {
    var buf: [40]u8 = undefined;

    // openai keeps the calls beside a null content.
    const openai = try testShape(
        \\[{"role":"user","content":"go"},
        \\ {"role":"assistant","content":null,"reasoning_content":"…",
        \\  "tool_calls":[{"id":"c1","function":{"name":"bash","arguments":"{}"}}]}]
    );
    try std.testing.expectEqual(@as(u32, 2), openai.blocks);
    try std.testing.expectEqual(@as(u64, 0), openai.text_len);
    try std.testing.expectEqualStrings("tool_use+reasoning", openai.typeSet(&buf));

    // Responses appends bare output items, so the trailing run spans several.
    const responses = try testShape(
        \\[{"type":"function_call_output","call_id":"c1","output":"ok"},
        \\ {"type":"reasoning","summary":[]},
        \\ {"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]
    );
    try std.testing.expectEqual(@as(u32, 2), responses.blocks);
    try std.testing.expectEqual(@as(u64, "done".len), responses.text_len);
    try std.testing.expectEqualStrings("text+reasoning", responses.typeSet(&buf));

    // #602: the same history with the turn cut AFTER execution — the tail is
    // tool results, and there is no final message. The shape must describe the
    // model-authored run that preceded them, not archive zero blocks.
    const cut_after_tools = try testShape(
        \\ [{"type":"message","role":"assistant","content":[{"type":"output_text","text":"merging"}]},
        \\ {"type":"reasoning","summary":[]},
        \\ {"type":"function_call","call_id":"c1","name":"bash","arguments":"{}"},
        \\ {"type":"function_call_output","call_id":"c1","output":"ok"}]
    );
    try std.testing.expectEqual(@as(u32, 3), cut_after_tools.blocks);
    try std.testing.expectEqualStrings("text+tool_use+reasoning", cut_after_tools.typeSet(&buf));
}
