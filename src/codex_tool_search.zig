//! OpenAI hosted `tool_search` on Codex Responses (gpt-5.4+).
//!
//! Folded native tools and MCP names ship with `defer_loading: true` plus a
//! `{"type":"tool_search"}` entry so the model loads schemas at the end of
//! the window (cache-preserving) instead of paying every parameter block up
//! front. Always-on loop tools (bash, files, codedb, …) stay eager.
//! `tool_search_call` / `tool_search_output` are server-executed — never
//! dispatched locally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;

const Provider = @import("provider.zig").Provider;
const native_fold = @import("native_fold.zig");

pub fn modelSupports(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-5.4") or
        std.mem.startsWith(u8, model, "gpt-5.5") or
        std.mem.startsWith(u8, model, "gpt-5.6") or
        std.mem.startsWith(u8, model, "gpt-6");
}

pub fn active(provider_id: []const u8, kind: Provider.Kind, model: []const u8) bool {
    return kind == .responses and std.mem.eql(u8, provider_id, "codex") and modelSupports(model);
}

pub fn isServerSideItem(itype: []const u8) bool {
    return std.mem.eql(u8, itype, "tool_search_call") or std.mem.eql(u8, itype, "tool_search_output");
}

fn toolName(tool: Value) []const u8 {
    if (tool != .object) return "";
    if (tool.object.get("function")) |fn_v| if (fn_v == .object) {
        if (fn_v.object.get("name")) |n| if (n == .string) return n.string;
    };
    if (tool.object.get("name")) |n| if (n == .string) return n.string;
    return "";
}

fn shouldDefer(name: []const u8) bool {
    if (name.len == 0) return false;
    if (native_fold.isFolded(name)) return true;
    return std.mem.startsWith(u8, name, "mcp__") or std.mem.startsWith(u8, name, "mcp_");
}

fn hasType(tools: []const Value, typ: []const u8) bool {
    for (tools) |tool| {
        if (tool != .object) continue;
        const t = if (tool.object.get("type")) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, t, typ)) return true;
    }
    return false;
}

/// Mark deferred functions and append hosted `tool_search` once.
pub fn splice(arena: Allocator, tools_json: []const u8) ![]const u8 {
    var value = std.json.parseFromSliceLeaky(Value, arena, tools_json, .{ .allocate = .alloc_always }) catch return tools_json;
    if (value != .array) return tools_json;
    var changed = false;
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        if (!shouldDefer(toolName(tool.*))) continue;
        if (tool.object.get("defer_loading")) |_| continue;
        try tool.object.put(arena, "defer_loading", .{ .bool = true });
        changed = true;
    }
    if (!hasType(value.array.items, "tool_search")) {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "type", .{ .string = "tool_search" });
        try value.array.append(.{ .object = obj });
        changed = true;
    }
    if (!changed) return tools_json;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.toOwnedSlice();
}

test "modelSupports is gpt-5.4+ / gpt-6, not gpt-5.3" {
    try std.testing.expect(modelSupports("gpt-5.4"));
    try std.testing.expect(modelSupports("gpt-5.6-sol"));
    try std.testing.expect(modelSupports("gpt-6-astra"));
    try std.testing.expect(!modelSupports("gpt-5.3-codex"));
    try std.testing.expect(!active("codex", .openai, "gpt-5.6-sol"));
    try std.testing.expect(active("codex", .responses, "gpt-5.6-sol"));
    try std.testing.expect(!active("openai", .responses, "gpt-5.6-sol"));
}

test "splice defers folded tools and appends tool_search once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tools =
        \\[{"type":"function","name":"bash","description":"run"},{"type":"function","name":"webfetch","description":"web"}]
    ;
    const out = try splice(a, tools);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"tool_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"webfetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"defer_loading\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"bash\"") != null);
    // bash is eager — the only defer_loading is on webfetch.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"defer_loading\":true"));
    const again = try splice(a, out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, again, "\"type\":\"tool_search\""));
}

test "isServerSideItem covers hosted search items" {
    try std.testing.expect(isServerSideItem("tool_search_call"));
    try std.testing.expect(isServerSideItem("tool_search_output"));
    try std.testing.expect(!isServerSideItem("function_call"));
}
