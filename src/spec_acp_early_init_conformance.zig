//! Impl half of AcpEarlyInit: the fixture's step table drives the REAL
//! `acp_early.step`, and every cube cell's request runs through the real
//! engine twice — the late path (live dispatch) and the early path (boundary
//! answer from the shared reader, then the loop-start replay with its output
//! discarded). Bytes and latches must be identical, and match the model.

const std = @import("std");
const Value = std.json.Value;
const early = @import("acp_early.zig");
const harness = @import("acp_early_tests.zig");
const v2 = @import("acp_v2.zig");

const fixtures_json = @embedFile("spec_acp_early_init");

fn str(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return o.get(key).?.string;
}

fn boolean(o: std.json.ObjectMap, key: []const u8) bool {
    return o.get(key).?.bool;
}

fn names(comptime E: type, list: []const Value) !void {
    const fields = comptime std.meta.fieldNames(E);
    try std.testing.expectEqual(fields.len, list.len);
    for (fields, 0..) |name, i| try std.testing.expectEqualStrings(name, list[i].string);
}

test "spec/acp_early_init: the step table is the Zig step" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const root = try std.json.parseFromSliceLeaky(Value, state.allocator(), fixtures_json, .{});
    const universe = root.object.get("universe").?.object;
    try names(early.State, universe.get("states").?.array.items);
    try names(early.Line, universe.get("lines").?.array.items);
    try names(early.Action, universe.get("actions").?.array.items);
    const rows = root.object.get("step").?.array.items;
    try std.testing.expectEqual(std.enums.values(early.State).len * (2 * std.enums.values(early.Line).len + 3), rows.len);
    for (rows) |row_v| {
        const row = row_v.object;
        const s = std.meta.stringToEnum(early.State, str(row, "state")).?;
        const ev = row.get("event").?.object;
        const kind = str(ev, "kind");
        const e: early.Event = if (std.mem.eql(u8, kind, "loop_start"))
            .loop_start
        else if (std.mem.eql(u8, kind, "sent"))
            .{ .sent = boolean(ev, "ok") }
        else
            .{ .boundary = .{ .acp = boolean(ev, "acp"), .line = std.meta.stringToEnum(early.Line, str(ev, "line")).? } };
        const got = early.step(s, e);
        try std.testing.expectEqualStrings(str(row, "next"), @tagName(got.next));
        try std.testing.expectEqualStrings(str(row, "action"), @tagName(got.action));
    }
}

test "spec/acp_early_init: early answer + replay equals the late path in every cube cell" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const root = try std.json.parseFromSliceLeaky(Value, a, fixtures_json, .{});
    const cases = root.object.get("cases").?.array.items;
    try std.testing.expect(cases.len >= 360);
    const saved = v2.gate;
    defer v2.gate = saved;
    defer harness.resetLatches();
    for (cases) |cell_v| {
        var cell_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer cell_arena.deinit();
        const ca = cell_arena.allocator();
        const cell = cell_v.object;
        v2.gate = boolean(cell, "gate");
        const can_load = boolean(cell, "can_load");
        const line = str(cell, "request");
        const late = try harness.late(ca, line, can_load, 0x5eed);
        const got = try harness.earlyThenReplay(ca, line, can_load, 0x5eed);
        std.testing.expectEqualStrings(late.bytes, got.bytes) catch |err| {
            std.debug.print("cell {s}\n", .{str(cell, "id")});
            return err;
        };
        try std.testing.expectEqual(late.latches, got.latches);

        // Both match the model's response and latches.
        const want = cell.get("response").?.object;
        const resp = (try std.json.parseFromSliceLeaky(Value, ca, std.mem.trimEnd(u8, got.bytes, "\n"), .{})).object.get("result").?.object;
        try std.testing.expectEqual(want.get("protocol_version").?.integer, resp.get("protocolVersion").?.integer);
        try std.testing.expectEqual(boolean(want, "v2_shape"), resp.get("info") != null);
        const usage = if (std.mem.indexOf(u8, got.bytes, "\"codegraff/usage\":true") != null) true else if (std.mem.indexOf(u8, got.bytes, "\"codegraff/usage\":false") != null) false else return error.NoUsageMarker;
        try std.testing.expectEqual(boolean(want, "can_load"), usage);
        try std.testing.expectEqual(boolean(want, "auth_terminal"), std.mem.indexOf(u8, got.bytes, "graff-login") != null);
        const lat = cell.get("latches").?.object;
        try std.testing.expectEqual(boolean(lat, "v2"), got.latches.v2);
        try std.testing.expectEqual(boolean(lat, "t3"), got.latches.t3);
        try std.testing.expectEqual(boolean(lat, "elicit"), got.latches.elicit != .none);
        try std.testing.expectEqual(boolean(lat, "compaction"), got.latches.compaction);
        try std.testing.expectEqual(boolean(lat, "subagents"), got.latches.subagents);
        try std.testing.expectEqual(boolean(lat, "bg"), got.latches.background_subagents);
    }
}
