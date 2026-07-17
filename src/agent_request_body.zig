//! Provider-specific request-body serialization.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const max_tokens = main_mod.max_tokens;
const Agent = @import("agent.zig").Agent;
const serde = @import("serde.zig");
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
                        try s.print("{s}", .{"{\"type\":\"enabled\"}"});
                        if (pricing.kimiThinkingEffort(self.provider.model, @tagName(self.reasoning))) |effort| {
                            try s.objectField("output_config");
                            try s.beginObject();
                            try s.objectField("effort");
                            try s.write(effort);
                            try s.endObject();
                        }
                    }
                } else {
                    try s.objectField("thinking");
                    try s.print("{s}", .{"{\"type\":\"adaptive\"}"});
                }
            }
            // Prompt caching (Anthropic): a cache_control breakpoint on the
            // system block caches the whole stable prefix (system + tools).
            // Must be block-level — a top-level cache_control is invalid.
            // Other anthropic-format providers (minimax) get a plain string,
            // since cache_control isn't part of their API. Kimi's official
            // Anthropic adapter uses the same cached text-block shape.
            try s.objectField("system");
            const cc = "{\"type\":\"ephemeral\"}";
            if (std.mem.eql(u8, self.provider.id, "anthropic") or is_kimi) {
                try s.beginArray();
                try s.beginObject();
                try s.objectField("type");
                try s.write("text");
                try s.objectField("text");
                try s.write(self.systemPrompt());
                try s.objectField("cache_control");
                try s.print("{s}", .{cc});
                try s.endObject();
                try s.endArray();
            } else {
                try s.write(self.systemPrompt());
            }
            if (tools) |t| {
                try s.objectField("tools");
                try writeAnthropicTools(&s, self.scratchAlloc(), t, is_kimi);
                if (force_tool) {
                    try s.objectField("tool_choice");
                    try s.print("{s}", .{"{\"type\":\"any\"}"});
                }
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
                if (is_kimi)
                    try writeKimiTools(&s, self.scratchAlloc(), t)
                else
                    try s.print("{s}", .{t});
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
            try s.write(self.systemPrompt());
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
                if (pricing.kimiThinkingEffort(self.provider.model, @tagName(self.reasoning))) |effort| {
                    try s.objectField("effort");
                    try s.write(effort);
                }
                try s.endObject();
            }
            // Reasoning-effort hint for OpenAI-compatible providers that
            // honor it (codegraff gateway, deepseek). Mirrors the
            // Responses `reasoning.effort` set in the branch below.
            if (!is_kimi and self.effortApplies() and !self.effort_rejected) {
                try s.objectField("reasoning_effort");
                try s.write(if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
            }
        },
        .responses => {
            // Codex / ChatGPT Responses API. system prompt → instructions;
            // history items are valid input items; stream is required by
            // the backend (we buffer + parse the SSE). reasoning items are
            // returned encrypted and passed back for cross-turn continuity.
            try s.objectField("instructions");
            try s.write(self.systemPrompt());
            // Codex WS delta: once a response.id is held on a live WS session,
            // send previous_response_id + only the items the server does not yet
            // hold, instead of the full history (avoids the huge frame that the
            // backend rejects → WriteFailed). Full input otherwise (first turn/SSE).
            if (self.codex_ws != null) if (self.codex_prev_id) |pid| {
                try s.objectField("previous_response_id");
                try s.write(pid);
            };
            try s.objectField("input");
            if (self.codex_ws != null and self.codex_prev_id != null and self.codex_sent_upto <= self.messages.items.len) {
                var delta = std.json.Array.init(self.arena);
                for (self.messages.items[self.codex_sent_upto..]) |m| try delta.append(m);
                try s.write(Value{ .array = delta });
            } else {
                try s.write(Value{ .array = self.messages });
            }
            if (tools) |t| {
                try s.objectField("tools");
                try s.print("{s}", .{t});
                try s.objectField("tool_choice");
                try s.write(if (force_tool) "required" else "auto");
                try s.objectField("parallel_tool_calls");
                try s.write(true);
            }
            // Codex "fast" mode (/fast): request the priority service
            // tier for lower latency. This branch is codex-only, so it is
            // never emitted for other providers.
            if (self.fast) {
                try s.objectField("service_tier");
                try s.write("priority");
            }
            try s.objectField("reasoning");
            try s.beginObject();
            try s.objectField("effort");
            // Ultra is a Graff/Codex client preset: maximum server reasoning
            // plus automatic delegation. The backend wire value is `max`.
            try s.write(if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
            try s.endObject();
            try s.objectField("include");
            try s.beginArray();
            try s.write("reasoning.encrypted_content");
            try s.endArray();
            try s.objectField("store");
            try s.write(false);
            // Bound every Responses request explicitly. The normal agent keeps
            // the existing 16k ceiling; compaction gets a focused 4k handoff
            // and title generation can override this to 64 tokens.
            try s.objectField("max_output_tokens");
            try s.write(responsesOutputLimit(self));
            try s.objectField("stream");
            try s.write(true);
        },
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
        .io = undefined,
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
    try std.testing.expect(std.mem.indexOf(u8, native, "\"thinking\":{\"type\":\"enabled\",\"effort\":\"max\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"role\":\"system\",\"content\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"reasoning_effort\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"target\":{\"anyOf\":[{\"const\":\"one\",\"type\":\"string\"},{\"const\":\"two\",\"type\":\"string\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, native, "\"oneOf\":[{\"required\":[\"target\"],\"type\":\"object\"},{\"required\":[\"other\"],\"type\":\"object\"}]") != null);

    agent.provider.kind = .anthropic;
    agent.provider.auth = .x_api_key;
    agent.provider.model = "anthropic-k3";
    const anthropic_tools = "[{\"name\":\"ping\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    const anthropic = try agent.buildBody(anthropic_tools, false, true, true);
    defer std.testing.allocator.free(anthropic);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"output_config\":{\"effort\":\"max\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"type\":\"adaptive\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"system\":[{\"type\":\"text\",\"text\":\"system\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"content\":[{\"type\":\"text\",\"text\":\"hello\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"input_schema\":{\"type\":\"object\"},\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}
