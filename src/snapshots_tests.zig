//! `/rewind` snapshot tests: the three-state `Before`, and what each state
//! does to the working tree end-to-end through write_file. Split off
//! snapshots.zig so the module stays a focused unit; reached from the test
//! root via test_hooks.zig.

const std = @import("std");
const builtin = @import("builtin");
const Value = std.json.Value;

const exec = @import("exec.zig");
const tools = @import("tools.zig");
const snapshots = @import("snapshots.zig");

test "beforeFromRead: only FileNotFound is 'absent' — every other failure has NO snapshot" {
    try std.testing.expect(snapshots.beforeFromRead(error.FileNotFound) == .absent);
    // A file past readFileAlloc's cap. Recording this as `absent` is what made
    // /rewind delete the file instead of restoring it.
    try std.testing.expect(snapshots.beforeFromRead(error.StreamTooLong) == .unreadable);
    try std.testing.expect(snapshots.beforeFromRead(error.AccessDenied) == .unreadable);
    var bytes = [_]u8{ 'h', 'i' };
    try std.testing.expectEqualStrings("hi", snapshots.beforeFromRead(bytes[0..]).content);
}

fn testCtx(client: *std.http.Client, snaps: *snapshots.Snapshots) tools.ToolCtx {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .client = client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .snapshots = snaps,
    };
}

/// Run write_file through the real dispatch (guards, snapshotting and all).
fn writeFile(snaps: *snapshots.Snapshots, a: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "path", .{ .string = path });
    try obj.put(a, "content", .{ .string = content });
    var client: std.http.Client = undefined;
    const out = exec.execTool(testCtx(&client, snaps), .{ .id = "call_1", .name = "write_file", .input = .{ .object = obj } });
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
}

test "/rewind: a file write_file CREATED is deleted, and an overwritten one is restored" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "original\n" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var snaps: snapshots.Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    snaps.turn = 1;
    try writeFile(&snaps, a, try std.fmt.allocPrint(a, "{s}/fresh.txt", .{dir}), "brand new\n");
    try writeFile(&snaps, a, try std.fmt.allocPrint(a, "{s}/old.txt", .{dir}), "clobbered\n");

    const rw = snaps.restore(1);
    try std.testing.expectEqual(@as(usize, 2), rw.restored);
    try std.testing.expectEqual(@as(usize, 0), rw.skipped);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "fresh.txt", .{}));
    const back = try tmp.dir.readFileAlloc(io, "old.txt", gpa, .limited(4096));
    defer gpa.free(back);
    try std.testing.expectEqualStrings("original\n", back);
}

test "/rewind: a file too big to snapshot survives — it is never mistaken for a new file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 5 MiB: past write_file's 4 MiB snapshot read cap, so the pre-write read
    // fails with StreamTooLong and no snapshot can be taken.
    const big = try a.alloc(u8, 5 * 1024 * 1024);
    @memset(big, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = big });

    var snaps: snapshots.Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    snaps.turn = 1;
    try writeFile(&snaps, a, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/big.txt", .{&tmp.sub_path}), "clobbered\n");

    const rw = snaps.restore(1);
    try std.testing.expectEqual(@as(usize, 0), rw.restored);
    try std.testing.expectEqual(@as(usize, 1), rw.skipped);
    // The file is still there — unrewound, but not destroyed by the rewind.
    const after = try tmp.dir.readFileAlloc(io, "big.txt", gpa, .limited(4096));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("clobbered\n", after);
}

test "/rewind: a delete that FAILS is not counted as a file restored" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sub", .default_dir);
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var snaps: snapshots.Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    snaps.turn = 1;
    // Brand new file → snapshot `.absent` → the rewind's job is to delete it.
    try writeFile(&snaps, a, try std.fmt.allocPrint(a, "{s}/sub/new.txt", .{dir}), "created this turn\n");

    // The tree moves under us between the write and the rewind: `sub` is a
    // regular FILE now, so deleting `sub/new.txt` fails with NotDir.
    try tmp.dir.deleteTree(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub", .data = "not a directory\n" });

    const rw = snaps.restore(1);
    // Nothing was put back and nothing was deleted, so the count must be 0:
    // reporting "restored 1 file(s)" here tells the user a lie they would act on.
    try std.testing.expectEqual(@as(usize, 0), rw.restored);
    // `skipped` is only for snapshots we never captured — this one we had.
    try std.testing.expectEqual(@as(usize, 0), rw.skipped);
    const kept = try tmp.dir.readFileAlloc(io, "sub", gpa, .limited(4096));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("not a directory\n", kept);
}

test "/rewind: a file already gone when the rewind runs still counts as restored" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var snaps: snapshots.Snapshots = .{ .gpa = gpa, .io = io };
    defer snaps.deinit();
    snaps.turn = 1;
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/gone.txt", .{&tmp.sub_path});
    try writeFile(&snaps, a, path, "created this turn\n");

    // A bash `rm` (untracked by /rewind) got there first. The delete fails with
    // FileNotFound, but the tree IS in the state the rewind wanted.
    try tmp.dir.deleteFile(io, "gone.txt");
    const rw = snaps.restore(1);
    try std.testing.expectEqual(@as(usize, 1), rw.restored);
    try std.testing.expectEqual(@as(usize, 0), rw.skipped);
}
