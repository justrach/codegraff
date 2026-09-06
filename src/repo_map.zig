//! A compact map of the working tree's top levels, appended to the root
//! system prompt once at session start. opencode/codex-shaped models read the
//! files they need directly; without this they spend their first turns on
//! `ls`/`find` exploration (measured: 8-12 turns of a ~40-call feature task).
//! Deterministic (sorted) so prompt rebuilds produce byte-identical text —
//! the segment lives inside the cache-stable prefix. Built once per process:
//! mid-session file changes are NOT reflected, which the header says.
//!
//! Selection is breadth-first and round-robin: every top-level entry is chosen
//! before any child, then each directory's first child, second child, and so
//! on, under the entry and byte caps. The old depth-first fill let the first
//! few fat directories spend the whole budget, so a late-alphabet top-level
//! folder never appeared and the prompt's "it is the tree" sent the model
//! looking for a remote host instead of the folder the user had named.
//! Emission stays depth-first (a path list in tree order), and the trailer
//! names the top-level directories that were not fully expanded, so an absent
//! top-level name means absent, not truncated.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_depth = 3;
const max_entries = 300;
const max_bytes = 6 * 1024;
/// How many not-fully-expanded top-level directories the trailer names.
const max_named = 12;

/// Directories that are never informative to the model at this granularity.
const skip_dirs = [_][]const u8{ ".git", "node_modules", "zig-cache", "zig-out", ".zig-cache", "target", "dist", "build", "__pycache__", ".venv", "venv", ".hg", ".svn" };

const Node = struct {
    /// Relative path; directories carry a trailing '/'.
    rel: []const u8,
    is_dir: bool,
    depth: usize,
    /// The depth-1 ancestor (self at depth 1) — where omissions are charged.
    top: ?*Node,
    kids: std.ArrayList(*Node) = .empty,
    selected: bool = false,
    /// Enumerated entries beneath this top-level directory the caps left out.
    omitted_below: usize = 0,
};

const Budget = struct {
    entries: usize = 0,
    bytes: usize = 0,
    omitted: usize = 0,
    root_omitted: usize = 0,
};

var cached: ?[]const u8 = null; // built once per process (see module doc)

fn skipped(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for (skip_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

fn nodeLt(_: void, a: *Node, b: *Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.lessThan(u8, a.rel, b.rel);
}

/// Read `parent`'s children, sorted directories first then by name.
fn readChildren(io: Io, arena: Allocator, root: []const u8, parent: *Node) void {
    const dir_path: []const u8 = if (parent.depth == 0)
        root
    else if (std.mem.eql(u8, root, "."))
        parent.rel[0 .. parent.rel.len - 1]
    else
        std.fmt.allocPrint(arena, "{s}/{s}", .{ root, parent.rel[0 .. parent.rel.len - 1] }) catch return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (skipped(entry.name)) continue;
        const is_dir = entry.kind == .directory;
        const rel = std.fmt.allocPrint(arena, "{s}{s}{s}", .{ parent.rel, entry.name, if (is_dir) "/" else "" }) catch continue;
        const n = arena.create(Node) catch continue;
        n.* = .{ .rel = rel, .is_dir = is_dir, .depth = parent.depth + 1, .top = null };
        n.top = if (parent.depth == 0) n else parent.top;
        parent.kids.append(arena, n) catch continue;
    }
    std.mem.sort(*Node, parent.kids.items, {}, nodeLt);
}

fn take(b: *Budget, n: *Node) void {
    const cost = n.rel.len + 1;
    if (b.entries < max_entries and b.bytes + cost <= max_bytes) {
        n.selected = true;
        b.entries += 1;
        b.bytes += cost;
        return;
    }
    b.omitted += 1;
    if (n.depth == 1) {
        b.root_omitted += 1;
    } else if (n.top) |t| {
        t.omitted_below += 1;
    }
}

fn emit(w: *Io.Writer, n: *Node) !void {
    for (n.kids.items) |k| {
        if (!k.selected) continue;
        try w.print("{s}\n", .{k.rel});
        if (k.is_dir) try emit(w, k);
    }
}

fn trailer(w: *Io.Writer, root_node: *Node, b: *const Budget) !void {
    try w.print("... ({d} more entries not shown", .{b.omitted});
    if (b.root_omitted > 0) try w.print("; {d} of them top-level", .{b.root_omitted});
    var named: usize = 0;
    var extra: usize = 0;
    for (root_node.kids.items) |k| {
        if (!k.is_dir or k.omitted_below == 0) continue;
        if (named == max_named) {
            extra += 1;
            continue;
        }
        try w.print("{s}{s}", .{ if (named == 0) "; not fully expanded: " else ", ", k.rel });
        named += 1;
    }
    if (extra > 0) try w.print(" and {d} more", .{extra});
    try w.writeAll(" — list a directory on demand)\n");
}

/// Build the segment for `root` ("." in production; tests pass a temp dir).
/// Null when the tree is empty or unreadable.
pub fn build(io: Io, arena: Allocator, root: []const u8) ?[]const u8 {
    const root_node = arena.create(Node) catch return null;
    root_node.* = .{ .rel = "", .is_dir = true, .depth = 0, .top = null };
    var budget: Budget = .{};
    var level: std.ArrayList(*Node) = .empty;
    level.append(arena, root_node) catch return null;
    var depth: usize = 1;
    while (depth <= max_depth and level.items.len > 0) : (depth += 1) {
        for (level.items) |p| readChildren(io, arena, root, p);
        // Round-robin across this level's directories: each gets its first
        // child before any gets its second, so a fat sibling cannot starve
        // the others.
        var i: usize = 0;
        var any = true;
        while (any) : (i += 1) {
            any = false;
            for (level.items) |p| {
                if (i < p.kids.items.len) {
                    any = true;
                    take(&budget, p.kids.items[i]);
                }
            }
        }
        var next: std.ArrayList(*Node) = .empty;
        for (level.items) |p| {
            for (p.kids.items) |k| {
                if (k.selected and k.is_dir) next.append(arena, k) catch {};
            }
        }
        level = next;
    }
    if (root_node.kids.items.len == 0) return null;

    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.print("\n\n# Project layout (working tree at session start, depth {d}; may omit later changes)\n", .{max_depth}) catch return null;
    emit(&aw.writer, root_node) catch return null;
    if (budget.omitted > 0) trailer(&aw.writer, root_node, &budget) catch return null;
    return aw.writer.buffered();
}

/// The prompt segment, or null when the tree is empty/unreadable. Cached for
/// the process so every prompt rebuild reuses the same bytes.
pub fn segment(io: Io, arena: Allocator) ?[]const u8 {
    if (cached) |c| return if (c.len == 0) null else c;
    const built = build(io, arena, ".") orelse "";
    cached = built;
    return if (built.len == 0) null else built;
}

fn tmpAbs(io: Io, tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "small tree emits in tree order, hides dot and build dirs, no trailer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "b") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "b/y.txt", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, "a/deep") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "a/x.txt", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, ".git/objects") catch unreachable;
    tmp.dir.createDirPath(io, "node_modules/pkg") catch unreachable;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = build(io, arena_state.allocator(), abs) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "\n\n# Project layout (working tree at session start, depth 3; may omit later changes)\n" ++
            "a/\na/deep/\na/x.txt\nb/\nb/y.txt\nc.txt\n",
        out,
    );
}

test "breadth-first: a late top-level directory survives fat early siblings" {
    // The failure this guards: fat directories ahead of it in the alphabet
    // spent the whole budget, so the model never saw the folder the user named.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var d: usize = 0;
    while (d < 10) : (d += 1) {
        var dn: [8]u8 = undefined;
        tmp.dir.createDirPath(io, std.fmt.bufPrint(&dn, "fat{d}", .{d}) catch unreachable) catch unreachable;
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            var name: [64]u8 = undefined;
            const n = std.fmt.bufPrint(&name, "fat{d}/file_with_a_longer_name_{d:0>3}.zig", .{ d, i }) catch unreachable;
            tmp.dir.writeFile(io, .{ .sub_path = n, .data = "x" }) catch unreachable;
        }
    }
    tmp.dir.createDirPath(io, "rachs-servers/egress-relay") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "rachs-servers/README.md", .data = "x" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "zz-top.txt", .data = "x" }) catch unreachable;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = build(io, arena_state.allocator(), abs) orelse return error.TestUnexpectedResult;
    // Every top-level entry is present …
    try std.testing.expect(std.mem.indexOf(u8, out, "\nrachs-servers/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nzz-top.txt\n") != null);
    // … each directory got its first children (round-robin) …
    try std.testing.expect(std.mem.indexOf(u8, out, "\nrachs-servers/egress-relay/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nrachs-servers/README.md\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nfat9/file_with_a_longer_name_000.zig\n") != null);
    // … the caps still hold, and the trailer names what was cut, not what was not.
    try std.testing.expect(out.len <= max_bytes + 512);
    const trailer_at = std.mem.indexOf(u8, out, "\n... (") orelse return error.TestUnexpectedResult;
    const tail = out[trailer_at..];
    try std.testing.expect(std.mem.indexOf(u8, tail, "more entries not shown; not fully expanded: fat0/, fat1/") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "fat9/ — list a directory on demand)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "rachs-servers/") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "top-level") == null);
}

test "top-level overflow is reported as such" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var i: usize = 0;
    while (i < 310) : (i += 1) {
        var name: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&name, "f{d:0>3}.txt", .{i}) catch unreachable;
        tmp.dir.writeFile(io, .{ .sub_path = n, .data = "x" }) catch unreachable;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmpAbs(io, &tmp, &buf);
    const out = build(io, arena_state.allocator(), abs) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, out, "\nf299.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nf300.txt\n") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "... (10 more entries not shown; 10 of them top-level — list a directory on demand)\n"));
}
