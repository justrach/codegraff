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
    // Sticky cache partition from the first request. Codex/OpenAI document
    // prompt_cache_key; xAI uses the same id as x-grok-conv-id (routes the
    // request to the server that already has the prefix). Root = project
    // id, child = suffix. Effort is NOT flipped per turn — that would miss
    // the prefix.
    var ckbuf: [96]u8 = undefined;
    try s.objectField("prompt_cache_key");
    try s.write(http_headers.promptCacheKey(self.io, self.label, self, &ckbuf));
    // Held-socket delta: previous_response_id + only the new items. xAI's
    // published WS contract supports this with store:false via the in-memory
    // connection cache; a not-found / 25-min close / drop re-anchors.
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
    try s.write(if (self.compaction_request or self.server_compaction_request) "low" else if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
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
    // #543 degrade: this provider cannot enforce json_schema server-side —
    // learned on the chat wire (sox), structural on the anthropic wire (no
    // response_format exists) — so the schema itself must reach the model:
    // through the structured_output tool when offered (the tools-off
    // formatting turn), else as the entire final message.
    // Chat-wire only for sox: a stale learned flag must not perturb the
    // responses wire's bytes (native text.format needs no prompt embed).
    if ((self.provider.kind == .openai and self.sox_json_object) or self.provider.kind == .anthropic) return std.mem.concat(self.scratchAlloc(), u8, &.{
        base,
        "\n\nA JSON output schema is enforced on your final answer. Use tools first to gather every fact you need — never guess values. This provider cannot enforce the schema server-side, so satisfy it yourself: call the structured_output tool when it is offered, otherwise reply with a single JSON object, matching exactly this schema: ",
        self.output_schema.?,
    });
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

/// #543 fallback for providers without json_schema support (deepseek): plain
/// JSON mode — the schema constraint moves into the prompt (schemaAwarePrompt).
pub fn writeJsonObjectFormat(s: *std.json.Stringify) !void {
    try s.objectField("response_format");
    try s.beginObject();
    try s.objectField("type");
    try s.write("json_object");
    try s.endObject();
}

/// #543 tool mode (dsh's structured_output pattern): on the tools-off
/// formatting turn the schema IS a tool — function calling replaces
/// response_format entirely, and argument validation (handleStructuredOutput)
/// gives a repair loop json_object mode never had. No forced tool_choice:
/// deepseek's thinking mode rejects it ("Thinking mode does not support this
/// tool_choice" — the same conflict the anthropic branch notes for Kimi), and
/// dsh's own MUST-call instruction carries the demand instead.
pub fn writeStructuredOutputTool(s: *std.json.Stringify, schema_json: []const u8) !void {
    try s.objectField("tools");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("function");
    try s.objectField("function");
    try s.beginObject();
    try s.objectField("name");
    try s.write("structured_output");
    try s.objectField("description");
    try s.write("Report your final answer. Call this exactly once, when your answer is complete; the arguments must match this tool's parameter schema exactly.");
    try s.objectField("parameters");
    try s.print("{s}", .{schema_json});
    try s.endObject();
    try s.endObject();
    try s.endArray();
}

/// #543, anthropic wire: same tool, Anthropic tool shape (input_schema). This
/// wire has no response_format at all, so the tool is not a degrade — it is
/// the only server-visible carrier the schema has (Anthropic's own canonical
/// structured-output pattern). Unforced, as everywhere: forced tool_choice
/// conflicts with thinking on this wire too.
pub fn writeAnthropicStructuredTool(s: *std.json.Stringify, schema_json: []const u8) !void {
    try s.objectField("tools");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("name");
    try s.write("structured_output");
    try s.objectField("description");
    try s.write("Report your final answer. Call this exactly once, when your answer is complete; the input must match this tool's input schema exactly.");
    try s.objectField("input_schema");
    try s.print("{s}", .{schema_json});
    try s.endObject();
    try s.endArray();
}

/// #543 tool-mode capture: the forced structured_output call IS the final
/// answer. Arguments are checked against the schema's top-level `required`
/// list; a violation returns a tool ERROR so the model corrects itself in
/// the ordinary loop (dsh's validate-and-repair). Valid arguments land via
/// self.completed — the same end-of-turn channel attempt_completion uses.
pub fn handleStructuredOutput(self: *Agent, input: Value) @import("tools.zig").ExecResult {
    if (input != .object) return .{ .text = "structured_output arguments must be a single JSON object matching the tool's parameter schema", .is_error = true };
    if (self.output_schema) |schema_json| {
        if (std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), schema_json, .{})) |schema_v| {
            if (schema_v == .object) if (schema_v.object.get("required")) |req| if (req == .array) {
                for (req.array.items) |k| if (k == .string and input.object.get(k.string) == null) {
                    const text = std.fmt.allocPrint(self.arena, "arguments do not match the schema: missing required key \"{s}\" — call structured_output again with every required key present", .{k.string}) catch "arguments do not match the schema: a required key is missing";
                    return .{ .text = text, .is_error = true };
                };
            };
        } else |_| {}
    }
    var aw: std.Io.Writer.Allocating = .init(self.arena);
    var st: std.json.Stringify = .{ .writer = &aw.writer };
    st.write(input) catch return .{ .text = "structured_output arguments could not be serialized", .is_error = true };
    self.completed = aw.toOwnedSlice() catch return .{ .text = "structured_output arguments could not be serialized", .is_error = true };
    return .{ .text = "structured output recorded", .is_error = false };
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

test "openai/codex Responses send prompt_cache_key and leave cache mode to the API" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var oai = try testAgentFor(a, "openai", .responses, "gpt-5.6");
    const ob = try oai.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ob);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_key\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "prompt_cache_options") == null);

    var codex = try testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const cb = try codex.buildBody(null, false, true, true);
    defer std.testing.allocator.free(cb);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"prompt_cache_key\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "prompt_cache_options") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"") != null); // xAI caches on it (+ x-grok-conv-id header)
    try std.testing.expect(std.mem.indexOf(u8, body, "service_tier") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_breakpoint") == null);
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

test "#543: json_schema rejection degrades dsh-style — forced structured_output tool on the formatting turn, json_object with tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}";
    var agent = try testAgentFor(arena_state.allocator(), "deepseek", .openai, "deepseek-v4-flash");
    agent.output_schema = schema;
    agent.sox_json_object = true; // learned via the request() quirk ladder on deepseek's rejection

    // Tools-off formatting turn: the schema IS a tool, forced — no response_format at all.
    const body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"structured_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{\"answer\"") != null);
    // NO forced tool_choice: deepseek thinking mode rejects it; the instruction demands the call.
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response_format") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "json_schema") == null);
    // The prompt suffix still teaches the contract and carries the schema.
    try std.testing.expect(std.mem.indexOf(u8, body, "cannot enforce the schema server-side") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"additionalProperties\\\":false") != null);

    // A turn with real tools cannot merge the synthetic one — json_object mode instead.
    const tools = "[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"\",\"parameters\":{\"type\":\"object\"}}}]";
    const body2 = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body2);
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"response_format\":{\"type\":\"json_object\"}") != null);
    // The prompt suffix may NAME the tool; the synthetic DEFINITION must not appear.
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"name\":\"structured_output\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body2, "json_schema") == null);
}

test "#543: the anthropic wire always carries the schema as a structured_output tool (no response_format exists there)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}";
    var agent = try testAgentFor(arena_state.allocator(), "anthropic", .anthropic, "claude-sonnet-5");
    agent.output_schema = schema; // no sox learning needed — structural on this wire

    // Tools-off formatting turn: anthropic tool shape, schema as input_schema, unforced.
    const body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"structured_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\",\"properties\":{\"answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response_format") == null);
    // The cached system block carries the schema-aware suffix (was self.systemPrompt() before — the schema never reached this wire at all).
    try std.testing.expect(std.mem.indexOf(u8, body, "cannot enforce the schema server-side") != null);

    // Agentic turn with real tools: no synthetic tool, but the suffix still teaches the contract.
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const body2 = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body2);
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"name\":\"structured_output\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body2, "cannot enforce the schema server-side") != null);

    // No schema → byte-identical prompt path (base), no tools field at all when tools==null.
    agent.output_schema = null;
    const plain = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "structured_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"tools\"") == null);
}

test "#543: handleStructuredOutput validates required keys, repairs via tool error, lands via completed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try testAgentFor(a, "deepseek", .openai, "deepseek-v4-flash");
    agent.output_schema = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}},\"required\":[\"n\",\"name\"]}";

    // Non-object arguments are a schema violation, not a capture.
    const bad_shape = handleStructuredOutput(&agent, .{ .string = "42" });
    try std.testing.expect(bad_shape.is_error);
    try std.testing.expect(agent.completed == null);

    // A missing required key names itself so the model can repair and retry.
    const missing = handleStructuredOutput(&agent, try std.json.parseFromSliceLeaky(Value, a, "{\"n\":4}", .{}));
    try std.testing.expect(missing.is_error);
    try std.testing.expect(std.mem.indexOf(u8, missing.text, "missing required key \"name\"") != null);
    try std.testing.expect(agent.completed == null);

    // Valid arguments become the final answer, verbatim JSON, via completed.
    const ok = handleStructuredOutput(&agent, try std.json.parseFromSliceLeaky(Value, a, "{\"n\":4,\"name\":\"SKU-B\"}", .{}));
    try std.testing.expect(!ok.is_error);
    try std.testing.expectEqualStrings("structured output recorded", ok.text);
    const final = agent.completed.?;
    try std.testing.expect(std.mem.indexOf(u8, final, "\"n\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "\"name\":\"SKU-B\"") != null);
}
