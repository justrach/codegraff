//! ADR 0243 tests: the per-repo context leaves the instructions on the
//! eligible Responses wires and rides as the first input item.

const std = @import("std");
const repo_context = @import("repo_context.zig");
const hot_context = @import("hot_context.zig");
const body = @import("agent_request_body_responses.zig");

const layout_a = "\n\n# Project layout (working tree at session start, depth 3; may omit later changes)\nlogs/\nlogs/auth.log\n";
const layout_b = "\n\n# Project layout (working tree at session start, depth 3; may omit later changes)\napi/\napi/routes.py\n";
const agents_block = "\n\n# Project instructions (from AGENTS.md)\nUse tabs.";

fn rootWith(a: std.mem.Allocator, id: []const u8, layout: []const u8) !@import("agent.zig").Agent {
    var agent = try body.testAgentFor(a, id, .responses, "gpt-6.1-sol");
    const base = try std.mem.concat(a, u8, &.{ "BASE", agents_block, layout, "\n\n# Skills\nstatic tail" });
    agent.sys_base = base;
    agent.sys_normal = base;
    agent.repo_map_snapshot = layout;
    return agent;
}

test "ADR 0243: instructions drop the per-repo blocks and are identical across repos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    hot_context.noteBaked("AGENTS.md", "Use tabs.");
    defer hot_context.resetForTest();

    var one = try rootWith(a, "codex", layout_a);
    var two = try rootWith(a, "codex", layout_b);
    const s1 = try repo_context.split(&one, one.sys_normal);
    const s2 = try repo_context.split(&two, two.sys_normal);
    try std.testing.expectEqualStrings("BASE\n\n# Skills\nstatic tail", s1.instructions);
    try std.testing.expectEqualStrings(s1.instructions, s2.instructions);
    try std.testing.expect(std.mem.startsWith(u8, s1.context, "# Project instructions (from AGENTS.md)\nUse tabs.\n\n# Project layout"));
    try std.testing.expect(std.mem.indexOf(u8, s1.context, "logs/auth.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2.context, "api/routes.py") != null);
}

test "ADR 0243: other wires, other providers and subagents keep the blocks in the instructions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "xai", "codegraff" }) |id| {
        var other = try rootWith(a, id, layout_a);
        const s = try repo_context.split(&other, other.sys_normal);
        try std.testing.expectEqualStrings(other.sys_normal, s.instructions);
        try std.testing.expectEqualStrings("", s.context);
    }
    var sub = try rootWith(a, "codex", layout_a);
    sub.sub = true;
    try std.testing.expectEqualStrings(sub.sys_normal, (try repo_context.split(&sub, sub.sys_normal)).instructions);
    var chat = try rootWith(a, "codex", layout_a);
    chat.provider.kind = .openai;
    try std.testing.expectEqualStrings(chat.sys_normal, (try repo_context.split(&chat, chat.sys_normal)).instructions);
}

test "ADR 0243: the wire body carries the layout as the first developer item; a prewarm carries none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    hot_context.resetForTest(); // no baked instructions: the layout alone moves

    var agent = try rootWith(a, "codex", layout_a);
    const full = try agent.buildBody("[]", false, true, true);
    defer std.testing.allocator.free(full);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, full, .{});
    const instructions = parsed.value.object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, instructions, "# Project layout") == null);
    const input = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqualStrings("developer", input[0].object.get("role").?.string);
    const text = input[0].object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.startsWith(u8, text, "# Project layout"));
    try std.testing.expect(std.mem.indexOf(u8, text, "logs/auth.log") != null);
    try std.testing.expectEqualStrings("user", input[1].object.get("role").?.string);

    agent.ws_prewarm = true; // instructions + tools only; turn 1 chains on with the item (from == 0)
    const warm = try agent.buildBody("[]", false, true, true);
    defer std.testing.allocator.free(warm);
    const warm_parsed = try std.json.parseFromSlice(std.json.Value, a, warm, .{});
    try std.testing.expectEqual(@as(usize, 0), warm_parsed.value.object.get("input").?.array.items.len);
    try std.testing.expectEqualStrings(instructions, warm_parsed.value.object.get("instructions").?.string);
}

fn chatRoot(a: std.mem.Allocator, id: []const u8, model: []const u8, layout: []const u8) !@import("agent.zig").Agent {
    var agent = try body.testAgentFor(a, id, .openai, model);
    const base = try std.mem.concat(a, u8, &.{ "BASE", agents_block, layout, "\n\n# Skills\nstatic tail" });
    agent.sys_base = base;
    agent.sys_normal = base;
    agent.repo_map_snapshot = layout;
    return agent;
}

test "ADR 0258: Gemini on the Codegraff chat wire sends the per-repo context once, as the first user message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    hot_context.noteBaked("AGENTS.md", "Use tabs.");
    defer hot_context.resetForTest();

    var agent = try chatRoot(a, "codegraff", "gemini-3.8-flash", layout_a);
    const full = try agent.buildBody("[]", false, true, true);
    defer std.testing.allocator.free(full);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, full, .{});
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
    const system = messages[0].object.get("content").?.string;
    try std.testing.expect(std.mem.startsWith(u8, system, "BASE\n\n# Skills\nstatic tail"));
    try std.testing.expect(std.mem.indexOf(u8, system, "# Project") == null);
    // A fixed opening exchange gives every session the same cacheable turn boundary.
    try std.testing.expectEqualStrings("user", messages[1].object.get("role").?.string);
    try std.testing.expectEqualStrings(repo_context.opening_user, messages[1].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", messages[2].object.get("role").?.string);
    try std.testing.expectEqualStrings(repo_context.opening_model, messages[2].object.get("content").?.string);
    try std.testing.expectEqualStrings("user", messages[3].object.get("role").?.string);
    const context = messages[3].object.get("content").?.string;
    try std.testing.expect(std.mem.startsWith(u8, context, repo_context.chat_frame ++ "# Project instructions (from AGENTS.md)\nUse tabs."));
    try std.testing.expect(std.mem.indexOf(u8, context, "logs/auth.log") != null);
    try std.testing.expectEqualStrings("hello", messages[4].object.get("content").?.string);

    // A second repo sends the same system prompt.
    var other = try chatRoot(a, "codegraff", "google/gemini-3.7-flash", layout_b);
    try std.testing.expectEqualStrings((try repo_context.split(&agent, agent.sys_normal)).instructions, (try repo_context.split(&other, other.sys_normal)).instructions);
}

test "ADR 0258: other chat routes and sub-agents keep the per-repo context in the system prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    hot_context.noteBaked("AGENTS.md", "Use tabs.");
    defer hot_context.resetForTest();
    const routes = [_]struct { id: []const u8, model: []const u8 }{
        .{ .id = "codegraff", .model = "deepseek-v4-flash" },
        .{ .id = "codegraff", .model = "mimo-v2.6-pro" },
        .{ .id = "openrouter", .model = "google/gemini-3.8-flash" },
    };
    for (routes) |r| {
        var agent = try chatRoot(a, r.id, r.model, layout_a);
        const full = try agent.buildBody("[]", false, true, true);
        defer std.testing.allocator.free(full);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, full, .{});
        const messages = parsed.value.object.get("messages").?.array.items;
        // The system prompt still holds the blocks (a model note may follow them).
        try std.testing.expect(std.mem.startsWith(u8, messages[0].object.get("content").?.string, agent.sys_normal));
        try std.testing.expectEqual(@as(usize, 2), messages.len);
    }
    var sub = try chatRoot(a, "codegraff", "gemini-3.8-flash", layout_a);
    sub.sub = true;
    try std.testing.expectEqualStrings(sub.sys_normal, (try repo_context.split(&sub, sub.sys_normal)).instructions);
}
