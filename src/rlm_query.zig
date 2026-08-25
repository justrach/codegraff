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
        .responses => {
            try s.objectField("max_output_tokens");
            try s.write(max_out_tokens);
            try s.objectField("input");
            try s.write(prompt);
        },
        .anthropic => {
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
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

fn extract(gpa: Allocator, kind: Provider.Kind, raw: []const u8) ToolOutput {
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
