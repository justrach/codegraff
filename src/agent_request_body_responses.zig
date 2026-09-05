//! The Responses-wire request body (codex / xAI / native Codegraff), split from
//! agent_request_body.zig under the 600-line ceiling, plus the structured-
//! output writers (text.format here, response_format for the chat wire).

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const serde = @import("serde.zig");
const http_headers = @import("http_headers.zig");
const codex_chain = @import("codex_chain.zig");
const server_compact = @import("agent_server_compact.zig");
const xai_hosted = @import("xai_hosted.zig");
const codex_tool_search = @import("codex_tool_search.zig");

pub fn write(self: *Agent, s: *std.json.Stringify, tools: ?[]const u8, force_tool: bool) !void {
    // Responses API (codex / ChatGPT, xAI, and native Codegraff aliases).
    // system prompt → instructions; history items are valid input items;
    // stream is required (we buffer + parse the SSE); reasoning items return
    // encrypted and are passed back per turn.
    const is_codex = std.mem.eql(u8, self.provider.id, "codex");
    try s.objectField("instructions");
    try s.write(try schemaAwarePrompt(self));
    // Sticky cache partition from the first request. xAI's key is a true
    // per-conversation routing id. OpenAI/Codex instead share deterministic
    // prefix lanes so repeated workflow roles can reuse the stable prompt.
    var ckbuf: [96]u8 = undefined;
    try s.objectField("prompt_cache_key");
    try s.write(http_headers.requestCacheKey(self.io, self.label, self, self.provider.id, &ckbuf));
    const explicit_cache = supportsExplicitPromptCache(self);
    if (explicit_cache) {
        try s.objectField("prompt_cache_options");
        try s.beginObject();
        try s.objectField("mode");
        // Root conversations grow append-only, so retain the useful implicit
        // latest-message breakpoint. One-shot children cache only the shared
        // system+tools prefix and avoid paying to write each unique task suffix.
        try s.write(if (self.sub) "explicit" else "implicit");
        try s.objectField("ttl");
        try s.write("30m");
        try s.endObject();
    }
    // Held-socket delta: previous_response_id + only the new items. xAI's
    // published WS contract supports this with store:false via the in-memory
    // connection cache; a not-found / 25-min close / drop re-anchors.
    const chain = codex_chain.chainUsable(self);
    if (chain) {
        try s.objectField("previous_response_id");
        try s.write(self.codex_prev_id.?);
    }
    try s.objectField("input");
    try s.beginArray();
    // Top-level `instructions` cannot carry a GPT-5.6 breakpoint. A stable,
    // semantically neutral developer block after it marks the reusable boundary;
    // tools are also part of the rendered prefix. Chained requests already hold
    // this item server-side, so only a full anchor writes it.
    if (!chain and explicit_cache) try writeCacheAnchor(s);
    const from = if (chain) self.codex_sent_upto else 0;
    for (self.messages.items[from..]) |m| try s.write(m);
    try s.endArray();
    if (tools) |t| {
        const payload = blk: {
            var next = t;
            if (xai_hosted.active(self.provider.id, self.provider.kind)) {
                const login = self.provider.source == .login;
                next = xai_hosted.splice(self.scratchAlloc(), next, login) catch next;
            }
            if (codex_tool_search.active(self.provider.id, self.provider.kind, self.provider.model)) {
                next = codex_tool_search.splice(self.scratchAlloc(), next) catch next;
                next = codex_tool_search.spliceWebSearch(self.scratchAlloc(), next) catch next;
            }
            break :blk next;
        };
        try s.objectField("tools");
        try serde.writeOpenAITools(s, self.scratchAlloc(), payload); // #261 follow-up
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
    // #379: compaction summaries run at low — a high-effort reasoner can
    // complete with only reasoning items and zero output text.
    try s.write(if (self.compaction_request or self.server_compaction_request) "low" else @import("effort_route.zig").wireEffort(self.provider.model, @tagName(self.reasoning)));
    try s.endObject();
    try s.objectField("include");
    try s.beginArray();
    try s.write("reasoning.encrypted_content");
    if (is_codex and codex_tool_search.web_search) try s.write("web_search_call.action.sources");
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

fn supportsExplicitPromptCache(self: *const Agent) bool {
    return std.mem.eql(u8, self.provider.id, "openai") and std.mem.startsWith(u8, self.provider.model, "gpt-5.6");
}

fn writeCacheAnchor(s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("message");
    try s.objectField("role");
    try s.write("developer");
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("input_text");
    try s.objectField("text");
    try s.write("The preceding instructions and available tools are the stable operating context for this session.");
    try s.objectField("prompt_cache_breakpoint");
    try s.beginObject();
    try s.objectField("mode");
    try s.write("explicit");
    try s.endObject();
    try s.endObject();
    try s.endArray();
    try s.endObject();
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
    // learned on the chat wire (sox), or structural on minimax / kimi-anthropic
    // (tool mode) — so the schema itself must reach the model through the
    // structured_output tool when offered (the tools-off formatting turn),
    // else as the entire final message.
    // Chat-wire only for sox: a stale learned flag must not perturb the
    // responses wire's bytes (native text.format needs no prompt embed).
    // Full-schema embed is the tool-mode / learned-fallback path. Native
    // Anthropic `output_config.format` (provider id `anthropic`, no sox)
    // enforces server-side on the formatting turn — same light prompt as
    // Responses. minimax / kimi-anthropic stay on the tool.
    const anthropic_tool_mode = self.provider.kind == .anthropic and
        (self.sox_json_object or !std.mem.eql(u8, self.provider.id, "anthropic"));
    if ((self.provider.kind == .openai and self.sox_json_object) or anthropic_tool_mode) return std.mem.concat(self.scratchAlloc(), u8, &.{
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

/// #550: native Anthropic structured outputs on the tools-off formatting
/// turn. Provider id `anthropic` only — minimax / kimi-anthropic keep the
/// structured_output tool, and a learned sox flag falls back to it too.
pub fn writeAnthropicSchema(s: *std.json.Stringify, self: *const Agent, schema_json: []const u8) !void {
    if (std.mem.eql(u8, self.provider.id, "anthropic") and !self.sox_json_object) {
        try writeAnthropicOutputConfig(s, schema_json);
        return;
    }
    try writeAnthropicStructuredTool(s, schema_json);
}

/// kimi-code's anthropic adapter: `output_config.format = {type, schema}`.
/// Formatting turn only (ADR 0001): never attach this to a tools turn.
pub fn writeAnthropicOutputConfig(s: *std.json.Stringify, schema_json: []const u8) !void {
    try s.objectField("output_config");
    try s.beginObject();
    try s.objectField("format");
    try s.beginObject();
    try s.objectField("type");
    try s.write("json_schema");
    try s.objectField("schema");
    try s.print("{s}", .{schema_json});
    try s.endObject();
    try s.endObject();
}

/// #543, anthropic wire: same tool, Anthropic tool shape (input_schema).
/// Fallback for minimax / kimi-anthropic and for a rejected output_config.
/// Unforced: forced tool_choice conflicts with thinking on this wire too.
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

// #695: the wide-native RLM showcase invalidated `tools_responses` and never
// rebuilt it, and the next body serialized `"tools":,` — an HTTP 400 on
// every provider. The serialization guard in buildBody turns an empty
// catalog string into "omit the field" on all three wires; this pins that
// so no future invalidate-without-rebuild can reach the wire malformed.
test "#695: an empty catalog string is omitted from the body, never serialized as tools:, (#695)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var responses = try testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const rb = try responses.buildBody("", false, true, true);
    defer std.testing.allocator.free(rb);
    try std.testing.expect(std.mem.indexOf(u8, rb, "\"tools\":,") == null);
    try std.testing.expect(std.mem.indexOf(u8, rb, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rb, "\"parallel_tool_calls\"") == null);

    var chat = try testAgentFor(a, "xai", .openai, "grok-4.6");
    const cb = try chat.buildBody("", false, true, true);
    defer std.testing.allocator.free(cb);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"tools\":,") == null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"tool_choice\"") == null);

    var anthropic = try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5");
    const ab = try anthropic.buildBody("", false, true, true);
    defer std.testing.allocator.free(ab);
    try std.testing.expect(std.mem.indexOf(u8, ab, "\"tools\":,") == null);
    try std.testing.expect(std.mem.indexOf(u8, ab, "\"tool_choice\"") == null);

    // A real catalog still rides every wire untouched.
    var live = try testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const catalog = "[{\"type\":\"function\",\"name\":\"bash\",\"description\":\"\"}]";
    const lb = try live.buildBody(catalog, false, true, true);
    defer std.testing.allocator.free(lb);
    try std.testing.expect(std.mem.indexOf(u8, lb, "\"name\":\"bash\"") != null);
}

test "GPT-5.6 Platform marks the stable prefix; Codex and older routes do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var oai = try testAgentFor(a, "openai", .responses, "gpt-5.6");
    const ob = try oai.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ob);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_key\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_options\":{\"mode\":\"implicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"role\":\"developer\",\"content\":[{\"type\":\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\"}") != null);

    var worker = try testAgentFor(a, "openai", .responses, "gpt-5.6-luna");
    worker.sub = true;
    worker.label = "implement";
    const wb = try worker.buildBody(null, false, true, true);
    defer std.testing.allocator.free(wb);
    try std.testing.expect(std.mem.indexOf(u8, wb, "\"prompt_cache_options\":{\"mode\":\"explicit\",\"ttl\":\"30m\"}") != null);

    var codex = try testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const cb = try codex.buildBody(null, false, true, true);
    defer std.testing.allocator.free(cb);
    try std.testing.expect(std.mem.indexOf(u8, cb, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "prompt_cache_breakpoint") == null);

    var older = try testAgentFor(a, "openai", .responses, "gpt-5.5");
    const old = try older.buildBody(null, false, true, true);
    defer std.testing.allocator.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, old, "prompt_cache_options") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "context_management") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "previous_response_id") == null);

    agent.reasoning = .max;
    const max_body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(max_body);
    try std.testing.expect(std.mem.indexOf(u8, max_body, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, max_body, "\"effort\":\"max\"") == null);
}

test "xAI Responses splices hosted x_search onto a tools turn; Codex and chat do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tools = "[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"\",\"parameters\":{\"type\":\"object\"}}}]";
    const saved = xai_hosted.enabled;
    defer xai_hosted.enabled = saved;
    xai_hosted.enabled = true;

    var xai = try testAgentFor(a, "xai", .responses, "grok-4.6");
    const body = try xai.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"x_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "web_search") == null);

    var login = try testAgentFor(a, "xai", .responses, "grok-4.6");
    login.provider.source = .login;
    const login_body = try login.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(login_body);
    try std.testing.expect(std.mem.indexOf(u8, login_body, "\"type\":\"web_search\"") != null);

    var codex = try testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const cb = try codex.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(cb);
    try std.testing.expect(std.mem.indexOf(u8, cb, "x_search") == null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"type\":\"tool_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"type\":\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "web_search_call.action.sources") != null);

    var chat = try testAgentFor(a, "xai", .openai, "grok-4.6");
    const chat_body = try chat.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(chat_body);
    try std.testing.expect(std.mem.indexOf(u8, chat_body, "x_search") == null);

    xai_hosted.enabled = false;
    const off = try xai.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "x_search") == null);
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

test "#550: anthropic id uses output_config.format on the formatting turn; tool-mode is the fallback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}";
    var agent = try testAgentFor(arena_state.allocator(), "anthropic", .anthropic, "claude-sonnet-5");
    agent.output_schema = schema;

    // Tools-off formatting turn: native json_schema (ADR 0001 — not on tools turns).
    const body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "structured_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response_format") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "cannot enforce the schema server-side") == null);

    // Agentic turn: no grammar (ADR 0001), light prompt, no synthetic tool.
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const body2 = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body2);
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"name\":\"structured_output\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body2, "output_config") == null);
    try std.testing.expect(std.mem.indexOf(u8, body2, "cannot enforce the schema server-side") == null);
    try std.testing.expect(std.mem.indexOf(u8, body2, "only the final message must match the schema") != null);

    // Learned rejection: same quirk flag as sox_json_object → tool mode.
    agent.sox_json_object = true;
    const body3 = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(body3);
    try std.testing.expect(std.mem.indexOf(u8, body3, "\"tools\":[{\"name\":\"structured_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body3, "\"input_schema\":{\"type\":\"object\",\"properties\":{\"answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body3, "output_config") == null);
    try std.testing.expect(std.mem.indexOf(u8, body3, "cannot enforce the schema server-side") != null);

    // minimax keeps the tool even without sox (no native output_config).
    var mm = try testAgentFor(arena_state.allocator(), "minimax", .anthropic, "MiniMax-M2.5");
    mm.output_schema = schema;
    const mm_body = try mm.buildBody(null, false, true, true);
    defer std.testing.allocator.free(mm_body);
    try std.testing.expect(std.mem.indexOf(u8, mm_body, "\"tools\":[{\"name\":\"structured_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mm_body, "output_config") == null);

    // No schema → byte-identical prompt path (base), no tools / output_config.
    agent.sox_json_object = false;
    agent.output_schema = null;
    const plain = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "structured_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "output_config") == null);
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
