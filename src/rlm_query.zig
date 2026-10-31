//! RLM `llm_query`: a tools-off sub-LM call on the session provider.
//!
//! [Recursive Language Models](https://github.com/alexzhang13/rlm) treat a
//! long context as a REPL variable and peel questions off with `llm_query` /
//! `rlm_query`. Here the host function is that sub-call: one bounded
//! completion, no tools, so spec_ptc can launch it the moment the prompt
//! literal closes — overlapping generation of the rest of the script.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const http = @import("http.zig");
const title = @import("title.zig");

pub const max_out_tokens: u32 = 256;

pub fn run(ctx: ToolCtx, args_json: []const u8) ToolOutput {
    var parsed = std.json.parseFromSlice(Value, ctx.gpa, args_json, .{}) catch {
        return .{ .text = ctx.gpa.dupe(u8, "rlm: llm_query needs prompt") catch &.{}, .is_error = true };
    };
    defer parsed.deinit();
    const prompt = tools.strField(parsed.value, "prompt") orelse {
        return .{ .text = ctx.gpa.dupe(u8, "rlm: llm_query needs prompt") catch &.{}, .is_error = true };
    };
    if (prompt.len == 0) {
        return .{ .text = ctx.gpa.dupe(u8, "rlm: llm_query prompt is empty") catch &.{}, .is_error = true };
    }
    var permit: ?@import("run_budget.zig").Permit = null;
    if (ctx.run_budget) |budget| {
        permit = budget.acquire(ctx.io, ctx.depth, .child) catch |err| return .{
            .text = std.fmt.allocPrint(ctx.gpa, "rlm: llm_query refused: {s}", .{@errorName(err)}) catch unreachable,
            .is_error = true,
        };
    }
    defer if (permit) |*p| p.release();
    // Claude Agent has no HTTP endpoint: every model call goes through the
    // session's `claude` child (ADR 0309), which a nested query cannot share.
    if (std.mem.eql(u8, ctx.provider.id, "claude-agent"))
        return .{ .text = ctx.gpa.dupe(u8, "rlm: llm_query is not available on Claude Agent; work with the data directly") catch &.{}, .is_error = true };
    const body = buildBody(ctx.gpa, ctx.provider, prompt) catch {
        return .{ .text = ctx.gpa.dupe(u8, "rlm: llm_query could not build request") catch &.{}, .is_error = true };
    };
    defer ctx.gpa.free(body);
    const raw = http.postWatched(ctx.gpa, ctx.io, ctx.client, ctx.provider, body, null) catch |err| {
        return .{
            .text = std.fmt.allocPrint(ctx.gpa, "rlm: llm_query failed: {s}", .{@errorName(err)}) catch &.{},
            .is_error = true,
        };
    };
    defer ctx.gpa.free(raw);
    return extract(ctx.gpa, ctx.provider.kind, raw);
}

pub fn buildBody(gpa: Allocator, provider: Provider, prompt: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(provider.model);
    switch (provider.kind) {
        .openai => {
            try s.objectField("max_tokens");
            try s.write(max_out_tokens);
            try s.objectField("messages");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("role");
            try s.write("user");
            try s.objectField("content");
            try s.write(prompt);
            try s.endObject();
            try s.endArray();
        },
        .responses => if (std.mem.eql(u8, provider.id, "chatgpt-new")) {
            // The ChatGPT plan route takes only stored-nothing streamed
            // requests with an input array, and no output cap (ADR 0221).
            try s.objectField("input");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("role");
            try s.write("user");
            try s.objectField("content");
            try s.write(prompt);
            try s.endObject();
            try s.endArray();
            try s.objectField("reasoning");
            try s.beginObject();
            try s.objectField("effort");
            try s.write("low");
            try s.endObject();
            try s.objectField("store");
            try s.write(false);
            try s.objectField("stream");
            try s.write(true);
        } else {
            try s.objectField("max_output_tokens");
            try s.write(max_out_tokens);
            try s.objectField("input");
            try s.write(prompt);
        },
        // Interactions takes a bare string as `input` like Responses, but caps
        // output under generation_config and keeps nothing when store is false.
        .interactions => {
            try s.objectField("store");
            try s.write(false);
            try s.objectField("generation_config");
            try s.beginObject();
            try s.objectField("max_output_tokens");
            try s.write(max_out_tokens);
            try s.endObject();
            try s.objectField("input");
            try s.write(prompt);
        },
        .anthropic => {
            const oauth = @import("anthropic_oauth_wire.zig");
            if (oauth.active(provider)) {
                try s.objectField("system");
                try s.beginArray();
                try oauth.writeSystemPrefix(&s);
                try s.endArray();
            }
            // ADR 0219: a Claude model that thinks by default spends max_tokens
            // on thinking first; 256 left no answer. Room, and little thinking.
            const claude = @import("claude_wire.zig");
            const thinks = claude.isClaudeApi(provider.id, provider.model) and claude.thinksByDefault(provider.model);
            try s.objectField("max_tokens");
            try s.write(if (thinks) @as(u32, 4096) else max_out_tokens);
            if (thinks and claude.takesEffort(provider.model)) {
                try s.objectField("output_config");
                try s.print("{{\"effort\":\"low\"}}", .{});
            }
            try s.objectField("messages");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("role");
            try s.write("user");
            try s.objectField("content");
            try s.write(prompt);
            try s.endObject();
            try s.endArray();
        },
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

/// The `response.output_text.delta` text of a streamed body, or null when
/// `raw` is a plain JSON response.
fn sseText(gpa: Allocator, raw: []const u8) ?[]u8 {
    const head = std.mem.trimStart(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, head, "event:") and !std.mem.startsWith(u8, head, "data:")) return null;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const data = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, data, "data:")) continue;
        var parsed = std.json.parseFromSlice(Value, gpa, std.mem.trim(u8, data["data:".len..], " "), .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const kind = tools.strField(parsed.value, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "response.output_text.delta")) continue;
        out.appendSlice(gpa, tools.strField(parsed.value, "delta") orelse continue) catch {};
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn extract(gpa: Allocator, kind: Provider.Kind, raw: []const u8) ToolOutput {
    if (sseText(gpa, raw)) |streamed| {
        defer gpa.free(streamed);
        const text = std.mem.trim(u8, streamed, " \t\r\n");
        if (text.len == 0) return .{ .text = gpa.dupe(u8, "rlm: llm_query returned no text") catch &.{}, .is_error = true };
        return .{ .text = gpa.dupe(u8, text) catch &.{} };
    }
    var parsed = std.json.parseFromSlice(Value, gpa, raw, .{}) catch {
        return .{ .text = gpa.dupe(u8, "rlm: llm_query returned non-JSON") catch &.{}, .is_error = true };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .text = gpa.dupe(u8, "rlm: llm_query returned a non-object") catch &.{}, .is_error = true };
    }
    const text = std.mem.trim(u8, title.assistantText(kind, parsed.value.object), " \t\r\n");
    if (text.len == 0) {
        return .{ .text = gpa.dupe(u8, "rlm: llm_query returned no text") catch &.{}, .is_error = true };
    }
    return .{ .text = gpa.dupe(u8, text) catch &.{} };
}

fn sampleProvider(kind: Provider.Kind) Provider {
    return .{
        .id = "xai",
        .kind = kind,
        .auth = .bearer,
        .url = "http://127.0.0.1/v1",
        .api_key = "test",
        .model = "grok-4.6",
        .context = 128_000,
    };
}

test "llm_query body is tools-off and carries the prompt on every wire" {
    const gpa = std.testing.allocator;
    const prompt = "sum the first line of each chunk";
    for ([_]Provider.Kind{ .openai, .responses, .anthropic }) |kind| {
        const body = try buildBody(gpa, sampleProvider(kind), prompt);
        defer gpa.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, prompt) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "grok-4.6") != null);
    }
}

test "llm_query on the ChatGPT plan route streams, stores nothing and reads SSE text" {
    const gpa = std.testing.allocator;
    var p = sampleProvider(.responses);
    p.id = "chatgpt-new";
    p.model = "gpt-6.1-sol";
    const body = try buildBody(gpa, p, "hi");
    defer gpa.free(body);
    for ([_][]const u8{ "\"stream\":true", "\"store\":false", "\"role\":\"user\"" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, body, part) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") == null);
    const sse = "event: response.created\ndata: {\"type\":\"response.created\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"4\"}\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"2\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n";
    const out = extract(gpa, .responses, sse);
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("42", out.text);
}

test "llm_query extract reads assistant text from each wire shape" {
    const gpa = std.testing.allocator;
    const openai = "{\"choices\":[{\"message\":{\"content\":\"42\"}}]}";
    const out_oa = extract(gpa, .openai, openai);
    defer gpa.free(out_oa.text);
    try std.testing.expect(!out_oa.is_error);
    try std.testing.expectEqualStrings("42", out_oa.text);

    const resp = "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}";
    const out_r = extract(gpa, .responses, resp);
    defer gpa.free(out_r.text);
    try std.testing.expect(!out_r.is_error);
    try std.testing.expectEqualStrings("ok", out_r.text);
}

test "llm_query cannot bypass exhausted aggregate model budget" {
    const a = std.testing.allocator;
    var client: std.http.Client = .{ .allocator = a, .io = std.testing.io };
    defer client.deinit();
    var budget: @import("run_budget.zig").RunBudget = .{ .max_model_calls = 1 };
    var first = try budget.acquire(std.testing.io, 0, .root);
    first.release();
    const out = run(.{ .gpa = a, .io = std.testing.io, .client = &client, .provider = undefined, .registry = null, .from_sub = true, .approvals = null, .tracer = null, .run_budget = &budget }, "{\"prompt\":\"never contact a provider\"}");
    defer a.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "RunBudgetExhausted") != null);
    try std.testing.expectEqual(@as(u64, 1), budget.used());
}

test "llm_query gives a thinking Claude model room to answer, at low effort (ADR 0219)" {
    const gpa = std.testing.allocator;
    var p = sampleProvider(.anthropic);
    p.id = "anthropic";
    p.model = "claude-opus-5-5";
    const body = try buildBody(gpa, p, "one word");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"low\"}") != null);
    p.model = "claude-haiku-4-5"; // no default thinking: the small budget stands
    const small = try buildBody(gpa, p, "one word");
    defer gpa.free(small);
    try std.testing.expect(std.mem.indexOf(u8, small, "\"max_tokens\":256") != null);
    try std.testing.expect(std.mem.indexOf(u8, small, "output_config") == null);
}
