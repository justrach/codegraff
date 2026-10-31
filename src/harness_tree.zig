//! The harness as one value: every file graff reads to decide HOW it works
//! (not what it works on), loaded from one checkout, written into another,
//! and digested. This is the editable surface of a refine loop (propose →
//! probe → compose): a proposer edits a Tree, harness_tree_check turns a bad
//! edit into prose the proposer can fix, a probe runs graff in a checkout the
//! Tree was written into, and the digest names a setup the way prompt_sha
//! names a persona.
//!
//! The eight parts map onto files graff already loads:
//!
//!   system prompt, guardrails,  the instruction file: the first non-empty
//!   memory, tool guidance    →  one of hot_context.instruction_names
//!   skills                   →  .agents/skills/<name>/SKILL.md (+ files
//!                               beside it) or .agents/skills/<name>.md
//!   subagents                →  .harness/agents/<name>.md | .toml
//!   scripts                  →  .harness/scripts/<file>
//!   plugins                  →  the "hooks" object of .harness/settings.json
//!
//! Anything else under those directories is off the surface: load skips it and
//! write never touches it. The hooks file holds only the hooks object; write
//! merges it into the destination's settings and leaves other keys alone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const instruction_names = @import("hot_context.zig").instruction_names;
pub const skills_dir = ".agents/skills";
pub const agents_dir = ".harness/agents";
pub const scripts_dir = ".harness/scripts";
pub const hooks_path = @import("harness_policy.zig").settings_path;

pub const max_file_bytes: usize = 256 * 1024;
pub const max_files: usize = 128;
/// Directory levels allowed below a skill's own directory (scripts/x.py).
const skill_depth: usize = 2;

pub const Part = enum {
    instructions,
    skill,
    skill_file,
    subagent,
    script,
    hooks,

    pub fn label(p: Part) []const u8 {
        return switch (p) {
            .instructions => "instructions",
            .skill => "skill",
            .skill_file => "skill file",
            .subagent => "subagent",
            .script => "script",
            .hooks => "hooks",
        };
    }
};

pub const File = struct { path: []const u8, data: []const u8 };

/// Files sorted by path, each path unique and on the surface.
pub const Tree = struct {
    files: []const File = &.{},

    pub fn get(self: Tree, path: []const u8) ?[]const u8 {
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return f.data;
        return null;
    }

    pub fn instructions(self: Tree) ?File {
        for (self.files) |f| if (classify(f.path) == .instructions) return f;
        return null;
    }
};

/// A loaded tree plus the paths under the surface directories that load left
/// out (off-surface names, oversize files), so a caller can say so.
pub const Loaded = struct { tree: Tree, skipped: []const []const u8 };

/// Which part of the harness `path` is, or null when it is off the surface.
pub fn classify(path: []const u8) ?Part {
    for (instruction_names) |n| if (std.mem.eql(u8, path, n)) return .instructions;
    if (std.mem.eql(u8, path, hooks_path)) return .hooks;
    if (under(path, skills_dir)) |rest| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
            const stem = stripSuffix(rest, ".md") orelse return null;
            return if (validName(stem)) .skill else null;
        };
        if (!validName(rest[0..slash])) return null;
        const tail = rest[slash + 1 ..];
        if (std.mem.eql(u8, tail, "SKILL.md")) return .skill;
        return if (safeRel(tail, skill_depth)) .skill_file else null;
    }
    if (under(path, agents_dir)) |rest| {
        const stem = stripSuffix(rest, ".md") orelse stripSuffix(rest, ".toml") orelse return null;
        return if (validName(stem)) .subagent else null;
    }
    if (under(path, scripts_dir)) |rest| return if (validFile(rest)) .script else null;
    return null;
}

/// The skill directory name a skill or skill-file path belongs to.
pub fn skillName(path: []const u8) ?[]const u8 {
    const rest = under(path, skills_dir) orelse return null;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| return rest[0..slash];
    return stripSuffix(rest, ".md");
}

/// Lowercase letters, digits, `_` and `-`, starting with a letter or digit.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn validFile(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '.') return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

fn safeRel(rel: []const u8, max_dirs: usize) bool {
    var dirs: usize = 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (!validFile(seg)) return false;
        if (it.peek() != null) dirs += 1;
    }
    return dirs <= max_dirs;
}

fn under(path: []const u8, dir: []const u8) ?[]const u8 {
    if (path.len <= dir.len + 1 or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') return null;
    return path[dir.len + 1 ..];
}

fn stripSuffix(s: []const u8, suffix: []const u8) ?[]const u8 {
    return if (std.mem.endsWith(u8, s, suffix)) s[0 .. s.len - suffix.len] else null;
}

/// Read the harness out of the checkout rooted at `root`.
pub fn load(io: Io, arena: Allocator, root: Io.Dir) !Loaded {
    var files: std.ArrayList(File) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (instruction_names) |name| {
        const data = root.readFileAlloc(io, name, arena, .limited(max_file_bytes + 1)) catch continue;
        if (std.mem.trim(u8, data, " \t\r\n").len == 0) continue;
        try addFile(arena, &files, &skipped, name, data);
        break; // graff reads only the first non-empty one
    }
    try walk(io, arena, root, skills_dir, &files, &skipped, skill_depth + 1);
    try walk(io, arena, root, agents_dir, &files, &skipped, 0);
    try walk(io, arena, root, scripts_dir, &files, &skipped, 0);
    if (try readHooks(io, arena, root)) |hooks| try files.append(arena, .{ .path = hooks_path, .data = hooks });
    std.mem.sort(File, files.items, {}, lessThan);
    return .{ .tree = .{ .files = files.items }, .skipped = skipped.items };
}

fn addFile(arena: Allocator, files: *std.ArrayList(File), skipped: *std.ArrayList([]const u8), path: []const u8, data: []const u8) !void {
    if (data.len > max_file_bytes) return skipped.append(arena, path);
    try files.append(arena, .{ .path = path, .data = data });
}

fn walk(io: Io, arena: Allocator, root: Io.Dir, dir_path: []const u8, files: *std.ArrayList(File), skipped: *std.ArrayList([]const u8), depth: usize) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => if (depth > 0) try walk(io, arena, root, path, files, skipped, depth - 1),
            .file => {
                if (classify(path) == null) {
                    try skipped.append(arena, path);
                    continue;
                }
                const data = root.readFileAlloc(io, path, arena, .limited(max_file_bytes + 1)) catch |err| switch (err) {
                    error.StreamTooLong => {
                        try skipped.append(arena, path);
                        continue;
                    },
                    else => return err,
                };
                try addFile(arena, files, skipped, path, data);
            },
            else => {},
        }
    }
}

/// The hooks object of the settings file, re-serialized, or null when absent.
fn readHooks(io: Io, arena: Allocator, root: Io.Dir) !?[]const u8 {
    const data = root.readFileAlloc(io, hooks_path, arena, .limited(1 << 20)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{}) catch return null;
    if (v != .object) return null;
    const hooks = v.object.get("hooks") orelse return null;
    return try std.json.Stringify.valueAlloc(arena, hooks, .{ .whitespace = .indent_2 });
}

fn lessThan(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Make the harness of the checkout at `root` exactly `tree`: surface files
/// the tree lacks are removed, every tree file is written, and an earlier
/// instruction file that would shadow the tree's is deleted. Off-surface files
/// and the rest of the settings file are left alone. Meant for a probe
/// checkout, not the user's own.
pub fn write(io: Io, arena: Allocator, tree: Tree, root: Io.Dir) !void {
    const current = try load(io, arena, root);
    for (current.tree.files) |f| {
        if (tree.get(f.path) != null) continue;
        if (classify(f.path) == .hooks) {
            try mergeHooks(io, arena, root, null);
            continue;
        }
        try root.deleteFile(io, f.path);
        if (skillName(f.path)) |name| {
            const skill_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ skills_dir, name });
            pruneEmpty(io, arena, root, skill_dir);
        }
    }
    const keep = if (tree.instructions()) |f| f.path else "";
    for (instruction_names) |name| {
        if (std.mem.eql(u8, name, keep)) break;
        root.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    for (tree.files) |f| {
        if (classify(f.path) == .hooks) {
            try mergeHooks(io, arena, root, f.data);
            continue;
        }
        if (std.fs.path.dirname(f.path)) |parent| try root.createDirPath(io, parent);
        try root.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    }
}

/// Remove a skill directory's now-empty subdirectories and the directory
/// itself; a non-empty one stays.
fn pruneEmpty(io: Io, arena: Allocator, root: Io.Dir, dir_path: []const u8) void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const sub = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        pruneEmpty(io, arena, root, sub);
    }
    dir.close(io);
    root.deleteDir(io, dir_path) catch {};
}

/// Set (or, with null, remove) the "hooks" key of the settings file.
fn mergeHooks(io: Io, arena: Allocator, root: Io.Dir, hooks: ?[]const u8) !void {
    var settings: std.json.ObjectMap = .empty;
    if (root.readFileAlloc(io, hooks_path, arena, .limited(1 << 20))) |data| {
        const v = std.json.parseFromSliceLeaky(Value, arena, data, .{}) catch return error.InvalidSettings;
        if (v != .object) return error.InvalidSettings;
        settings = v.object;
    } else |err| switch (err) {
        error.FileNotFound => if (hooks == null) return,
        else => return err,
    }
    if (hooks) |text| {
        const v = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
        try settings.put(arena, "hooks", v);
    } else if (!settings.orderedRemove("hooks")) return;
    if (std.fs.path.dirname(hooks_path)) |parent| try root.createDirPath(io, parent);
    const out = try std.json.Stringify.valueAlloc(arena, Value{ .object = settings }, .{ .whitespace = .indent_2 });
    try root.writeFile(io, .{ .sub_path = hooks_path, .data = out });
}

pub const Digest = [32]u8;

/// Content address of a tree: path, length and bytes of every file in order.
pub fn digest(tree: Tree) Digest {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("graff.harness_tree.v1\n");
    for (tree.files) |f| {
        h.update(f.path);
        h.update(&.{0});
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, f.data.len, .little);
        h.update(&len);
        h.update(f.data);
    }
    var out: Digest = undefined;
    h.final(&out);
    return out;
}

/// The first 16 hex digits, the width fleet ids use.
pub fn shortId(d: Digest) [16]u8 {
    const hex = std.fmt.bytesToHex(d, .lower);
    return hex[0..16].*;
}

pub const Diff = struct {
    added: []const []const u8,
    removed: []const []const u8,
    modified: []const []const u8,

    pub fn empty(self: Diff) bool {
        return self.added.len == 0 and self.removed.len == 0 and self.modified.len == 0;
    }
};

/// Paths `after` adds, drops, or changes relative to `before`.
pub fn diff(arena: Allocator, before: Tree, after: Tree) !Diff {
    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var modified: std.ArrayList([]const u8) = .empty;
    for (after.files) |f| {
        const old = before.get(f.path) orelse {
            try added.append(arena, f.path);
            continue;
        };
        if (!std.mem.eql(u8, old, f.data)) try modified.append(arena, f.path);
    }
    for (before.files) |f| if (after.get(f.path) == null) try removed.append(arena, f.path);
    return .{ .added = added.items, .removed = removed.items, .modified = modified.items };
}
