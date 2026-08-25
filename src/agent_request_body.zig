//! Provider-specific request-body serialization.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const max_tokens = main_mod.max_tokens;
const Agent = @import("agent.zig").Agent;
const serde = @import("serde.zig");
const http_headers = @import("http_headers.zig");
const codex_chain = @import("codex_chain.zig");
const server_compact = @import("agent_server_compact.zig");
const pricing = @import("pricing.zig");
const writeAnthropicMessages = serde.writeAnthropicMessages;
const writeAnthropicTools = serde.writeAnthropicTools;
const writeKimiTools = serde.writeKimiTools;
const writeOpenAIMessageNormalized = serde.writeOpenAIMessageNormalized;

pub fn responsesOutputLimit(self: *const Agent) u32 {
    if (self.compaction_request) return 4096;
    return self.responses_output_limit orelse max_tokens;
}

pub fn buildBody(self: *Agent, tools: ?[]const u8, force_tool: bool, stream: bool, stream_usage: bool) ![]u8 {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(self.provider.model);
    switch (self.provider.kind) {
        .anthropic => {
            const is_kimi = std.mem.eql(u8, self.provider.id, "kimi");
            try s.objectField("max_tokens");
            try s.write(max_tokens);
            if (stream) {
                try s.objectField("stream");
                try s.write(true);
            }
            // Kimi's catalog-declared Anthropic transport uses enabled
            // thinking plus output_config.effort; Claude uses adaptive.
            // Forced tool_choice conflicts with thinking, so skip it then.
            if (!force_tool) {
                if (is_kimi) {
                    if (pricing.kimiSupportsThinking(self.provider.model)) {
                        try s.objectField("thinking");
                        // kimi-code default: keep:"all" on every thinking request (#323; k3 accepts it — verified live).
                        try s.print("{s}", .{"{\"type\":\"enabled\",\"keep\":\"all\"}"});
                        if (pricing.kimiThinkingEffort(self.provider.model, @tagName(self.reasoning))) |effort| {
                            try s.objectField("output_config");
                            try s.beginObject();
                            try s.objectField("effort");
                            try s.write(effort);
                            try s.endObject();
                        }
                    }
                } else {
                    // Current Claude models default thinking.display to "omitted", which
                    // streams thinking blocks with an empty body — graff's live Thinking
                    // panel then shows nothing. Ask for the summary. Only the real
                    // Anthropic API knows the field; the other anthropic-format providers
                    // (minimax) must never see it.
                    const thinking_obj: []const u8 = if (std.mem.eql(u8, self.provider.id, "anthropic"))
                        "{\"type\":\"adaptive\",\"display\":\"summarized\"}"
                    else
                        "{\"type\":\"adaptive\"}";
                    try s.objectField("thinking");
                    try s.print("{s}", .{thinking_obj});
                }
            }
            // Prompt caching (Anthropic): a block-level cache_control breakpoint
            // on the system block caches the whole stable prefix (system+tools);
            // other anthropic-format providers (minimax) get a plain string.
            try s.objectField("system");
            const sys = try @import("agent_request_body_responses.zig").schemaAwarePrompt(self);
            const cc = "{\"type\":\"ephemeral\"}";
            if (std.mem.eql(u8, self.provider.id, "anthropic") or is_kimi) {
                try s.beginArray();
                try s.beginObject();
                try s.objectField("type");
                try s.write("text");
                try s.objectField("text");
                try s.write(sys);
                try s.objectField("cache_control");
                try s.print("{s}", .{cc});
                try s.endObject();
                try s.endArray();
            } else {
                try s.write(sys);
            }
            if (tools) |t| {
                try s.objectField("tools");
                try writeAnthropicTools(&s, self.scratchAlloc(), t, is_kimi);
                if (force_tool) {
                    try s.objectField("tool_choice");
                    try s.print("{s}", .{"{\"type\":\"any\"}"});
                }
            } else if (self.output_schema != null) {
                // #543: this wire has no response_format at all — the schema is
                // ALWAYS delivered as the structured_output tool (dsh pattern).
                try @import("agent_request_body_responses.zig").writeAnthropicStructuredTool(&s, self.output_schema.?);
            }
            try s.objectField("messages");
            // Cache the conversation prefix too (not just system) on the real
            // Anthropic API and Kimi's declared Anthropic transport. Kimi also
            // normalizes all string content into Anthropic text blocks.
            const cache_msgs = std.mem.eql(u8, self.provider.id, "anthropic") or is_kimi;
            try writeAnthropicMessages(&s, self.messages, cache_msgs, is_kimi);
        },
        .openai => {
            // graff's MakeOpenAiCompat: OpenAI deprecated max_tokens in
            // favor of max_completion_tokens — send the new name to the
            // direct OpenAI API, and to any provider that rejected the
            // old one (cap_new, learned via the retry in request()).
            const is_kimi = std.mem.eql(u8, self.provider.id, "kimi");
            const cap_field = if (std.mem.eql(u8, self.provider.id, "openai") or is_kimi or self.cap_new)
                "max_completion_tokens"
            else
                "max_tokens";
            try s.objectField(cap_field);
            try s.write(max_tokens);
            if (stream) {
                try s.objectField("stream");
                try s.write(true);
                // Without include_usage the stream carries no token
                // counts (context tracking + auto-compaction need them).
                if (stream_usage) {
                    try s.objectField("stream_options");
                    try s.print("{s}", .{"{\"include_usage\":true}"});
                }
            }
            if (tools) |t| {
                try s.objectField("tools");
                // #261 follow-up: the rest need the root-schema repair too.
                if (is_kimi)
                    try writeKimiTools(&s, self.scratchAlloc(), t)
                else
                    try serde.writeOpenAITools(&s, self.scratchAlloc(), t);
                if (force_tool) {
                    try s.objectField("tool_choice");
                    try s.write("required");
                }
            }
            try s.objectField("messages");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("role");
            try s.write("system");
            try s.objectField("content");
            try s.write(try @import("agent_request_body_responses.zig").schemaAwarePrompt(self));
            try s.endObject();
            for (self.messages.items) |m| try writeOpenAIMessageNormalized(&s, m);
            try s.endArray();
            // The live Kimi catalog declares thinking support and allowed
            // efforts per model. Native Kimi places this proprietary object at
            // the top level (not `reasoning_effort`).
            if (is_kimi and pricing.kimiSupportsThinking(self.provider.model)) {
                try s.objectField("thinking");
                try s.beginObject();
                try s.objectField("type");
                try s.write("enabled");
                // kimi-code default: keep:"all" on every thinking request (#323).
                try s.objectField("keep");
                try s.write("all");
                if (pricing.kimiThinkingEffort(self.provider.model, @tagName(self.reasoning))) |effort| {
                    try s.objectField("effort");
                    try s.write(effort);
                }
                try s.endObject();
            }
            // Sticky cache partition. Same value as x-grok-conv-id (xAI
            // official maximize-hits). Root is the project id; children
            // share a role lane so sibling scouts reuse system+tools.
            var ckbuf: [96]u8 = undefined;
            try s.objectField("prompt_cache_key");
            try s.write(http_headers.requestCacheKey(self.io, self.label, self, self.provider.id, &ckbuf));
            // reasoning_effort (codegraff/deepseek/zai) + Z.AI thinking + Vercel reasoning.effort.
            try @import("zai_wire.zig").writeChatExtras(&s, self.provider.id, self.sendReasoningEffort(), @tagName(self.reasoning));
            // --output-schema: structured outputs (xAI docs' response_format).
            // A provider that rejected json_schema (#543, deepseek) degrades
            // dsh-style: the tools-off formatting turn carries the schema as a
            // forced structured_output tool (validation + repair loop); a turn
            // with real tools falls back to json_object + schema-in-prompt.
            if (self.output_schema) |schema_json| {
                const sox = @import("agent_request_body_responses.zig");
                if (!self.sox_json_object)
                    try sox.writeResponseFormat(&s, schema_json)
                else if (tools != null)
                    try sox.writeJsonObjectFormat(&s)
                else
                    try sox.writeStructuredOutputTool(&s, schema_json);
            }
        },
        // The Responses-wire body (codex / xAI / native Codegraff) lives in its own module
        // under the 600-line ceiling; structured-output writers ride along.
        .responses => try @import("agent_request_body_responses.zig").write(self, &s, tools, force_tool),
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

test "Kimi request body follows live native or Anthropic protocol metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    const rows = [_]pricing.ModelInfo{
        .{ .provider = "kimi", .name = "native-k3", .context = 1_048_576, .protocol = .kimi, .supports_reasoning = true, .support_efforts = &.{"max"}, .default_effort = "max" },
        .{ .provider = "kimi", .name = "anthropic-k3", .context = 1_048_576, .protocol = .anthropic, .supports_reasoning = true, .support_efforts = &.{"max"}, .default_effort = "max" },
    };
    try std.testing.expect(pricing.activateKimiModels(arena, &rows));

    var messages = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "hello" });
    try messages.append(.{ .object = user });
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "native-k3", .context = 1_048_576 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const openai_tools = "[{\"type\":\"function\",\"function\":{\"name\":\"ping\",\"description\":\"\",\"parameters\":{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\",\"anyOf\":[{\"const\":\"one\"},{\"const\":\"two\"}]},\"other\":{\"type\":\"string\"}},\"anyOf\":[{\"required\":[\"target\"]},{\"required\":[\"other\"]}]}}}]";
    const native = try agent.buildBody(openai_tools, false, true, true);
    defer std.testing.allocator.free(native);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"max_completion_tokens\":16000") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\",\"effort\":\"max\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"role\":\"system\",\"content\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"reasoning_effort\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"target\":{\"anyOf\":[{\"const\":\"one\",\"type\":\"string\"},{\"const\":\"two\",\"type\":\"string\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"oneOf\":[{\"required\":[\"target\"],\"type\":\"object\"},{\"required\":[\"other\"],\"type\":\"object\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"prompt_cache_key\":\"") != null); // kimi-code: session-id cache affinity on every request

    agent.provider.kind = .anthropic;
    agent.provider.auth = .x_api_key;
    agent.provider.model = "anthropic-k3";
    const anthropic_tools = "[{\"name\":\"ping\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const anthropic = try agent.buildBody(anthropic_tools, false, true, true);
    defer std.testing.allocator.free(anthropic);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"output_config\":{\"effort\":\"max\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"type\":\"adaptive\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"system\":[{\"type\":\"text\",\"text\":\"system\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"content\":[{\"type\":\"text\",\"text\":\"hello\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"input_schema\":{\"type\":\"object\"},\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"prompt_cache_key\"") == null); // native-transport field only
}

// ── Retained-reasoning wire-format regressions ──────────────────────────────
// OpenAI's ARC-AGI-3 result showed that keeping a model's reasoning across
// turns (rather than dropping it once a turn ends) is worth a large capability
// jump. graff already retains it on all three wire formats, but only as a side
// effect of echoing provider output verbatim into history — nothing pinned that
// behavior down, so a future normalization pass could silently drop it and no
// test would fail. These three tests assert the retention at the point it
// matters: the bytes that go on the wire.

fn testUserMessage(arena: std.mem.Allocator, text: []const u8) !Value {
    var m: std.json.ObjectMap = .empty;
    try m.put(arena, "role", .{ .string = "user" });
    try m.put(arena, "content", .{ .string = text });
    return .{ .object = m };
}

test "retained reasoning: openai-chat history replays reasoning_content on the next turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "count the files"));

    // Assistant turn 1: streamed reasoning plus a tool call. content is null
    // here, which is exactly the shape writeOpenAIMessageNormalized rebuilds
    // field-by-field — the one place a replay could lose reasoning_content.
    var call_fn: std.json.ObjectMap = .empty;
    try call_fn.put(arena, "name", .{ .string = "bash" });
    try call_fn.put(arena, "arguments", .{ .string = "{}" });
    var call: std.json.ObjectMap = .empty;
    try call.put(arena, "id", .{ .string = "c1" });
    try call.put(arena, "type", .{ .string = "function" });
    try call.put(arena, "function", .{ .object = call_fn });
    var calls = std.json.Array.init(arena);
    try calls.append(.{ .object = call });
    var assistant_call: std.json.ObjectMap = .empty;
    try assistant_call.put(arena, "role", .{ .string = "assistant" });
    try assistant_call.put(arena, "content", .null);
    try assistant_call.put(arena, "reasoning_content", .{ .string = "plan: list the directory" });
    try assistant_call.put(arena, "tool_calls", .{ .array = calls });
    try messages.append(.{ .object = assistant_call });

    var tool_result: std.json.ObjectMap = .empty;
    try tool_result.put(arena, "role", .{ .string = "tool" });
    try tool_result.put(arena, "tool_call_id", .{ .string = "c1" });
    try tool_result.put(arena, "content", .{ .string = "3 files" });
    try messages.append(.{ .object = tool_result });

    // Assistant turn 2: reasoning plus ordinary text (the verbatim path).
    var assistant_text: std.json.ObjectMap = .empty;
    try assistant_text.put(arena, "role", .{ .string = "assistant" });
    try assistant_text.put(arena, "content", .{ .string = "there are 3" });
    try assistant_text.put(arena, "reasoning_content", .{ .string = "the tool reported 3" });
    try messages.append(.{ .object = assistant_text });

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 128_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const body = try agent.buildBody("[{\"type\":\"function\",\"function\":{\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{}}}]", false, true, true);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null); // #261 follow-up: repaired on every non-kimi openai endpoint

    // Both turns' reasoning must reach the wire. DeepSeek's thinking mode
    // REQUIRES the tool-call turn's reasoning_content to be replayed on every
    // later request; dropping it is a hard 400, not a silent quality loss.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"plan: list the directory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"the tool reported 3\"") != null);
    // The null-content rebuild coerces content to "" (providers reject null
    // alongside tool_calls) and must keep every other field, reasoning included.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":null") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
}

test "retained reasoning: anthropic replays thinking+signature inside a multi-step tool turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "fix the build"));

    // Assistant turn: thinking block (with its signature) followed by tool_use.
    // Anthropic requires the thinking block to be replayed unchanged, in place,
    // when the turn that produced it contained a tool call — editing or dropping
    // it is a signature/ordering 400.
    var thinking_block: std.json.ObjectMap = .empty;
    try thinking_block.put(arena, "type", .{ .string = "thinking" });
    try thinking_block.put(arena, "thinking", .{ .string = "the linker flag is wrong" });
    try thinking_block.put(arena, "signature", .{ .string = "sigabc" });
    var use_block: std.json.ObjectMap = .empty;
    try use_block.put(arena, "type", .{ .string = "tool_use" });
    try use_block.put(arena, "id", .{ .string = "tu_1" });
    try use_block.put(arena, "name", .{ .string = "bash" });
    try use_block.put(arena, "input", .{ .object = .empty });
    var assistant_blocks = std.json.Array.init(arena);
    try assistant_blocks.append(.{ .object = thinking_block });
    try assistant_blocks.append(.{ .object = use_block });
    var assistant: std.json.ObjectMap = .empty;
    try assistant.put(arena, "role", .{ .string = "assistant" });
    try assistant.put(arena, "content", .{ .array = assistant_blocks });
    try messages.append(.{ .object = assistant });

    var result_block: std.json.ObjectMap = .empty;
    try result_block.put(arena, "type", .{ .string = "tool_result" });
    try result_block.put(arena, "tool_use_id", .{ .string = "tu_1" });
    try result_block.put(arena, "content", .{ .string = "ok" });
    var result_blocks = std.json.Array.init(arena);
    try result_blocks.append(.{ .object = result_block });
    var result_msg: std.json.ObjectMap = .empty;
    try result_msg.put(arena, "role", .{ .string = "user" });
    try result_msg.put(arena, "content", .{ .array = result_blocks });
    try messages.append(.{ .object = result_msg });

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const body = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body);

    // Adaptive thinking is what enables interleaved reasoning between tool
    // calls; it needs no beta header on current models. It also opts into a
    // summarized display, since current Claude models default to an empty one.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}") != null);
    // The whole block, signature included, survives the cache-breakpoint rewrite.
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"thinking\",\"thinking\":\"the linker flag is wrong\",\"signature\":\"sigabc\"}") != null);
    // A cache breakpoint belongs on the trailing tool_result, never on a
    // thinking block (cache_control is not a valid field there).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"signature\":\"sigabc\",\"cache_control\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"ok\",\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}

test "retained reasoning: codex full resend keeps encrypted reasoning items and requests them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "refactor this"));
    var reasoning_item: std.json.ObjectMap = .empty;
    try reasoning_item.put(arena, "type", .{ .string = "reasoning" });
    try reasoning_item.put(arena, "id", .{ .string = "rs_1" });
    try reasoning_item.put(arena, "encrypted_content", .{ .string = "ENCBLOB" });
    try messages.append(.{ .object = reasoning_item });
    var fc: std.json.ObjectMap = .empty;
    try fc.put(arena, "type", .{ .string = "function_call" });
    try fc.put(arena, "call_id", .{ .string = "c1" });
    try fc.put(arena, "name", .{ .string = "bash" });
    try fc.put(arena, "arguments", .{ .string = "{}" });
    try messages.append(.{ .object = fc });
    var fco: std.json.ObjectMap = .empty;
    try fco.put(arena, "type", .{ .string = "function_call_output" });
    try fco.put(arena, "call_id", .{ .string = "c1" });
    try fco.put(arena, "output", .{ .string = "done" });
    try messages.append(.{ .object = fco });

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 272_000 },
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
    const body = try agent.buildBody("[{\"type\":\"function\",\"name\":\"mcp__s__t\",\"description\":\"\",\"parameters\":{},\"strict\":false}]", false, true, true);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null); // #261 follow-up: repaired on the responses wire too
    // Ask the backend to hand reasoning back encrypted...
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    // ...and send the prior turn's reasoning item straight back. store:false
    // means the server keeps nothing, so this resend IS the retention.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"encrypted_content\":\"ENCBLOB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    // No live WS session -> no chaining, so the full input must carry it.
    try std.testing.expect(std.mem.indexOf(u8, body, "previous_response_id") == null);

    // Because store:false makes every turn a full resend, the backend needs a
    // cache partition to land it in. openai/codex send prompt_cache_key on
    // this exact path, keyed by the durable project id.
    var ckbuf: [96]u8 = undefined;
    const key = try std.fmt.allocPrint(arena, "\"prompt_cache_key\":\"{s}\"", .{http_headers.promptCacheKey(agent.io, agent.label, &agent, &ckbuf)});
    try std.testing.expect(std.mem.indexOf(u8, body, key) != null);
}

test "anthropic asks for summarized thinking; other anthropic-format providers do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "hello"));

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";

    // a. Real Anthropic, thinking allowed: adaptive thinking opts into a
    // summarized display, since current Claude models default to empty.
    const body_a = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body_a);
    try std.testing.expect(std.mem.indexOf(u8, body_a, "\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}") != null);

    // b. Forced tool_choice still suppresses the whole thinking object, exactly
    // as before this change.
    const body_b = try agent.buildBody(tools, true, true, true);
    defer std.testing.allocator.free(body_b);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "\"tool_choice\":{\"type\":\"any\"}") != null);

    // c. Other anthropic-format providers (minimax) reject unknown fields, so
    // they must never see "display" — only the bare adaptive object.
    agent.provider.id = "minimax";
    agent.provider.model = "MiniMax-M3";
    const body_c = try agent.buildBody(tools, false, true, true);
    defer std.testing.allocator.free(body_c);
    try std.testing.expect(std.mem.indexOf(u8, body_c, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_c, "\"display\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_c, "\"keep\"") == null); // #323: thinking.keep is Kimi-only
}

test "kimi k2.6 opts into thinking.keep so replayed reasoning is used, not just billed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    // Live-catalog shape for a keep-wanting model. #323: k2.6 supports
    // `thinking.keep` and defaults it to null, so without keep:"all" the
    // reasoning_content we replay each turn is billed and then discarded.
    const rows = [_]pricing.ModelInfo{.{ .provider = "kimi", .name = "kimi-k2.6", .context = 262_144, .supports_reasoning = true }};
    try std.testing.expect(pricing.activateKimiModels(arena, &rows));
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "kimi-k2.6", .context = 262_144 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "system",
    };
    const keep = "\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}";
    const native = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(native);
    try std.testing.expect(std.mem.indexOf(u8, native, keep) != null);
    // Kimi's Anthropic transport carries the same opt-in.
    agent.provider.kind = .anthropic;
    const anthropic = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(anthropic);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, keep) != null);
}

test "openai-wire bodies send a sticky prompt_cache_key; children isolate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = std.json.Array.init(arena);
    try messages.append(try testUserMessage(arena, "hello"));

    var root: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 1_000_000 },
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
    const rb = try root.buildBody(null, false, true, true);
    defer std.testing.allocator.free(rb);
    const needle = "\"prompt_cache_key\":\"";
    const rs = std.mem.indexOf(u8, rb, needle) orelse return error.MissingPromptCacheKey;
    const re = std.mem.indexOfScalarPos(u8, rb, rs + needle.len, '"') orelse return error.MissingPromptCacheKey;
    const root_key = rb[rs + needle.len .. re];
    var rkbuf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(http_headers.promptCacheKey(root.io, root.label, &root, &rkbuf), root_key);
    try std.testing.expect(!std.mem.eql(u8, root_key, http_headers.sessionId(root.io)));

    var child = root;
    child.sub = true;
    child.label = "sub";
    child.provider.id = "deepseek";
    child.provider.model = "deepseek-v4-flash";
    const cb = try child.buildBody(null, false, true, true);
    defer std.testing.allocator.free(cb);
    const cs = std.mem.indexOf(u8, cb, needle) orelse return error.MissingPromptCacheKey;
    const ce = std.mem.indexOfScalarPos(u8, cb, cs + needle.len, '"') orelse return error.MissingPromptCacheKey;
    const child_key = cb[cs + needle.len .. ce];
    try std.testing.expect(!std.mem.eql(u8, root_key, child_key));
    try std.testing.expect(std.mem.indexOf(u8, child_key, "-child-") != null);
    // Same role, different Agent: one prefix lane (prompt-cache max).
    var twin = child;
    const tb = try twin.buildBody(null, false, true, true);
    defer std.testing.allocator.free(tb);
    const ts = std.mem.indexOf(u8, tb, needle) orelse return error.MissingPromptCacheKey;
    const te = std.mem.indexOfScalarPos(u8, tb, ts + needle.len, '"') orelse return error.MissingPromptCacheKey;
    try std.testing.expectEqualStrings(child_key, tb[ts + needle.len .. te]);

    var oai = root;
    oai.provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 1_050_000 };
    const ob = try oai.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ob);
    try std.testing.expect(std.mem.indexOf(u8, ob, needle) != null);
}
