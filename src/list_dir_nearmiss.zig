//! Near-miss help for `codedb list_dir <path>` when the path does not exist.
//!
//! A bare not-found error gives no way to recover from a mistyped path.
//! Naming the closest visible siblings and listing the parent helps the next
//! call use the right path. Distance is edit distance over a normalized form
//! (case and the separators '-', '_', '.', ' ' ignored); containment either
//! way is close.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const gitignore = @import("gitignore.zig");

const max_scanned = 4000;
const max_close = 3;
const max_listed_bytes = 1200;
const max_compare = 64;

const Entry = struct { shown: []const u8, is_dir: bool, dist: usize };

fn normalize(s: []const u8, buf: *[max_compare]u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n == max_compare) break;
        if (c == '-' or c == '_' or c == '.' or c == ' ') continue;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

fn levenshtein(a: []const u8, b: []const u8) usize {
    var prev: [max_compare + 1]usize = undefined;
    var cur: [max_compare + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @as(usize, if (ca == cb) 0 else 1);
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// 0 = same name up to case and separators; 1 = one contains the other.
pub fn distance(want: []const u8, have: []const u8) usize {
    var wb: [max_compare]u8 = undefined;
    var hb: [max_compare]u8 = undefined;
    const w = normalize(want, &wb);
    const h = normalize(have, &hb);
    if (w.len == 0 or h.len == 0) return max_compare;
    if (std.mem.eql(u8, w, h)) return 0;
    if (w.len >= 3 and (std.mem.indexOf(u8, h, w) != null or std.mem.indexOf(u8, w, h) != null)) return 1;
    return levenshtein(w, h);
}

fn threshold(want: []const u8) usize {
    return @max(2, want.len / 3);
}

fn byDist(_: void, a: Entry, b: Entry) bool {
    if (a.dist != b.dist) return a.dist < b.dist;
    return std.mem.lessThan(u8, a.shown, b.shown);
}

fn byName(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.lessThan(u8, a.shown, b.shown);
}

/// Text to append to the not-found error, or null when the parent cannot be
/// read. `resolved` is the path that failed; `display` is what the model
/// typed (its parent is echoed back so the next command can be copied).
pub fn suggest(io: Io, arena: Allocator, resolved: []const u8, display: []const u8, agent_cwd: ?[]const u8) ?[]const u8 {
    return suggestBudget(io, arena, resolved, display, agent_cwd, max_scanned);
}

fn suggestBudget(io: Io, arena: Allocator, resolved: []const u8, display: []const u8, agent_cwd: ?[]const u8, scan_budget: usize) ?[]const u8 {
    const target = std.mem.trimEnd(u8, resolved, "/");
    const leaf = std.fs.path.basename(target);
    if (leaf.len == 0) return null;
    const parent_abs = std.fs.path.dirname(target) orelse (agent_cwd orelse ".");
    const parent_display = std.fs.path.dirname(std.mem.trimEnd(u8, display, "/")) orelse ".";

    var dir = Io.Dir.cwd().openDir(io, parent_abs, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_len = dir.realPath(io, &parent_buf) catch return null;
    const root_abs = parent_buf[0..parent_len];
    const rules = gitignore.loadClimb(io, arena, root_abs) catch return null;
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    var scanned: usize = 0;
    var limited = false;
    while (true) {
        // The budget counts physical entries, including ignored names and
        // symlinks. Never enumerate a huge parent just to find a few matches.
        if (scanned == scan_budget) {
            limited = true;
            break;
        }
        const entry = (it.next(io) catch return null) orelse break;
        scanned += 1;
        if (entry.kind == .sym_link or std.mem.eql(u8, entry.name, ".git")) continue;
        const is_dir = entry.kind == .directory;
        const child_abs = std.fmt.allocPrint(arena, "{s}/{s}", .{ root_abs, entry.name }) catch return null;
        if (gitignore.ignored(arena, rules, root_abs, child_abs, is_dir) catch return null) continue;
        const shown = std.fmt.allocPrint(arena, "{s}{s}", .{ entry.name, if (is_dir) "/" else "" }) catch return null;
        entries.append(arena, .{ .shown = shown, .is_dir = is_dir, .dist = distance(leaf, entry.name) }) catch return null;
    }
    if (entries.items.len == 0) {
        if (!limited) return null;
        return std.fmt.allocPrint(arena, " Scan stopped after {d} entries in {s}; no visible entries were found among those scanned. Other matches may exist.", .{ scanned, parent_display }) catch null;
    }

    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    std.mem.sort(Entry, entries.items, {}, byDist);
    var close: usize = 0;
    for (entries.items) |e| {
        if (e.dist > threshold(leaf) or close == max_close) break;
        w.print("{s}{s}", .{ if (close == 0) (if (limited) " Closest among scanned entries: " else " Closest match: ") else ", ", e.shown }) catch return null;
        close += 1;
    }
    if (close > 0) w.writeAll(".") catch return null;

    std.mem.sort(Entry, entries.items, {}, byName);
    if (limited)
        w.print(" Visible entries among {d} scanned in {s} ({d}): ", .{ scanned, parent_display, entries.items.len }) catch return null
    else
        w.print(" Entries in {s} ({d}): ", .{ parent_display, entries.items.len }) catch return null;
    var bytes: usize = 0;
    var listed: usize = 0;
    for (entries.items) |e| {
        if (bytes + e.shown.len + 2 > max_listed_bytes) break;
        w.print("{s}{s}", .{ if (listed == 0) "" else ", ", e.shown }) catch return null;
        bytes += e.shown.len + 2;
        listed += 1;
    }
    if (listed < entries.items.len) w.print(", … {d} more", .{entries.items.len - listed}) catch return null;
    w.writeAll(".") catch return null;
    if (limited) w.print(" Scan stopped after {d} entries; other matches may exist.", .{scanned}) catch return null;
    return aw.writer.buffered();
}

test "distance: separators and case are free, containment is close, unrelated is far" {
    try std.testing.expectEqual(@as(usize, 0), distance("Demos_Servers", "demos-servers"));
    try std.testing.expect(distance("demo-server", "demos-servers") <= 2);
    try std.testing.expectEqual(@as(usize, 1), distance("server", "demos-servers"));
    try std.testing.expect(distance("demo-server", "frontend") > threshold("demo-server"));
}

test "not found: names the closest sibling and lists the parent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "demos-servers") catch unreachable;
    tmp.dir.createDirPath(io, "frontend") catch unreachable;
    tmp.dir.createDirPath(io, ".git") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "demo-server.log\ndemo-servers/\n" }) catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "demo-server.log", .data = "x" }) catch unreachable;
    tmp.dir.createDirPath(io, "demo-servers") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" }) catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const missing = try std.fmt.allocPrint(arena, "{s}/demo-server", .{buf[0..n]});

    const hint = suggest(io, arena, missing, "demo-server", null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(" Closest match: demos-servers/. Entries in . (4): demos-servers/, frontend/, .gitignore, README.md.", hint);

    try std.testing.expect(std.mem.indexOf(u8, hint, "demo-server.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "demo-servers/") == null);

    const unrelated = try std.fmt.allocPrint(arena, "{s}/zzz", .{buf[0..n]});
    const none = suggest(io, arena, unrelated, "sub/zzz", null) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, none, "Closest match") == null);
    try std.testing.expect(std.mem.startsWith(u8, none, " Entries in sub (4): "));
}

test "near-miss scan budget counts ignored entries and still reports an empty partial scan" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*\n" });
    for (0..4) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "ignored-{d}", .{i}), .data = "x" });
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const missing = try std.fmt.allocPrint(arena, "{s}/missing", .{path_buf[0..n]});
    const hint = suggestBudget(io, arena, missing, "missing", null, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, hint, "Scan stopped after 2 entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "no visible entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Closest match") == null);
}

test "near-miss partial scan never claims a global closest match" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const missing = try std.fmt.allocPrint(arena, "{s}/ax", .{path_buf[0..n]});
    const hint = suggestBudget(io, arena, missing, "ax", null, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, hint, "Closest among scanned entries:") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Visible entries among 1 scanned") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "other matches may exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Closest match:") == null);
}
