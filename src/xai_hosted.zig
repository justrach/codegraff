//! Hosted xAI tools on the Responses wire (`{"type":"x_search"}`).
//!
//! Not a graff catalog function and not on the always-on prefix (ADR 0011 /
//! 0013). xAI runs the search server-side; graff must never local-exec the
//! resulting `custom_tool_call` / `x_search_call`. Chat-completions and
//! non-xAI Responses providers never see this splice.
//! `GRAFF_XAI_X_SEARCH=0|off|false|no` turns the default off.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;

const Provider = @import("provider.zig").Provider;

/// Test / env seam. `applyEnvKnobs` sets this from GRAFF_XAI_X_SEARCH.
pub var enabled: bool = true;

pub fn active(provider_id: []const u8, kind: Provider.Kind) bool {
    return enabled and kind == .responses and std.mem.eql(u8, provider_id, "xai");
}

/// Append `{"type":"x_search"}` when the tools array does not already carry it.
/// Invalid JSON is returned unchanged so the existing writer path still fires.
pub fn splice(arena: Allocator, tools_json: []const u8) ![]const u8 {
    var value = std.json.parseFromSliceLeaky(Value, arena, tools_json, .{ .allocate = .alloc_always }) catch return tools_json;
    if (value != .array) return tools_json;
    for (value.array.items) |tool| {
        if (hostedType(tool)) return tools_json;
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "type", .{ .string = "x_search" });
    try value.array.append(.{ .object = obj });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.toOwnedSlice();
}

fn hostedType(tool: Value) bool {
    if (tool != .object) return false;
    const t = if (tool.object.get("type")) |v| (if (v == .string) v.string else "") else "";
    return std.mem.eql(u8, t, "x_search");
}

/// Server-executed search items: keep them in history, never dispatch locally.
pub fn isServerSideCall(itype: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, itype, "x_search_call") or std.mem.eql(u8, itype, "web_search_call"))
        return true;
    if (!std.mem.eql(u8, itype, "custom_tool_call") and !std.mem.eql(u8, itype, "function_call"))
        return false;
    return std.mem.eql(u8, name, "x_search") or
        std.mem.eql(u8, name, "x_keyword_search") or
        std.mem.eql(u8, name, "x_semantic_search") or
        std.mem.eql(u8, name, "x_user_search") or
        std.mem.eql(u8, name, "x_thread_fetch");
}

test "active only for xAI Responses while enabled" {
    const saved = enabled;
    defer enabled = saved;
    enabled = true;
    try std.testing.expect(active("xai", .responses));
    try std.testing.expect(!active("xai", .openai));
    try std.testing.expect(!active("codex", .responses));
    try std.testing.expect(!active("openai", .responses));
    enabled = false;
    try std.testing.expect(!active("xai", .responses));
}

test "splice appends hosted x_search once" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = "[{\"type\":\"function\",\"name\":\"bash\",\"parameters\":{\"type\":\"object\"}}]";
    const out = try splice(arena, tools);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"x_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"bash\"") != null);
    const again = try splice(arena, out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, again, "\"type\":\"x_search\""));
}

test "splice of an empty tools array is just x_search" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try splice(arena_state.allocator(), "[]");
    try std.testing.expectEqualStrings("[{\"type\":\"x_search\"}]", out);
}

test "splice leaves invalid JSON alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("not-json", try splice(arena_state.allocator(), "not-json"));
}

test "isServerSideCall matches the live xAI shapes and ignores bash" {
    try std.testing.expect(isServerSideCall("custom_tool_call", "x_keyword_search"));
    try std.testing.expect(isServerSideCall("x_search_call", ""));
    try std.testing.expect(isServerSideCall("function_call", "x_search"));
    try std.testing.expect(!isServerSideCall("function_call", "bash"));
    try std.testing.expect(!isServerSideCall("function_call", "webfetch"));
    try std.testing.expect(!isServerSideCall("message", "x_search"));
}
