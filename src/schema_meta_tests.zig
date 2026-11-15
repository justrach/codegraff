const std = @import("std");
const root = @import("main.zig");
const learn_store = @import("learn_store.zig");
const schema = @import("schema.zig");

const effectiveRootSpecs = schema.effectiveRootSpecs;
const root_specs = schema.root_specs;
const learn_candidate_spec = schema.learn_candidate_spec;
const tools_openai_sub = schema.tools_openai_sub;
const tools_anthropic_sub = schema.tools_anthropic_sub;
const subagent_spec = schema.subagent_spec;
const workflow_spec = schema.workflow_spec;
const providerDisplayName = schema.providerDisplayName;
const providerLoginKind = schema.providerLoginKind;
const providerTakesEffort = schema.providerTakesEffort;
const isMetaName = schema.isMetaName;

test "providerDisplayName & providerLoginKind: id mapping with sane fallbacks" {
    try std.testing.expectEqualStrings("OpenAI", providerDisplayName("openai"));
    try std.testing.expectEqualStrings("Codex (ChatGPT)", providerDisplayName("codex"));
    try std.testing.expectEqualStrings("mystery", providerDisplayName("mystery")); // unknown -> echoed id
    try std.testing.expectEqualStrings("codegraff_device", providerLoginKind("codegraff"));
    try std.testing.expectEqualStrings("codex_device", providerLoginKind("codex"));
    try std.testing.expectEqualStrings("kimi_device", providerLoginKind("kimi"));
    try std.testing.expectEqualStrings("zai_cli", providerLoginKind("zai"));
    try std.testing.expectEqualStrings("api_key", providerLoginKind("openai"));
}

test "effectiveRootSpecs: drops clock_sleep from the root tool catalog unless the flag is on (#225)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = root.g_clock_sleep;
    const saved_learning = learn_store.active_agent_loaded;
    defer {
        root.g_clock_sleep = saved;
        learn_store.active_agent_loaded = saved_learning;
    }
    learn_store.active_agent_loaded = true;

    root.g_clock_sleep = false;
    const off_specs = try effectiveRootSpecs(a);
    try std.testing.expectEqual(root_specs.len, off_specs.len); // -clock_sleep +rlm
    for (off_specs) |t| try std.testing.expect(!std.mem.eql(u8, t.name, "clock_sleep"));
    try std.testing.expect(arena_state.queryCapacity() > 0); // maybeAppend copies to append rlm

    root.g_clock_sleep = true;
    const on_specs = try effectiveRootSpecs(a);
    try std.testing.expectEqual(root_specs.len + 1, on_specs.len); // +rlm
    var found = false;
    for (on_specs) |t| {
        if (std.mem.eql(u8, t.name, "clock_sleep")) found = true;
    }
    try std.testing.expect(found);

    root.g_clock_sleep = false;
    learn_store.active_agent_loaded = false;
    const minimal_specs = try effectiveRootSpecs(a);
    try std.testing.expectEqual(root_specs.len - 1, minimal_specs.len); // -clock -learn +rlm
    for (minimal_specs) |tool| try std.testing.expect(!std.mem.eql(u8, tool.name, "learn_candidate"));
}

test "learn_candidate is root-only and cannot become a subagent tool" {
    var found = false;
    for (root_specs) |tool| if (std.mem.eql(u8, tool.name, "learn_candidate")) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expect(std.mem.indexOf(u8, learn_candidate_spec.desc, "adapters may send it") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_openai_sub, "learn_candidate") == null);
}

test "providerTakesEffort: native xAI grok takes effort; gateway grok does not" {
    try std.testing.expect(providerTakesEffort(.responses, "codex", "gpt-5.5"));
    try std.testing.expect(providerTakesEffort(.openai, "codegraff", "deepseek-v4-pro"));
    try std.testing.expect(providerTakesEffort(.openai, "deepseek", "deepseek-v4-pro"));
    try std.testing.expect(providerTakesEffort(.openai, "zai", "glm-5.3"));
    try std.testing.expect(providerTakesEffort(.openai, "vercel", "alibaba/qwen3.8-27b"));
    try std.testing.expect(providerTakesEffort(.openai, "openrouter", "anthropic/claude-sonnet-4.6"));
    try std.testing.expect(providerTakesEffort(.openai, "omlx", "any-downloaded-model"));
    try std.testing.expect(providerTakesEffort(.openai, "kimi", "k3"));
    try std.testing.expect(!providerTakesEffort(.openai, "openai", "gpt-5.5")); // direct openai chat
    try std.testing.expect(providerTakesEffort(.responses, "xai", "grok-4.6"));
    try std.testing.expect(providerTakesEffort(.openai, "xai", "grok-4.6")); // chat opt-out
    try std.testing.expect(!providerTakesEffort(.openai, "codegraff", "grok-build"));
}

test "agent_output: root-only (subagent/workflow's run_in_background has nothing to poll from inside a child), never doubles as a meta tool" {
    var found_root = false;
    for (root_specs) |t| if (std.mem.eql(u8, t.name, "agent_output")) {
        found_root = true;
    };
    try std.testing.expect(found_root);
    try std.testing.expect(!isMetaName("agent_output")); // dispatched like shell action=output, not handled inline

    // Subagents can't spawn subagents (execSubagent's from_sub gate), so they
    // can never mint an agent id to poll — keep it out of their own catalog
    // (tools_anthropic_sub is built from base_specs only).
    try std.testing.expect(std.mem.indexOf(u8, tools_anthropic_sub, "agent_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools_anthropic_sub, "subagent") == null);
}

test "subagent_spec: run_in_background is a boolean, optional (not in required), valid JSON alongside the rest of the schema" {
    try std.testing.expect(std.mem.indexOf(u8, subagent_spec.schema, "\"run_in_background\": {\"type\": \"boolean\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, subagent_spec.schema, .{});
    defer parsed.deinit();
    const required = parsed.value.object.get("required").?.array.items;
    for (required) |r| try std.testing.expect(!std.mem.eql(u8, r.string, "run_in_background"));
}

test "subagent_spec: independent fan-out defaults to worktree, not shared_cwd" {
    try std.testing.expect(std.mem.indexOf(u8, subagent_spec.schema, "fan-out children default to") != null);
    try std.testing.expect(std.mem.indexOf(u8, subagent_spec.schema, "worktree") != null);
    try std.testing.expect(std.mem.indexOf(u8, subagent_spec.schema, "Default shared_cwd") == null);
    try std.testing.expect(std.mem.indexOf(u8, workflow_spec.schema, "fan-out tasks default to") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow_spec.schema, "pipeline stages default to") != null);
}
