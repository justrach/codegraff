//! Native Anthropic login-token wire compatibility. API keys and gateways
//! continue using their ordinary Anthropic Messages serialization.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Provider = @import("provider.zig").Provider;
const claude = @import("claude_wire.zig");
const serde = @import("serde.zig");

pub const user_agent = "claude-cli/2.1.280";
pub const system_prefix = "You are Claude Code, Anthropic's official CLI for Claude.";
const oauth_beta = "claude-code-20250219,oauth-2025-04-20";

pub fn active(provider: Provider) bool {
    return std.mem.eql(u8, provider.id, "anthropic") and provider.source == .login;
}

pub fn beta(provider: Provider) ?[]const u8 {
    if (!std.mem.eql(u8, provider.id, "anthropic")) return null;
    if (active(provider)) return if (claude.bindsThinking(provider.model)) oauth_beta ++ "," ++ claude.binding_beta else oauth_beta;
    return if (claude.bindsThinking(provider.model)) claude.binding_beta else null;
}

pub fn identityHeaders(buf: []std.http.Header) usize {
    const headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "user-agent", .value = user_agent },
        .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" },
        .{ .name = "x-app", .value = "cli" },
    };
    @memcpy(buf[0..headers.len], &headers);
    return headers.len;
}

pub fn writeSystemPrefix(s: *std.json.Stringify) !void {
    try s.write(.{ .type = "text", .text = system_prefix });
}

const known_names = [_][]const u8{
    "Read",          "Write",        "Edit",      "Bash",         "Grep",  "Glob", "AskUserQuestion",
    "EnterPlanMode", "ExitPlanMode", "KillShell", "NotebookEdit", "Skill", "Task", "TaskOutput",
    "TodoWrite",     "WebFetch",     "WebSearch",
};

pub fn canonical(name: []const u8) []const u8 {
    for (known_names) |known| if (std.ascii.eqlIgnoreCase(name, known)) return known;
    return name;
}

fn string(obj: Value, field: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const value = obj.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// One reversible map per advertised catalog. Case-distinct tools which
/// would share a Claude Code spelling retain their exact original names.
pub const ToolNames = struct {
    tools: []const Value = &.{},

    pub fn init(arena: Allocator, raw: []const u8) !ToolNames {
        if (raw.len == 0) return .{};
        const tools = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
        return .{ .tools = if (tools == .array) tools.array.items else &.{} };
    }

    pub fn encode(self: ToolNames, name: []const u8) []const u8 {
        const wire = canonical(name);
        var matches: usize = 0;
        for (self.tools) |tool| {
            const actual = string(tool, "name") orelse continue;
            if (std.mem.eql(u8, canonical(actual), wire)) matches += 1;
        }
        return if (matches > 1) name else wire;
    }

    pub fn decode(self: ToolNames, name: []const u8) []const u8 {
        // Exact names win, including a collision group left unchanged.
        for (self.tools) |tool| {
            const actual = string(tool, "name") orelse continue;
            if (std.mem.eql(u8, actual, name)) return actual;
        }
        for (self.tools) |tool| {
            const actual = string(tool, "name") orelse continue;
            if (std.mem.eql(u8, self.encode(actual), name)) return actual;
        }
        return name;
    }

    pub fn writeTools(self: ToolNames, s: *std.json.Stringify, arena: Allocator) !void {
        try s.beginArray();
        for (self.tools) |tool| {
            var copy = tool;
            if (string(tool, "name")) |name| {
                copy = .{ .object = try tool.object.clone(arena) };
                try copy.object.put(arena, "name", .{ .string = self.encode(name) });
                if (copy.object.getPtr("input_schema")) |schema| {
                    if (schema.* == .object) schema.* = .{ .object = try schema.object.clone(arena) };
                    _ = try serde.defaultRootObjectType(arena, schema);
                }
            }
            try s.write(copy);
        }
        try s.endArray();
    }

    pub fn writeMessages(self: ToolNames, s: *std.json.Stringify, arena: Allocator, messages: std.json.Array, cache: ?[]const u8) !void {
        var copy = std.json.Array.init(arena);
        for (messages.items) |message| {
            var next = message;
            if (message == .object) if (message.object.get("content")) |content| {
                if (content == .array) {
                    var blocks = std.json.Array.init(arena);
                    for (content.array.items) |block| {
                        var encoded = block;
                        if (string(block, "type")) |kind| {
                            if (std.mem.eql(u8, kind, "tool_use")) if (string(block, "name")) |name| {
                                encoded = .{ .object = try block.object.clone(arena) };
                                try encoded.object.put(arena, "name", .{ .string = self.encode(name) });
                            };
                        }
                        try blocks.append(encoded);
                    }
                    next = .{ .object = try message.object.clone(arena) };
                    try next.object.put(arena, "content", .{ .array = blocks });
                }
            };
            try copy.append(next);
        }
        try serde.writeAnthropicMessages(s, copy, cache, false);
    }

    /// Decode before storing history or dispatching tools. Only the name is
    /// changed: signed thinking, IDs and arguments remain exactly as returned.
    pub fn decodeContent(self: ToolNames, arena: Allocator, content: Value) !void {
        if (content != .array) return;
        for (content.array.items) |*block| {
            const kind = string(block.*, "type") orelse continue;
            if (!std.mem.eql(u8, kind, "tool_use")) continue;
            const name = string(block.*, "name") orelse continue;
            const actual = self.decode(name);
            if (!std.mem.eql(u8, actual, name))
                try block.object.put(arena, "name", .{ .string = try arena.dupe(u8, actual) });
        }
    }
};

test {
    _ = @import("anthropic_oauth_wire_tests.zig");
}
