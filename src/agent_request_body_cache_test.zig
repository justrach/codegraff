const std = @import("std");
const bodies = @import("agent_request_body_responses.zig");
const cache = @import("openai_prompt_cache.zig");

fn bodyOf(arena: std.mem.Allocator, id: []const u8, kind: @import("provider.zig").Provider.Kind, model: []const u8) ![]u8 {
    var agent = try bodies.testAgentFor(arena, id, kind, model);
    return agent.buildBody(null, false, true, true);
}

fn expectNoCacheFields(hay: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, hay, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "\"ttl\":\"12h\"") == null);
}

test "GPT-5.6 and later Platform marks the stable prefix; Codex and older routes do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    cache.setOverride(.twelve_h);
    defer cache.clearOverride();

    var oai = try bodies.testAgentFor(a, "openai", .responses, "gpt-5.6");
    const ob = try oai.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ob);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_key\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_options\":{\"mode\":\"implicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"role\":\"developer\",\"content\":[{\"type\":\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\",\"ttl\":\"12h\"}") != null);
    // The current user turn is not an explicit breakpoint.
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"content\":\"hello\",\"prompt_cache_breakpoint\"") == null);

    var astra = try bodies.testAgentFor(a, "openai", .responses, "gpt-6-astra");
    const ast = try astra.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ast);
    try std.testing.expect(std.mem.indexOf(u8, ast, "\"prompt_cache_options\":{\"mode\":\"implicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ast, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\",\"ttl\":\"12h\"}") != null);

    var worker = try bodies.testAgentFor(a, "openai", .responses, "gpt-5.6-luna");
    worker.sub = true;
    worker.label = "implement";
    const wb = try worker.buildBody(null, false, true, true);
    defer std.testing.allocator.free(wb);
    try std.testing.expect(std.mem.indexOf(u8, wb, "\"prompt_cache_options\":{\"mode\":\"explicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, wb, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\",\"ttl\":\"12h\"}") != null);

    var sol = try bodies.testAgentFor(a, "openai", .responses, "gpt-6.1-sol");
    const sb = try sol.buildBody(null, false, true, true);
    defer std.testing.allocator.free(sb);
    try std.testing.expect(std.mem.indexOf(u8, sb, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\",\"ttl\":\"12h\"}") != null);
}

test "OpenAI cache TTL 30m keeps the previous GPT-5.6 Responses bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    cache.setOverride(.thirty_m);
    defer cache.clearOverride();

    const ob = try bodyOf(a, "openai", .responses, "gpt-5.6");
    defer std.testing.allocator.free(ob);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_options\":{\"mode\":\"implicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"ttl\":\"12h\"") == null);
}

test "OpenAI cache TTL off sends no Platform cache fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    cache.setOverride(.off);
    defer cache.clearOverride();
    const ob = try bodyOf(a, "openai", .responses, "gpt-5.6");
    defer std.testing.allocator.free(ob);
    try expectNoCacheFields(ob);
}

test "Chat Completions and older models stay byte-identical across TTL settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cache.clearOverride();

    cache.setOverride(.twelve_h);
    const chat_12 = try bodyOf(a, "openai", .openai, "gpt-5.6");
    defer std.testing.allocator.free(chat_12);
    const old_12 = try bodyOf(a, "openai", .responses, "gpt-5.5");
    defer std.testing.allocator.free(old_12);
    const chat4_12 = try bodyOf(a, "openai", .openai, "gpt-4o");
    defer std.testing.allocator.free(chat4_12);
    const codex_12 = try bodyOf(a, "codex", .responses, "gpt-5.6-sol");
    defer std.testing.allocator.free(codex_12);

    cache.setOverride(.thirty_m);
    const chat_30 = try bodyOf(a, "openai", .openai, "gpt-5.6");
    defer std.testing.allocator.free(chat_30);
    const old_30 = try bodyOf(a, "openai", .responses, "gpt-5.5");
    defer std.testing.allocator.free(old_30);
    const chat4_30 = try bodyOf(a, "openai", .openai, "gpt-4o");
    defer std.testing.allocator.free(chat4_30);
    const codex_30 = try bodyOf(a, "codex", .responses, "gpt-5.6-sol");
    defer std.testing.allocator.free(codex_30);

    cache.setOverride(.off);
    const chat_off = try bodyOf(a, "openai", .openai, "gpt-5.6");
    defer std.testing.allocator.free(chat_off);
    const old_off = try bodyOf(a, "openai", .responses, "gpt-5.5");
    defer std.testing.allocator.free(old_off);
    const codex_off = try bodyOf(a, "codex", .responses, "gpt-5.6-sol");
    defer std.testing.allocator.free(codex_off);

    try std.testing.expectEqualStrings(chat_12, chat_30);
    try std.testing.expectEqualStrings(chat_12, chat_off);
    try std.testing.expectEqualStrings(old_12, old_30);
    try std.testing.expectEqualStrings(old_12, old_off);
    try std.testing.expectEqualStrings(chat4_12, chat4_30);
    try std.testing.expectEqualStrings(codex_12, codex_30);
    try std.testing.expectEqualStrings(codex_12, codex_off);
    try expectNoCacheFields(chat_12);
    try expectNoCacheFields(old_12);
    try expectNoCacheFields(chat4_12);
    try expectNoCacheFields(codex_12);
}

test "model x API x setting gate matrix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cache.clearOverride();

    const Case = struct { id: []const u8, kind: @import("provider.zig").Provider.Kind, model: []const u8, ttl: cache.Ttl, want_12h: bool, want_options: bool };
    const cases = [_]Case{
        .{ .id = "openai", .kind = .responses, .model = "gpt-5.6", .ttl = .twelve_h, .want_12h = true, .want_options = true },
        .{ .id = "openai", .kind = .responses, .model = "gpt-6-sol", .ttl = .twelve_h, .want_12h = true, .want_options = true },
        .{ .id = "openai", .kind = .responses, .model = "gpt-5.6", .ttl = .thirty_m, .want_12h = false, .want_options = true },
        .{ .id = "openai", .kind = .responses, .model = "gpt-5.6", .ttl = .off, .want_12h = false, .want_options = false },
        .{ .id = "openai", .kind = .responses, .model = "gpt-5.5", .ttl = .twelve_h, .want_12h = false, .want_options = false },
        .{ .id = "openai", .kind = .openai, .model = "gpt-5.6", .ttl = .twelve_h, .want_12h = false, .want_options = false },
        .{ .id = "openai", .kind = .openai, .model = "gpt-6.1-sol", .ttl = .twelve_h, .want_12h = false, .want_options = false },
        .{ .id = "codex", .kind = .responses, .model = "gpt-5.6-sol", .ttl = .twelve_h, .want_12h = false, .want_options = false },
        .{ .id = "chatgpt-new", .kind = .responses, .model = "gpt-6.1-sol", .ttl = .twelve_h, .want_12h = false, .want_options = false },
        .{ .id = "xai", .kind = .responses, .model = "grok-4.6", .ttl = .twelve_h, .want_12h = false, .want_options = false },
    };
    for (cases) |c| {
        cache.setOverride(c.ttl);
        const b = try bodyOf(a, c.id, c.kind, c.model);
        defer std.testing.allocator.free(b);
        const has_12h = std.mem.indexOf(u8, b, "\"ttl\":\"12h\"") != null;
        const has_options = std.mem.indexOf(u8, b, "prompt_cache_options") != null;
        try std.testing.expectEqual(c.want_12h, has_12h);
        try std.testing.expectEqual(c.want_options, has_options);
    }
}

test "workflow synthesis report keeps chat and Responses cache prefixes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const catalog = "[{\"type\":\"function\",\"function\":{\"name\":\"ping\",\"description\":\"fixture\",\"parameters\":{\"type\":\"object\"}}}]";
    for ([_]@import("provider.zig").Provider.Kind{ .openai, .responses }) |kind| {
        var agent = try bodies.testAgentFor(a, "openai", kind, "gpt-5.6");
        agent.sub = true;
        agent.label = "synthesize";
        agent.synthesis = .{ .enabled = true, .requests = 7 };
        try agent.synthesis.beforeRequest(&agent);
        const before = try agent.buildBody(catalog, true, true, true);
        defer std.testing.allocator.free(before);
        try agent.synthesis.beforeRequest(&agent);
        const after = try agent.buildBody(if (agent.synthesis.keepsCatalog(&agent)) catalog else null, true, true, true);
        defer std.testing.allocator.free(after);
        const first = try std.json.parseFromSliceLeaky(std.json.Value, a, before, .{});
        const report = try std.json.parseFromSliceLeaky(std.json.Value, a, after, .{});
        try std.testing.expectEqualStrings(
            try std.json.Stringify.valueAlloc(a, first.object.get("tools").?, .{}),
            try std.json.Stringify.valueAlloc(a, report.object.get("tools").?, .{}),
        );
        try std.testing.expectEqualStrings(first.object.get("prompt_cache_key").?.string, report.object.get("prompt_cache_key").?.string);
        const first_prefix = if (kind == .responses) first.object.get("instructions").? else first.object.get("messages").?.array.items[0];
        const report_prefix = if (kind == .responses) report.object.get("instructions").? else report.object.get("messages").?.array.items[0];
        try std.testing.expectEqualStrings(
            try std.json.Stringify.valueAlloc(a, first_prefix, .{}),
            try std.json.Stringify.valueAlloc(a, report_prefix, .{}),
        );
        try std.testing.expectEqualStrings("required", first.object.get("tool_choice").?.string);
        try std.testing.expectEqualStrings("none", report.object.get("tool_choice").?.string);
    }
}

test "ADR 0312: the default sends no 12h ttl (opt-in until a live probe)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    cache.clearOverride();
    try std.testing.expectEqual(cache.Ttl.thirty_m, cache.default_ttl);
    const b = try bodyOf(arena.allocator(), "openai", .responses, "gpt-5.6");
    defer std.testing.allocator.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"ttl\":\"12h\"") == null);
}
