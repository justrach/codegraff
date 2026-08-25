//! Impl half of spec/conformance.py: every cell in
//! spec/kernels/tool_catalog.json must match effectiveRootSpecs / subToolsJson.
//! A mismatch prints the cell id and the first differing name.

const std = @import("std");
const schema = @import("schema.zig");
const tool_gates = @import("tool_gates.zig");
const no_local_tools = @import("no_local_tools.zig");
const imagegen = @import("imagegen.zig");
const learn_store = @import("learn_store.zig");
const root = @import("main.zig");

const fixtures_json = @embedFile("spec_tool_catalog");

fn namesFromSpecs(arena: std.mem.Allocator, specs: []const schema.ToolSpec) ![]const []const u8 {
    const out = try arena.alloc([]const u8, specs.len);
    for (specs, 0..) |spec, i| out[i] = spec.name;
    return out;
}

fn namesFromSubJson(gpa: std.mem.Allocator, arena: std.mem.Allocator, gated: bool) ![]const []const u8 {
    const raw = schema.subToolsJson(.anthropic, gated);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    const out = try arena.alloc([]const u8, arr.len);
    for (arr, 0..) |item, i| {
        const name = item.object.get("name") orelse return error.MissingName;
        out[i] = try arena.dupe(u8, name.string);
    }
    return out;
}

fn expectEqualNames(id: []const u8, want: []const std.json.Value, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("\ncounterexample {s}: len want={d} got={d}\n  want ", .{ id, want.len, got.len });
        for (want) |n| std.debug.print("{s} ", .{n.string});
        std.debug.print("\n  got  ", .{});
        for (got) |n| std.debug.print("{s} ", .{n});
        std.debug.print("\n", .{});
        return error.CatalogMismatch;
    }
    for (want, got) |w, g| {
        if (!std.mem.eql(u8, w.string, g)) {
            std.debug.print("\ncounterexample {s}: name want={s} got={s}\n", .{ id, w.string, g });
            return error.CatalogMismatch;
        }
    }
}

test "spec/tool_catalog: implementation matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();

    const rlm = @import("rlm.zig");
    const saved_local = no_local_tools.enabled;
    const saved_lean = no_local_tools.lean;
    const saved_img = imagegen.available;
    const saved_clock = root.g_clock_sleep;
    const saved_learn = learn_store.active_agent_loaded;
    const saved_rlm = rlm.available;
    defer {
        no_local_tools.enabled = saved_local;
        no_local_tools.lean = saved_lean;
        imagegen.available = saved_img;
        root.g_clock_sleep = saved_clock;
        learn_store.active_agent_loaded = saved_learn;
        rlm.available = saved_rlm;
        rlm.sync();
    }
    // The 64-cell kernel is the structured catalog (`--old`). rlm is a
    // session overlay (ADR 0022) and must not grow this cube.
    rlm.available = false;
    rlm.sync();

    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expect(cases.len == 64);

    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const flags = case.get("flags").?.object;
        no_local_tools.enabled = flags.get("no_local").?.bool;
        no_local_tools.lean = flags.get("lean").?.bool;
        imagegen.available = flags.get("imagegen").?.bool;
        root.g_clock_sleep = flags.get("clock_sleep").?.bool;
        learn_store.active_agent_loaded = flags.get("learn_loaded").?.bool;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const want = case.get("advertised").?.array.items;
        const seat = flags.get("seat").?.string;
        const got = if (std.mem.eql(u8, seat, "sub"))
            try namesFromSubJson(gpa, arena, no_local_tools.enabled)
        else
            try namesFromSpecs(arena, try schema.effectiveRootSpecs(arena));
        try expectEqualNames(id, want, got);
    }

    // Reachability: the spec module is what the Lean/Python side talks about.
    _ = tool_gates.advertised;
}
