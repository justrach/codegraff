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

test "normalizeResponsesHistory spills full oversized results once before the wire cap" {
    const messages = @import("messages.zig");
    const spill = @import("tool_spill.zig");
    const reader = @import("result_read.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    handle.resetForTest();
    defer handle.resetForTest();
    spill.resetForTest();
    defer spill.resetForTest();
    spill.enable(.{ .io = std.testing.io, .dir = tmp.dir, .base_abs = "" });
    var history = std.json.Array.init(a);
    const needle = "RECOVERABLE_MIDDLE_1526";
    const footer = "\nTests: 19 passed, 1 failed\n[exit code 1]\n";
    // The smaller result passed tool-time handling's 64 KiB threshold, but
    // still hit the old 16 KiB wire cut. Also cover much larger legacy text.
    for ([_]usize{ 32 * 1024, 260 * 1024 }, 0..) |size, i| {
        const full = try a.alloc(u8, size);
        @memset(full, 'x');
        @memcpy(full[size / 2 ..][0..needle.len], needle);
        @memcpy(full[size - footer.len ..], footer);
        try history.append(try messages.toolResultMessage(a, .responses, "call", full, false));
        messages.normalizeResponsesHistory(a, &history);
        const stub = history.items[i].object.get("output").?.string;
        try std.testing.expect(stub.len <= 16384);
        try std.testing.expect(std.unicode.utf8ValidateSlice(stub));
        try std.testing.expect(std.mem.indexOf(u8, stub, needle) == null);
        try std.testing.expect(std.mem.indexOf(u8, stub, footer) != null);
        try std.testing.expectEqualStrings("call", history.items[i].object.get("call_id").?.string);
        const id = try std.fmt.allocPrint(a, "tr_{d}", .{i});
        try std.testing.expect(std.mem.indexOf(u8, stub, id) != null);
        const rel = try reader.resolveRel(a, id);
        const stored = try tmp.dir.readFileAlloc(std.testing.io, rel, a, .limited(1 << 20));
        try std.testing.expectEqualStrings(full, stored);
        messages.normalizeResponsesHistory(a, &history);
        try std.testing.expectEqualStrings(stub, history.items[i].object.get("output").?.string);
    }
    var dir = try tmp.dir.openDir(std.testing.io, handle.handles_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "normalizeResponsesHistory reports unavailable storage without inventing a handle" {
    const messages = @import("messages.zig");
    const spill = @import("tool_spill.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    handle.resetForTest();
    defer handle.resetForTest();
    const saved_budget = handle.run_cap_bytes;
    defer handle.run_cap_bytes = saved_budget;
    spill.resetForTest();
    defer spill.resetForTest();
    const full = try a.alloc(u8, 32768);
    @memset(full, 'x');
    for ([_]bool{ false, true }) |wired| {
        if (wired) {
            spill.enable(.{ .io = std.testing.io, .dir = tmp.dir, .base_abs = "" });
            handle.run_cap_bytes = 1;
        }
        var history = std.json.Array.init(a);
        try history.append(try messages.toolResultMessage(a, .responses, "call", full, false));
        messages.normalizeResponsesHistory(a, &history);
        const stub = history.items[0].object.get("output").?.string;
        try std.testing.expect(stub.len <= 16384);
        try std.testing.expect(std.mem.indexOf(u8, stub, "truncated") != null);
        try std.testing.expect(std.mem.indexOf(u8, stub, "handle could be written") != null);
        try std.testing.expect(std.mem.indexOf(u8, stub, "handle tr_") == null);
        messages.normalizeResponsesHistory(a, &history);
        try std.testing.expectEqualStrings(stub, history.items[0].object.get("output").?.string);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, handle.handles_dir ++ "/tr_0.txt", .{}));
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
