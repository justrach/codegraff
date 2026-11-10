const std = @import("std");
const store = @import("session_store.zig");
const lock = @import("session_lock.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;
const path = "session.json";
const old_header = "{\"v\":1,\"m\":[\"";
const new_header = "{\"v\":2,\"m\":[\"";
const history = "retained history";
const old_parts: []const []const u8 = &.{ old_header, history, "\"]}" };
const new_parts: []const []const u8 = &.{ new_header, history, "\",\"next\"]}" };

fn delta(mark: store.Mark) store.Delta {
    return .{ .old_parts = old_parts, .old_mark = mark, .prefix = old_header.len, .tail = old_header.len + history.len };
}
fn expectFile(dir: std.Io.Dir, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}
fn expectNew(dir: std.Io.Dir) !void {
    const bytes = try std.mem.concat(gpa, u8, new_parts);
    defer gpa.free(bytes);
    try expectFile(dir, bytes);
}

test "session store small append writes only changed bytes, keeping canonical JSON and inode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const large = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(large);
    @memset(large, 'x');
    const old: []const []const u8 = &.{ old_header, large, "\"]}" };
    const new: []const []const u8 = &.{ new_header, large, "\",\"next\"]}" };
    const mark = try store.write(io, gpa, tmp.dir, path, old, null);
    store.stats = .{};
    const now = try store.write(io, gpa, tmp.dir, path, new, .{
        .old_parts = old,
        .old_mark = mark,
        .prefix = old_header.len,
        .tail = old_header.len + large.len,
    });
    try std.testing.expectEqual(mark.inode, now.inode);
    try std.testing.expect(store.matches(now, try store.observe(io, tmp.dir, path)));
    try std.testing.expectEqual(@as(u64, 1), store.stats.delta_writes);
    try std.testing.expectEqual(@as(u64, 0), store.stats.full_writes);
    try std.testing.expectEqual(@as(u64, new_header.len + new[2].len), store.stats.bytes_written);
    const bytes = try tmp.dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("m").?.array.items.len);
}

test "session store shorter history truncates and stale mark safely falls back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mark = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    // An independently changed size makes the old immutable snapshot stale.
    try lock.writeSession(io, tmp.dir, path, "{\"external\":true}");
    store.stats = .{};
    _ = try store.write(io, gpa, tmp.dir, path, &.{"{}"}, delta(mark));
    try expectFile(tmp.dir, "{}");
    try std.testing.expectEqual(@as(u64, 1), store.stats.full_writes);
    try std.testing.expectEqual(@as(u64, 0), store.stats.delta_writes);
}

test "session store shrinking incremental tail preserves the middle and truncates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mark = try store.write(io, gpa, tmp.dir, path, new_parts, null);
    store.stats = .{};
    _ = try store.write(io, gpa, tmp.dir, path, old_parts, .{
        .old_parts = new_parts,
        .old_mark = mark,
        .prefix = old_header.len,
        .tail = old_header.len + history.len,
    });
    const expected = try std.mem.concat(gpa, u8, old_parts);
    defer gpa.free(expected);
    try expectFile(tmp.dir, expected);
    try std.testing.expectEqual(@as(u64, 1), store.stats.delta_writes);
}

test "session store rejects locked writer contention without publishing a journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    const held = try lock.open(io, tmp.dir, path);
    defer held.close(io);
    try std.testing.expectError(error.SessionOpenInAnotherGraff, store.write(io, gpa, tmp.dir, path, new_parts, null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path ++ ".journal", .{}));
}

test "session store ignores an incomplete staged journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    try tmp.dir.writeFile(io, .{ .sub_path = path ++ ".journal.tmp", .data = "GRAFFSJ1partial" });
    try store.recover(io, gpa, tmp.dir, path);
    _ = try store.write(io, gpa, tmp.dir, path, new_parts, null);
    try expectNew(tmp.dir);
}

test "session store recovers partially applied prefix and recovery is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mark = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    try store.testing.stage(io, gpa, tmp.dir, path, new_parts, delta(mark), true);
    try store.recover(io, gpa, tmp.dir, path);
    try expectNew(tmp.dir);
    const final = try store.observe(io, tmp.dir, path);
    try store.recover(io, gpa, tmp.dir, path);
    try std.testing.expect(store.matches(final, try store.observe(io, tmp.dir, path)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, path ++ ".journal", .{}));
}

test "session store new save recovers an outstanding journal under its own lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mark = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    try store.testing.stage(io, gpa, tmp.dir, path, new_parts, delta(mark), true);
    _ = try store.write(io, gpa, tmp.dir, path, &.{"{\"final\":true}"}, null);
    try expectFile(tmp.dir, "{\"final\":true}");
}

test "session store conflicts on external retained or changed range edits" {
    for ([_]usize{ old_header.len + 1, 0 }) |offset| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const mark = try store.write(io, gpa, tmp.dir, path, old_parts, null);
        try store.testing.stage(io, gpa, tmp.dir, path, new_parts, delta(mark), false);
        const file = try tmp.dir.openFile(io, path, .{ .mode = .read_write });
        try file.writePositionalAll(io, "!", offset);
        file.close(io);
        try std.testing.expectError(error.SessionJournalConflict, store.recover(io, gpa, tmp.dir, path));
        _ = try tmp.dir.statFile(io, path ++ ".journal", .{});
        var back: [1]u8 = undefined;
        const kept = try tmp.dir.openFile(io, path, .{});
        defer kept.close(io);
        _ = try kept.readPositionalAll(io, &back, offset);
        try std.testing.expectEqual(@as(u8, '!'), back[0]);
    }
}

test "session store conflicts on replacement inode even with identical old bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mark = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    try store.testing.stage(io, gpa, tmp.dir, path, new_parts, delta(mark), false);
    const bytes = try std.mem.concat(gpa, u8, old_parts);
    defer gpa.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement", .data = bytes });
    try tmp.dir.rename("replacement", tmp.dir, path, io);
    try std.testing.expectError(error.SessionJournalConflict, store.recover(io, gpa, tmp.dir, path));
    try expectFile(tmp.dir, bytes);
}

test "session store rejects malformed or corrupted committed journals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mark = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    try store.testing.stage(io, gpa, tmp.dir, path, new_parts, delta(mark), false);
    const journal = try tmp.dir.openFile(io, path ++ ".journal", .{ .mode = .read_write });
    try journal.writePositionalAll(io, "!", 120);
    journal.close(io);
    try std.testing.expectError(error.BadSessionJournal, store.recover(io, gpa, tmp.dir, path));
    try tmp.dir.writeFile(io, .{ .sub_path = path ++ ".journal", .data = "GRAFFSJ1" });
    try std.testing.expectError(error.BadSessionJournal, store.recover(io, gpa, tmp.dir, path));
}

test "session store replays a full fallback transaction after a crash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try store.write(io, gpa, tmp.dir, path, old_parts, null);
    try store.testing.stage(io, gpa, tmp.dir, path, new_parts, null, false);
    try store.recover(io, gpa, tmp.dir, path);
    try expectNew(tmp.dir);
}
