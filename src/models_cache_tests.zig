//! Catalog parsing and precedence fixtures.

const std = @import("std");
const Value = std.json.Value;

pub fn numberFields(num_field: anytype, u64_field: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"i": 42, "f": 2.5, "neg": -3, "s": "x"}
    , .{ .allocate = .alloc_always });
    try std.testing.expectEqual(@as(f64, 42), num_field(value.object, "i").?);
    try std.testing.expectEqual(@as(f64, 2.5), num_field(value.object, "f").?);
    try std.testing.expect(num_field(value.object, "s") == null);
    try std.testing.expect(num_field(value.object, "missing") == null);
    try std.testing.expectEqual(@as(u64, 42), u64_field(value.object, "i"));
    try std.testing.expectEqual(@as(u64, 0), u64_field(value.object, "neg"));
    try std.testing.expectEqual(@as(u64, 0), u64_field(value.object, "missing"));
}

pub fn lazyCatalog(comptime Catalog: type, source: *[]const u8) !void {
    const previous_source = source.*;
    defer source.* = previous_source;
    var catalog: Catalog = .{ .codex_home = "" };
    catalog.ensure(std.testing.io, std.testing.allocator, std.testing.allocator, "", "", "");
    try std.testing.expect(catalog.loaded);
    catalog.invalidate();
    try std.testing.expect(!catalog.loaded);
}

pub fn canonicalVendor(find_model: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"reseller":{"models":{"gpt-5.6":{"limit":{"context":100},"cost":{"input":99,"output":99,"cache_read":9}}}},
        \\ "openai":{"models":{"gpt-5.6":{"limit":{"context":1050000},"cost":{"input":5,"output":30,"cache_read":0.5}}}}}
    , .{ .allocate = .alloc_always });
    const model = find_model(value.object, "gpt-5.6").?;
    try std.testing.expectEqual(@as(f64, 5), model.in);
    try std.testing.expectEqual(@as(u64, 1_050_000), model.context);
    try std.testing.expect(find_model(value.object, "gpt5.6") != null);
    try std.testing.expect(find_model(value.object, "no-such-model") == null);
}

pub fn visibleSnapshots(parse_snapshot: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snapshot = parse_snapshot(arena.allocator(),
        \\{"client_version":"9.9.9","models":[
        \\ {"slug":"future-sol","visibility":"list","context_window":372000},
        \\ {"slug":"future-hidden","visibility":"hide","context_window":999000},
        \\ {"slug":"future-luna","visibility":"list","context_window":128000},
        \\ {"slug":"future-luna","visibility":"list","context_window":1}]}
    ).?;
    try std.testing.expectEqualStrings("9.9.9", snapshot.client_version);
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqualStrings("future-sol", snapshot.models[0].name);
    try std.testing.expectEqual(@as(u64, 372_000), snapshot.models[0].context);
    try std.testing.expectEqualStrings("future-luna", snapshot.models[1].name);
    try std.testing.expectEqual(@as(u64, 128_000), snapshot.models[1].context);
}

pub fn versionFloor(floor: []const u8, effective_version: anytype, snapshot_matches: anytype) !void {
    try std.testing.expectEqualStrings(floor, effective_version("0.130.0", null));
    try std.testing.expectEqualStrings("0.145.0", effective_version("0.145.0", null));
    try std.testing.expectEqualStrings(floor, effective_version("invalid", null));
    try std.testing.expect(!snapshot_matches(.{
        .models = &.{},
        .client_version = "0.130.0",
    }, floor));
}
