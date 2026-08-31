const std = @import("std");
const provider = @import("provider.zig");
const Agent = @import("agent.zig").Agent;
const http_headers = @import("http_headers.zig");

fn build(model: []const u8) provider.Provider {
    const keys: provider.Keys = .{ .values = @splat(null) };
    return keys.build(provider.specFor("codegraff").?, "key", model);
}

test "Codegraff selects the gateway wire and endpoint per model" {
    for ([_][]const u8{ "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "grok-4.6" }) |model| {
        const got = build(model);
        try std.testing.expectEqual(provider.Provider.Kind.responses, got.kind);
        try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/responses", got.url);
    }

    for ([_][]const u8{ "deepseek-v4-pro", "claude-opus-4.8", "gemini-3.7-flash" }) |model| {
        const got = build(model);
        try std.testing.expectEqual(provider.Provider.Kind.openai, got.kind);
        try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/chat/completions", got.url);
    }
}

test "Codegraff-only credentials route native aliases without live discovery" {
    var keys: provider.Keys = .{ .values = @splat(null) };
    try std.testing.expect(keys.set("codegraff", "key", .environment));
    for ([_][]const u8{ "gpt-5.6", "grok-4.6" }) |model| {
        const got = try keys.providerFor(model);
        try std.testing.expectEqualStrings("codegraff", got.id);
        try std.testing.expectEqual(provider.Provider.Kind.responses, got.kind);
        try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/responses", got.url);
    }
}

test "Codegraff model switches rebuild both wire and endpoint" {
    const chat = build("gemini-3.7-flash");
    const responses = chat.withModel("grok-4.6");
    try std.testing.expectEqual(provider.Provider.Kind.responses, responses.kind);
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/responses", responses.url);

    const back_to_chat = responses.withModel("claude-opus-4.8");
    try std.testing.expectEqual(provider.Provider.Kind.openai, back_to_chat.kind);
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/chat/completions", back_to_chat.url);
}

test "Codegraff Responses aliases pin a sticky prompt_cache_key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(.{ .object = blk: {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "role", .{ .string = "user" });
        try obj.put(arena, "content", .{ .string = "hello" });
        break :blk obj;
    } });

    for ([_][]const u8{ "gpt-5.6", "grok-4.6" }) |model| {
        var root: Agent = .{
            .gpa = std.testing.allocator,
            .arena = arena,
            .io = std.testing.io,
            .client = undefined,
            .provider = build(model),
            .messages = messages,
            .sub = false,
            .label = "main",
            .out = null,
            .sys_normal = "system",
        };
        const first = try root.buildBody(null, false, true, true);
        defer std.testing.allocator.free(first);
        const second = try root.buildBody(null, false, true, true);
        defer std.testing.allocator.free(second);
        const needle = "\"prompt_cache_key\":\"";
        const s1 = std.mem.indexOf(u8, first, needle) orelse return error.MissingPromptCacheKey;
        const e1 = std.mem.indexOfScalarPos(u8, first, s1 + needle.len, '"') orelse return error.MissingPromptCacheKey;
        const k1 = first[s1 + needle.len .. e1];
        const s2 = std.mem.indexOf(u8, second, needle) orelse return error.MissingPromptCacheKey;
        const e2 = std.mem.indexOfScalarPos(u8, second, s2 + needle.len, '"') orelse return error.MissingPromptCacheKey;
        try std.testing.expectEqualStrings(k1, second[s2 + needle.len .. e2]);
        var buf: [96]u8 = undefined;
        try std.testing.expectEqualStrings(http_headers.promptCacheKey(root.io, root.label, &root, &buf), k1);
    }
}

test "Codegraff Gemini sends low for default effort; /effort high still sends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(.{ .object = blk: {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "role", .{ .string = "user" });
        try obj.put(arena, "content", .{ .string = "hello" });
        break :blk obj;
    } });
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = build("gemini-3.7-flash"),
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
    try std.testing.expect(agent.effortApplies());
    try std.testing.expect(agent.sendReasoningEffort());
    const low = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(low);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"reasoning_effort\":\"low\"") != null);

    agent.reasoning = .high;
    try std.testing.expect(agent.sendReasoningEffort());
    const high = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(high);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"reasoning_effort\":\"high\"") != null);

    var deepseek: Agent = agent;
    deepseek.provider = build("deepseek-v4-pro");
    deepseek.reasoning = .medium;
    try std.testing.expect(deepseek.sendReasoningEffort());
    const ds = try deepseek.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ds);
    try std.testing.expect(std.mem.indexOf(u8, ds, "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds, "\"thinking\":{\"type\":\"enabled\"}") != null);
}

test "Codegraff glm-5.3-flash sends low for default effort; /effort high still sends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(.{ .object = blk: {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "role", .{ .string = "user" });
        try obj.put(arena, "content", .{ .string = "hello" });
        break :blk obj;
    } });
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = build("glm-5.3-flash"),
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
    try std.testing.expect(agent.effortApplies());
    try std.testing.expect(agent.sendReasoningEffort());
    const low = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(low);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"reasoning_effort\":\"low\"") != null);

    agent.reasoning = .high;
    try std.testing.expect(agent.sendReasoningEffort());
    const high = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(high);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"reasoning_effort\":\"high\"") != null);
}

test "Codegraff DeepSeek flash disables thinking at default low; /effort high still thinks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(.{ .object = blk: {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "role", .{ .string = "user" });
        try obj.put(arena, "content", .{ .string = "hello" });
        break :blk obj;
    } });
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = build("deepseek-v4-flash"),
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
    const low = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(low);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"thinking\":{\"type\":\"enabled\"}") == null);

    agent.reasoning = .high;
    const high = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(high);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"thinking\":{\"type\":\"disabled\"}") == null);

    var glm: Agent = agent;
    glm.provider = build("glm-5.3-flash");
    glm.reasoning = .medium;
    const glm_body = try glm.buildBody(null, false, true, true);
    defer std.testing.allocator.free(glm_body);
    try std.testing.expect(std.mem.indexOf(u8, glm_body, "\"thinking\":{\"type\":\"disabled\"}") == null);
    try std.testing.expect(std.mem.indexOf(u8, glm_body, "\"reasoning_effort\":\"low\"") != null);
}
