//! Per-model working guidance, composed at request time (schemaAwarePrompt)
//! so a model switch cannot leave another model's note on the prompt. API
//! features stay in the wire layer; this is only behavior the model must own.
//!
//! GPT-5.6 (sol / terra / luna, the bare `gpt-5.6` alias, gateway `openai/`
//! names): the note follows OpenAI's GPT-5.6 prompting guide. The model is
//! proactive across multi-step work and more concise by default than 5.5, so
//! the note states the autonomy/approval boundary ONCE, names the safe local
//! actions, and adds no brevity rule — repeating "ask first" makes it over-ask,
//! and stacked "be concise" lines cut detail the user wanted. Length control
//! belongs to `text.verbosity`, not to more prose here.
const std = @import("std");
const Agent = @import("agent.zig").Agent;

const gpt56 =
    \\
    \\# GPT-5.6 working guidance
    \\For requests to answer, explain, review, diagnose, or plan: inspect the
    \\relevant material and report; do not implement changes unless the request
    \\also asks for them. For requests to change, build, or fix: make the in-scope
    \\local changes and run relevant non-destructive validation without asking.
    \\Reading files, inspecting logs, editing in-scope code, and running tests are
    \\safe local actions. Confirm before external writes, destructive actions, or a
    \\material expansion of scope; the harness's tool approval gates are the only
    \\approval flow — do not invent additional ones.
    \\Before the first tool call of a multi-step task, state the first step in one
    \\or two sentences; afterwards update only when a phase begins or a finding
    \\changes the plan. Finish with the most relevant validation available
    \\(targeted tests, lint or type checks, a build); if it cannot run, say why and
    \\name the next best check.
;

/// Bare model name, without a gateway vendor prefix (`openai/gpt-5.6-luna`).
fn bareName(model: []const u8) []const u8 {
    return model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| i + 1 else 0..];
}

pub fn isGpt56(model: []const u8) bool {
    const bare = bareName(model);
    return std.mem.eql(u8, bare, "gpt-5.6") or std.mem.startsWith(u8, bare, "gpt-5.6-");
}

/// Compose `base` plus the note for the agent's current model, if it has one.
pub fn append(self: *Agent, base: []const u8) ![]const u8 {
    if (isGpt56(self.provider.model)) return std.mem.concat(self.scratchAlloc(), u8, &.{ base, "\n", gpt56 });
    return @import("prompt_astra.zig").append(self, base);
}

test {
    _ = @import("prompt_astra.zig");
}

test "GPT-5.6 guidance follows the model on every Responses route, and only that family" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5.6", .context = 1_050_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "BASE",
    };
    const compose = @import("agent_request_body_responses.zig").schemaAwarePrompt;
    const routes = [_]struct { id: []const u8, model: []const u8 }{
        .{ .id = "openai", .model = "gpt-5.6" },
        .{ .id = "openai", .model = "gpt-5.6-terra" },
        .{ .id = "openai", .model = "gpt-5.6-luna" },
        .{ .id = "codex", .model = "gpt-5.6-sol" },
        .{ .id = "codegraff", .model = "openai/gpt-5.6-sol" },
    };
    for (routes) |r| {
        agent.provider.id = r.id;
        agent.provider.model = r.model;
        const result = try compose(&agent);
        try std.testing.expect(std.mem.startsWith(u8, result, "BASE\n"));
        try std.testing.expect(std.mem.indexOf(u8, result, "# GPT-5.6 working guidance") != null);
        // Stated once: the approval boundary appears a single time, and no
        // brevity instruction rides along (the model is already concise).
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "Confirm before"));
        try std.testing.expect(std.mem.indexOf(u8, result, "concise") == null);
        try std.testing.expect(std.mem.indexOf(u8, result, "# Astra working guidance") == null);
    }
    // The schema line still lands after the note.
    agent.output_schema = "{\"type\":\"object\"}";
    const schema = try compose(&agent);
    try std.testing.expect(std.mem.indexOf(u8, schema, "# GPT-5.6 working guidance") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "A JSON output schema is enforced") != null);
    agent.output_schema = null;
    // Not the family: GPT-5.5, GPT-6 Astra (its own note), other vendors.
    for ([_][]const u8{ "gpt-5.5", "gpt-5.4-mini", "grok-4.6", "claude-sonnet-5", "gpt-6-astra" }) |model| {
        agent.provider.id = "openai";
        agent.provider.model = model;
        const result = try compose(&agent);
        try std.testing.expect(std.mem.indexOf(u8, result, "# GPT-5.6 working guidance") == null);
    }
    try std.testing.expect(isGpt56("openai/gpt-5.6-luna"));
    try std.testing.expect(!isGpt56("gpt-5.65"));
}
