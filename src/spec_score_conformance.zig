//! Impl half of the score kernel: stageScore, roleOf/canonicalSlot,
//! normalizeOutboundScore, and the providerClass needle table.

const std = @import("std");
const scoring = @import("scoring.zig");
const shapes = @import("shapes.zig");
const route_policy = @import("route_policy.zig");
const pipeline_score = @import("pipeline_score.zig");

const fixtures_json = @embedFile("spec_score");

fn titleOf(slot: []const u8) []const u8 {
    if (std.mem.eql(u8, slot, "none")) return "ponder";
    return slot;
}

fn slotName(got: []const u8) []const u8 {
    return if (got.len == 0) "none" else got;
}

fn asF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

test "spec/score: filing gate matches stageScore + roleOf" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 1210), cases.len);
    var filed: usize = 0;
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const fleet = case.get("fleet").?.bool;
        const label = case.get("label").?.string;
        const niche = case.get("niche").?.string;
        const attempted: u32 = @intCast(case.get("attempted").?.integer);
        const ok_n: u32 = @intCast(case.get("ok").?.integer);
        const role = route_policy.roleOf(titleOf(label), titleOf(niche));
        const signal = pipeline_score.stageScore(attempted, ok_n);
        const got = fleet and role.len > 0 and signal != null;
        const want = case.get("files").?.bool;
        if (got != want or !std.mem.eql(u8, slotName(role), case.get("role").?.string)) {
            std.debug.print("\ncounterexample {s}: files want={} got={} role want={s} got={s}\n", .{ id, want, got, case.get("role").?.string, slotName(role) });
            return error.CatalogMismatch;
        }
        if (want) filed += 1;
    }
    const want_filed: usize = @intCast(parsed.value.object.get("filed").?.integer);
    try std.testing.expectEqual(want_filed, filed);
    try std.testing.expectEqual(@as(usize, 240), filed);
}

test "spec/score: canonical slots and titles match the live scan" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const slots = parsed.value.object.get("slots").?.array.items;
    try std.testing.expectEqual(shapes.canonical_slots.len, slots.len);
    for (slots, shapes.canonical_slots) |sv, live| {
        if (!std.mem.eql(u8, sv.string, live)) {
            std.debug.print("\ncounterexample slots: want={s} got={s}\n", .{ live, sv.string });
            return error.CatalogMismatch;
        }
        if (!std.mem.eql(u8, live, scoring.telemetrySlot(live))) {
            std.debug.print("\ncounterexample telemetrySlot dropped {s}\n", .{live});
            return error.CatalogMismatch;
        }
    }
    try std.testing.expectEqualStrings("", scoring.telemetrySlot("ponder"));
    const titles = parsed.value.object.get("titles").?.array.items;
    for (titles) |tv| {
        const t = tv.object;
        const got = slotName(shapes.canonicalSlot(t.get("title").?.string));
        const want = t.get("slot").?.string;
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("\ncounterexample title {s}: want={s} got={s}\n", .{ t.get("title").?.string, want, got });
            return error.CatalogMismatch;
        }
    }
}

test "spec/score: normalizeOutboundScore matches the scale samples" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const scale = parsed.value.object.get("scale").?.array.items;
    for (scale) |sv| {
        const s = sv.object;
        const id = s.get("id").?.string;
        const raw = asF64(s.get("raw").?);
        const got = scoring.normalizeOutboundScore(raw);
        const milli_v = s.get("milli").?;
        if (milli_v == .null) {
            if (got != null) {
                std.debug.print("\ncounterexample scale {s}: want reject got={d}\n", .{ id, got.? });
                return error.CatalogMismatch;
            }
            continue;
        }
        const want = @as(f64, @floatFromInt(milli_v.integer)) / 1000.0;
        if (got) |g| {
            if (@abs(g - want) > 1e-12) {
                std.debug.print("\ncounterexample scale {s}: want={d} got={d}\n", .{ id, want, g });
                return error.CatalogMismatch;
            }
        } else {
            std.debug.print("\ncounterexample scale {s}: want={d} got reject\n", .{ id, want });
            return error.CatalogMismatch;
        }
    }
}

test "spec/score: providerClass needles match; fallback stays unknown" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const classes = parsed.value.object.get("classes").?.array.items;
    try std.testing.expectEqual(@as(usize, 16), classes.len);
    for (classes) |cv| {
        const c = cv.object;
        const id = c.get("id").?.string;
        const want = c.get("tier").?.string;
        const source = c.get("source").?.string;
        if (std.mem.eql(u8, source, "fallback")) {
            try std.testing.expectEqualStrings("unknown", want);
            continue;
        }
        const got = scoring.providerClass(id);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("\ncounterexample class {s}: want={s} got={s}\n", .{ id, want, got });
            return error.CatalogMismatch;
        }
    }
}
