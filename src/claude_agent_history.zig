//! Claude Agent history (ADR 0309): graff's transcript stays the source of
//! truth. A running `claude` holds the part it has seen; each request sends
//! only what is new. A fresh process (first use, a changed prompt or tool
//! list, a compaction, an edit) gets everything it missed as one user
//! message wrapped in `<conversation-checkpoint>`, without thinking text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const wire = @import("claude_agent_wire.zig");

/// Identity of a history prefix, to tell "only grew" from "rewritten".
pub fn hashMessages(a: Allocator, items: []const Value) u64 {
    var h = std.hash.Wyhash.init(0x6772_6166_665f_6361);
    for (items) |m| {
        const bytes = std.json.Stringify.valueAlloc(a, m, .{}) catch return 0;
        h.update(bytes);
        h.update("\x00");
    }
    return h.final();
}

/// Text of a `system` field (a string or an array of text blocks).
pub fn textOf(a: Allocator, v: ?Value) ![]const u8 {
    const value = v orelse return "";
    switch (value) {
        .string => |s| return s,
        .array => |items| {
            var out: std.ArrayList(u8) = .empty;
            for (items.items) |b| {
                if (b != .object) continue;
                const t = wire.strField(b.object, "text") orelse continue;
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, t);
            }
            return out.items;
        },
        else => return "",
    }
}

fn role(m: Value) []const u8 {
    if (m != .object) return "";
    return wire.strField(m.object, "role") orelse "";
}

fn hasToolResult(m: Value) bool {
    if (m != .object) return false;
    const c = m.object.get("content") orelse return false;
    if (c != .array) return false;
    for (c.array.items) |b| if (b == .object and std.mem.eql(u8, wire.strField(b.object, "type") orelse "", "tool_result")) return true;
    return false;
}

/// Content for the first message of a fresh session: the checkpoint of
/// everything before the latest user prompt, then that prompt's own blocks.
pub fn freshContent(a: Allocator, items: []const Value) !Value {
    var blocks: std.json.Array = .init(a);
    const last_is_prompt = items.len > 0 and std.mem.eql(u8, role(items[items.len - 1]), "user") and !hasToolResult(items[items.len - 1]);
    const head = if (last_is_prompt) items[0 .. items.len - 1] else items;
    if (head.len > 0) try blocks.append(try textBlock(a, try checkpoint(a, head)));
    if (last_is_prompt) {
        const c = items[items.len - 1].object.get("content") orelse Value{ .string = "" };
        try appendPromptBlocks(a, &blocks, c);
    } else if (head.len > 0) {
        try blocks.append(try textBlock(a, "Continue from where the checkpoint ends."));
    }
    if (blocks.items.len == 0) try blocks.append(try textBlock(a, ""));
    return .{ .array = blocks };
}

/// User blocks Claude Code takes as-is (text, image, document); anything
/// else is rendered as text.
fn appendPromptBlocks(a: Allocator, blocks: *std.json.Array, c: Value) !void {
    switch (c) {
        .string => |s| try blocks.append(try textBlock(a, s)),
        .array => |items| for (items.items) |b| try appendBlock(a, blocks, b),
        else => {},
    }
}

fn appendBlock(a: Allocator, blocks: *std.json.Array, b: Value) !void {
    if (b != .object) return;
    const kind = wire.strField(b.object, "type") orelse "";
    if (std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "document")) {
        try blocks.append(try stripCacheControl(a, b));
    } else {
        var out: std.ArrayList(u8) = .empty;
        try renderBlock(a, &out, b);
        if (out.items.len > 0) try blocks.append(try textBlock(a, out.items));
    }
}

/// A block without graff's `cache_control` marker (Claude Code places its own).
fn stripCacheControl(a: Allocator, b: Value) !Value {
    if (b.object.get("cache_control") == null) return b;
    var copy: std.json.ObjectMap = .empty;
    var it = b.object.iterator();
    while (it.next()) |kv| if (!std.mem.eql(u8, kv.key_ptr.*, "cache_control")) try copy.put(a, kv.key_ptr.*, kv.value_ptr.*);
    return .{ .object = copy };
}

fn textBlock(a: Allocator, text: []const u8) !Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "type", .{ .string = "text" });
    try o.put(a, "text", .{ .string = text });
    return .{ .object = o };
}

pub fn checkpoint(a: Allocator, items: []const Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "<conversation-checkpoint>\nThe conversation so far, from before this session started. Tool calls and results are shown as text; continue from where it ends.\n");
    for (items) |m| {
        if (m != .object) continue;
        try out.print(a, "\n[{s}]\n", .{role(m)});
        const c = m.object.get("content") orelse continue;
        switch (c) {
            .string => |s| try out.appendSlice(a, s),
            .array => |blocks| for (blocks.items) |b| try renderBlock(a, &out, b),
            else => {},
        }
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "</conversation-checkpoint>");
    return out.items;
}

fn renderBlock(a: Allocator, out: *std.ArrayList(u8), b: Value) !void {
    if (b != .object) return;
    const kind = wire.strField(b.object, "type") orelse "";
    if (std.mem.eql(u8, kind, "text")) {
        try out.appendSlice(a, wire.strField(b.object, "text") orelse "");
        try out.append(a, '\n');
    } else if (std.mem.eql(u8, kind, "tool_use")) {
        const input = std.json.Stringify.valueAlloc(a, b.object.get("input") orelse Value{ .object = .empty }, .{}) catch "{}";
        try out.print(a, "<tool_call name=\"{s}\" id=\"{s}\">{s}</tool_call>\n", .{ wire.strField(b.object, "name") orelse "", wire.strField(b.object, "id") orelse "", input });
    } else if (std.mem.eql(u8, kind, "tool_result")) {
        try out.print(a, "<tool_result id=\"{s}\"{s}>", .{ wire.strField(b.object, "tool_use_id") orelse "", if (isError(b)) " error=\"true\"" else "" });
        if (b.object.get("content")) |c| switch (c) {
            .string => |s| try out.appendSlice(a, s),
            .array => |parts| for (parts.items) |p| {
                if (p == .object and std.mem.eql(u8, wire.strField(p.object, "type") orelse "", "text"))
                    try out.appendSlice(a, wire.strField(p.object, "text") orelse "")
                else
                    try out.appendSlice(a, "[image]");
            },
            else => {},
        };
        try out.appendSlice(a, "</tool_result>\n");
    } else if (std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "document")) {
        try out.print(a, "[{s}]\n", .{kind});
    }
    // thinking / redacted_thinking: left out of the checkpoint.
}

fn isError(b: Value) bool {
    const e = b.object.get("is_error") orelse return false;
    return e == .bool and e.bool;
}

pub const ToolRes = struct { id: []const u8, block: std.json.ObjectMap };

/// What changed since Claude Code's last step, from `items = messages[seen..]`.
pub const Delta = struct {
    results: []const ToolRes,
    /// Non-result text that arrived with results (reminders, a steer).
    extra_text: []const u8,
    /// A new prompt when there are no results.
    user: ?Value,
};

/// Null when the new messages are not a shape a live session can take
/// (graff injected an assistant message, or nothing new at all): the caller
/// then starts a fresh session from a checkpoint.
pub fn delta(a: Allocator, items: []const Value) !?Delta {
    var i: usize = 0;
    // Claude Code's own reply, which graff appended after the last step.
    if (items.len > 0 and std.mem.eql(u8, role(items[0]), "assistant")) i = 1;
    if (i == items.len) return null;
    var results: std.ArrayList(ToolRes) = .empty;
    var extra: std.ArrayList(u8) = .empty;
    var prompt: std.json.Array = .init(a);
    for (items[i..]) |m| {
        if (!std.mem.eql(u8, role(m), "user")) return null;
        const c = m.object.get("content") orelse continue;
        switch (c) {
            .string => |s| try prompt.append(try textBlock(a, s)),
            .array => |blocks| for (blocks.items) |b| {
                if (b != .object) continue;
                if (std.mem.eql(u8, wire.strField(b.object, "type") orelse "", "tool_result")) {
                    try results.append(a, .{ .id = wire.strField(b.object, "tool_use_id") orelse "", .block = b.object });
                } else try appendBlock(a, &prompt, b);
            },
            else => {},
        }
    }
    if (results.items.len > 0) {
        for (prompt.items) |b| {
            const t = wire.strField(b.object, "text") orelse "[image]";
            if (t.len == 0) continue;
            if (extra.items.len > 0) try extra.append(a, '\n');
            try extra.appendSlice(a, t);
        }
        return .{ .results = results.items, .extra_text = extra.items, .user = null };
    }
    if (prompt.items.len == 0) return null;
    return .{ .results = &.{}, .extra_text = "", .user = .{ .array = prompt } };
}
