//! TUI /resume glue: list and load the line REPL's saved sessions
//! (.graff/sessions/*.session.json) for the fullscreen TUI's picker seam.
//! List rows are "base\ttitle\tage" lines, newest first — the same store
//! and metadata the line REPL's /resume and /sessions read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const repl_glue = @import("repl_glue.zig");
const ReplCtx = repl_glue.ReplCtx;
const session_index = @import("session_index.zig");
const tui = @import("tui");

/// engine.SessionsFn. gpa-owned; null when the store is missing/empty.
pub fn sessionsCb(ctx_ptr: ?*anyopaque, gpa: Allocator) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Item = struct { base: []const u8, title: []const u8, updated_ms: i64 };
    var items = std.array_list.Managed(Item).init(arena);
    var dir = Io.Dir.cwd().openDir(c.io, session_index.sessions_dir, .{ .iterate = true }) catch return null;
    defer dir.close(c.io);
    var it = dir.iterate();
    while (it.next(c.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, session_index.session_ext)) continue;
        const base = arena.dupe(u8, entry.name[0 .. entry.name.len - session_index.session_ext.len]) catch continue;
        const path = session_index.sessionPath(arena, base) catch continue;
        const data = Io.Dir.cwd().readFileAlloc(c.io, path, arena, .limited(8 * 1024 * 1024)) catch continue;
        const meta = session_index.sessionMetaFromBytes(arena, data);
        items.append(.{ .base = base, .title = meta.title orelse "", .updated_ms = meta.updated_ms }) catch {};
    }
    if (items.items.len == 0) return null;
    std.mem.sort(Item, items.items, {}, struct {
        fn newerFirst(_: void, a: Item, b: Item) bool {
            return a.updated_ms > b.updated_ms;
        }
    }.newerFirst);

    var out = std.array_list.Managed(u8).init(gpa);
    for (items.items) |item| {
        const age = session_index.sessionAge(arena, c.io, item.updated_ms);
        out.appendSlice(item.base) catch break;
        out.append('\t') catch break;
        appendSanitized(&out, item.title);
        out.append('\t') catch break;
        out.appendSlice(age) catch break;
        out.append('\n') catch break;
    }
    return out.toOwnedSlice() catch null;
}

/// Row fields are tab/newline-delimited; titles may contain either.
fn appendSanitized(out: *std.array_list.Managed(u8), s: []const u8) void {
    for (s) |ch| {
        out.append(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch) catch return;
    }
}

/// engine.ResumeFn: user/assistant text turns + the saved model name.
/// Tool traffic and non-text blocks are skipped — the TUI's model-visible
/// history is text turns, exactly what its next startJob will resend.
pub fn resumeCb(ctx_ptr: ?*anyopaque, gpa: Allocator, base: []const u8, out: *tui.ResumeOut) bool {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return false));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = session_index.sessionPath(arena, base) catch return false;
    const data = Io.Dir.cwd().readFileAlloc(c.io, path, arena, .limited(32 * 1024 * 1024)) catch return false;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, data, .{}) catch return false;
    if (parsed != .object) return false;
    const msgs = parsed.object.get("messages") orelse return false;
    if (msgs != .array) return false;

    var turns = std.array_list.Managed(tui.Turn).init(gpa);
    for (msgs.array.items) |m| {
        if (m != .object) continue;
        const role_v = m.object.get("role") orelse continue;
        if (role_v != .string) continue;
        const role: tui.Turn.Role = if (std.mem.eql(u8, role_v.string, "user"))
            .user
        else if (std.mem.eql(u8, role_v.string, "assistant"))
            .assistant
        else
            continue;
        const text = textOf(arena, m.object.get("content") orelse continue) orelse continue;
        const dup = gpa.dupe(u8, text) catch continue;
        turns.append(.{ .role = role, .text = dup }) catch gpa.free(dup);
    }
    out.turns = turns.toOwnedSlice() catch &.{};
    if (parsed.object.get("model")) |mv| {
        if (mv == .string and mv.string.len > 0) out.model = gpa.dupe(u8, mv.string) catch "";
    }
    return true;
}

/// Plain string content, or the joined text blocks of a structured message.
fn textOf(arena: Allocator, v: Value) ?[]const u8 {
    if (v == .string) return if (v.string.len > 0) v.string else null;
    if (v != .array) return null;
    var buf = std.array_list.Managed(u8).init(arena);
    for (v.array.items) |part| {
        if (part != .object) continue;
        const t = part.object.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "text")) continue;
        const s = part.object.get("text") orelse continue;
        if (s != .string) continue;
        if (buf.items.len > 0) buf.append('\n') catch {};
        buf.appendSlice(s.string) catch {};
    }
    return if (buf.items.len == 0) null else buf.items;
}

test "textOf: plain string, anthropic text blocks, tool-only content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain = try std.json.parseFromSliceLeaky(Value, arena, "\"hello\"", .{});
    try std.testing.expectEqualStrings("hello", textOf(arena, plain).?);
    const blocks = try std.json.parseFromSliceLeaky(Value, arena,
        \\[{"type":"text","text":"a"},{"type":"tool_use","id":"x"},{"type":"text","text":"b"}]
    , .{});
    try std.testing.expectEqualStrings("a\nb", textOf(arena, blocks).?);
    const tool_only = try std.json.parseFromSliceLeaky(Value, arena,
        \\[{"type":"tool_use","id":"x"}]
    , .{});
    try std.testing.expect(textOf(arena, tool_only) == null);
}
