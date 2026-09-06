//! Near-miss help for `codedb list_dir <path>` when the path does not exist.
//!
//! The prompt tells the model to prefer list_dir over `ls`, so a bare "was not
//! found" is a dead end: one slipped letter (`rach-server` for
//! `rachs-servers/`) cost a session six tool calls and a question to the user
//! before a plain listing surfaced the name. The not-found reply now names the
//! closest sibling entries and lists the parent, so the next call can be the
//! right one. Distance is edit distance over a normalized form (case and the
//! separators '-', '_', '.', ' ' ignored); containment either way is close.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

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
    const target = std.mem.trimEnd(u8, resolved, "/");
    const leaf = std.fs.path.basename(target);
    if (leaf.len == 0) return null;
    const parent_abs = std.fs.path.dirname(target) orelse (agent_cwd orelse ".");
    const parent_display = std.fs.path.dirname(std.mem.trimEnd(u8, display, "/")) orelse ".";

    var dir = Io.Dir.cwd().openDir(io, parent_abs, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (entries.items.len == max_scanned) break;
        const is_dir = entry.kind == .directory;
        const shown = std.fmt.allocPrint(arena, "{s}{s}", .{ entry.name, if (is_dir) "/" else "" }) catch return null;
        entries.append(arena, .{ .shown = shown, .is_dir = is_dir, .dist = distance(leaf, entry.name) }) catch return null;
    }
    if (entries.items.len == 0) return null;

    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    std.mem.sort(Entry, entries.items, {}, byDist);
    var close: usize = 0;
    for (entries.items) |e| {
        if (e.dist > threshold(leaf) or close == max_close) break;
        w.print("{s}{s}", .{ if (close == 0) " Closest match: " else ", ", e.shown }) catch return null;
        close += 1;
    }
    if (close > 0) w.writeAll(".") catch return null;

    std.mem.sort(Entry, entries.items, {}, byName);
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
    return aw.writer.buffered();
}

test "distance: separators and case are free, containment is close, unrelated is far" {
    try std.testing.expectEqual(@as(usize, 0), distance("Rachs_Servers", "rachs-servers"));
    try std.testing.expect(distance("rach-server", "rachs-servers") <= 2);
    try std.testing.expectEqual(@as(usize, 1), distance("server", "rachs-servers"));
    try std.testing.expect(distance("rach-server", "frontend") > threshold("rach-server"));
}

test "not found: names the closest sibling and lists the parent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.createDirPath(io, "rachs-servers") catch unreachable;
    tmp.dir.createDirPath(io, "frontend") catch unreachable;
    tmp.dir.createDirPath(io, ".git") catch unreachable;
    tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" }) catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const missing = try std.fmt.allocPrint(arena, "{s}/rach-server", .{buf[0..n]});

    const hint = suggest(io, arena, missing, "rach-server", null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(" Closest match: rachs-servers/. Entries in . (3): frontend/, rachs-servers/, README.md.", hint);

    const unrelated = try std.fmt.allocPrint(arena, "{s}/zzz", .{buf[0..n]});
    const none = suggest(io, arena, unrelated, "sub/zzz", null) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, none, "Closest match") == null);
    try std.testing.expect(std.mem.startsWith(u8, none, " Entries in sub (3): "));
}
