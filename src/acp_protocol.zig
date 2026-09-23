//! ACP JSON-RPC envelopes: parse, version negotiate, prompt flatten, writers.
//! Split from acp.zig so the agent loop can stream session/update without
//! growing that file past 600.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const util = @import("util.zig");
const command_catalog = @import("command_catalog.zig");

/// Highest ACP protocol version this agent implements (v1 shapes).
pub const protocol_version: i64 = 1;

pub const err_method_not_found: i32 = -32601;
pub const err_internal: i32 = -32603;
pub const err_auth_required: i32 = -32000;

/// ACP v1 `promptCapabilities` (https://agentclientprotocol.com/protocol/v1/schema).
/// Missing keys default to false; we send the three named fields so a client
/// does not have to guess. `embeddedContext` includes nested resource contents;
/// resource links are baseline ACP support, independent of this capability.
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
    // ACP requires the requested version if supported, otherwise our latest.
    // We implement only v1: echoing an older number would promise other shapes.
    _ = params;
    return protocol_version;
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
        if (block == .object and std.mem.eql(u8, util.strFieldObj(block.object, "type") orelse "", "resource")) {
            const resource = block.object.get("resource") orelse continue;
            if (resource != .object) continue;
            const o = resource.object;
            const text = util.strFieldObj(o, "text");
            const blob = util.strFieldObj(o, "blob");
            if (text == null and blob == null) continue;
            if (buf.items.len != 0) try buf.append('\n');
            if (util.strFieldObj(o, "uri")) |uri| {
                try buf.appendSlice(uri);
                try buf.append('\n');
            }
            if (text) |content| {
                try buf.appendSlice(content);
            } else if (blob) |content| {
                // Preserve opaque bytes in their wire encoding, never as UTF-8.
                try buf.appendSlice("[base64");
                if (util.strFieldObj(o, "mimeType")) |mime| {
                    try buf.appendSlice(" ");
                    try buf.appendSlice(mime);
                }
                try buf.appendSlice("]\n");
                try buf.appendSlice(content);
            }
            continue;
        }
        const text = blockText(block) orelse continue;
        if (text.len == 0) continue;
        if (buf.items.len != 0) try buf.append('\n');
        try buf.appendSlice(text);
    }
    return buf.items;
}

test "ACP v1 rejects unsupported version claims without numeric conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "0", "-1", "2", "1.5", "1e100" }) |version| {
        const json = try std.fmt.allocPrint(arena.allocator(), "{{\"protocolVersion\":{s}}}", .{version});
        const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), json, .{});
        try std.testing.expectEqual(protocol_version, negotiateVersion(value));
    }
}

test "ACP embedded resources preserve URI and text alongside prompt blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"type":"text","text":"Review this"},{"type":"resource","resource":{"uri":"file:///draft.zig","mimeType":"text/plain","text":"const draft = 1;\n"}},{"type":"resource_link","uri":"file:///related.zig"}]
    , .{});
    try std.testing.expectEqualStrings("Review this\nfile:///draft.zig\nconst draft = 1;\n\nfile:///related.zig", try flattenPrompt(a, value));
}

test "ACP embedded blobs retain encoding and malformed resources are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"type":"resource"},{"type":"resource","resource":4},{"type":"resource","resource":{"text":3}},{"type":"resource","resource":{"uri":"memory://bytes","mimeType":"application/octet-stream","blob":"AAEC"}}]
    , .{});
    try std.testing.expectEqualStrings("memory://bytes\n[base64 application/octet-stream]\nAAEC", try flattenPrompt(a, value));
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

/// The advertised set, built from the one catalog the REPL and tab
/// completion already read, so a command cannot exist in one surface and be
/// missing from the other. Names go out bare: ACP owns the leading slash.
pub fn slashCommands() []const AvailableCommand {
    const built = comptime blk: {
        var out: [command_catalog.commands.len]AvailableCommand = undefined;
        var n: usize = 0;
        for (command_catalog.commands) |c| {
            out[n] = .{
                .name = c.name[1..],
                .description = c.desc,
                .input = .{ .hint = c.usage },
            };
            n += 1;
        }
        const frozen = out[0..n].*;
        break :blk frozen;
    };
    return &built;
}
