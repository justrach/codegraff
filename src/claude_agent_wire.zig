//! Claude Agent wire (ADR 0309): the stream-json lines graff writes to, and
//! reads from, the user's own `claude` program. Pure functions over strings
//! and parsed JSON, so the protocol is testable without a child process.
//!
//! graff speaks the control protocol the Agent SDK uses: one `initialize`
//! control request carrying graff's tool server (`sdkMcpServers`) and system
//! prompt, user messages as `{"type":"user",...}` lines, and MCP JSON-RPC
//! tunnelled through `mcp_message` control requests. Each `tools/call`
//! carries the model's tool_use id in `_meta["claudecode/toolUseId"]`, which
//! is how a held call is matched to the result graff's own loop produces.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const server_name = "graff";
pub const tool_prefix = "mcp__graff__";
/// Older binaries ignore `client_composed` and can read user text as Claude
/// Code commands.
pub const min_version = "2.1.248";

/// Whose system prompt the session runs on. `graff` replaces Claude Code's
/// prompt with graff's own; `claude` keeps Claude Code's and appends graff's.
pub const PromptMode = enum { graff, claude };

pub fn promptMode(value: ?[]const u8) PromptMode {
    const v = value orelse return .graff;
    if (std.ascii.eqlIgnoreCase(v, "claude") or std.ascii.eqlIgnoreCase(v, "append")) return .claude;
    return .graff;
}

/// graff's effort ladder onto `claude --effort` (low|medium|high|xhigh|max).
pub fn effortFlag(tag: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{ .{ "low", "low" }, .{ "medium", "medium" }, .{ "high", "high" }, .{ "xhigh", "xhigh" }, .{ "max", "max" }, .{ "ultra", "max" } };
    for (pairs) |p| if (std.mem.eql(u8, tag, p[0])) return p[1];
    return null;
}

/// Claude Code features that duplicate graff's are switched off; graff's own
/// versions win. The three cleared names would skip the subscription login,
/// override graff's effort, or cap every graff tool call.
pub const isolation_env = [_][2][]const u8{
    .{ "CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1" },
    .{ "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1" },
    .{ "DISABLE_AUTO_COMPACT", "1" },
    .{ "CLAUDE_CODE_ENABLE_AWAY_SUMMARY", "0" },
    .{ "ENABLE_TOOL_SEARCH", "false" },
    .{ "CLAUDE_CODE_DISABLE_ADVISOR_TOOL", "1" },
    .{ "MAX_MCP_OUTPUT_TOKENS", "200000" },
};

/// Inherited variables that must not reach `claude`. A graff started from
/// inside Claude Code inherits that session's identity (CLAUDECODE, the
/// entrypoint, its messaging socket), which the child would otherwise adopt.
/// CLAUDE_CODE_SIMPLE would skip the subscription login, the effort names
/// would override graff's effort, and MCP_TOOL_TIMEOUT would cap every graff
/// tool call. The user's own settings (CLAUDE_CONFIG_DIR,
/// CLAUDE_CODE_OAUTH_TOKEN, the Bedrock/Vertex switches) pass through.
const dropped_env = [_][]const u8{
    "CLAUDECODE",               "CLAUDE_CODE_ENTRYPOINT",       "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_ID",   "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SSE_PORT",     "CLAUDE_PID",                   "CLAUDE_EFFORT",
    "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_SIMPLE",           "CLAUDE_AGENT_SDK_VERSION",
    "MCP_TOOL_TIMEOUT",
};
const dropped_prefixes = [_][]const u8{"CLAUDE_CODE_MESSAGING_"};

pub fn dropsEnv(name: []const u8) bool {
    for (dropped_env) |d| if (std.mem.eql(u8, name, d)) return true;
    for (dropped_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// Whether a model name belongs to Claude Agent once it is chosen: a model in
/// its catalog, or one of the `claude-agent-<alias>` names it first shipped.
pub fn routes(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "claude-agent-")) return true;
    return @import("pricing.zig").providerModelInTable("claude-agent", model);
}

/// An early `claude-agent-sonnet` is Claude Code's `sonnet`; any other id
/// (`claude-opus-5-5`, `claude-opus-5-5[1m]`) goes through as given.
pub fn modelArg(model: []const u8) []const u8 {
    const prefix = "claude-agent-";
    return if (std.mem.startsWith(u8, model, prefix)) model[prefix.len..] else model;
}

pub const Spawn = struct {
    exe: []const u8,
    model: []const u8,
    effort: ?[]const u8,
    has_tools: bool,
};

pub fn argv(a: Allocator, s: Spawn) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, &.{
        s.exe,                 "--output-format",            "stream-json",         "--verbose",
        "--input-format",      "stream-json",                "--tools",             "",
        "--permission-mode",   "dontAsk",                    "--setting-sources",   "",
        "--settings",          "{\"disableAllHooks\":true}", "--strict-mcp-config", "--include-partial-messages",
        "--thinking=adaptive", "--thinking-display",         "summarized",          "--no-session-persistence",
        "--model",             s.model,
    });
    if (s.has_tools) try out.appendSlice(a, &.{
        "--allowedTools", tool_prefix ++ "*",
        "--mcp-config",   "{\"mcpServers\":{\"" ++ server_name ++ "\":{\"type\":\"sdk\",\"name\":\"" ++ server_name ++ "\"}}}",
    });
    if (s.effort) |e| try out.appendSlice(a, &.{ "--effort", e });
    return out.items;
}

pub fn initRequest(a: Allocator, request_id: []const u8, mode: PromptMode, system: []const u8, has_tools: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("control_request");
    try s.objectField("request_id");
    try s.write(request_id);
    try s.objectField("request");
    try s.beginObject();
    try s.objectField("subtype");
    try s.write("initialize");
    if (has_tools) {
        try s.objectField("sdkMcpServers");
        try s.write(&[_][]const u8{server_name});
    }
    if (system.len > 0) switch (mode) {
        .graff => {
            try s.objectField("systemPrompt");
            try s.write(&[_][]const u8{system});
        },
        .claude => {
            try s.objectField("appendSystemPrompt");
            try s.write(system);
        },
    };
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

/// One user turn. `content` is Anthropic message content (string or blocks).
pub fn userLine(a: Allocator, content: Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("user");
    try s.objectField("message");
    try s.beginObject();
    try s.objectField("role");
    try s.write("user");
    try s.objectField("content");
    try s.write(content);
    try s.endObject();
    try s.objectField("parent_tool_use_id");
    try s.write(null);
    try s.objectField("session_id");
    try s.write("");
    // graff already expanded its own commands; Claude Code must not read the
    // text as slash commands or add its per-turn context again.
    try s.objectField("client_composed");
    try s.write(true);
    try s.endObject();
    return aw.toOwnedSlice();
}

/// A success control_response; `response_json` is the raw `response` object.
pub fn controlOk(a: Allocator, request_id: []const u8, response_json: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("control_response");
    try s.objectField("response");
    try s.beginObject();
    try s.objectField("subtype");
    try s.write("success");
    try s.objectField("request_id");
    try s.write(request_id);
    try s.objectField("response");
    try s.beginWriteRaw();
    try aw.writer.writeAll(response_json);
    s.endWriteRaw();
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

pub fn controlErr(a: Allocator, request_id: []const u8, message: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("control_response");
    try s.objectField("response");
    try s.beginObject();
    try s.objectField("subtype");
    try s.write("error");
    try s.objectField("request_id");
    try s.write(request_id);
    try s.objectField("error");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    return aw.toOwnedSlice();
}

/// The control_response carrying a JSON-RPC reply. `rpc_id` is the request's
/// raw id JSON, or null for a notification's ack.
pub fn mcpReply(a: Allocator, request_id: []const u8, rpc_id: ?[]const u8, result_json: []const u8) ![]u8 {
    const inner = if (rpc_id) |id|
        try std.fmt.allocPrint(a, "{{\"mcp_response\":{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}}}", .{ id, result_json })
    else
        try std.fmt.allocPrint(a, "{{\"mcp_response\":{{\"jsonrpc\":\"2.0\",\"result\":{s}}}}}", .{result_json});
    return controlOk(a, request_id, inner);
}

/// Control request telling Claude Code that graff's server has a new tool
/// list (MCP `notifications/tools/list_changed`, client to CLI).
pub const tools_changed_request = "{\"subtype\":\"mcp_message\",\"server_name\":\"" ++ server_name ++ "\",\"message\":{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}}";

pub fn initializeResult(a: Allocator, protocol_version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"protocolVersion\":{f},\"capabilities\":{{\"tools\":{{\"listChanged\":true}}}},\"serverInfo\":{{\"name\":\"" ++ server_name ++ "\",\"version\":\"1\"}}}}", .{std.json.fmt(protocol_version, .{})});
}

/// graff's Anthropic tool list (`[{name, description, input_schema}]`) as an
/// MCP `tools/list` result.
pub fn toolsList(a: Allocator, tools: ?Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    if (tools) |t| if (t == .array) for (t.array.items) |tool| {
        if (tool != .object) continue;
        const name = tool.object.get("name") orelse continue;
        if (name != .string) continue;
        try s.beginObject();
        try s.objectField("name");
        try s.write(name.string);
        if (tool.object.get("description")) |d| {
            try s.objectField("description");
            try s.write(d);
        }
        try s.objectField("inputSchema");
        try s.write(tool.object.get("input_schema") orelse Value{ .object = .empty });
        try s.endObject();
    };
    try s.endArray();
    try s.endObject();
    return aw.toOwnedSlice();
}

/// An Anthropic `tool_result` block as an MCP `tools/call` result. Text that
/// graff appended to the same user message (reminders, a steer) rides along
/// as one more text item: the model reads it with the result, as it would
/// on the Messages wire.
pub fn toolResult(a: Allocator, block: ObjectMap, extra_text: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    if (block.get("content")) |c| switch (c) {
        .string => |text| try textItem(&s, text),
        .array => |items| for (items.items) |item| {
            if (item != .object) continue;
            const kind = strField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, kind, "text")) {
                try textItem(&s, strField(item.object, "text") orelse "");
            } else if (std.mem.eql(u8, kind, "image")) {
                const src = item.object.get("source") orelse continue;
                if (src != .object) continue;
                const data = strField(src.object, "data") orelse continue;
                try s.beginObject();
                try s.objectField("type");
                try s.write("image");
                try s.objectField("data");
                try s.write(data);
                try s.objectField("mimeType");
                try s.write(strField(src.object, "media_type") orelse "image/png");
                try s.endObject();
            }
        },
        else => {},
    };
    if (extra_text.len > 0) try textItem(&s, extra_text);
    try s.endArray();
    if (block.get("is_error")) |e| if (e == .bool and e.bool) {
        try s.objectField("isError");
        try s.write(true);
    };
    try s.endObject();
    return aw.toOwnedSlice();
}

fn textItem(s: *std.json.Stringify, text: []const u8) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
}

pub fn strField(o: ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// One line from `claude`, classified. Slices point into the parse arena.
pub const Line = union(enum) {
    /// A raw Anthropic stream event (`stream_event.event`).
    event: Value,
    control: Control,
    /// `control_cancel_request`: Claude Code abandoned a request it sent.
    cancel: []const u8,
    /// The answer to a control request graff sent.
    response: Response,
    result: Result,
    ignore,
};

pub const Control = struct { request_id: []const u8, subtype: []const u8, request: ObjectMap };
pub const Response = struct { request_id: []const u8, ok: bool, body: ?Value, err: []const u8 };
pub const Result = struct { is_error: bool, text: []const u8 };

pub fn classify(a: Allocator, line: []const u8) !Line {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return .ignore;
    const v = std.json.parseFromSliceLeaky(Value, a, trimmed, .{ .allocate = .alloc_always }) catch return .ignore;
    if (v != .object) return .ignore;
    const kind = strField(v.object, "type") orelse return .ignore;
    if (std.mem.eql(u8, kind, "stream_event")) {
        const ev = v.object.get("event") orelse return .ignore;
        // A subagent's events carry its parent's tool_use id; graff has no
        // Claude Code subagents (its tools are the only tools), so skip them.
        if (v.object.get("parent_tool_use_id")) |p| if (p != .null) return .ignore;
        return if (ev == .object) .{ .event = ev } else .ignore;
    }
    if (std.mem.eql(u8, kind, "control_request")) {
        const req = v.object.get("request") orelse return .ignore;
        if (req != .object) return .ignore;
        return .{ .control = .{
            .request_id = strField(v.object, "request_id") orelse return .ignore,
            .subtype = strField(req.object, "subtype") orelse "",
            .request = req.object,
        } };
    }
    if (std.mem.eql(u8, kind, "control_cancel_request")) return .{ .cancel = strField(v.object, "request_id") orelse return .ignore };
    if (std.mem.eql(u8, kind, "control_response")) {
        const r = v.object.get("response") orelse return .ignore;
        if (r != .object) return .ignore;
        return .{ .response = .{
            .request_id = strField(r.object, "request_id") orelse return .ignore,
            .ok = std.mem.eql(u8, strField(r.object, "subtype") orelse "", "success"),
            .body = r.object.get("response"),
            .err = strField(r.object, "error") orelse "",
        } };
    }
    if (std.mem.eql(u8, kind, "result")) {
        const is_error = if (v.object.get("is_error")) |e| e == .bool and e.bool else false;
        const subtype = strField(v.object, "subtype") orelse "success";
        return .{ .result = .{
            .is_error = is_error or !std.mem.eql(u8, subtype, "success"),
            .text = strField(v.object, "result") orelse subtype,
        } };
    }
    return .ignore;
}

/// Strip graff's MCP server prefix from a streamed tool_use block, in place,
/// so graff's loop sees its own tool names. True if the event is a tool_use start.
pub fn unprefixToolUse(ev: *Value) bool {
    if (ev.* != .object) return false;
    if (!std.mem.eql(u8, strField(ev.object, "type") orelse "", "content_block_start")) return false;
    const block = ev.object.getPtr("content_block") orelse return false;
    if (block.* != .object or !std.mem.eql(u8, strField(block.object, "type") orelse "", "tool_use")) return false;
    const name = block.object.getPtr("name") orelse return true;
    if (name.* == .string and std.mem.startsWith(u8, name.string, tool_prefix)) name.* = .{ .string = name.string[tool_prefix.len..] };
    return true;
}

/// Whether `version` (e.g. "2.1.304", suffixes ignored) is at least `floor`.
pub fn atLeast(version: []const u8, floor: []const u8) bool {
    var vi = std.mem.splitScalar(u8, std.mem.sliceTo(version, '-'), '.');
    var fi = std.mem.splitScalar(u8, floor, '.');
    while (fi.next()) |fpart| {
        const want = std.fmt.parseUnsigned(u32, fpart, 10) catch 0;
        const have = std.fmt.parseUnsigned(u32, vi.next() orelse "0", 10) catch 0;
        if (have != want) return have > want;
    }
    return true;
}
