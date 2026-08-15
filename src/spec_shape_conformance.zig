//! Impl half of the shape kernel: ladderRung, decide(explicit), classOf.

const std = @import("std");
const escalation = @import("escalation.zig");
const route_policy = @import("route_policy.zig");
const shapes = @import("shapes.zig");

const fixtures_json = @embedFile("spec_shape");

fn observablesOf(st: std.json.ObjectMap) escalation.Observables {
    const affordable = st.get("fleet_affordable").?.bool;
    return .{
        .shape = route_policy.Shape.parse(st.get("shape").?.string),
        .files = if (st.get("files_lt3").?.bool) 2 else 3,
        .widest = if (st.get("widest_ge2").?.bool) 2 else 1,
        .audit = st.get("audit").?.bool,
        .prior_failure = st.get("prior_failure").?.bool,
        .prior_failure_count = @intCast(st.get("prior_count").?.integer),
        .verifier = if (st.get("has_verifier").?.bool) .diff else .none,
        // cap must be nonzero: cap 0 is unlimited and remaining 0 still fits.
        .remaining = if (affordable) 1_000_000 else 0,
        .cap = 1_000_000,
    };
}

test "spec/shape: ladderRung matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 1152), cases.len);
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const got = escalation.ladderRung(observablesOf(case.get("obs").?.object));
        const want = case.get("ladder").?.string;
        if (!std.mem.eql(u8, want, got.label())) {
            std.debug.print("\ncounterexample {s}: ladder want={s} got={s}\n", .{ id, want, got.label() });
            return error.CatalogMismatch;
        }
    }
}

test "spec/shape: explicit decide never trades below R2" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const o = observablesOf(case.get("obs").?.object);
        const d = escalation.decide(o, &.{}, true, &.{}, .{});
        const want = case.get("explicit").?.string;
        if (d.source != .explicit or !std.mem.eql(u8, want, d.rung.label()) or d.rung.level() < 3) {
            std.debug.print("\ncounterexample {s}: explicit want={s} got={s} src={s}\n", .{ id, want, d.rung.label(), d.source.label() });
            return error.CatalogMismatch;
        }
    }
}

test "spec/shape: classOf precedence matches the Lean needles" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("class_cases").?.array.items;
    try std.testing.expect(cases.len >= 6);
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const got = shapes.classOf(case.get("raw").?.string);
        const want = case.get("class").?.string;
        if (!std.mem.eql(u8, want, got.label())) {
            std.debug.print("\ncounterexample {s}: class want={s} got={s}\n", .{ id, want, got.label() });
            return error.CatalogMismatch;
        }
    }
}
