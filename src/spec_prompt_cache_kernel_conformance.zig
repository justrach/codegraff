//! Impl half of the PromptCache kernel: every cell in
//! spec/kernels/prompt_cache.json must match promptCacheKey's partition
//! and the one-level spawn gate.

const std = @import("std");
const http_headers = @import("http_headers.zig");
const spawn_gate = @import("subagent_spawn.zig");

const fixtures_json = @embedFile("spec_prompt_cache");

fn labelOf(s: []const u8) []const u8 {
    return if (std.mem.eql(u8, s, "main")) "main" else "sub";
}

fn partitionOf(io: std.Io, label: []const u8, agent: *const anyopaque) []const u8 {
    var buf: [96]u8 = undefined;
    const key = http_headers.promptCacheKey(io, label, agent, &buf);
    const root = http_headers.projectRootId(io);
    if (std.mem.eql(u8, key, root)) return "root";
    return "child";
}

test "spec/prompt_cache: partition and spawn_ok match the export" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 48), cases.len);

    const io = std.testing.io;
    var root_slot: usize = 1;
    var child_slot: usize = 2;
    const root_agent: *const anyopaque = @ptrCast(&root_slot);
    const child_agent: *const anyopaque = @ptrCast(&child_slot);

    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const cell = case.get("cell").?.object;
        const label = labelOf(cell.get("label").?.string);
        const seat = cell.get("seat").?.string;
        const want_part = case.get("partition").?.string;
        const want_spawn = case.get("spawn_ok").?.bool;
        const agent: *const anyopaque = if (std.mem.eql(u8, label, "main")) root_agent else child_agent;
        const got_part = partitionOf(io, label, agent);
        if (!std.mem.eql(u8, want_part, got_part)) {
            std.debug.print("\ncounterexample {s}: partition want={s} got={s}\n", .{ id, want_part, got_part });
            return error.CatalogMismatch;
        }
        const got_spawn = spawn_gate.allowed(std.mem.eql(u8, seat, "sub"));
        if (want_spawn != got_spawn) {
            std.debug.print("\ncounterexample {s}: spawn_ok want={} got={}\n", .{ id, want_spawn, got_spawn });
            return error.CatalogMismatch;
        }
    }
}

test "spec/prompt_cache: isolation is not a promptCacheKey argument" {
    // The live function is (io, label, agent, buf). Isolation cannot mint a
    // key because it is not an input. Same label ⇒ same partition kind.
    const io = std.testing.io;
    var slot: usize = 7;
    const agent: *const anyopaque = @ptrCast(&slot);
    var a: [96]u8 = undefined;
    var b: [96]u8 = undefined;
    const main_a = http_headers.promptCacheKey(io, "main", agent, &a);
    const main_b = http_headers.promptCacheKey(io, "main", agent, &b);
    try std.testing.expectEqualStrings(main_a, main_b);
    try std.testing.expectEqualStrings(main_a, http_headers.projectRootId(io));
    var c: [96]u8 = undefined;
    var d: [96]u8 = undefined;
    const sub_a = http_headers.promptCacheKey(io, "sub", agent, &c);
    const sub_b = http_headers.promptCacheKey(io, "sub", agent, &d);
    try std.testing.expectEqualStrings(sub_a, sub_b);
    try std.testing.expect(!std.mem.eql(u8, main_a, sub_a));
}
