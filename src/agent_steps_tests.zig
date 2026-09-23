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
