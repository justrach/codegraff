const std = @import("std");
const prompts = @import("prompts.zig");
const agent_mod = @import("agent.zig");
const playbook = @import("playbook.zig");

test "pinStandingGoal: active objective rides the prefix; paused and cleared disarm" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = playbook.g_root_inject;
    playbook.g_root_inject = false; // composeRoot would need a live io
    defer playbook.g_root_inject = saved;
    var agent: agent_mod.Agent = undefined;
    agent.goal = null;
    defer {
        agent.goal = null;
        prompts.pinStandingGoal(&agent, a);
    }
    try prompts.setSystemPrompts(&agent, "BASE", a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "[standing goal:") == null);
    agent.goal = .{ .objective = "keep the build green", .status = .active };
    prompts.pinStandingGoal(&agent, a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "[standing goal: keep the build green]") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "BASE") != null);
    agent.goal = .{ .objective = "keep the build green", .status = .paused };
    prompts.pinStandingGoal(&agent, a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "[standing goal:") == null);
    agent.goal = null;
    prompts.pinStandingGoal(&agent, a);
}
