//! Fixture half of the wasm kernels. Lives outside kernel_catalog /
//! kernel_path so those stay freestanding (no `@embedFile` of spec/).

const std = @import("std");
const catalog = @import("kernel_catalog.zig");
const path = @import("kernel_path.zig");

test "kernel catalog matches exported tool_catalog fixtures" {
    const fixtures = @embedFile("spec_tool_catalog");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixtures, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;
    try std.testing.expectEqual(catalog.cube_cells, cases.len);

    for (cases) |case_v| {
        const case = case_v.object;
        const flags = case.get("flags").?.object;
        const f = catalog.Flags{
            .no_local = flags.get("no_local").?.bool,
            .lean = flags.get("lean").?.bool,
            .imagegen = flags.get("imagegen").?.bool,
            .clock_sleep = flags.get("clock_sleep").?.bool,
            .learn_loaded = flags.get("learn_loaded").?.bool,
            .is_sub = std.mem.eql(u8, flags.get("seat").?.string, "sub"),
        };
        var buf: [catalog.max_names][]const u8 = undefined;
        const got = buf[0..catalog.catalog(f, &buf)];
        const want = case.get("advertised").?.array.items;
        if (got.len != want.len) {
            std.debug.print("\ncounterexample {s}: len want={d} got={d}\n", .{
                case.get("id").?.string, want.len, got.len,
            });
            return error.CatalogMismatch;
        }
        for (want, got) |w, g| {
            if (!std.mem.eql(u8, w.string, g)) {
                std.debug.print("\ncounterexample {s}: name want={s} got={s}\n", .{
                    case.get("id").?.string, w.string, g,
                });
                return error.CatalogMismatch;
            }
        }
    }
}

test "kernel confined matches exported path_confine fixtures" {
    const fixtures = @embedFile("spec_path_confine");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixtures, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.array.items;
    try std.testing.expect(paths.len > 10);
    for (paths) |row_v| {
        const row = row_v.object;
        const p = row.get("path").?.string;
        const want = row.get("confined").?.bool;
        const got = path.confined(p);
        if (want != got) {
            std.debug.print("\ncounterexample confined {s}: want={} got={}\n", .{ p, want, got });
            return error.PathMismatch;
        }
    }
}
