//! Explicit user-owned plugin management. Foreign packages remain in place.
//! No subprocesses, downloads, hooks, PATH changes, or model-facing write API.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const policy = @import("harness_policy.zig");

pub const State = struct {
    disabled: []const []const u8 = &.{},
    directories: []const []const u8 = &.{},

    /// Applies equally to foreign origin/name IDs and native runtime IDs.
    pub fn enabled(self: State, id: []const u8) bool {
        for (self.disabled) |item| if (std.mem.eql(u8, item, id)) return false;
        return true;
    }
};

fn strings(arena: Allocator, value: ?Value) ![]const []const u8 {
    const v = value orelse return &.{};
    if (v != .array) return error.InvalidPluginSettings;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidPluginSettings;
        try out.append(arena, item.string);
    }
    return out.items;
}

fn document(io: Io, arena: Allocator, project: Io.Dir) !Value {
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try project.realPath(io, &base_buf);
    if (!policy.noSymlinkEscape(io, policy.settings_path, base_buf[0..n])) return error.UnsafePluginSettingsPath;
    const text = project.readFileAlloc(io, policy.settings_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = .empty },
        else => return err,
    };
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return error.InvalidPluginSettings;
    if (root != .object) return error.InvalidPluginSettings;
    return root;
}

fn section(root: Value) !Value {
    const value = root.object.get("plugins") orelse return .{ .object = .empty };
    if (value != .object) return error.InvalidPluginSettings;
    return value;
}

pub fn load(io: Io, arena: Allocator, project: Io.Dir) !State {
    const s = try section(try document(io, arena, project));
    return .{
        .disabled = try strings(arena, s.object.get("disabled")),
        .directories = try strings(arena, s.object.get("directories")),
    };
}

/// Convenience for the native runtime rooted at the current workspace.
/// Configuration failures never opt a runtime plugin in.
pub fn isEnabled(io: Io, arena: Allocator, id: []const u8) bool {
    return isEnabledAt(io, arena, Io.Dir.cwd(), id);
}

pub fn isEnabledAt(io: Io, arena: Allocator, project: Io.Dir, id: []const u8) bool {
    const state = load(io, arena, project) catch return false;
    return state.enabled(id);
}

pub fn foreignId(arena: Allocator, origin: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ origin, name });
}

// A pending reload never invalidates an in-flight catalog. The frontend calls
// reloadAtBoundary after the current turn has completed, before its next user turn.
var reload_pending: std.atomic.Value(bool) = .init(false);

pub fn requestReload() void {
    reload_pending.store(true, .release);
}

pub fn reloadAtBoundary() bool {
    if (!reload_pending.swap(false, .acq_rel)) return false;
    @import("plugin_scan.zig").invalidate();
    return true;
}

fn update(io: Io, arena: Allocator, project: Io.Dir, key: []const u8, item: []const u8, present: bool) !void {
    if (item.len == 0 or std.mem.indexOfScalar(u8, item, 0) != null) return error.InvalidPluginId;
    var root = try document(io, arena, project);
    var s = try section(root);
    // Validate the whole management section before preserving or mutating it.
    _ = try strings(arena, s.object.get("disabled"));
    _ = try strings(arena, s.object.get("directories"));
    const before = try strings(arena, s.object.get(key));
    var after = std.json.Array.init(arena);
    var found = false;
    for (before) |entry| {
        const matches = std.mem.eql(u8, entry, item);
        if (matches) {
            if (found or !present) continue;
            found = true;
        }
        try after.append(.{ .string = entry });
    }
    if (present and !found) try after.append(.{ .string = item });
    try s.object.put(arena, key, .{ .array = after });
    try root.object.put(arena, "plugins", s);
    const bytes = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    // Keep workspace policy isolated: do not follow a .harness directory or
    // settings symlink into another workspace. The existing policy guards also
    // prevent model write/edit tools from changing this file directly.
    try project.createDirPath(io, policy.settings_dir);
    try @import("credential_store.zig").replaceFile(io, project, policy.settings_path, bytes, @import("credential_store.zig").private_file);
    requestReload();
}

/// Only explicit user CLI/slash commands may call these mutation entry points.
pub fn setEnabled(io: Io, arena: Allocator, project: Io.Dir, id: []const u8, enabled: bool) !void {
    try update(io, arena, project, "disabled", id, !enabled);
}

pub fn canonicalDirectory(io: Io, arena: Allocator, project: Io.Dir, path: []const u8) ![]const u8 {
    var dir = try project.openDir(io, path, .{});
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

pub fn register(io: Io, arena: Allocator, project: Io.Dir, path: []const u8) ![]const u8 {
    const canonical = try canonicalDirectory(io, arena, project, path);
    try update(io, arena, project, "directories", canonical, true);
    return canonical;
}

/// Unregister, never delete the source directory or its secrets. Canonical
/// absolute paths can be removed even after the source directory was deleted.
pub fn remove(io: Io, arena: Allocator, project: Io.Dir, path: []const u8) !void {
    const canonical = canonicalDirectory(io, arena, project, path) catch |err| blk: {
        if (!std.fs.path.isAbsolute(path)) return err;
        break :blk path;
    };
    try update(io, arena, project, "directories", canonical, false);
}
