//! GPT-6 Astra/Sol behavioral guidance, selected at request time so model
//! switches cannot leave it on another model's prompt. API features belong
//! in the wire layer, not in instructions claiming tools we do not expose.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const prompts = @import("prompts.zig");

const guidance =
    \\Infer intent and scope from the conversation. Treat requests to change,
    \\build, or fix as authorization to do the in-scope work and finish it.
    \\For review, explanation, or planning, inspect and report unless changes are
    \\also requested. Resolve routine gaps with reasonable assumptions; ask only
    \\when an answer materially changes the result or a real ambiguity blocks it.
    \\Complete independent authorized work before presenting a concrete choice.
    \\Respect tool gates, task boundaries, and destructive-action restrictions;
    \\do not invent extra approval flows or hypothetical-risk checklists.
    \\
    \\Explicit user instructions outrank skill guidelines, subject to system and
    \\developer instructions. If a skill blocks work, link its exact SKILL.md,
    \\quote the relevant rule, and distinguish the rule from your interpretation.
    \\
    \\Lead with the useful result. Write concise, connected paragraphs in plain
    \\language; use lists when they clarify steps or comparisons. Avoid stock
    \\phrases, unnecessary headings, and unrequested contrasts. Keep technical
    \\detail proportional to the reader and inter-agent messages legible.
    \\
    \\Run meaningful checks proportional to the change and required project
    \\checks. Avoid tests that only mirror trivial implementation. After checks
    \\pass, repeat or broaden them only for new changes, failures, or unresolved
    \\concerns; then complete the task.
;

const delegation =
    \\
    \\Delegate only bounded, independent work that can save time or improve
    \\quality while useful local work continues. Keep the critical path local,
    \\respect available tools, depth and concurrency limits, and integrate the
    \\results. Do not create recursive delegation chains.
;

fn heading(model: []const u8) ?[]const u8 {
    const bare = model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| i + 1 else 0..];
    for ([_][]const u8{ "gpt-6-astra", "gpt-6-sol" }, [_][]const u8{ "# Astra working guidance", "# GPT-6 Sol working guidance" }) |name, title| {
        if (std.mem.eql(u8, bare, name) or (std.mem.startsWith(u8, bare, name) and bare.len > name.len and bare[name.len] == '-')) return title;
    }
    return null;
}

pub fn append(self: *Agent, base: []const u8) ![]const u8 {
    const title = heading(self.provider.model) orelse return base;
    const fanout = !self.sub and prompts.detectCaps().subagents;
    return std.mem.concat(self.scratchAlloc(), u8, &.{ base, "\n", title, "\n", guidance, if (fanout) delegation else "" });
}

test "Astra guidance follows model switches, child limits and output schemas" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-astra", .context = 270_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "BASE",
    };
    const compose = @import("agent_request_body_responses.zig").schemaAwarePrompt;
    for ([_][]const u8{ "gpt-6-astra", "openai/gpt-6-astra", "gpt-6-astra-2026-09-03" }) |model| {
        agent.provider.model = model;
        const result = try compose(&agent);
        try std.testing.expect(std.mem.startsWith(u8, result, "BASE\n"));
        try std.testing.expect(std.mem.indexOf(u8, result, "# Astra working guidance") != null);
        try std.testing.expectEqual(prompts.detectCaps().subagents, std.mem.indexOf(u8, result, "Delegate only bounded") != null);
    }
    agent.sub = true;
    agent.output_schema = "{\"type\":\"object\"}";
    const child = try compose(&agent);
    try std.testing.expect(std.mem.indexOf(u8, child, "# Astra working guidance") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "Delegate only bounded") == null);
    try std.testing.expect(std.mem.indexOf(u8, child, "A JSON output schema is enforced") != null);
    agent.output_schema = null;
    agent.sub = false;
    for ([_][]const u8{ "gpt-5.5", "gemini-3.7-flash", "gpt-6-astraish" }) |model| { // gpt-5.6 has its own note (prompt_guidance.zig)
        agent.provider.model = model;
        try std.testing.expectEqualStrings("BASE", try compose(&agent));
    }
}

test "GPT6 emitted requests keep one stable guidance block and refresh on model switches" {
    const testing = std.testing;
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    for ([_][]const u8{ "openai", "codex", "codegraff" }) |provider| {
        var agent = try @import("agent_request_body_responses.zig").testAgentFor(a, provider, .responses, "gpt-6-astra");
        agent.reasoning = .medium;
        for ([_][]const u8{ "gpt-6-astra", "gpt-6-sol", "openai/gpt-6-sol", "gpt-6-sol-2026-09-22", "mimo-v2.6-flash", "gpt-5.6-terra", "grok-4.6", "grok-4.7", "gpt-6-solish", "gpt-6-luna", "gpt-6-astra" }) |model| {
            agent.provider.model = model;
            const before = try agent.buildBody("[]", false, true, true);
            defer testing.allocator.free(before);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, before, .{});
            const instructions = parsed.value.object.get("instructions").?.string;
            if (heading(model)) |title| {
                try testing.expectEqual(@as(usize, 1), std.mem.count(u8, instructions, title));
                try testing.expectEqual(@as(usize, 1), std.mem.count(u8, instructions, "Explicit user instructions outrank skill guidelines"));
                try testing.expectEqual(prompts.detectCaps().subagents, std.mem.indexOf(u8, instructions, "Delegate only bounded") != null);
            } else {
                try testing.expect(std.mem.indexOf(u8, instructions, "# Astra working guidance") == null);
                try testing.expect(std.mem.indexOf(u8, instructions, "# GPT-6 Sol working guidance") == null);
            }
            try testing.expectEqualStrings(if (std.mem.eql(u8, model, "mimo-v2.6-flash")) "low" else "medium", parsed.value.object.get("reasoning").?.object.get("effort").?.string);
            var followup: std.json.ObjectMap = .empty;
            try followup.put(a, "role", .{ .string = "user" });
            try followup.put(a, "content", .{ .string = "continue with the requested work" });
            try agent.messages.append(.{ .object = followup });
            const after = try agent.buildBody("[]", false, true, true);
            defer testing.allocator.free(after);
            const appended = try std.json.parseFromSlice(std.json.Value, a, after, .{});
            try testing.expectEqualStrings(instructions, appended.value.object.get("instructions").?.string);
            try testing.expectEqualStrings(parsed.value.object.get("prompt_cache_key").?.string, appended.value.object.get("prompt_cache_key").?.string);
        }
        agent.sub = true;
        agent.provider.model = "gpt-6-sol";
        const child = try agent.buildBody("[]", false, true, true);
        defer testing.allocator.free(child);
        try testing.expect(std.mem.indexOf(u8, child, "Delegate only bounded") == null);
        try testing.expect(std.mem.indexOf(u8, child, "# GPT-6 Sol working guidance") != null);
    }
}
