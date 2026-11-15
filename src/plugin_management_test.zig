const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const management = @import("plugin_management.zig");
const plugins = @import("plugins.zig");
const commands = @import("plugin_commands.zig");

fn run(arena: std.mem.Allocator, dir: Io.Dir, command: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    try testing.expect(try commands.run(testing.io, arena, "", dir, command, &out.writer));
    return out.writer.buffered();
}

fn fixture(dir: Io.Dir) !void {
    try dir.createDirPath(testing.io, ".harness/plugins/demo/commands");
    try dir.writeFile(testing.io, .{ .sub_path = ".harness/plugins/demo/plugin.json", .data = "{\"name\":\"demo\",\"hooks\":{\"before_request\":\"never-run\"}}" });
    try dir.writeFile(testing.io, .{ .sub_path = ".harness/plugins/demo/commands/hello.md", .data = "---\nname: hello\ndescription: hello\n---\nhello" });
}

test "plugin management enable disable reload preserve runtime trust and unrelated settings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    try fixture(tmp.dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".harness/settings.json", .data = "{\"theme\":\"dark\",\"plugins\":{\"future\":true},\"runtime_plugins\":[{\"id\":\"native-demo\",\"trusted\":false}]}" });
    try testing.expectEqual(@as(usize, 1), plugins.discover(testing.io, arena, null, tmp.dir).len);
    const listed = try run(arena, tmp.dir, "list");
    try testing.expect(std.mem.indexOf(u8, listed, "demo  [harness/project] id=harness/demo") != null);
    const loaded = try run(arena, tmp.dir, "load\tDEMO");
    try testing.expect(std.mem.indexOf(u8, loaded, "hooks are not run") != null);
    const saved = try run(arena, tmp.dir, "disable harness/demo");
    try testing.expect(std.mem.indexOf(u8, saved, "next safe") != null);
    try testing.expectEqual(@as(usize, 0), plugins.discover(testing.io, arena, null, tmp.dir).len);
    _ = try run(arena, tmp.dir, "disable native-demo");
    try testing.expect(!management.isEnabledAt(testing.io, arena, tmp.dir, "native-demo"));
    const bytes = try tmp.dir.readFileAlloc(testing.io, ".harness/settings.json", arena, .limited(1 << 20));
    const json = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    try testing.expectEqualStrings("dark", json.object.get("theme").?.string);
    try testing.expect(json.object.get("plugins").?.object.get("future").?.bool);
    try testing.expect(!json.object.get("runtime_plugins").?.array.items[0].object.get("trusted").?.bool);
    _ = try run(arena, tmp.dir, "enable harness/demo");
    _ = try run(arena, tmp.dir, "enable native-demo");
    try testing.expectEqual(@as(usize, 1), plugins.discover(testing.io, arena, null, tmp.dir).len);
    try testing.expect(management.isEnabledAt(testing.io, arena, tmp.dir, "native-demo"));
    const queued = try run(arena, tmp.dir, "reload");
    try testing.expect(std.mem.indexOf(u8, queued, "queued") != null);
    try testing.expect(management.reloadAtBoundary());
}

test "plugin management register install remove unregister in place and workspace isolation" {
    var a = testing.tmpDir(.{});
    defer a.cleanup();
    var b = testing.tmpDir(.{});
    defer b.cleanup();
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    try a.dir.createDirPath(testing.io, "local bundle/commands");
    try a.dir.writeFile(testing.io, .{ .sub_path = "local bundle/plugin.json", .data = "{\"name\":\"local\"}" });
    try a.dir.writeFile(testing.io, .{ .sub_path = "local bundle/secrets.env", .data = "private-fixture-sentinel" });
    _ = try run(arena, a.dir, "install local bundle");
    _ = try run(arena, a.dir, "register local bundle");
    const state = try management.load(testing.io, arena, a.dir);
    try testing.expectEqual(@as(usize, 1), state.directories.len);
    const discovered = plugins.discover(testing.io, arena, null, a.dir);
    try testing.expectEqual(@as(usize, 1), discovered.len);
    try testing.expectEqualStrings(state.directories[0], discovered[0].path);
    try testing.expectEqualStrings("registered", discovered[0].origin);
    try testing.expectEqual(@as(usize, 0), plugins.discover(testing.io, arena, null, b.dir).len);
    _ = try run(arena, a.dir, "disable registered/local");
    try testing.expect((try management.load(testing.io, arena, b.dir)).enabled("registered/local"));
    const bytes = try a.dir.readFileAlloc(testing.io, ".harness/settings.json", arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, bytes, "private-fixture-sentinel") == null);
    _ = try run(arena, a.dir, "remove local bundle");
    try testing.expectEqual(@as(usize, 0), (try management.load(testing.io, arena, a.dir)).directories.len);
    const secret = try a.dir.readFileAlloc(testing.io, "local bundle/secrets.env", arena, .limited(100));
    try testing.expectEqualStrings("private-fixture-sentinel", secret);
    _ = try run(arena, a.dir, "register local bundle");
    try a.dir.deleteTree(testing.io, "local bundle");
    _ = try run(arena, a.dir, try std.fmt.allocPrint(arena, "unregister {s}", .{state.directories[0]}));
    try testing.expectEqual(@as(usize, 0), (try management.load(testing.io, arena, a.dir)).directories.len);
}

test "plugin management policy denied plugins stay excluded after enable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    try fixture(tmp.dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".harness/settings.json", .data = "{\"policies\":[{\"action\":\"plugin.use\",\"resource\":\"demo\",\"effect\":\"deny\"}]}" });
    try management.setEnabled(testing.io, arena, tmp.dir, "harness/demo", true);
    try testing.expectEqual(@as(usize, 0), plugins.discover(testing.io, arena, null, tmp.dir).len);
    try testing.expectEqual(@as(usize, 0), plugins.skillDirs(testing.io, arena, null, tmp.dir, false).len);
}

test "plugin management rejects cross-workspace settings symlinks" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var a = testing.tmpDir(.{});
    defer a.cleanup();
    var b = testing.tmpDir(.{});
    defer b.cleanup();
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    try a.dir.createDirPath(testing.io, ".harness");
    const original = "{\"plugins\":{\"disabled\":[\"keep\"]}}";
    try b.dir.writeFile(testing.io, .{ .sub_path = "settings.json", .data = original });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try b.dir.realPath(testing.io, &buf);
    const target = try std.fs.path.join(arena, &.{ buf[0..n], "settings.json" });
    try a.dir.symLink(testing.io, target, ".harness/settings.json", .{});
    try testing.expectError(error.UnsafePluginSettingsPath, management.load(testing.io, arena, a.dir));
    try testing.expectError(error.UnsafePluginSettingsPath, management.setEnabled(testing.io, arena, a.dir, "keep", true));
    try testing.expectEqualStrings(original, try b.dir.readFileAlloc(testing.io, "settings.json", arena, .limited(1000)));
}

test "plugin management invalid configuration fails closed and is never overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    try fixture(tmp.dir);
    const malformed = "{\"plugins\":{\"disabled\":false}}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".harness/settings.json", .data = malformed });
    try testing.expectEqual(@as(usize, 0), plugins.discover(testing.io, arena, null, tmp.dir).len);
    try testing.expect(!management.isEnabledAt(testing.io, arena, tmp.dir, "native-demo"));
    try testing.expectError(error.InvalidPluginSettings, management.setEnabled(testing.io, arena, tmp.dir, "harness/demo", true));
    try testing.expectEqualStrings(malformed, try tmp.dir.readFileAlloc(testing.io, ".harness/settings.json", arena, .limited(1000)));
}
