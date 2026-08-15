//! Impl half of the transport kernel: every cell in
//! spec/kernels/transport.json must match `transport_gate.eligible`.

const std = @import("std");
const gate = @import("transport_gate.zig");

const fixtures_json = @embedFile("spec_transport");

test "spec/transport: wsEligible matches executable semantics" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();

    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 96), cases.len);

    var ws_cells: usize = 0;
    for (cases) |case_v| {
        const case = case_v.object;
        const id = case.get("id").?.string;
        const turn = case.get("turn").?.object;
        const kind = gate.kindFromName(turn.get("kind").?.string) orelse {
            std.debug.print("\ncounterexample {s}: unknown kind\n", .{id});
            return error.CatalogMismatch;
        };
        const got = gate.eligible(.{
            .kind = kind,
            .is_sub = turn.get("is_sub").?.bool,
            .codex_ws = turn.get("codex_ws").?.bool,
            .ws_off = turn.get("ws_off").?.bool,
            .has_out = turn.get("has_out").?.bool,
            .quiet = turn.get("quiet").?.bool,
        });
        const want = case.get("eligible").?.bool;
        if (got != want) {
            std.debug.print("\ncounterexample {s}: eligible want={} got={}\n", .{ id, want, got });
            return error.CatalogMismatch;
        }
        if (got) ws_cells += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ws_cells);
}
