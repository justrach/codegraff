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
const window_pad: usize = 80;

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
        const lo = abs -| window_pad;
        const hi = @min(text.len, abs + query.len + window_pad);
        try aw.writer.print("hit {d} at byte {d}:\n{s}\n---\n", .{ hits + 1, abs, text[lo..hi] });
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

/// Resolve a handle token to a cwd-relative path under the handle dir.
pub fn resolveRel(arena: std.mem.Allocator, handle: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, handle, " \t");
    if (parseId(t)) |id| return relPath(arena, id);
    // Accept the file's own relative or absolute path when it still names
    // the handle dir (old markers printed the absolute path).
    const needle = tool_handle.handles_dir;
    if (std.mem.indexOf(u8, t, needle)) |at| {
        const rest = t[at..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null) return error.BadHandle;
        if (std.mem.indexOf(u8, rest, "..") != null) return error.BadHandle;
        return rest;
    }
    return error.BadHandle;
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
    const rel = resolveRel(arena, handle) catch
        return .{ .text = try std.fmt.allocPrint(gpa, "read_tool_result: '{s}' is not a handle (want tr_N)", .{handle}), .is_error = true };
    const stored = readStored(ctx.io, arena, rel) catch
        return .{ .text = try std.fmt.allocPrint(gpa, "read_tool_result: no stored result at {s}", .{rel}), .is_error = true };
    const text = if (tools.strField(call.input, "query")) |q| blk: {
        break :blk search(arena, stored, q) catch
            return .{ .text = try gpa.dupe(u8, "read_tool_result: query must not be empty"), .is_error = true };
    } else blk: {
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
