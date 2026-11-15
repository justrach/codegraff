//! Wire-catalog restriction, including real server-executed search routes.
const std = @import("std");
const policy = @import("hard_policy.zig");
const gate = @import("hard_policy_gate.zig");
const Value = std.json.Value;

pub fn filter(io: std.Io, arena: std.mem.Allocator, json: []const u8, provider: []const u8, registry: ?*@import("mcp.zig").Registry) ![]const u8 {
    return filterDocument(policy.loadAt(io, arena, std.Io.Dir.cwd()), arena, json, provider, registry);
}

pub fn filterAgent(agent: anytype, arena: std.mem.Allocator, json: []const u8, provider: []const u8, registry: ?*@import("mcp.zig").Registry) ![]const u8 {
    return filterDocument(@import("hard_policy_context.zig").load(agent.io, arena, agent.agent_cwd, agent.hard_policy), arena, json, provider, registry);
}

pub fn filterDocument(doc: policy.Document, arena: std.mem.Allocator, json: []const u8, provider: []const u8, registry: ?*@import("mcp.zig").Registry) ![]const u8 {
    if (doc.problem != null) return "[]";
    if (doc.statements.len == 0 and doc.ceiling == null) return json;
    const value = try std.json.parseFromSliceLeaky(Value, arena, json, .{ .allocate = .alloc_always });
    if (value != .array) return error.InvalidPolicyToolCatalog;
    var kept: std.ArrayList(Value) = .empty;
    for (value.array.items) |tool| {
        const name = toolName(tool);
        const typ = field(tool, "type");
        if (name.len > 0 and gate.callDenial(doc, arena, name, registry) != null) continue;
        if (name.len == 0 and typ.len > 0 and !doc.allows("tool.use", typ)) continue;
        if ((std.mem.eql(u8, typ, "web_search") or std.mem.eql(u8, typ, "x_search")) and
            (!doc.allows("websearch.use", provider) or !doc.allows("tool.use", typ))) continue;
        try kept.append(arena, tool);
    }
    if (kept.items.len == value.array.items.len) return json;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(kept.items);
    return aw.toOwnedSlice();
}

fn field(v: Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

fn toolName(v: Value) []const u8 {
    if (v == .object) if (v.object.get("function")) |f| return field(f, "name");
    return field(v, "name");
}
