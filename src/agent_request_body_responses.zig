//! The Responses-wire request body (codex / xAI #502), split from
//! agent_request_body.zig under the 600-line ceiling, plus the structured-
//! output writers (text.format here, response_format for the chat wire).

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const serde = @import("serde.zig");
const http_headers = @import("http_headers.zig");
const codex_chain = @import("codex_chain.zig");
const server_compact = @import("agent_server_compact.zig");

pub fn write(self: *Agent, s: *std.json.Stringify, tools: ?[]const u8, force_tool: bool) !void {
    // Responses API (codex / ChatGPT backend, and xAI behind GRAFF_XAI_WIRE).
    // system prompt → instructions; history items are valid input items;
    // stream is required (we buffer + parse the SSE); reasoning items return
    // encrypted and are passed back per turn.
    const is_codex = std.mem.eql(u8, self.provider.id, "codex");
    try s.objectField("instructions");
    try s.write(try schemaAwarePrompt(self));
    if (is_codex) {
        // Pin our full resends to a per-session cache partition, the way
        // openai/codex does (it defaults this to the same session UUID it
        // puts in the `session_id` header). xAI documents automatic prompt
        // caching and no such field, so it stays codex-only.
        var ckbuf: [96]u8 = undefined;
        try s.objectField("prompt_cache_key");
        try s.write(http_headers.promptCacheKey(self.io, self.label, self, &ckbuf));
    }
    // Codex WS delta: once a response.id is held on a live WS session, send
    // previous_response_id + only the items the server does not yet hold.
    // codex_chain gates this to codex — xAI's WS stalls silently on a
    // store:false chained turn (probed 2026-08-15). ONE gate for both fields.
    const chain = codex_chain.chainUsable(self);
    if (chain) {
        try s.objectField("previous_response_id");
        try s.write(self.codex_prev_id.?);
    }
    try s.objectField("input");
    if (chain) {
        var delta = std.json.Array.init(self.arena);
        for (self.messages.items[self.codex_sent_upto..]) |m| try delta.append(m);
        try s.write(Value{ .array = delta });
    } else {
        try s.write(Value{ .array = self.messages });
    }
    if (tools) |t| {
        try s.objectField("tools");
        try serde.writeOpenAITools(s, self.scratchAlloc(), t); // #261 follow-up
        try s.objectField("tool_choice");
        try s.write(if (force_tool) "required" else "auto");
        try s.objectField("parallel_tool_calls");
        try s.write(true);
    }
    // Codex "fast" mode (/fast): priority service tier — a ChatGPT-backend
    // field the other Responses providers must never see.
    if (self.fast and is_codex) {
        try s.objectField("service_tier");
        try s.write("priority");
    }
    try s.objectField("reasoning");
    try s.beginObject();
    try s.objectField("effort");
    // Ultra preset → wire value `max`. #379: compaction summaries run at low
    // effort — a high-effort reasoner can complete with only reasoning items
    // and zero output text, i.e. an empty summary.
    try s.write(if (self.compaction_request) "low" else if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
    try s.endObject();
    try s.objectField("include");
    try s.beginArray();
    try s.write("reasoning.encrypted_content");
    try s.endArray();
    try s.objectField("store");
    try s.write(false);
    server_compact.noteExposure(self);
    try server_compact.writeContextManagement(self, s);
    if (self.output_schema) |schema_json| try writeTextFormat(s, schema_json);
    // No top-level max_output_tokens: the codex backend rejects it
    // ("Unsupported parameter") on gpt-5.6-* — codex sets it only as a tool argument.
    try s.objectField("stream");
    try s.write(true);
}

/// With --output-schema the strict grammar tempts the model to answer
/// immediately instead of touching tools (graff-evals caught grok-4.6
/// answering a file-inspection task without reading the file). One standing
/// line restores tools-first behavior; without a schema the prompt is
/// byte-identical to before.
pub fn schemaAwarePrompt(self: *Agent) ![]const u8 {
    const base = self.systemPrompt();
    if (self.output_schema == null) return base;
    return std.mem.concat(self.scratchAlloc(), u8, &.{
        base,
        "\n\nA JSON output schema is enforced on your final message. Use tools first to gather every fact you need; only the final message must match the schema — never guess values.",
    });
}

/// Structured outputs on the Responses wire (xAI/OpenAI): `text.format` with
/// the user's JSON schema the final answer must satisfy (--output-schema).
pub fn writeTextFormat(s: *std.json.Stringify, schema_json: []const u8) !void {
    try s.objectField("text");
    try s.beginObject();
    try s.objectField("format");
    try s.beginObject();
    try s.objectField("type");
    try s.write("json_schema");
    try s.objectField("name");
    try s.write("result");
    try s.objectField("strict");
    try s.write(true);
    try s.objectField("schema");
    try s.print("{s}", .{schema_json});
    try s.endObject();
    try s.endObject();
}

/// Structured outputs on the chat-completions wire: response_format
/// json_schema (the shape xAI/OpenAI/compatible routers document).
pub fn writeResponseFormat(s: *std.json.Stringify, schema_json: []const u8) !void {
    try s.objectField("response_format");
    try s.beginObject();
    try s.objectField("type");
    try s.write("json_schema");
    try s.objectField("json_schema");
    try s.beginObject();
    try s.objectField("name");
    try s.write("result");
    try s.objectField("strict");
    try s.write(true);
    try s.objectField("schema");
    try s.print("{s}", .{schema_json});
    try s.endObject();
    try s.endObject();
}

fn testAgentFor(arena: std.mem.Allocator, id: []const u8, kind: @import("provider.zig").Provider.Kind, model: []const u8) !Agent {
    var messages = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "hello" });
    try messages.append(.{ .object = user });
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = id, .kind = kind, .auth = .bearer, .url = "", .api_key = "k", .model = model, .context = 500_000 },
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
}

test "xai Responses body is bearer-clean: no codex-isms, xAI-legal fields only (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try testAgentFor(arena_state.allocator(), "xai", .responses, "grok-4.6");
    agent.fast = true; // must NOT leak service_tier off codex
    const body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"medium\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "service_tier") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "context_management") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "previous_response_id") == null);
}

test "--output-schema rides text.format on Responses and response_format on chat (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}";
    var agent = try testAgentFor(arena_state.allocator(), "xai", .responses, "grok-4.6");
    agent.output_schema = schema;
    const responses_body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(responses_body);
    try std.testing.expect(std.mem.indexOf(u8, responses_body, "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"result\",\"strict\":true,\"schema\":{\"type\":\"object\"") != null);

    var chat = try testAgentFor(arena_state.allocator(), "xai", .openai, "grok-4.6");
    chat.output_schema = schema;
    const chat_body = try chat.buildBody(null, false, true, true);
    defer std.testing.allocator.free(chat_body);
    try std.testing.expect(std.mem.indexOf(u8, chat_body, "\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"result\",\"strict\":true,\"schema\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chat_body, "\"text\":{\"format\"") == null);

    // No schema set → neither field appears (the overwhelmingly common path).
    var plain = try testAgentFor(arena_state.allocator(), "xai", .openai, "grok-4.6");
    const plain_body = try plain.buildBody(null, false, true, true);
    defer std.testing.allocator.free(plain_body);
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "response_format") == null);
}
