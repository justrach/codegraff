//! Impl half of PromptStable: OpenGauss must-nots against live gates.
//! Essay refresh is 0 (ADR 0005). Skills stay out of the prefix. The
//! system prompt has no per-request clock. Standing-line change busts
//! once; the same objective re-composes identically.

const std = @import("std");
const goal_state = @import("goal_state.zig");
const prompts = @import("prompts.zig");
const skill_docs = @import("skill_docs.zig");
const Agent = @import("agent.zig").Agent;

const fixtures_json = @embedFile("spec_prompt_stable");

fn keep(event: []const u8, land: []const u8) bool {
    const hist = std.mem.eql(u8, land, "history");
    const pref = std.mem.eql(u8, land, "prefix");
    if (std.mem.eql(u8, event, "turn") or std.mem.eql(u8, event, "skill_inject") or std.mem.eql(u8, event, "schema_load"))
        return hist;
    if (std.mem.eql(u8, event, "toolset_append") or std.mem.eql(u8, event, "compact"))
        return pref;
    return false;
}

test "spec/prompt_stable: cube matches 5 keep cells" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 20), cases.len);
    var hits: usize = 0;
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const cell = case.get("cell").?.object;
        const event = cell.get("event").?.string;
        const land = cell.get("land").?.string;
        const want = case.get("keep").?.bool;
        const got = keep(event, land);
        if (want != got) {
            std.debug.print("\ncounterexample {s}: keep want={} got={}\n", .{ id, want, got });
            return error.CatalogMismatch;
        }
        if (got) hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), hits);
}

test "spec/prompt_stable: standing essay never refreshes (OpenGauss: no mid-session rebuild)" {
    try std.testing.expectEqual(@as(u32, 0), goal_state.essay_refresh_turns);
    const first = goal_state.steeringGate("[standing goal: x]", 0, 0, 0);
    try std.testing.expect(first.inject);
    const again = goal_state.steeringGate("[standing goal: x]", first.fp, 99, 0);
    try std.testing.expect(!again.inject);
}

test "spec/prompt_stable: system prompt has no per-request clock" {
    const p = prompts.main_system_prompt;
    try std.testing.expect(std.mem.indexOf(u8, p, "Current date") == null);
    try std.testing.expect(std.mem.indexOf(u8, p, "current time") == null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Monday") == null);
}

test "spec/prompt_stable: same standing line re-composes; a change busts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const playbook = @import("playbook.zig");
    const saved = playbook.g_root_inject;
    playbook.g_root_inject = false;
    defer playbook.g_root_inject = saved;
    var agent: Agent = undefined;
    agent.goal = null;
    defer {
        agent.goal = null;
        prompts.pinStandingGoal(&agent, a);
    }
    try prompts.setSystemPrompts(&agent, "BASE", a);
    agent.goal = .{ .objective = "keep the build green", .status = .active };
    prompts.pinStandingGoal(&agent, a);
    const first = agent.sys_normal;
    prompts.pinStandingGoal(&agent, a);
    try std.testing.expectEqualStrings(first, agent.sys_normal);
    agent.goal = .{ .objective = "ship the release", .status = .active };
    prompts.pinStandingGoal(&agent, a);
    try std.testing.expect(!std.mem.eql(u8, first, agent.sys_normal));
}

test "spec/prompt_stable: skill load lands in history, not the prefix" {
    const prev = skill_docs.g_skills;
    defer skill_docs.g_skills = prev;
    const pinned = [_]skill_docs.Skill{
        .{ .name = "keep", .desc = "stays", .body = "SECRET-BODY", .path = "/tmp/keep/SKILL.md", .source = .builtin },
    };
    skill_docs.g_skills = &pinned;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const before = skill_docs.promptCatalog(arena_state.allocator(), skill_docs.g_skills);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena_state.allocator(), "name", .{ .string = "keep" });
    const loaded = try skill_docs.execSkill(std.testing.allocator, std.testing.io, .{ .object = obj });
    defer std.testing.allocator.free(loaded.text);
    try std.testing.expect(std.mem.indexOf(u8, loaded.text, "SECRET-BODY") != null);
    try std.testing.expectEqualStrings(before, skill_docs.promptCatalog(arena_state.allocator(), skill_docs.g_skills));
}
