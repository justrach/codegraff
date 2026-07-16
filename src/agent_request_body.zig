//! Provider-specific request-body serialization.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const max_tokens = main_mod.max_tokens;
const Agent = @import("agent.zig").Agent;
const serde = @import("serde.zig");
const writeAnthropicMessages = serde.writeAnthropicMessages;
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
            try s.objectField("max_tokens");
            try s.write(max_tokens);
            if (stream) {
                try s.objectField("stream");
                try s.write(true);
            }
            // Forced tool_choice conflicts with adaptive thinking; skip
            // thinking only when forcing.
            if (!force_tool) {
                try s.objectField("thinking");
                try s.print("{s}", .{"{\"type\":\"adaptive\"}"});
            }
            // Prompt caching (Anthropic): a cache_control breakpoint on the
            // system block caches the whole stable prefix (system + tools).
            // Must be block-level — a top-level cache_control is invalid.
            // Other anthropic-format providers (minimax) get a plain
            // string, since cache_control isn't part of their API.
            try s.objectField("system");
            const cc = "{\"type\":\"ephemeral\"}";
            if (std.mem.eql(u8, self.provider.id, "anthropic")) {
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
                try s.print("{s}", .{t});
                if (force_tool) {
                    try s.objectField("tool_choice");
                    try s.print("{s}", .{"{\"type\":\"any\"}"});
                }
            }
            try s.objectField("messages");
            // Cache the conversation prefix too (not just system) on the real
            // Anthropic API: a rolling cache_control breakpoint on the last
            // message. minimax (anthropic-format, no cache_control) is excluded.
            const cache_msgs = std.mem.eql(u8, self.provider.id, "anthropic");
            try writeAnthropicMessages(&s, self.messages, cache_msgs);
        },
        .openai => {
            // graff's MakeOpenAiCompat: OpenAI deprecated max_tokens in
            // favor of max_completion_tokens — send the new name to the
            // direct OpenAI API, and to any provider that rejected the
            // old one (cap_new, learned via the retry in request()).
            const cap_field = if (std.mem.eql(u8, self.provider.id, "openai") or self.cap_new)
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
            // Reasoning-effort hint for OpenAI-compatible providers that
            // honor it (codegraff gateway, deepseek). Mirrors the
            // Responses `reasoning.effort` set in the branch below.
            if (self.effortApplies() and !self.effort_rejected) {
                try s.objectField("reasoning_effort");
                try s.write(if (self.reasoning == .ultra) "max" else @tagName(self.reasoning));
            }
            // Kimi K2.7's model card recommends temperature 1.0 + top_p 0.95
            // for its (always-on) Thinking mode; graff otherwise leaves
            // sampling to the server default.
            if (std.mem.eql(u8, self.provider.id, "kimi")) {
                try s.objectField("temperature");
                try s.write(@as(f64, 1.0));
                try s.objectField("top_p");
                try s.write(@as(f64, 0.95));
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
