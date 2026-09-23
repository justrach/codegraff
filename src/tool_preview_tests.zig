//! Source-range and bounded-evidence regressions for spilled tool results.
const std = @import("std");
const handle = @import("tool_handle.zig");
const preview = @import("handle_preview.zig");

fn fixture(a: std.mem.Allocator, early: bool, tail: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (0..3000) |i| {
        if (early and i == 25) try out.writer.writeAll("ERROR omitted-first\n") else if (tail and i == 2999) try out.writer.writeAll("ERROR tail-evidence\n") else try out.writer.print("line {d}\n", .{i});
    }
    return out.writer.buffered();
}

fn render(a: std.mem.Allocator, tmp: *std.testing.TmpDir, text: []const u8) ![]const u8 {
    const got = try handle.forResult(std.testing.allocator, a, .{ .io = std.testing.io, .dir = tmp.dir, .run_id = "test" }, text, 4096);
    try std.testing.expect(got.path != null);
    try std.testing.expectEqual(text.len, got.bytes);
    try std.testing.expect(got.text.len <= 4096);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got.text));
    const stored = try tmp.dir.readFileAlloc(std.testing.io, handle.handles_dir ++ "/tr_0.txt", a, .limited(1 << 20));
    try std.testing.expectEqualStrings(text, stored);
    return got.text;
}

test "spill preview retains first omitted error using original source offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    handle.resetForTest();
    defer handle.resetForTest();
    const text = try fixture(arena.allocator(), true, false);
    const got = try render(arena.allocator(), &tmp, text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "ERROR omitted-first"));
}

test "spill preview does not duplicate error lines already in its tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    handle.resetForTest();
    defer handle.resetForTest();
    const text = try fixture(arena.allocator(), false, true);
    const got = try render(arena.allocator(), &tmp, text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "ERROR tail-evidence"));
}

test "spill preview skips oversized notable line but retains later whole UTF8 evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const large = try a.alloc(u8, 8192);
    @memset(large, 'x');
    const text = try std.fmt.allocPrint(a, "ERROR {s}\nERROR café 原因\nERROR final\n", .{large});
    var storage: [512]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&storage);
    const got = try preview.notableExcerpt(bounded.allocator(), text, 0, 128);
    try std.testing.expect(std.mem.indexOf(u8, got, "ERROR café 原因\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ERROR final\n") != null);
    try std.testing.expect(got.len <= 128);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "spill preview whole UTF8 lines survive both omitted boundaries and prefix fallback" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const text = "visible\nERROR café 原因\nERROR tail crossing\nERROR fully visible tail\n";
    const from = std.mem.indexOf(u8, text, "é").? + 1;
    const until = std.mem.indexOf(u8, text, "crossing").? + 2;
    const got = try preview.notableRange(arena.allocator(), text, from, until, 256);
    try std.testing.expect(std.mem.indexOf(u8, got, "ERROR café 原因\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ERROR tail crossing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "fully visible tail") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    const fully_shown = "ERROR shown\nERROR omitted\n";
    const at_newline = try preview.notableRange(arena.allocator(), fully_shown, "ERROR shown".len, fully_shown.len, 256);
    try std.testing.expect(std.mem.indexOf(u8, at_newline, "ERROR shown") == null);
    try std.testing.expect(std.mem.indexOf(u8, at_newline, "ERROR omitted") != null);
    const prefix = preview.prefixPreview(text, from);
    try std.testing.expectEqual(prefix.text.len, prefix.omitted_start);
    try std.testing.expectEqual(text.len, prefix.omitted_end);
    try std.testing.expect(std.unicode.utf8ValidateSlice(prefix.text));
    const fallback = try preview.notableRange(arena.allocator(), text, prefix.omitted_start, prefix.omitted_end, 256);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "ERROR café 原因\n") != null);
}
