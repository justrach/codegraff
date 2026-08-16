//! Impl half of BashPolicy: live isSimple / escapesCwd / readOnlyAllowed.

const std = @import("std");
const policy = @import("harness_policy.zig");

const fixtures_json = @embedFile("spec_bash_policy");

test "spec/bash_policy: seed table matches read_only_seed" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const seed = parsed.value.object.get("seed").?.array.items;
    try std.testing.expectEqual(policy.read_only_seed.len, seed.len);
    for (seed, policy.read_only_seed) |sv, live| {
        if (!std.mem.eql(u8, sv.string, live)) {
            std.debug.print("\ncounterexample seed: want={s} got={s}\n", .{ live, sv.string });
            return error.CatalogMismatch;
        }
    }
}

test "spec/bash_policy: live predicates match the export" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 32), cases.len);
    for (cases) |case_v| {
        const case = case_v.object;
        const cmd = case.get("cmd").?.string;
        const id = case.get("id").?.string;
        const simple = policy.isSimple(cmd);
        const escapes = policy.escapesCwd(cmd);
        const allowed = policy.readOnlyAllowed(cmd);
        const external = policy.readOnlyExternal(cmd);
        if (simple != case.get("simple").?.bool or
            escapes != case.get("escapes").?.bool or
            allowed != case.get("allowed").?.bool or
            external != case.get("external").?.bool)
        {
            std.debug.print(
                "\ncounterexample {s}: simple {}/{} escapes {}/{} allowed {}/{} external {}/{}\n",
                .{
                    id,
                    case.get("simple").?.bool,
                    simple,
                    case.get("escapes").?.bool,
                    escapes,
                    case.get("allowed").?.bool,
                    allowed,
                    case.get("external").?.bool,
                    external,
                },
            );
            return error.CatalogMismatch;
        }
    }
}
