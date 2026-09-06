//! White-box tests for agent_steps.zig's stream assembler, parked here under
//! the 600-line ceiling (same pattern as router_catalog_tests.zig).

const std = @import("std");
const Agent = @import("agent.zig").Agent;

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
