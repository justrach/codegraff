//! White-box tests for agent_steps.zig's stream assembler, parked here under
//! the 600-line ceiling (same pattern as router_catalog_tests.zig).

const std = @import("std");
const Agent = @import("agent.zig").Agent;

fn streamedCalls(arena: std.mem.Allocator, body: []const u8) !std.json.Array {
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const root = (try agent.assembleOpenAI(body)).?;
    return root.get("choices").?.array.items[0].object.get("message").?.object.get("tool_calls").?.array;
}

test "same-index fresh IDs retain complete replacement after incomplete read_file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = try streamedCalls(
        arena,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"old\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\": \"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"new\",\"function\":{\"name\":\"rlm\",\"arguments\":\"{\\\"code\\\":\\\"print(1)\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n",
    );
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    const first = calls.items[0].object;
    const second = calls.items[1].object;
    try std.testing.expectEqualStrings("old", first.get("id").?.string);
    try std.testing.expectEqualStrings("new", second.get("id").?.string);
    const args = @import("tool_call_args.zig");
    try std.testing.expect(!args.parse(arena, first.get("function").?.object.get("arguments").?.string).valid);
    const clean = args.parse(arena, second.get("function").?.object.get("arguments").?.string);
    try std.testing.expect(clean.valid);
    try std.testing.expectEqualStrings("print(1)", clean.input.object.get("code").?.string);
}

test "same-index complete calls preserve both; repeated ID fragments and indexes interleave" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = try streamedCalls(
        arena,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"b\\\"}\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"arguments\":\"\\\"}\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"c\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n",
    );
    try std.testing.expectEqual(@as(usize, 3), calls.items.len);
    const expected = [_][]const u8{ "a", "b", "c" };
    for (calls.items, expected) |call, id| {
        try std.testing.expectEqualStrings(id, call.object.get("id").?.string);
        const parsed = @import("tool_call_args.zig").parse(arena, call.object.get("function").?.object.get("arguments").?.string);
        try std.testing.expect(parsed.valid);
        try std.testing.expectEqualStrings(id, parsed.input.object.get("path").?.string);
    }
}

test "empty first call is guarded when a fresh ID restarts the index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = try streamedCalls(
        arena,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"old\",\"function\":{\"name\":\"read_file\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"new\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"next.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n",
    );
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    const parse = @import("tool_call_args.zig").parse;
    try std.testing.expect(!parse(arena, calls.items[0].object.get("function").?.object.get("arguments").?.string).valid);
    const next = parse(arena, calls.items[1].object.get("function").?.object.get("arguments").?.string);
    try std.testing.expect(next.valid);
    try std.testing.expectEqualStrings("next.txt", next.input.object.get("path").?.string);
}

test "#1218: a length stop cuts the unfinished last call; [DONE] without a finish does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = @import("tool_call_args.zig");
    const read_a = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}]}}]}\n";
    const name_only = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"read_file\"}}]}}]}\n";
    // Output limit hit right after the second call's header: it never got arguments.
    const limited = try streamedCalls(arena, read_a ++ name_only ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n");
    try std.testing.expectEqual(args.Refusal.none, args.takeInvalidMark(&limited.items[0].object));
    try std.testing.expectEqual(args.Refusal.cut, args.takeInvalidMark(&limited.items[1].object));
    // The stream ended with no finish_reason and no [DONE]: dropped mid-call.
    const dropped = try streamedCalls(arena, read_a ++ name_only);
    try std.testing.expectEqual(args.Refusal.cut, args.takeInvalidMark(&dropped.items[1].object));
    // A provider that omits finish_reason but ends with [DONE] finished the call.
    const done = try streamedCalls(arena, read_a ++ name_only ++ "data: [DONE]\n");
    try std.testing.expectEqual(args.Refusal.none, args.takeInvalidMark(&done.items[1].object));
}

test "same ID with contradictory function names remains non-executable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = try streamedCalls(
        arena,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"shell\"}}]},\"finish_reason\":\"tool_calls\"}]}\n",
    );
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expect(!@import("tool_call_args.zig").parse(arena, calls.items[0].object.get("function").?.object.get("arguments").?.string).valid);
}

test "assembleOpenAI preserves streamed reasoning and Gemini echo fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };

    const root = (try agent.assembleOpenAI(
        "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"thought_signature\":\"SIG\"}}]}\n" ++
            "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"reasoning_content\":\"think \"}}]}\n" ++
            "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"reasoning_content\":\"deep\"}}]}\n" ++
            "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"reasoning\":\"alt \"}}]}\n" ++
            "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"reasoning\":\"path\"}}]}\n" ++
            "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{}\"},\"thought_signature\":\"SIG\"}]}}]}\n" ++
            "data: {\"id\":\"v1_thread\",\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"tool_calls\"}]}\n" ++
            "data: [DONE]\n",
    )).?;
    const choices = root.get("choices").?;
    const message = choices.array.items[0].object.get("message").?.object;
    try std.testing.expectEqualStrings("assistant", message.get("role").?.string);
    try std.testing.expectEqualStrings("done", message.get("content").?.string);
    try std.testing.expectEqualStrings("think deep", message.get("reasoning_content").?.string);
    try std.testing.expectEqualStrings("alt path", message.get("reasoning").?.string);
    try std.testing.expectEqualStrings("v1_thread", message.get("id").?.string);
    try std.testing.expectEqualStrings("SIG", message.get("thought_signature").?.string);
    try std.testing.expectEqualStrings("SIG", message.get("tool_calls").?.array.items[0].object.get("thought_signature").?.string);

    // Google's own OpenAI-compat wire (as opposed to the gateway's flattened
    // one): the signature rides extra_content on the CALL, and the turn ends
    // "stop" even though it is a tool call. Both must survive the echo, or the
    // next request loses the thinking binding for that call.
    const google = (try agent.assembleOpenAI(
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"c9\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"},\"extra_content\":{\"google\":{\"thought_signature\":\"GSIG\"}}}]},\"finish_reason\":\"stop\"}]}\n" ++
            "data: [DONE]\n",
    )).?;
    const gchoice = google.get("choices").?.array.items[0].object;
    const gcall = gchoice.get("message").?.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("stop", gchoice.get("finish_reason").?.string);
    try std.testing.expectEqualStrings("GSIG", gcall.get("extra_content").?.object.get("google").?.object.get("thought_signature").?.string);
}

test "#748: error-only OpenAI SSE is an error envelope, not a missing stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    const root = (try agent.assembleOpenAI(
        "event: error\n" ++
            "data: {\"error\":{\"type\":\"invalid_request_error\",\"message\":\"only auto is supported\"}}\n\n",
    )).?;
    try std.testing.expectEqualStrings("error", root.get("type").?.string);
    try std.testing.expectEqualStrings("invalid_request_error", root.get("error").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("only auto is supported", root.get("error").?.object.get("message").?.string);
}

test "yield_turn (#1531): every wire returns the handoff after recording the tool result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idle = @import("peer_idle.zig");
    const was_suppressed = idle.idleWakeSuppressed();
    const was_waiting = idle.waitingForInput();
    defer {
        idle.noteHumanPrompt();
        if (was_suppressed) idle.noteCompletion();
        if (was_waiting) idle.noteHandoff();
    }
    const cases = .{
        .{ .openai, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"y\",\"function\":{\"name\":\"yield_turn\",\"arguments\":\"{\\\"message\\\":\\\"Attach the screenshot on the next prompt.\\\"}\"}}]}}]}" },
        .{ .anthropic, "{\"content\":[{\"type\":\"tool_use\",\"id\":\"y\",\"name\":\"yield_turn\",\"input\":{\"message\":\"Attach the screenshot on the next prompt.\"}}]}" },
        .{ .responses, "{\"output\":[{\"type\":\"function_call\",\"call_id\":\"y\",\"name\":\"yield_turn\",\"arguments\":\"{\\\"message\\\":\\\"Attach the screenshot on the next prompt.\\\"}\"}]}" },
        .{ .interactions, "{\"steps\":[{\"type\":\"function_call\",\"id\":\"y\",\"name\":\"yield_turn\",\"arguments\":{\"message\":\"Attach the screenshot on the next prompt.\"}}]}" },
    };
    inline for (cases) |case| {
        var agent: Agent = .{
            .gpa = std.testing.allocator,
            .arena = arena,
            .io = std.testing.io,
            .client = undefined,
            .provider = .{ .id = "test", .kind = case[0], .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 128000 },
            .messages = .init(arena),
            .sub = false,
            .label = "test",
            .out = null,
            .session_name = "", // protocol-only fixture has no durable session
        };
        defer agent.tools_used.deinit(std.testing.allocator);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, case[1], .{});
        const result = (try @import("agent_steps.zig").stepForWire(&agent, root.object)).?;
        try std.testing.expectEqualStrings("Attach the screenshot on the next prompt.", result);
        try std.testing.expect(agent.completed == null);
        try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    }
}

test "#1881: OpenAI delta.reasoning populates reasoning_content and serde normalizes non-streamed reasoning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 128000 },
        .messages = .init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };

    const root = (try agent.assembleOpenAI(
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"reasoning\":\"step 1; \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"reasoning\":\"step 2\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n" ++
            "data: [DONE]\n",
    )).?;
    const msg = root.get("choices").?.array.items[0].object.get("message").?.object;
    try std.testing.expectEqualStrings("step 1; step 2", msg.get("reasoning_content").?.string);
    try std.testing.expectEqualStrings("step 1; step 2", msg.get("reasoning").?.string);

    // Non-streamed / restored assistant message carrying only `reasoning` gets
    // `reasoning_content` emitted on the OpenAI wire for chat-template KV cache stability.
    const restored = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"role\":\"assistant\",\"content\":\"ok\",\"reasoning\":\"cached chain\"}",
        .{},
    );
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try @import("serde.zig").writeOpenAIMessageNormalized(&s, restored);
    const wire = aw.writer.buffered();
    const reparsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, wire, .{});
    try std.testing.expectEqualStrings("cached chain", reparsed.object.get("reasoning_content").?.string);
}
