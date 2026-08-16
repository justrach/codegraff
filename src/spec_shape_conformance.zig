//! Impl half of the shape kernel: ladderRung, decide(explicit), classOf.
//! Models the hand ladder + explicit arm, not admit/override/explore.

const std = @import("std");
const escalation = @import("escalation.zig");
const route_policy = @import("route_policy.zig");
const shapes = @import("shapes.zig");
const needles = @import("shape_needles.zig");

const fixtures_json = @embedFile("spec_shape");

fn observablesOf(st: std.json.ObjectMap) escalation.Observables {
    return .{
        .shape = route_policy.Shape.parse(st.get("shape").?.string),
        .files = if (st.get("files_lt3").?.bool) 2 else 3,
        .widest = if (st.get("widest_ge2").?.bool) 2 else 1,
        .audit = st.get("audit").?.bool,
        .prior_failure = st.get("prior_failure").?.bool,
        .prior_failure_count = @intCast(st.get("prior_count").?.integer),
        .verifier = if (st.get("has_verifier").?.bool) .diff else .none,
        .remaining = @intCast(st.get("remaining").?.integer),
        .cap = @intCast(st.get("cap").?.integer),
    };
}

fn liveNeedles(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "audit")) return &needles.audit;
    if (std.mem.eql(u8, name, "bugfix")) return &needles.bugfix;
    if (std.mem.eql(u8, name, "refactor")) return &needles.refactor;
    if (std.mem.eql(u8, name, "review")) return &needles.review;
    if (std.mem.eql(u8, name, "research")) return &needles.research;
    return &needles.feature;
}

test "spec/shape: ladderRung matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 1728), cases.len);
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

test "spec/shape: split budget admits adhoc fleet and refuses design" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const split = parsed.value.object.get("split").?.object;
    const rem: u64 = @intCast(split.get("remaining").?.integer);
    const cap: u64 = @intCast(split.get("cap").?.integer);
    const adhoc = escalation.Observables{ .shape = .adhoc, .files = 3, .widest = 2, .remaining = rem, .cap = cap };
    const design = escalation.Observables{ .shape = .design, .files = 3, .widest = 2, .remaining = rem, .cap = cap };
    const got_a = escalation.ladderRung(adhoc);
    const got_d = escalation.ladderRung(design);
    if (!std.mem.eql(u8, split.get("adhoc_ladder").?.string, got_a.label()) or
        !std.mem.eql(u8, split.get("design_ladder").?.string, got_d.label()))
    {
        std.debug.print("\ncounterexample split: adhoc={s} design={s}\n", .{ got_a.label(), got_d.label() });
        return error.CatalogMismatch;
    }
}

test "spec/shape: classOf uses the shared needle table" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const exported = parsed.value.object.get("needles").?.object;
    const names = [_][]const u8{ "audit", "bugfix", "refactor", "review", "research", "feature" };
    for (names) |name| {
        const want = exported.get(name).?.array.items;
        const got = liveNeedles(name);
        if (want.len != got.len) {
            std.debug.print("\ncounterexample needles {s}: len want={} got={}\n", .{ name, want.len, got.len });
            return error.CatalogMismatch;
        }
        for (want, got) |w, g| {
            if (!std.mem.eql(u8, w.string, g)) {
                std.debug.print("\ncounterexample needles {s}: want={s} got={s}\n", .{ name, w.string, g });
                return error.CatalogMismatch;
            }
        }
    }
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
