//! `read_tool_result`: byte-range or literal-search a spilled #440 handle.
//!
//! A fat bash/codedb result lands in `.graff/tool-results/tr_N.txt` and the
//! model sees a preview + handle id. This tool is how it pages the rest
//! without pulling the whole payload back into history (fx's overflow
//! handle). The path jail is the handle dir itself — not an extra workspace
//! root, and not a way around PathConfine for arbitrary files.

const std = @import("std");
const Io = std.Io;

const tools = @import("tools.zig");
const tool_handle = @import("tool_handle.zig");
const util = @import("util.zig");

pub const tool_name = "read_tool_result";
pub const tool_desc = "Read a spilled tool-result handle. Pass handle (tr_N from the overflow marker) plus offset/limit in bytes, or query for a literal search. Never pull the whole payload — one fat bash/codedb hit stays out of history.";
pub const tool_schema =
    \\{"type": "object", "properties": {"handle": {"type": "string", "description": "Handle id (tr_N) from a tool-result overflow marker, or the handle file path"}, "offset": {"type": "integer", "description": "Byte offset into the stored result (default 0)"}, "limit": {"type": "integer", "description": "Max bytes to return (default 4096, cap 16384)"}, "query": {"type": "string", "description": "Optional literal search; returns matching windows instead of a raw slice"}}, "required": ["handle"]}
;

pub const default_limit: usize = 4096;
pub const max_limit: usize = 16384;
const max_hits: usize = 8;
const handle_preview = @import("handle_preview.zig");
const max_hit_bytes: usize = 1024;

/// Parse `tr_12` (or `TR_12`) into the sequence number. null when the token
/// is not a handle id.
pub fn parseId(raw: []const u8) ?u64 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len < 4) return null;
    if (!std.ascii.eqlIgnoreCase(t[0..3], "tr_")) return null;
    return std.fmt.parseInt(u64, t[3..], 10) catch null;
}

/// Relative path under cwd for handle `tr_N`.
pub fn relPath(arena: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/tr_{d}.txt", .{ tool_handle.handles_dir, id });
}

fn clampLimit(n: ?i64) usize {
    const raw: usize = if (n) |v| (if (v <= 0) default_limit else @intCast(v)) else default_limit;
    return @min(raw, max_limit);
}

fn clampOffset(n: ?i64, len: usize) usize {
    if (n == null or n.? <= 0) return 0;
    const off: usize = @intCast(n.?);
    return @min(off, len);
}

/// Literal search: up to `max_hits` windows around each match.
fn search(arena: std.mem.Allocator, text: []const u8, query: []const u8) ![]const u8 {
    if (query.len == 0) return error.EmptyQuery;
    var aw: Io.Writer.Allocating = .init(arena);
    var hits: usize = 0;
    var i: usize = 0;
    while (i < text.len and hits < max_hits) {
        const rest = text[i..];
        const at = std.mem.indexOf(u8, rest, query) orelse break;
        const abs = i + at;
        // Whole matching line, not an 80-byte pad: a long `status=FAILED`
        // line has request_id before the match, and a pad cut it off.
        const b = handle_preview.lineBounds(text, abs);
        const span = text[b.lo..b.hi];
        const shown = if (span.len > max_hit_bytes) span[0..max_hit_bytes] else span;
        try aw.writer.print("hit {d} at byte {d}:\n{s}\n---\n", .{ hits + 1, abs, shown });
        hits += 1;
        i = abs + query.len;
    }
    if (hits == 0) return std.fmt.allocPrint(arena, "no match for {s} in {d} bytes", .{ query, text.len });
    try aw.writer.print("{d} hit(s), {d} bytes total", .{ hits, text.len });
    return aw.writer.buffered();
}

fn sliceText(arena: std.mem.Allocator, text: []const u8, offset: usize, limit: usize) ![]const u8 {
    if (offset >= text.len) return std.fmt.allocPrint(arena, "offset {d} is past the {d}-byte result", .{ offset, text.len });
    const end = @min(text.len, offset + limit);
    const body = text[offset..end];
    if (end == text.len and offset == 0) return arena.dupe(u8, body);
    return std.fmt.allocPrint(arena, "{s}\n\n[{d}..{d} of {d} bytes]", .{ body, offset, end, text.len });
}

const max_tracked_handles: usize = 256;
const TrackedEntry = struct {
    id: u64 = 0,
    len: usize = 0,
    path: [std.fs.max_path_bytes]u8 = undefined,
    used: bool = false,
};
var g_lock: std.atomic.Value(bool) = .init(false);
var g_entries: [max_tracked_handles]TrackedEntry = @splat(.{});
var g_next_slot: usize = 0;

fn lockTable() void {
    while (g_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockTable() void {
    g_lock.store(false, .release);
}

pub fn resetForTest() void {
    lockTable();
    defer unlockTable();
    for (&g_entries) |*e| e.used = false;
    g_next_slot = 0;
}

/// Bind a handle id to its originating absolute file path so a later
/// `workspace use` cannot redirect `tr_N` to a same-numbered file in another
/// worktree (#1820).
pub fn rememberHandle(id: u64, path: []const u8) void {
    if (!std.fs.path.isAbsolute(path) or path.len == 0 or path.len > std.fs.max_path_bytes) return;
    lockTable();
    defer unlockTable();
    for (&g_entries) |*e| {
        if (e.used and e.id == id) {
            @memcpy(e.path[0..path.len], path);
            e.len = path.len;
            return;
        }
    }
    const slot = g_next_slot % max_tracked_handles;
    g_next_slot +%= 1;
    g_entries[slot].id = id;
    g_entries[slot].len = path.len;
    @memcpy(g_entries[slot].path[0..path.len], path);
    g_entries[slot].used = true;
}

pub fn lookupHandle(arena: std.mem.Allocator, id: u64) ?[]const u8 {
    lockTable();
    defer unlockTable();
    for (&g_entries) |*e| {
        if (e.used and e.id == id) return arena.dupe(u8, e.path[0..e.len]) catch null;
    }
    return null;
}

fn hasDotDot(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| if (std.mem.eql(u8, comp, "..")) return true;
    return false;
}

const handles_dir_win = ".graff\\tool-results";

fn findHandlesDir(t: []const u8) ?usize {
    return std.mem.indexOf(u8, t, tool_handle.handles_dir) orelse std.mem.indexOf(u8, t, handles_dir_win);
}

fn validTailId(rest: []const u8) ?u64 {
    const dir_len = tool_handle.handles_dir.len;
    if (rest.len <= dir_len + 1) return null;
    if (!std.mem.startsWith(u8, rest, tool_handle.handles_dir) and !std.mem.startsWith(u8, rest, handles_dir_win)) return null;
    if (rest[dir_len] != '/' and rest[dir_len] != '\\') return null;
    const base = rest[dir_len + 1 ..];
    if (std.mem.indexOfAny(u8, base, "/\\") != null) return null;
    if (!std.mem.endsWith(u8, base, ".txt")) return null;
    return parseId(base[0 .. base.len - 4]);
}

/// Resolve a handle token to a cwd-relative path under the handle dir.
pub fn resolveRel(arena: std.mem.Allocator, handle: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, handle, " \t");
    if (parseId(t)) |id| return relPath(arena, id);
    if (hasDotDot(t)) return error.BadHandle;
    if (findHandlesDir(t)) |at| {
        if (at > 0 and t[at - 1] != '/' and t[at - 1] != '\\') return error.BadHandle;
        const rest = t[at..];
        const id = validTailId(rest) orelse return error.BadHandle;
        return relPath(arena, id);
    }
    return error.BadHandle;
}

/// Resolve a handle id or explicit handle path to the file to read (#1820).
/// Keeps an explicit worktree path intact instead of stripping the prefix and
/// reading the new workspace's `.graff/tool-results/tr_N.txt`.
pub fn resolvePath(arena: std.mem.Allocator, handle: []const u8, agent_cwd: ?[]const u8) ![]const u8 {
    const t = std.mem.trim(u8, handle, " \t");
    if (parseId(t)) |id| {
        if (lookupHandle(arena, id)) |abs| return abs;
        const rel = try relPath(arena, id);
        if (agent_cwd) |cwd| return std.fs.path.join(arena, &.{ cwd, rel });
        return rel;
    }
    if (hasDotDot(t)) return error.BadHandle;
    const at = findHandlesDir(t) orelse return error.BadHandle;
    if (at > 0 and t[at - 1] != '/' and t[at - 1] != '\\') return error.BadHandle;
    const rest = t[at..];
    const id = validTailId(rest) orelse return error.BadHandle;
    if (at > 0) {
        if (std.fs.path.isAbsolute(t) or agent_cwd == null) return t;
        return std.fs.path.join(arena, &.{ agent_cwd.?, t });
    }
    if (lookupHandle(arena, id)) |abs| return abs;
    const rel = try relPath(arena, id);
    if (agent_cwd) |cwd| return std.fs.path.join(arena, &.{ cwd, rel });
    return rel;
}

pub fn readStored(io: Io, arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, rel, arena, .limited(64 * 1024 * 1024)) catch return error.MissingHandle;
}

pub fn exec(ctx: tools.ToolCtx, call: tools.ToolCall) !tools.ToolOutput {
    const gpa = ctx.gpa;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const handle = tools.strField(call.input, "handle") orelse return tools.missingArg(gpa, "handle");
    const rel = resolvePath(arena, handle, ctx.agent_cwd) catch
        return .{ .text = try std.fmt.allocPrint(gpa, "read_tool_result: '{s}' is not a handle (want tr_N)", .{handle}), .is_error = true };
    const stored = readStored(ctx.io, arena, rel) catch
        return .{ .text = try std.fmt.allocPrint(gpa, "read_tool_result: no stored result at {s}", .{rel}), .is_error = true };
    const text = if (tools.strField(call.input, "query")) |q| blk: {
        break :blk search(arena, stored, q) catch
            return .{ .text = try gpa.dupe(u8, "read_tool_result: query must not be empty"), .is_error = true };
    } else blk: {
        // ADR 0238: an rlm bind is not in the conversation, so a read with no
        // range binds the whole stored result; print() still shows the slim view.
        if (ctx.rlm_host and tools.intField(call.input, "offset") == null and tools.intField(call.input, "limit") == null) break :blk stored;
        const off = clampOffset(tools.intField(call.input, "offset"), stored.len);
        const lim = clampLimit(tools.intField(call.input, "limit"));
        break :blk try sliceText(arena, stored, off, lim);
    };
    return .{ .text = try gpa.dupe(u8, text) };
}

test "parseId accepts tr_N only" {
    try std.testing.expectEqual(@as(?u64, 0), parseId("tr_0"));
    try std.testing.expectEqual(@as(?u64, 12), parseId("TR_12"));
    try std.testing.expect(parseId("tr_") == null);
    try std.testing.expect(parseId("/etc/passwd") == null);
    try std.testing.expect(parseId("run-0.txt") == null);
}

test "resolveRel maps tr_N and rejects escape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(".graff/tool-results/tr_3.txt", try resolveRel(a, "tr_3"));
    try std.testing.expectEqualStrings(".graff/tool-results/tr_1.txt", try resolveRel(a, "/tmp/proj/.graff/tool-results/tr_1.txt"));
    try std.testing.expectEqualStrings(".graff/tool-results/tr_1.txt", try resolveRel(a, "D:\\a\\proj\\.graff\\tool-results\\tr_1.txt"));
    try std.testing.expectEqualStrings("D:\\a\\proj\\.graff\\tool-results\\tr_1.txt", try resolvePath(a, "D:\\a\\proj\\.graff\\tool-results\\tr_1.txt", null));
    try std.testing.expectError(error.BadHandle, resolveRel(a, "../secret"));
    try std.testing.expectError(error.BadHandle, resolveRel(a, "/etc/passwd"));
}

test "byte-range and query stay bounded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const big = "aaa NEEDLE aaa NEEDLE zzz";
    const sliced = try sliceText(a, big, 4, 6);
    try std.testing.expect(std.mem.indexOf(u8, sliced, "NEEDLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sliced, "of 25 bytes") != null);
    const hits = try search(a, big, "NEEDLE");
    try std.testing.expect(std.mem.indexOf(u8, hits, "2 hit(s)") != null);
    try std.testing.expectError(error.EmptyQuery, search(a, big, ""));
}

test "query returns the whole matching line, including bytes before the needle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = "request_id=req-8c41de07 stage=link status=FAILED reason=undefined_symbol";
    const hits = try search(a, "ok\n" ++ line ++ "\nzz", "FAILED");
    try std.testing.expect(std.mem.indexOf(u8, hits, "req-8c41de07") != null);
    try std.testing.expect(std.mem.indexOf(u8, hits, "1 hit(s)") != null);
}

test "#1820: read_tool_result keeps the originating artifact across a workspace switch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    tool_handle.resetForTest();
    defer tool_handle.resetForTest();

    var tree_a = std.testing.tmpDir(.{});
    defer tree_a.cleanup();
    var tree_b = std.testing.tmpDir(.{});
    defer tree_b.cleanup();

    const pad: [512]u8 = @splat('a');
    const payload_a = "WORKTREE_A_ORIGIN_RESULT_" ++ &pad;
    const handled = try tool_handle.forResult(std.testing.allocator, a, .{ .io = io, .dir = tree_a.dir }, payload_a, 128);
    const path_a = handled.path orelse return error.TestUnexpectedResult;

    // Colliding tr_0.txt in worktree B from an earlier session.
    try tree_b.dir.createDirPath(io, tool_handle.handles_dir);
    try tree_b.dir.writeFile(io, .{ .sub_path = ".graff/tool-results/tr_0.txt", .data = "WORKTREE_B_WRONG_RESULT" });
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const n_b = tree_b.dir.realPath(io, &buf_b) catch return error.SkipZigTest;
    const cwd_b = buf_b[0..n_b];

    // Even when the current workspace is B, both `tr_0` and the explicit path
    // from A resolve to A's artifact rather than B's colliding tr_0.txt.
    const by_id = try resolvePath(a, "tr_0", cwd_b);
    const by_abs = try resolvePath(a, path_a, cwd_b);
    try std.testing.expectEqualStrings(path_a, by_id);
    try std.testing.expectEqualStrings(path_a, by_abs);
    const read_id = try readStored(io, a, by_id);
    const read_abs = try readStored(io, a, by_abs);
    try std.testing.expectEqualStrings(payload_a, read_id);
    try std.testing.expectEqualStrings(payload_a, read_abs);
}
