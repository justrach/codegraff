//! A compact map of the working tree's top levels, appended to the root
//! system prompt once at session start. opencode/codex-shaped models read the
//! files they need directly; without this they spend their first turns on
//! `ls`/`find` exploration (measured: 8-12 turns of a ~40-call feature task).
//! Deterministic (sorted) so prompt rebuilds produce byte-identical text —
//! the segment lives inside the cache-stable prefix. Built once per process:
//! mid-session file changes are NOT reflected, which the header says.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_depth = 3;
const max_entries = 300;
const max_bytes = 6 * 1024;

/// Directories that are never informative to the model at this granularity.
const skip_dirs = [_][]const u8{ ".git", "node_modules", "zig-cache", "zig-out", ".zig-cache", "target", "dist", "build", "__pycache__", ".venv", "venv", ".hg", ".svn" };

const Ent = struct { name: []const u8, dir: bool };

fn entLt(_: void, a: Ent, b: Ent) bool {
    if (a.dir != b.dir) return a.dir;
    return std.mem.lessThan(u8, a.name, b.name);
}

var cached: ?[]const u8 = null; // built once per process (see module doc)

fn skipped(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for (skip_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

fn walk(io: Io, arena: Allocator, out: *std.ArrayList([]const u8), dir_path: []const u8, depth: usize, omitted: *usize) void {
    if (out.items.len >= max_entries) return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList(Ent) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (skipped(entry.name)) continue;
        const recursed = entry.kind == .directory and depth < max_depth and out.items.len < max_entries;
        names.append(arena, .{ .name = std.fmt.allocPrint(arena, "{s}{s}", .{ entry.name, if (entry.kind == .directory) "/" else "" }) catch continue, .dir = recursed }) catch continue;
    }
    // Directories first, then files, alphabetical within each — stable output.
    std.mem.sort(Ent, names.items, {}, entLt);
    for (names.items) |item| {
        if (out.items.len >= max_entries) {
            omitted.* += 1;
            continue;
        }
        const rel = if (std.mem.eql(u8, dir_path, ".")) item.name else std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, item.name }) catch continue;
        out.append(arena, rel) catch return;
        if (item.dir) walk(io, arena, out, rel[0 .. rel.len - 1], depth + 1, omitted);
    }
}

/// The prompt segment, or null when the tree is empty/unreadable. Cached for
/// the process so every prompt rebuild reuses the same bytes.
pub fn segment(io: Io, arena: Allocator) ?[]const u8 {
    if (cached) |c| return if (c.len == 0) null else c;
    var entries: std.ArrayList([]const u8) = .empty;
    var omitted: usize = 0;
    walk(io, arena, &entries, ".", 1, &omitted);
    if (entries.items.len == 0) {
        cached = "";
        return null;
    }
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.print("\n\n# Project layout (working tree at session start, depth {d}; may omit later changes)\n", .{max_depth}) catch return null;
    var bytes: usize = 0;
    for (entries.items) |e| {
        if (bytes + e.len > max_bytes) {
            omitted += 1;
            continue;
        }
        bytes += e.len + 1;
        aw.writer.print("{s}\n", .{e}) catch return null;
    }
    if (omitted > 0) aw.writer.print("... ({d} more entries not shown — list directories on demand)\n", .{omitted}) catch return null;
    cached = aw.writer.buffered();
    return cached;
}
