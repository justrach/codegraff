//! Impl half of PathConfine: confinedPath, ownerVerdict, destructiveGitAllowed.

const std = @import("std");
const policy = @import("harness_policy.zig");
const lease = @import("worktree_lease.zig");
const proc_identity = @import("proc_identity.zig");

const fixtures_json = @embedFile("spec_path_confine");

fn probeOf(name: []const u8) proc_identity.Probe {
    if (std.mem.eql(u8, name, "gone")) return .gone;
    if (std.mem.eql(u8, name, "unknown")) return .unknown;
    if (std.mem.eql(u8, name, "match")) return .{ .id = 777 };
    return .{ .id = 778 }; // mismatch
}

fn identitiesOf(kind: []const u8) struct { rec: []const u8, mine: []const u8 } {
    if (std.mem.eql(u8, kind, "both_empty")) return .{ .rec = "", .mine = "" };
    if (std.mem.eql(u8, kind, "rec_empty")) return .{ .rec = "", .mine = "/repo/.git" };
    if (std.mem.eql(u8, kind, "mine_empty")) return .{ .rec = "/repo/.git", .mine = "" };
    if (std.mem.eql(u8, kind, "differ")) return .{ .rec = "/repo/.git", .mine = "/repo/.git/worktrees/wt1" };
    return .{ .rec = "/repo/.git", .mine = "/repo/.git" };
}

fn verdictName(v: lease.OwnerVerdict) []const u8 {
    return switch (v) {
        .self => "self",
        .other_worktree => "other_worktree",
        .live_foreign => "live_foreign",
        .live_unverified => "live_unverified",
        .stale_dead => "stale_dead",
        .stale_unverifiable => "stale_unverifiable",
    };
}

test "spec/path_confine: confinedPath matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.array.items;
    try std.testing.expect(paths.len > 10);
    for (paths) |row_v| {
        const row = row_v.object;
        const path = row.get("path").?.string;
        const want = row.get("confined").?.bool;
        const got = policy.confinedPath(path);
        if (want != got) {
            std.debug.print("\ncounterexample confinedPath {s}: want={} got={}\n", .{ path, want, got });
            return error.CatalogMismatch;
        }
    }
}

test "spec/path_confine: ownerVerdict matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("leases").?.array.items;
    try std.testing.expectEqual(@as(usize, 80), cases.len);
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const st = case.get("lease").?.object;
        const ids = identitiesOf(st.get("identities").?.string);
        const rec: lease.Owner = .{
            .pid = 4242,
            .start_id = if (st.get("start_zero").?.bool) 0 else 777,
            .session_id = "s-1",
            .identity = ids.rec,
        };
        const my_pid: i32 = if (st.get("pid_self").?.bool) 4242 else 99;
        const got = verdictName(lease.ownerVerdict(rec, ids.mine, my_pid, probeOf(st.get("probe").?.string)));
        const want = case.get("verdict").?.string;
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("\ncounterexample {s}: verdict want={s} got={s}\n", .{ id, want, got });
            return error.CatalogMismatch;
        }
    }
}

test "spec/path_confine: destructiveGitAllowed is yolo and not sub" {
    try std.testing.expect(policy.destructiveGitAllowed(true, false));
    try std.testing.expect(!policy.destructiveGitAllowed(true, true));
    try std.testing.expect(!policy.destructiveGitAllowed(false, false));
    try std.testing.expect(!policy.destructiveGitAllowed(false, true));
}
