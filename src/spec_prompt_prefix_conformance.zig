//! Impl half of PromptPrefix: live `promptCatalog` is names + triggers,
//! sorted, no bodies / `file:` paths, and `skill` events do not rewrite
//! the pinned `g_skills` list that startup spliced into the prefix.

const std = @import("std");
const skill_docs = @import("skill_docs.zig");

const fixtures_json = @embedFile("spec_prompt_prefix");

fn cacheable(catalog: []const u8, pin: []const u8) bool {
    return std.mem.eql(u8, catalog, "names_only") and std.mem.eql(u8, pin, "once");
}

test "spec/prompt_prefix: cube matches names_only × once" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), cases.len);
    var hits: usize = 0;
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const cell = case.get("cell").?.object;
        const catalog = cell.get("catalog").?.string;
        const pin = cell.get("pin").?.string;
        const want = case.get("cacheable").?.bool;
        const got = cacheable(catalog, pin);
        if (want != got) {
            std.debug.print("\ncounterexample {s}: cacheable want={} got={}\n", .{ id, want, got });
            return error.CatalogMismatch;
        }
        if (got) hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
}

test "spec/prompt_prefix: live catalog is names + triggers, never bodies or paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shuffled = [_]skill_docs.Skill{
        .{ .name = "zeta", .desc = "z trigger", .body = "SECRET-BODY", .path = "/tmp/zeta/SKILL.md", .source = .personal },
        .{ .name = "alpha", .desc = "a trigger", .body = "MORE-SECRET", .path = "/tmp/alpha/SKILL.md", .source = .plugin },
    };
    const text = skill_docs.promptCatalog(arena, &shuffled);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zeta") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET-BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "MORE-SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "file:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/") == null);
    const alpha_at = std.mem.indexOf(u8, text, "alpha") orelse return error.TestUnexpectedResult;
    const zeta_at = std.mem.indexOf(u8, text, "zeta") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alpha_at < zeta_at);
}

test "spec/prompt_prefix: skill list/load do not rewrite the pinned g_skills prefix" {
    const prev = skill_docs.g_skills;
    defer skill_docs.g_skills = prev;
    const pinned = [_]skill_docs.Skill{
        .{ .name = "keep", .desc = "stays", .body = "", .source = .builtin },
    };
    skill_docs.g_skills = &pinned;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const before = skill_docs.promptCatalog(arena_state.allocator(), skill_docs.g_skills);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena_state.allocator(), "name", .{ .string = "keep" });
    const loaded = try skill_docs.execSkill(std.testing.allocator, std.testing.io, .{ .object = obj });
    defer std.testing.allocator.free(loaded.text);
    try std.testing.expect(!loaded.is_error);
    const listed = try skill_docs.execSkill(std.testing.allocator, std.testing.io, .{ .object = .empty });
    defer std.testing.allocator.free(listed.text);

    try std.testing.expectEqual(@as(usize, 1), skill_docs.g_skills.len);
    try std.testing.expectEqualStrings("keep", skill_docs.g_skills[0].name);
    try std.testing.expectEqualStrings(before, skill_docs.promptCatalog(arena_state.allocator(), skill_docs.g_skills));
}

test "spec/prompt_prefix: maximizing walk stays on names_only × once" {
    const prev = skill_docs.g_skills;
    defer skill_docs.g_skills = prev;
    const pinned = [_]skill_docs.Skill{
        .{ .name = "keep", .desc = "stays", .body = "SECRET-BODY", .path = "/tmp/keep/SKILL.md", .source = .builtin },
        .{ .name = "zeta", .desc = "later", .body = "MORE-SECRET", .path = "file:/tmp/zeta", .source = .plugin },
    };
    skill_docs.g_skills = &pinned;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = skill_docs.promptCatalog(arena, skill_docs.g_skills);
    try std.testing.expect(std.mem.indexOf(u8, start, "SECRET-BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, start, "MORE-SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, start, "file:") == null);
    try std.testing.expect(std.mem.indexOf(u8, start, "/") == null);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "keep" });
    const loaded = try skill_docs.execSkill(std.testing.allocator, std.testing.io, .{ .object = obj });
    defer std.testing.allocator.free(loaded.text);
    const listed = try skill_docs.execSkill(std.testing.allocator, std.testing.io, .{ .object = .empty });
    defer std.testing.allocator.free(listed.text);

    const after = skill_docs.promptCatalog(arena, skill_docs.g_skills);
    try std.testing.expectEqualStrings(start, after);
    try std.testing.expectEqual(@as(usize, 2), skill_docs.g_skills.len);
    try std.testing.expect(std.mem.indexOf(u8, after, "keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "zeta") != null);
}
