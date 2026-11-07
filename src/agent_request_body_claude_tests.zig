//! Claude request shapes (ADR 0219), split out of agent_request_body.zig
//! (600-line cap). The unversioned model id `claude` keeps the pre-5.5
//! shape; versioned 5.5-era ids get the new contract.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;

fn testUserMessage(arena: std.mem.Allocator, text: []const u8) !Value {
    var m: std.json.ObjectMap = .empty;
    try m.put(arena, "role", .{ .string = "user" });
    try m.put(arena, "content", .{ .string = text });
    return .{ .object = m };
}

fn claudeAgent(arena: std.mem.Allocator, model: []const u8) !Agent {
    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "hello"));
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = model, .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
}

const bash_tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";

fn has(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

test "a 5.5-era Claude model is never forced to a tool; it keeps and binds its thinking" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try claudeAgent(arena_state.allocator(), "claude-opus-5-5");
    // --strict / --eval / a named-work nudge ask for a forced tool call.
    const body = try agent.buildBody(bash_tools, true, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(!has(body, "\"tool_choice\""));
    try std.testing.expect(has(body, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\",\"block_binding\":{\"prefix_mismatch_behavior\":\"drop_block\"}}"));
    try std.testing.expect(has(body, "\"max_tokens\":64000"));
}

test "effort rides output_config on Claude, in one object with a structured-output format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try claudeAgent(arena_state.allocator(), "claude-sonnet-5-5");

    // ADR 0220: graff's default is sent as shown; Sonnet 5.5's own is high.
    const plain = try agent.buildBody(bash_tools, false, true, true);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(has(plain, "\"output_config\":{\"effort\":\"medium\"}"));
    // A title is one line: low effort, whatever the session's level.
    agent.call_kind = .title;
    const title = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(title);
    try std.testing.expect(has(title, "\"output_config\":{\"effort\":\"low\"}"));
    agent.call_kind = .root;
    // An older model keeps its own default at graff's default.
    agent.provider.model = "claude-opus-4-8";
    const older = try agent.buildBody(bash_tools, false, true, true);
    defer std.testing.allocator.free(older);
    try std.testing.expect(!has(older, "\"output_config\""));
    agent.provider.model = "claude-sonnet-5-5";

    agent.reasoning = .high;
    const high = try agent.buildBody(bash_tools, false, true, true);
    defer std.testing.allocator.free(high);
    try std.testing.expect(has(high, "\"output_config\":{\"effort\":\"high\"}"));

    // A formatting turn carries effort and the schema together: two
    // output_config keys would leave one of them unread.
    agent.output_schema = "{\"type\":\"object\"}";
    agent.reasoning = .max;
    const shaped = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(shaped);
    try std.testing.expect(has(shaped, "\"output_config\":{\"effort\":\"max\",\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\"}}}"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shaped, "\"output_config\""));
    try std.testing.expect(has(shaped, "\"max_tokens\":128000"));

    // A model that rejected the effort hint does not get it again.
    agent.effort_rejected = true;
    agent.output_schema = null;
    const rejected = try agent.buildBody(bash_tools, false, true, true);
    defer std.testing.allocator.free(rejected);
    try std.testing.expect(!has(rejected, "\"effort\""));
}

test "older Claude models keep forced tools, no binding, and graff's default budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try claudeAgent(arena_state.allocator(), "claude-opus-4-8");
    const body = try agent.buildBody(bash_tools, true, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(has(body, "\"tool_choice\":{\"type\":\"any\"}"));
    try std.testing.expect(!has(body, "block_binding"));
    try std.testing.expect(has(body, "\"max_tokens\":16000"));
    // Haiku takes no effort parameter at all.
    agent.provider.model = "claude-haiku-4-5";
    agent.reasoning = .high;
    const haiku = try agent.buildBody(bash_tools, false, true, true);
    defer std.testing.allocator.free(haiku);
    try std.testing.expect(!has(haiku, "\"effort\""));
}

test "retained reasoning: anthropic replays thinking+signature inside a multi-step tool turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "fix the build"));

    // Assistant turn: thinking block (with its signature) followed by tool_use.
    // Anthropic requires the thinking block to be replayed unchanged, in place,
    // when the turn that produced it contained a tool call — editing or dropping
    // it is a signature/ordering 400.
    var thinking_block: std.json.ObjectMap = .empty;
    try thinking_block.put(arena, "type", .{ .string = "thinking" });
    try thinking_block.put(arena, "thinking", .{ .string = "the linker flag is wrong" });
    try thinking_block.put(arena, "signature", .{ .string = "sigabc" });
    var use_block: std.json.ObjectMap = .empty;
    try use_block.put(arena, "type", .{ .string = "tool_use" });
    try use_block.put(arena, "id", .{ .string = "tu_1" });
    try use_block.put(arena, "name", .{ .string = "bash" });
    try use_block.put(arena, "input", .{ .object = .empty });
    var assistant_blocks = std.json.Array.init(arena);
    try assistant_blocks.append(.{ .object = thinking_block });
    try assistant_blocks.append(.{ .object = use_block });
    var assistant: std.json.ObjectMap = .empty;
    try assistant.put(arena, "role", .{ .string = "assistant" });
    try assistant.put(arena, "content", .{ .array = assistant_blocks });
    try messages.append(.{ .object = assistant });

    var result_block: std.json.ObjectMap = .empty;
    try result_block.put(arena, "type", .{ .string = "tool_result" });
    try result_block.put(arena, "tool_use_id", .{ .string = "tu_1" });
    try result_block.put(arena, "content", .{ .string = "ok" });
    var result_blocks = std.json.Array.init(arena);
    try result_blocks.append(.{ .object = result_block });
    var result_msg: std.json.ObjectMap = .empty;
    try result_msg.put(arena, "role", .{ .string = "user" });
    try result_msg.put(arena, "content", .{ .array = result_blocks });
    try messages.append(.{ .object = result_msg });

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const body = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body);

    // Adaptive thinking is what enables interleaved reasoning between tool
    // calls; it needs no beta header on current models. It also opts into a
    // summarized display, since current Claude models default to an empty one.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}") != null);
    // The whole block, signature included, survives the cache-breakpoint rewrite.
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"thinking\",\"thinking\":\"the linker flag is wrong\",\"signature\":\"sigabc\"}") != null);
    // A cache breakpoint belongs on the trailing tool_result, never on a
    // thinking block (cache_control is not a valid field there).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"signature\":\"sigabc\",\"cache_control\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"ok\",\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}

test "anthropic asks for summarized thinking; other anthropic-format providers do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "hello"));

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";

    // a. Real Anthropic, thinking allowed: adaptive thinking opts into a
    // summarized display, since current Claude models default to empty.
    const body_a = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body_a);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}") != null);

    // b. Forced tool_choice still suppresses the whole thinking object, exactly
    // as before this change.
    const body_b = try agent.buildBody(tools, true, true, true);
    defer std.testing.allocator.free(body_b);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "\"tool_choice\":{\"type\":\"any\"}") != null);

    // c. Other anthropic-format providers (minimax) reject unknown fields, so
    // they must never see "display" — only the bare adaptive object.
    agent.provider.id = "minimax";
    agent.provider.model = "MiniMax-M3";
    const body_c = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body_c);
    try std.testing.expect(std.mem.indexOf(u8, body_c, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_c, "\"display\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_c, "\"keep\"") == null); // #323: thinking.keep is Kimi-only
}

test "Claude's own error text takes the retry-without ladder (ADR 0219)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try claudeAgent(arena_state.allocator(), "claude-opus-5-5");
    const retryWithout = @import("agent_request_policy.zig").retryWithout;
    var force = true;
    var stream_usage = true;
    // The 400 Opus 5.5 returns for a forced tool: drop the force, retry.
    try std.testing.expect(retryWithout(&agent, "tool_choice: type \"tool\" and \"any\" are not supported for this model.", &force, &stream_usage));
    try std.testing.expect(!force);
    // An effort the model does not take is dropped, not misread as the
    // structured-output format that shares output_config.
    agent.output_schema = "{\"type\":\"object\"}";
    try std.testing.expect(retryWithout(&agent, "output_config.effort: xhigh is not supported for this model", &force, &stream_usage));
    try std.testing.expect(agent.effort_rejected);
    try std.testing.expect(!agent.sox_json_object);
    try std.testing.expect(retryWithout(&agent, "output_config.format: unsupported schema", &force, &stream_usage));
    try std.testing.expect(agent.sox_json_object);
    // Anything else is a real failure.
    try std.testing.expect(!retryWithout(&agent, "messages: at least one message is required", &force, &stream_usage));
}

test "ADR 0282: the Claude system breakpoint closes before the per-repo blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const layouts = [_][]const u8{
        "\n\n# Project layout (working tree at session start, depth 3; may omit later changes)\nlogs/\nlogs/auth.log\n",
        "\n\n# Project layout (working tree at session start, depth 3; may omit later changes)\napi/\napi/routes.py\n",
    };
    var heads: [2][]const u8 = undefined;
    for (layouts, 0..) |layout, i| {
        var agent = try claudeAgent(a, "claude-sonnet-5-5");
        const sys = try std.mem.concat(a, u8, &.{ "BASE", layout, "\n\n# Skills\nstatic tail" });
        agent.sys_base = sys;
        agent.sys_normal = sys;
        agent.repo_map_snapshot = layout;
        const body = try agent.buildBody(bash_tools, false, true, true);
        defer std.testing.allocator.free(body);
        const parsed = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, body), .{});
        const blocks = parsed.object.get("system").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), blocks.len);
        // The breakpoint sits on the static block; the tail carries none.
        try std.testing.expect(blocks[0].object.get("cache_control") != null);
        try std.testing.expect(blocks[1].object.get("cache_control") == null);
        const head = blocks[0].object.get("text").?.string;
        const tail = blocks[1].object.get("text").?.string;
        // Same bytes as one block: only the cache boundary moved.
        try std.testing.expectEqualStrings(sys, try std.mem.concat(a, u8, &.{ head, tail }));
        heads[i] = head;
    }
    // Two repos share the cached block byte for byte.
    try std.testing.expectEqualStrings("BASE", heads[0]);
    try std.testing.expectEqualStrings(heads[0], heads[1]);
}

test "ADR 0282: a Claude system prompt without per-repo blocks stays one block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try claudeAgent(a, "claude-sonnet-5-5");
    const body = try agent.buildBody(bash_tools, false, true, true);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSliceLeaky(Value, a, try a.dupe(u8, body), .{});
    const blocks = parsed.object.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0].object.get("cache_control") != null);
}
