//! Policy reachability, not a claim that a scripted model exercises judgment.
const std = @import("std");
const prompts = @import("prompts.zig");
const text = @import("prompt_text.zig");
const no_local = @import("no_local_tools.zig");

test "#739 publication safety survives capability removal and lean; workers share it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved = no_local.lean;
    defer no_local.lean = saved;
    for ([_]bool{ false, true }) |lean| {
        no_local.lean = lean;
        const floor = try prompts.composeSegments(arena.allocator(), .{
            .local_tools = false,
            .subagents = false,
            .todos = false,
            .constraints = false,
            .git_repo = false,
        });
        for ([_][]const u8{ floor, prompts.sub_system_prompt, prompts.main_system_prompt_strict }) |policy| {
            try std.testing.expect(std.mem.indexOf(u8, policy, text.public_write_note) != null);
            try std.testing.expect(std.mem.indexOf(u8, policy, text.constraint_authority_note) != null);
        }
    }
    for ([_][]const u8{
        "Immediately before each outbound write", "exact payload",           "identifiers inside errors or logs",
        "explicit disclosure approval",           "not disclosure approval", "Never disclose secrets",
        "agent-composed telemetry/reporting",     "through ANY tool",        "through its orchestrator",
    }) |required| try std.testing.expect(std.mem.indexOf(u8, text.public_write_note, required) != null);
}

test "#738 summaries are not the recorded-policy authority; style overrides are immediate" {
    for ([_][]const u8{
        "ledger is authoritative",       "not proof of recording", "an actual user instruction",
        "bounded view",                  "defaults immediately",   "optional commit attribution",
        "do not override secret-safety",
    }) |required| try std.testing.expect(std.mem.indexOf(u8, text.constraint_authority_note, required) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.compact_instruction, "Do not write that a") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.compact_instruction, "in full") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.git_authoring_note, "omit this optional attribution") != null);
}

test "#739 custom worker and review personas cannot remove standing policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var agent: @import("agent.zig").Agent = undefined;
    agent.arena = arena.allocator();
    agent.sys_override = "CUSTOM_PERSONA";
    for ([_]bool{ false, true }) |review| {
        agent.review_mode = review;
        agent.sub = !review;
        const policy = agent.systemPrompt();
        try std.testing.expect(std.mem.startsWith(u8, policy, "CUSTOM_PERSONA"));
        try std.testing.expect(std.mem.indexOf(u8, policy, text.public_write_note) != null);
        try std.testing.expect(std.mem.indexOf(u8, policy, text.constraint_authority_note) != null);
        try std.testing.expectEqual(policy.ptr, text.withAuthority(agent.arena, policy).ptr);
    }
    var storage: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectEqualStrings(text.public_write_note ++ text.constraint_authority_note, text.withAuthority(failing.allocator(), "CUSTOM_PERSONA"));
}

test "#738 failed prompt allocation never installs only some variants" {
    const playbook = @import("playbook.zig");
    const saved = playbook.g_root_inject;
    defer playbook.g_root_inject = saved;
    playbook.g_root_inject = false;
    var agent: @import("agent.zig").Agent = undefined;
    agent.sys_base = "old-base";
    agent.sys_normal = "old-normal";
    agent.sys_strict = "old-strict";
    agent.sys_ultra = "old-ultra";
    agent.sys_ultra_strict = "old-ultra-strict";
    var buffer: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expectError(error.OutOfMemory, prompts.setSystemPrompts(&agent, "new-base", failing.allocator()));
    try std.testing.expectEqualStrings("old-base", agent.sys_base);
    try std.testing.expectEqualStrings("old-normal", agent.sys_normal);
    try std.testing.expectEqualStrings("old-strict", agent.sys_strict);
    try std.testing.expectEqualStrings("old-ultra", agent.sys_ultra);
    try std.testing.expectEqualStrings("old-ultra-strict", agent.sys_ultra_strict);
}
