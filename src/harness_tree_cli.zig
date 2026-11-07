//! `graff harness-tree …`: the harness tree from the command line.
//!
//!   show [dir] [--json]      the files that make up the harness, with its id
//!   digest [dir]             just the id
//!   check <dir> [--base <d>] can graff run the harness in <dir>? (exit 1 if not)
//!   apply <from> <to>        make <to>'s harness exactly <from>'s
//!   diff <a> <b>             paths added, removed and changed from a to b
//!
//! `check` is for a harness-only directory (one `apply` exported): every file
//! in it must be part of the harness, so a misplaced file is reported rather
//! than silently left out.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tree_mod = @import("harness_tree.zig");
const check_mod = @import("harness_tree_check.zig");

const usage =
    \\usage: graff harness-tree show [dir] [--json]
    \\       graff harness-tree digest [dir]
    \\       graff harness-tree check <dir> [--base <dir>]
    \\       graff harness-tree apply <from> <to>
    \\       graff harness-tree diff <a> <b>
    \\
;

pub fn command(io: Io, arena: Allocator, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};
    const code = run(io, arena, out, args) catch |err| {
        try out.print("graff harness-tree: {s}\n", .{@errorName(err)});
        try out.flush();
        std.process.exit(1);
    };
    if (code != 0) {
        try out.flush();
        std.process.exit(code);
    }
}

pub fn run(io: Io, arena: Allocator, out: *Io.Writer, args: []const []const u8) !u8 {
    const action = if (args.len > 0) args[0] else "show";
    var pos: std.ArrayList([]const u8) = .empty;
    var json = false;
    var base_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, args[i], "--base") and i + 1 < args.len) {
            i += 1;
            base_dir = args[i];
        } else try pos.append(arena, args[i]);
    }
    const p = pos.items;
    if (std.mem.eql(u8, action, "show")) return show(io, arena, out, if (p.len > 0) p[0] else ".", json);
    if (std.mem.eql(u8, action, "digest")) {
        const loaded = try loadAt(io, arena, if (p.len > 0) p[0] else ".");
        try out.print("{s}\n", .{&std.fmt.bytesToHex(tree_mod.digest(loaded.tree), .lower)});
        return 0;
    }
    if (std.mem.eql(u8, action, "check") and p.len == 1) return check(io, arena, out, p[0], base_dir);
    if (std.mem.eql(u8, action, "apply") and p.len == 2) {
        const from = try loadAt(io, arena, p[0]);
        try Io.Dir.cwd().createDirPath(io, p[1]);
        var dest = try Io.Dir.cwd().openDir(io, p[1], .{});
        defer dest.close(io);
        try tree_mod.write(io, arena, from.tree, dest);
        try out.print("{s}\n", .{&tree_mod.shortId(tree_mod.digest(from.tree))});
        return 0;
    }
    if (std.mem.eql(u8, action, "diff") and p.len == 2) {
        const a = try loadAt(io, arena, p[0]);
        const b = try loadAt(io, arena, p[1]);
        const d = try tree_mod.diff(arena, a.tree, b.tree);
        for (d.added) |path| try out.print("+ {s}\n", .{path});
        for (d.removed) |path| try out.print("- {s}\n", .{path});
        for (d.modified) |path| try out.print("~ {s}\n", .{path});
        return 0;
    }
    try out.writeAll(usage);
    return 2;
}

fn loadAt(io: Io, arena: Allocator, path: []const u8) !tree_mod.Loaded {
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    return tree_mod.load(io, arena, dir);
}

fn show(io: Io, arena: Allocator, out: *Io.Writer, path: []const u8, json: bool) !u8 {
    const loaded = try loadAt(io, arena, path);
    const id = tree_mod.digest(loaded.tree);
    if (json) {
        var s: std.json.Stringify = .{ .writer = out };
        try s.beginObject();
        try s.objectField("digest");
        try s.write(&std.fmt.bytesToHex(id, .lower));
        try s.objectField("files");
        try s.beginArray();
        for (loaded.tree.files) |f| {
            try s.write(.{ .path = f.path, .part = tree_mod.classify(f.path).?.label(), .bytes = f.data.len });
        }
        try s.endArray();
        try s.objectField("skipped");
        try s.write(loaded.skipped);
        try s.endObject();
        try out.writeAll("\n");
        return 0;
    }
    try out.print("harness {s} ({d} files)\n", .{ &tree_mod.shortId(id), loaded.tree.files.len });
    for (loaded.tree.files) |f| try out.print("  {s:<12} {d:>7}  {s}\n", .{ tree_mod.classify(f.path).?.label(), f.data.len, f.path });
    for (loaded.skipped) |s| try out.print("  {s:<12} {s:>7}  {s}\n", .{ "skipped", "-", s });
    return 0;
}

fn check(io: Io, arena: Allocator, out: *Io.Writer, path: []const u8, base_dir: ?[]const u8) !u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const loaded = try tree_mod.load(io, arena, dir);
    const base: ?tree_mod.Tree = if (base_dir) |b| (try loadAt(io, arena, b)).tree else null;
    var lines: std.ArrayList([]const u8) = .empty;
    try strays(io, arena, dir, "", &lines, 6);
    for (loaded.skipped) |s| {
        if (tree_mod.classify(s) != null) try lines.append(arena, try std.fmt.allocPrint(arena, "{s} is over {d} bytes; keep each file smaller", .{ s, tree_mod.max_file_bytes }));
    }
    try lines.appendSlice(arena, try check_mod.problems(arena, loaded.tree, base));
    if (lines.items.len == 0) {
        try out.print("ok {s}\n", .{&tree_mod.shortId(tree_mod.digest(loaded.tree))});
        return 0;
    }
    for (lines.items) |l| try out.print("- {s}\n", .{l});
    return 1;
}

/// Every file under a harness-only directory that is not part of the harness.
fn strays(io: Io, arena: Allocator, root: Io.Dir, rel: []const u8, lines: *std.ArrayList([]const u8), depth: usize) !void {
    var dir = (if (rel.len == 0) root.openDir(io, ".", .{ .iterate = true }) else root.openDir(io, rel, .{ .iterate = true })) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const path = if (rel.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => if (depth > 0) try strays(io, arena, root, path, lines, depth - 1),
            .file => if (tree_mod.classify(path) == null) try lines.append(arena, try std.fmt.allocPrint(arena, "{s} is not part of the harness; move it to {s}/<name>/, {s}/ or {s}/, or drop it", .{ path, tree_mod.skills_dir, tree_mod.agents_dir, tree_mod.scripts_dir })),
            else => {},
        }
    }
}
