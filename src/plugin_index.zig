//! Claude/Cursor `installed_plugins.json` (grok-build's cheap path).
//!
//! OpenCode glob-scans `.claude/skills` and `.opencode/`; grok-build never
//! walks `plugins/cache/`. It reads this registry's `installPath` entries
//! (which happen to live under cache/) and only shallow-lists plugin parent
//! dirs. Walking hashed version trees is what made graff's scan a second.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
};

/// JSON string literal, including quotes. Tests must use this when a native
/// path goes into JSON — Windows `\` is an escape and silently empties parse.
pub fn quote(arena: Allocator, s: []const u8) []const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeByte('"') catch return "\"\"";
    for (s) |c| {
        if (c == '\\' or c == '"') aw.writer.writeByte('\\') catch return "\"\"";
        aw.writer.writeByte(c) catch return "\"\"";
    }
    aw.writer.writeByte('"') catch return "\"\"";
    return aw.writer.buffered();
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// User/unscoped always surface. `local`/`project` (or any entry with a
/// projectPath) only when `cwd` is that project or a subdirectory.
fn visible(obj: std.json.ObjectMap, cwd: []const u8) bool {
    const scope = strField(obj, "scope");
    const project = strField(obj, "projectPath");
    const gated = std.mem.eql(u8, scope, "local") or std.mem.eql(u8, scope, "project") or project.len > 0;
    if (!gated) return true;
    if (project.len == 0 or cwd.len == 0) return false;
    if (std.mem.eql(u8, cwd, project)) return true;
    if (!std.mem.startsWith(u8, cwd, project)) return false;
    return project[project.len - 1] == '/' or cwd[project.len] == '/';
}

fn nameFromKey(key: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, key, '@')) |i| key[0..i] else key;
}

fn resolvePath(arena: Allocator, json_path: []const u8, install: []const u8) []const u8 {
    if (install.len == 0) return "";
    if (std.fs.path.isAbsolute(install)) return install;
    const dir = std.fs.path.dirname(json_path) orelse return install;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, install }) catch "";
}

/// Parse one registry. Empty on missing/invalid file. Caps at 32.
pub fn load(io: Io, arena: Allocator, json_path: []const u8, cwd: []const u8) []const Entry {
    const text = Io.Dir.cwd().readFileAlloc(io, json_path, arena, .limited(1 << 20)) catch return &.{};
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return &.{};
    if (parsed != .object) return &.{};
    const plugins_v = parsed.object.get("plugins") orelse return &.{};
    if (plugins_v != .object) return &.{};
    var out: std.ArrayList(Entry) = .empty;
    var it = plugins_v.object.iterator();
    while (it.next()) |e| {
        if (out.items.len >= 32) break;
        const items = switch (e.value_ptr.*) {
            .array => |a| a.items,
            else => continue,
        };
        const name = nameFromKey(e.key_ptr.*);
        for (items) |item| {
            if (out.items.len >= 32) break;
            if (item != .object) continue;
            if (!visible(item.object, cwd)) continue;
            const raw = strField(item.object, "installPath");
            const path = resolvePath(arena, json_path, raw);
            if (path.len == 0) continue;
            out.append(arena, .{ .name = name, .path = path }) catch {};
        }
    }
    return out.items;
}

const testing = std.testing;

fn tmpBase(io: Io, tmp: *testing.TmpDir, arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

test "load: names and installPath; project scope is cwd-gated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const json_path = std.fmt.allocPrint(arena, "{s}/installed_plugins.json", .{base}) catch return error.OutOfMemory;
    const user_plug = std.fmt.allocPrint(arena, "{s}/user-plug", .{base}) catch return error.OutOfMemory;
    const proj_plug = std.fmt.allocPrint(arena, "{s}/proj-plug", .{base}) catch return error.OutOfMemory;
    const project = std.fmt.allocPrint(arena, "{s}/repo", .{base}) catch return error.OutOfMemory;
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = json_path,
        .data = try std.fmt.allocPrint(arena,
            \\{{"plugins":{{"gmail@cursor":[{{"installPath":{s}}}],"pack@official":[{{"installPath":{s},"scope":"project","projectPath":{s}}}]}}}}
        , .{ quote(arena, user_plug), quote(arena, proj_plug), quote(arena, project) }),
    });

    const user_only = load(io, arena, json_path, "/elsewhere");
    try testing.expectEqual(@as(usize, 1), user_only.len);
    try testing.expectEqualStrings("gmail", user_only[0].name);
    try testing.expectEqualStrings(user_plug, user_only[0].path);

    const both = load(io, arena, json_path, project);
    try testing.expectEqual(@as(usize, 2), both.len);
}

test "load: relative installPath is next to the json" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const json_path = std.fmt.allocPrint(arena, "{s}/installed_plugins.json", .{base}) catch return error.OutOfMemory;
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = json_path,
        .data = "{\"plugins\":{\"pack@official\":[{\"installPath\":\"cache/pack/1.0.0\"}]}}",
    });
    const got = load(io, arena, json_path, base);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("pack", got[0].name);
    try testing.expect(std.mem.endsWith(u8, got[0].path, "cache/pack/1.0.0"));
}
