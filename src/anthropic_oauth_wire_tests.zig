//! Native login-token Anthropic request/header and reversible tool-name tests.
const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const oauth = @import("anthropic_oauth_wire.zig");
const headers = @import("http_headers.zig");
const testing = std.testing;

const catalog = "[{\"name\":\"bAsH\",\"description\":\"shell\",\"input_schema\":{\"properties\":{\"name\":{\"type\":\"string\"}}}},{\"name\":\"custom_tool\",\"input_schema\":{\"type\":\"object\"}}]";
const history = "[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig-preserve\"},{\"type\":\"tool_use\",\"id\":\"call-1\",\"name\":\"bAsH\",\"input\":{\"name\":\"bAsH\",\"command\":\"true\"}}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call-1\",\"content\":\"ok\"}]}]";

fn provider() Provider {
    return .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "opaque-login-token", .source = .login, .model = "claude-opus-5-5", .context = 1_000_000 };
}

fn agentFor(arena: std.mem.Allocator) !Agent {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, history, .{ .allocate = .alloc_always });
    return .{
        .gpa = testing.allocator,
        .arena = arena,
        .io = testing.io,
        .client = undefined,
        .provider = provider(),
        .messages = parsed.array,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "Actual Graff instructions remain unchanged.",
        .tools_anthropic = catalog,
    };
}

fn field(h: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (h) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
    return null;
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

fn parse(arena: std.mem.Allocator, body: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always });
}

test "Anthropic OAuth headers are source scoped with native CLI identity and Bearer" {
    var p = provider();
    var buf: [12]std.http.Header = undefined;
    const h = headers.providerHeaders(testing.io, p, "Bearer opaque-login-token", &buf);
    try testing.expectEqualStrings("Bearer opaque-login-token", field(h, "authorization").?);
    try testing.expect(field(h, "x-api-key") == null);
    try testing.expectEqualStrings("application/json", field(h, "accept").?);
    try testing.expectEqualStrings("true", field(h, "anthropic-dangerous-direct-browser-access").?);
    try testing.expectEqualStrings("cli", field(h, "x-app").?);
    try testing.expectEqualStrings("claude-cli/2.1.280", field(h, "user-agent").?);
    var user_agents: usize = 0;
    for (h) |item| if (std.ascii.eqlIgnoreCase(item.name, "user-agent")) {
        user_agents += 1;
    };
    try testing.expectEqual(@as(usize, 1), user_agents); // HTTP/2 forwards extras once
    try testing.expect(headers.userAgent(p) == .omit); // no duplicate on HTTP/1.1

    // An OAuth-looking key is still an API key when it came from the environment.
    p.source = .environment;
    p.auth = .x_api_key;
    p.api_key = "sk-ant-oat-looking-but-not-login";
    const api = headers.providerHeaders(testing.io, p, "", &buf);
    try testing.expectEqualStrings(p.api_key, field(api, "x-api-key").?);
    try testing.expect(field(api, "authorization") == null);
    try testing.expect(field(api, "x-app") == null);
    try testing.expect(field(api, "accept") == null);
    try testing.expect(headers.userAgent(p) == .default);
    p.source = .login;
    p.id = "gateway";
    try testing.expect(!oauth.active(p));
    try testing.expect(field(headers.providerHeaders(testing.io, p, "", &buf), "x-app") == null);
    try testing.expect(headers.userAgent(p) == .default);
}

test "Anthropic OAuth beta combines login requirements and existing thinking binding once" {
    var p = provider();
    var buf: [12]std.http.Header = undefined;
    const h = headers.providerHeaders(testing.io, p, "Bearer token", &buf);
    try testing.expectEqualStrings("claude-code-20250219,oauth-2025-04-20,thinking-binding-controls-2026-08-01", field(h, "anthropic-beta").?);
    var count: usize = 0;
    for (h) |item| if (std.mem.eql(u8, item.name, "anthropic-beta")) {
        count += 1;
    };
    try testing.expectEqual(@as(usize, 1), count);
    p.model = "claude-opus-4-8";
    try testing.expectEqualStrings("claude-code-20250219,oauth-2025-04-20", field(headers.providerHeaders(testing.io, p, "Bearer token", &buf), "anthropic-beta").?);
    p.source = .environment;
    try testing.expect(field(headers.providerHeaders(testing.io, p, "Bearer token", &buf), "anthropic-beta") == null);
    p.model = "claude-opus-5-5";
    try testing.expectEqualStrings(@import("claude_wire.zig").binding_beta, field(headers.providerHeaders(testing.io, p, "Bearer token", &buf), "anthropic-beta").?);
}

test "Anthropic OAuth body prepends identity and adapts definitions and history without mutating Graff" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = try agentFor(arena);
    const body = try agent.buildBody(catalog, false, true, true);
    defer testing.allocator.free(body);
    const root = (try parse(arena, body)).object;
    const system = root.get("system").?.array.items;
    try testing.expectEqual(@as(usize, 2), system.len);
    try testing.expectEqualStrings(oauth.system_prefix, system[0].object.get("text").?.string);
    try testing.expect(system[0].object.get("cache_control") == null);
    try testing.expectEqualStrings(agent.sys_normal, system[1].object.get("text").?.string);
    try testing.expect(system[1].object.get("cache_control") != null);
    try testing.expectEqualStrings("Actual Graff instructions remain unchanged.", agent.sys_normal);
    const tools = root.get("tools").?.array.items;
    try testing.expectEqualStrings("Bash", tools[0].object.get("name").?.string);
    try testing.expectEqualStrings("custom_tool", tools[1].object.get("name").?.string);
    try testing.expectEqualStrings("object", tools[0].object.get("input_schema").?.object.get("type").?.string);
    const blocks = root.get("messages").?.array.items[0].object.get("content").?.array.items;
    try testing.expectEqualStrings("sig-preserve", blocks[0].object.get("signature").?.string);
    try testing.expect(blocks[0].object.get("cache_control") == null);
    try testing.expectEqualStrings("Bash", blocks[1].object.get("name").?.string);
    try testing.expectEqualStrings("call-1", blocks[1].object.get("id").?.string);
    try testing.expectEqualStrings("bAsH", blocks[1].object.get("input").?.object.get("name").?.string);
    try testing.expectEqualStrings("bAsH", agent.messages.items[0].object.get("content").?.array.items[1].object.get("name").?.string);
    try testing.expect(contains(body, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\",\"block_binding\""));
    try testing.expect(contains(body, "\"tool_use_id\":\"call-1\""));
}

test "Anthropic OAuth leaves API key and gateway Anthropic request bodies unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = try agentFor(arena);
    agent.provider.source = .environment;
    agent.provider.auth = .x_api_key;
    for ([_][]const u8{ "anthropic", "minimax", "codegraff" }) |id| {
        agent.provider.id = id;
        const body = try agent.buildBody(catalog, false, false, false);
        defer testing.allocator.free(body);
        const root = (try parse(arena, body)).object;
        try testing.expect(!contains(body, oauth.system_prefix));
        try testing.expectEqualStrings("bAsH", root.get("tools").?.array.items[0].object.get("name").?.string);
        try testing.expectEqualStrings("bAsH", root.get("messages").?.array.items[0].object.get("content").?.array.items[1].object.get("name").?.string);
        // A gateway login is not a native Anthropic login either.
        agent.provider.source = .login;
    }
}

test "Anthropic OAuth recognizes only known Claude Code tool names case insensitively" {
    const names = [_][]const u8{ "Read", "Write", "Edit", "Bash", "Grep", "Glob", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode", "KillShell", "NotebookEdit", "Skill", "Task", "TaskOutput", "TodoWrite", "WebFetch", "WebSearch" };
    var lower: [32]u8 = undefined;
    for (names) |name| {
        for (name, 0..) |char, i| lower[i] = std.ascii.toLower(char);
        try testing.expectEqualStrings(name, oauth.canonical(lower[0..name.len]));
    }
    for ([_][]const u8{ "read_file", "ask_user", "web_fetch", "Bash_extra", "mcp__Read" }) |name|
        try testing.expectEqualStrings(name, oauth.canonical(name));
}

test "Anthropic OAuth case collisions keep distinct advertised names and reversible dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = "[{\"name\":\"bash\"},{\"name\":\"Bash\"},{\"name\":\"READ\"},{\"name\":\"custom_tool\"}]";
    const names = try oauth.ToolNames.init(arena, raw);
    try testing.expectEqualStrings("bash", names.encode("bash"));
    try testing.expectEqualStrings("Bash", names.encode("Bash"));
    try testing.expectEqualStrings("bash", names.decode("bash"));
    try testing.expectEqualStrings("Bash", names.decode("Bash"));
    try testing.expectEqualStrings("Read", names.encode("READ"));
    try testing.expectEqualStrings("READ", names.decode("Read"));
    try testing.expectEqualStrings("custom_tool", names.decode("custom_tool"));
    var agent = try agentFor(arena);
    const body = try agent.buildBody(raw, false, false, false);
    defer testing.allocator.free(body);
    const tools = (try parse(arena, body)).object.get("tools").?.array.items;
    try testing.expectEqualStrings("bash", tools[0].object.get("name").?.string);
    try testing.expectEqualStrings("Bash", tools[1].object.get("name").?.string);
}

test "Anthropic OAuth streamed response names round trip to actual Graff tools preserving signatures and arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = try agentFor(arena);
    const response = (try agent.assembleAnthropic(
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n\n" ++
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig-roundtrip\"}}\n\n" ++
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"roundtrip-id\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"true\\\"}\"}}\n\n" ++
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n" ++
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    )).?;
    const content = response.get("content").?;
    const names = try oauth.ToolNames.init(arena, catalog);
    try names.decodeContent(arena, content);
    const blocks = content.array.items;
    try testing.expectEqualStrings("bAsH", blocks[1].object.get("name").?.string);
    try testing.expectEqualStrings("roundtrip-id", blocks[1].object.get("id").?.string);
    try testing.expectEqualStrings("true", blocks[1].object.get("input").?.object.get("command").?.string);
    try testing.expectEqualStrings("sig-roundtrip", blocks[0].object.get("signature").?.string);
    var message: std.json.ObjectMap = .empty;
    try message.put(arena, "role", .{ .string = "assistant" });
    try message.put(arena, "content", content);
    agent.messages = std.json.Array.init(arena);
    try agent.messages.append(.{ .object = message });
    const body = try agent.buildBody(catalog, false, false, false);
    defer testing.allocator.free(body);
    const replay = (try parse(arena, body)).object.get("messages").?.array.items[0].object.get("content").?.array.items;
    try testing.expectEqualStrings("Bash", replay[1].object.get("name").?.string);
    try testing.expectEqualStrings("sig-roundtrip", replay[0].object.get("signature").?.string);
    try testing.expectEqualStrings("roundtrip-id", replay[1].object.get("id").?.string);
    try testing.expectEqualStrings("true", replay[1].object.get("input").?.object.get("command").?.string);
}

test "Anthropic OAuth title metadata and compaction bodies retain their real system instructions after identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = try agentFor(arena);
    agent.sys_override = "Auxiliary call instructions.";
    for ([_]@import("run_budget.zig").CallKind{ .title, .recap, .compaction }) |kind| {
        agent.call_kind = kind;
        agent.sub = kind == .title;
        agent.compaction_request = kind == .compaction;
        const body = try agent.buildBody(null, false, true, true);
        defer testing.allocator.free(body);
        const root = (try parse(arena, body)).object;
        const system = root.get("system").?.array.items;
        try testing.expectEqualStrings(oauth.system_prefix, system[0].object.get("text").?.string);
        try testing.expectEqualStrings(agent.systemPrompt(), system[1].object.get("text").?.string);
        try testing.expect(root.get("tools") == null);
        if (agent.compaction_request) try testing.expect(system[1].object.get("cache_control") == null);
    }
}

test "Anthropic OAuth RLM standalone body supplies identity only for native login source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = provider();
    const build = @import("rlm_query.zig").buildBody;
    const body = try build(testing.allocator, p, "Answer briefly.");
    defer testing.allocator.free(body);
    const root = (try parse(arena, body)).object;
    try testing.expectEqualStrings(oauth.system_prefix, root.get("system").?.array.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("Answer briefly.", root.get("messages").?.array.items[0].object.get("content").?.string);
    p.source = .environment;
    const api_body = try build(testing.allocator, p, "Answer briefly.");
    defer testing.allocator.free(api_body);
    try testing.expect((try parse(arena, api_body)).object.get("system") == null);
    p.source = .login;
    p.id = "minimax";
    const gateway_body = try build(testing.allocator, p, "Answer briefly.");
    defer testing.allocator.free(gateway_body);
    try testing.expect((try parse(arena, gateway_body)).object.get("system") == null);
}
