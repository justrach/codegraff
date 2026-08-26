//! ACP JSON-RPC envelopes: parse, version negotiate, prompt flatten, writers.
//! Split from acp.zig so the agent loop can stream session/update without
//! growing that file past 600.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");

/// Highest ACP protocol version this agent implements (v1 shapes).
pub const protocol_version: i64 = 1;

pub const err_method_not_found: i32 = -32601;
pub const err_internal: i32 = -32603;

/// ACP v1 `promptCapabilities` (https://agentclientprotocol.com/protocol/v1/schema).
/// Missing keys default to false; we send the three named fields so a client
/// does not have to guess. `embeddedContext` is on because flattenPrompt
/// already lifts `resource_link` blocks into the user text.
pub const PromptCapabilities = struct {
    image: bool = false,
    audio: bool = false,
    embeddedContext: bool = true,
};

pub const AgentImplementation = struct {
    name: []const u8 = "graff",
    title: []const u8 = "graff",
    version: []const u8,
};

pub const AvailableCommand = struct {
    name: []const u8,
    description: []const u8,
    input: struct { hint: []const u8 },
};

pub const Request = struct {
    id: ?Value = null,
    method: []const u8 = "",
    params: ?Value = null,
};

pub fn parseRequest(arena: Allocator, line: []const u8) ?Request {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, trimmed, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const method = util.strFieldObj(v.object, "method") orelse return null;
    const raw_id = v.object.get("id");
    return .{
        .id = if (raw_id) |id| (if (id == .null) null else id) else null,
        .method = method,
        .params = v.object.get("params"),
    };
}

pub fn negotiateVersion(params: ?Value) i64 {
    const p = params orelse return protocol_version;
    if (p != .object) return protocol_version;
    const v = p.object.get("protocolVersion") orelse return protocol_version;
    return switch (v) {
        .integer => |n| @min(n, protocol_version),
        .float => |f| @min(@as(i64, @intFromFloat(f)), protocol_version),
        else => protocol_version,
    };
}

fn blockText(block: Value) ?[]const u8 {
    if (block == .string) return block.string;
    if (block != .object) return null;
    const o = block.object;
    const kind = util.strFieldObj(o, "type") orelse "";
    if (std.mem.eql(u8, kind, "text")) return util.strFieldObj(o, "text");
    if (std.mem.eql(u8, kind, "resource_link"))
        return util.strFieldObj(o, "uri") orelse util.strFieldObj(o, "name");
    return util.strFieldObj(o, "text") orelse util.strFieldObj(o, "uri");
}

pub fn flattenPrompt(arena: Allocator, prompt: ?Value) ![]const u8 {
    const blocks = switch (prompt orelse return "") {
        .array => |a| a,
        .string => |s| return s,
        else => return "",
    };
    var buf: std.array_list.Managed(u8) = .init(arena);
    for (blocks.items) |block| {
        const text = blockText(block) orelse continue;
        if (text.len == 0) continue;
        if (buf.items.len != 0) try buf.append('\n');
        try buf.appendSlice(text);
    }
    return buf.items;
}

pub fn writeResult(w: *Io.Writer, id: ?Value, result: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    try s.write(result);
    try s.endObject();
    try w.writeByte('\n');
}

pub fn writeError(w: *Io.Writer, id: ?Value, code: i32, message: []const u8) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
}

pub fn writeNotification(w: *Io.Writer, method: []const u8, params: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(.{ .jsonrpc = "2.0", .method = method, .params = params });
    try w.writeByte('\n');
}

/// One `agent_message_chunk` notification (the v0 final-text update).
pub fn writeSessionUpdate(w: *Io.Writer, session_id: []const u8, text: []const u8) !void {
    try writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{
            .sessionUpdate = "agent_message_chunk",
            .content = .{ .type = "text", .text = text },
        },
    });
}

/// ACP v1 slash-command advertisement (`available_commands_update`).
pub fn writeAvailableCommands(w: *Io.Writer, session_id: []const u8, commands: []const AvailableCommand) !void {
    try writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{
            .sessionUpdate = "available_commands_update",
            .availableCommands = commands,
        },
    });
}

pub fn slashCommands() []const AvailableCommand {
    return &.{
        .{
            .name = "never",
            .description = "List, add, or retire a standing constraint. Bare lists them; `rm <id-or-text>` retires one.",
            .input = .{ .hint = "[<text>|rm <id-or-text>]" },
        },
        .{
            .name = "constraint",
            .description = "Alias for never.",
            .input = .{ .hint = "[<text>|rm <id-or-text>]" },
        },
    };
}
