//! `/rewind` and `/edit`: drop or replace a past user prompt and everything
//! after it. The prefix before that prompt is unchanged, so a follow-up can
//! still hit the provider cache.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;
const Agent = @import("agent.zig").Agent;
const messages = @import("messages.zig");
pub fn userPromptIndexes(items: []const Value, gpa: Allocator) ![]usize {
    var turns: std.ArrayList(usize) = .empty;
    errdefer turns.deinit(gpa);
    for (items, 0..) |m, i| {
        if (messages.userPromptText(m) != null) try turns.append(gpa, i);
    }
    return turns.toOwnedSlice(gpa);
}

/// Drop prompt `n` (1-based) and everything after it. Returns the cut index.
pub fn rewindTo(root: *Agent, n: usize) !usize {
    const turns = try userPromptIndexes(root.messages.items, root.gpa);
    defer root.gpa.free(turns);
    if (turns.len == 0) return error.NoPrompts;
    if (n < 1 or n > turns.len) return error.InvalidN;
    const cut = turns[n - 1];
    root.messages.items.len = cut;
    root.last_context_tokens = 0;
    root.context_local_tokens = 0;
    root.compact_transport_failures = 0;
    root.goal_note_fp = 0;
    if (root.snapshots) |snaps| {
        _ = snaps.restore(@intCast(n));
        snaps.turn = @intCast(n - 1);
    }
    return cut;
}

pub fn tryHandle(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    const is_edit = std.mem.startsWith(u8, line, "/edit");
    const is_rewind = std.mem.startsWith(u8, line, "/rewind");
    if (!is_edit and !is_rewind) return false;
    const cmd = if (is_edit) "/edit" else "/rewind";
    if (line.len > cmd.len and line[cmd.len] != ' ' and line[cmd.len] != '\t') return false;
    const rest = std.mem.trim(u8, line[cmd.len..], " \t");
    const turns = try userPromptIndexes(root.messages.items, root.gpa);
    defer root.gpa.free(turns);
    if (turns.len == 0) {
        try out.writeAll("nothing to edit — no prompts in this conversation yet\n");
        try out.flush();
        return true;
    }
    var n: usize = 0;
    var text: []const u8 = "";
    if (rest.len > 0) {
        const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        n = std.fmt.parseInt(usize, rest[0..sp], 10) catch 0;
        text = std.mem.trim(u8, rest[sp..], " \t");
    }
    if (n == 0) {
        try out.writeAll(if (is_edit) "edit which prompt?\n" else "rewind to before which prompt?\n");
        for (turns, 1..) |idx, i| {
            var snip = messages.userPromptText(root.messages.items[idx]) orelse "";
            if (std.mem.indexOfScalar(u8, snip, '\n')) |nl| snip = snip[0..nl];
            const shown = if (snip.len > 70) snip[0..70] else snip;
            try out.print("  {s}{d}{s}: {s}{s}\n", .{ style.accent, i, style.reset, shown, if (snip.len > 70) "…" else "" });
        }
        if (is_edit)
            try out.print("{s}usage: /edit <n> <text> — replace prompt n, drop n+after, keep the prefix for cache{s}\n", .{ style.dim, style.reset })
        else
            try out.print("{s}usage: /rewind <n> — drops prompt <n>+after and reverts its write_file/edit_file changes{s}\n", .{ style.dim, style.reset });
        try out.flush();
        return true;
    }
    if (n < 1 or n > turns.len) {
        try out.print("invalid — pick 1..{d} (see {s})\n", .{ turns.len, cmd });
        try out.flush();
        return true;
    }
    if (is_edit and text.len == 0) {
        try out.print("usage: /edit {d} <text> — the new prompt that replaces #{d}\n", .{ n, n });
        try out.flush();
        return true;
    }
    const before = root.messages.items.len;
    _ = rewindTo(root, n) catch unreachable;
    const dropped = before - root.messages.items.len;
    if (is_edit) {
        try out.print("edited prompt {d} — dropped {d} message(s); next send continues from here (prefix before {d} is unchanged)\n", .{ n, dropped, n });
        try out.print("{s}replacement: {s}{s}\n", .{ style.dim, text, style.reset });
    } else {
        try out.print("⏪ rewound to before prompt {d} — dropped {d} message(s)\n", .{ n, dropped });
    }
    try out.flush();
    return true;
}

test "userPromptIndexes counts Responses input_text and chat strings" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    try items.append(try messages.textMessage(a, "user", "one"));
    try items.append(try messages.textMessage(a, "assistant", "ok"));
    var resp: std.json.ObjectMap = .empty;
    try resp.put(a, "role", .{ .string = "user" });
    var blocks = std.json.Array.init(a);
    var block: std.json.ObjectMap = .empty;
    try block.put(a, "type", .{ .string = "input_text" });
    try block.put(a, "text", .{ .string = "two" });
    try blocks.append(.{ .object = block });
    try resp.put(a, "content", .{ .array = blocks });
    try items.append(.{ .object = resp });
    const idx = try userPromptIndexes(items.items, gpa);
    defer gpa.free(idx);
    try std.testing.expectEqual(@as(usize, 2), idx.len);
    try std.testing.expectEqual(@as(usize, 0), idx[0]);
    try std.testing.expectEqual(@as(usize, 2), idx[1]);
}

test "rewindTo drops prompt n and after, keeps the prefix" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = gpa,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 100_000 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };
    try agent.messages.append(try messages.textMessage(a, "user", "one"));
    try agent.messages.append(try messages.textMessage(a, "assistant", "a1"));
    try agent.messages.append(try messages.textMessage(a, "user", "two"));
    try agent.messages.append(try messages.textMessage(a, "assistant", "a2"));
    _ = try rewindTo(&agent, 2);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqualStrings("one", messages.userPromptText(agent.messages.items[0]).?);
}
