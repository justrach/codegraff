const std = @import("std");
const Io = std.Io;
const workers = @import("terminal_workers.zig");
const activity = @import("subagent_activity.zig");
const ansi = @import("ansi.zig");

fn packet(keys: *workers.Keys, bytes: []const u8) workers.Action {
    var action: workers.Action = .none;
    for (bytes) |b| action = keys.feed(b);
    return action;
}

test "terminal workers parses fragmented mouse keyboard and escape input" {
    var keys: workers.Keys = .{};
    try std.testing.expect(packet(&keys, "\x1b[<0;7;") == .none);
    const click = packet(&keys, "4M");
    try std.testing.expectEqual(workers.Point{ .x = 7, .y = 4 }, click.click);
    try std.testing.expect(packet(&keys, "\x1b[<0;7;4m") == .none);
    try std.testing.expect(packet(&keys, "\x1b[<35;7;4M") == .none);
    try std.testing.expect(packet(&keys, "\x1b[<64;7;4M") == .up);
    try std.testing.expect(packet(&keys, "\x1b[<65;7;4M") == .down);
    try std.testing.expect(packet(&keys, "\x1b[A") == .up);
    try std.testing.expect(packet(&keys, "\x1b[B") == .down);
    try std.testing.expect(packet(&keys, "\x1b[13u") == .select);
    try std.testing.expect(packet(&keys, "\x1b") == .none);
    try std.testing.expect(keys.expire() == .back);
    try std.testing.expect(packet(&keys, "\x03") == .quit);
    try std.testing.expect(packet(&keys, "t") == .tools);
    try std.testing.expect(packet(&keys, "h") == .thoughts);
    try std.testing.expect(packet(&keys, "\x1b[<0;0;4M") == .none);
}

test "terminal workers list keeps narrow cards and hit targets aligned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = ansi.style;
    defer ansi.style = old;
    ansi.style = .{};
    var rows: [8]activity.Meta = undefined;
    for (&rows) |*row| row.* = .{ .id = "child-a", .label = "Long\nlabel\twith\x1b[2Jcontrols", .task = "Inspect", .model = "example-model" };
    var out: Io.Writer.Allocating = .init(a);
    const off = try workers.drawList(a, &out.writer, &rows, 7, 20, 10);
    try std.testing.expectEqual(@as(usize, 7), off);
    try std.testing.expectEqual(@as(?usize, 7), workers.clickedRow(.{ .x = 3, .y = 4 }, off, rows.len, 20, 10));
    try std.testing.expect(workers.clickedRow(.{ .x = 3, .y = 3 }, off, rows.len, 20, 10) == null);
    try std.testing.expect(workers.clickedRow(.{ .x = 20, .y = 4 }, off, rows.len, 20, 10) == null);
    try std.testing.expect(workers.clickedRow(.{ .x = 3, .y = 7 }, off, rows.len, 20, 10) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), 0x1b) == null);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        try std.testing.expect(@import("markdown_url.zig").codepointCount(line) < 20);
        if (row == 3) try std.testing.expect(std.mem.startsWith(u8, line, "› ● "));
    }
    _ = try workers.drawList(a, &out.writer, &.{}, 999, 20, 10);
}

test "terminal workers wraps UTF8 and ANSI without splitting either" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try workers.wrap(arena.allocator(), "\x1b[1ma界bc\x1b[0m", 3);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("\x1b[1ma界", lines[0]);
    try std.testing.expectEqualStrings("bc\x1b[0m", lines[1]);
    const words = try workers.wrap(arena.allocator(), "one two three", 7);
    try std.testing.expectEqualStrings("one two", words[0]);
    try std.testing.expectEqualStrings("three", words[1]);
}

test "terminal workers snapshots reject traversal and mismatched identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(error.InvalidChildId, workers.snapshot(a, io, tmp.dir, "../child-a"));
    const child: activity.Snapshot = .{ .agent = .{ .id = "child-a", .label = "Review", .task = "Inspect" }, .events = &.{}, .response = "Done" };
    try tmp.dir.writeFile(io, .{ .sub_path = "child-a.json", .data = try std.json.Stringify.valueAlloc(a, child, .{}) });
    const read = try workers.snapshot(a, io, tmp.dir, "child-a");
    try std.testing.expectEqualStrings("Done", read.response);
    try tmp.dir.writeFile(io, .{ .sub_path = "child-b.json", .data = try std.json.Stringify.valueAlloc(a, child, .{}) });
    try std.testing.expectError(error.InvalidChildSnapshot, workers.snapshot(a, io, tmp.dir, "child-b"));
    var events: [activity.max_events + 1]activity.Event = @splat(.{ .type = "text" });
    var excess = child;
    excess.events = &events;
    try tmp.dir.writeFile(io, .{ .sub_path = "child-a.json", .data = try std.json.Stringify.valueAlloc(a, excess, .{}) });
    try std.testing.expectError(error.InvalidChildSnapshot, workers.snapshot(a, io, tmp.dir, "child-a"));
}

test "terminal workers details are sanitized and disclosures stay opt in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = ansi.style;
    defer ansi.style = old;
    ansi.style = .{};
    var root: @import("agent.zig").Agent = .{ .gpa = a, .arena = a, .io = std.testing.io, .client = undefined, .provider = undefined, .messages = .init(a), .sub = false, .label = "Test", .out = null, .md_fence = true };
    const child: activity.Snapshot = .{ .agent = .{ .id = "child-a", .label = "Review", .task = "Inspect the **boundary**", .truncated = true }, .events = &.{
        .{ .type = "tool_call", .id = "tool-a", .name = "read_file", .text = "example.zig" },
        .{ .type = "tool_result", .id = "tool-a", .name = "read_file", .text = "hidden tool body" },
        .{ .type = "reasoning", .text = "emitted thought text" },
        .{ .type = "tool_result", .is_error = true, .text = "visible failure" },
    }, .response = "## Report\n*Ready*\x1b[2J\x1b]52;c;bad\x07" };
    const quiet = try workers.detail(&root, a, child, false, false);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Inspect the boundary") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "visible failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "hidden tool body") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "emitted thought text") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "bounded snapshot") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, quiet, 0x1b) == null);
    const expanded = try workers.detail(&root, a, child, true, true);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "hidden tool body") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "emitted thought text") != null);
    try std.testing.expect(root.md_fence);
}
