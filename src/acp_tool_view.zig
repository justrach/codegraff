//! What an ACP client needs to show a file tool call: where it works
//! (`locations`) and, for an edit, the change (`diff` content). Shared by
//! tool_call announcements and permission requests (#1287, #1289).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");

fn filePath(input: Value) ?[]const u8 {
    if (input != .object) return null;
    return util.strFieldObj(input.object, "path") orelse util.strFieldObj(input.object, "file");
}

/// ACP wants absolute paths; a relative tool path joins the session's
/// working directory when that is known to be absolute.
fn absolute(arena: Allocator, path: []const u8, cwd: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path) or !std.fs.path.isAbsolute(cwd)) return path;
    return std.fs.path.join(arena, &.{ cwd, path });
}

/// `[{path, line?}]` for a read or edit tool naming a file; empty otherwise.
pub fn locations(arena: Allocator, kind: []const u8, input: Value, cwd: []const u8) !Value {
    var out = std.json.Array.init(arena);
    if (!std.mem.eql(u8, kind, "read") and !std.mem.eql(u8, kind, "edit")) return .{ .array = out };
    const path = filePath(input) orelse return .{ .array = out };
    var loc: std.json.ObjectMap = .empty;
    try loc.put(arena, "path", .{ .string = try absolute(arena, path, cwd) });
    if (input.object.get("start_line")) |line| if (line == .integer and line.integer > 0) try loc.put(arena, "line", line);
    try out.append(.{ .object = loc });
    return .{ .array = out };
}

fn diff(arena: Allocator, path: []const u8, old: ?[]const u8, new: []const u8) !Value {
    var d: std.json.ObjectMap = .empty;
    try d.put(arena, "type", .{ .string = "diff" });
    try d.put(arena, "path", .{ .string = path });
    try d.put(arena, "oldText", if (old) |t| .{ .string = t } else .null);
    try d.put(arena, "newText", .{ .string = new });
    return .{ .object = d };
}

/// ACP `diff` content for a native file edit: each `edit_file` span (single
/// or batch form) as oldText/newText, `write_file` as new content. Empty for
/// every other tool.
pub fn diffs(arena: Allocator, name: []const u8, input: Value, cwd: []const u8) !Value {
    var out = std.json.Array.init(arena);
    const raw_path = filePath(input) orelse return .{ .array = out };
    const path = try absolute(arena, raw_path, cwd);
    if (std.mem.eql(u8, name, "write_file")) {
        if (util.strFieldObj(input.object, "content")) |content| try out.append(try diff(arena, path, null, content));
    } else if (std.mem.eql(u8, name, "edit_file")) {
        if (input.object.get("edits")) |edits| if (edits == .array) for (edits.array.items) |e| {
            if (e != .object) continue;
            const old = util.strFieldObj(e.object, "old_string") orelse continue;
            const new = util.strFieldObj(e.object, "new_string") orelse continue;
            try out.append(try diff(arena, path, old, new));
        };
        if (util.strFieldObj(input.object, "old_string")) |old| if (util.strFieldObj(input.object, "new_string")) |new|
            try out.append(try diff(arena, path, old, new));
    }
    return .{ .array = out };
}

/// An absolute working directory on the host platform.
const test_cwd = if (@import("builtin").os.tag == .windows) "C:\\repo" else "/repo";

test "locations: file tools name an absolute path and optional line; others none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const read = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"src/x.zig\",\"start_line\":40}", .{});
    const locs = try locations(a, "read", read, test_cwd);
    try std.testing.expectEqual(@as(usize, 1), locs.array.items.len);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ test_cwd, "src/x.zig" }), locs.array.items[0].object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 40), locs.array.items[0].object.get("line").?.integer);
    const abs_path = try std.fs.path.join(a, &.{ test_cwd, "hosts" });
    var abs_obj: std.json.ObjectMap = .empty;
    try abs_obj.put(a, "path", .{ .string = abs_path });
    try std.testing.expectEqualStrings(abs_path, (try locations(a, "edit", .{ .object = abs_obj }, "/elsewhere")).array.items[0].object.get("path").?.string);
    try std.testing.expectEqual(@as(usize, 0), (try locations(a, "execute", read, test_cwd)).array.items.len);
}

test "diffs: edit_file single and batch spans, write_file as new content, nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const single = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"calc.py\",\"old_string\":\"a - b\",\"new_string\":\"a + b\"}", .{});
    const one = try diffs(a, "edit_file", single, test_cwd);
    try std.testing.expectEqual(@as(usize, 1), one.array.items.len);
    try std.testing.expectEqualStrings("diff", one.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ test_cwd, "calc.py" }), one.array.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("a - b", one.array.items[0].object.get("oldText").?.string);
    try std.testing.expectEqualStrings("a + b", one.array.items[0].object.get("newText").?.string);
    const batch = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"f\",\"edits\":[{\"old_string\":\"1\",\"new_string\":\"2\"},{\"old_string\":\"3\",\"new_string\":\"4\"}]}", .{});
    try std.testing.expectEqual(@as(usize, 2), (try diffs(a, "edit_file", batch, test_cwd)).array.items.len);
    const write = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"new.txt\",\"content\":\"hi\"}", .{});
    const created = try diffs(a, "write_file", write, test_cwd);
    try std.testing.expect(created.array.items[0].object.get("oldText").? == .null);
    try std.testing.expectEqual(@as(usize, 0), (try diffs(a, "read_file", single, test_cwd)).array.items.len);
}
