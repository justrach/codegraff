//! Astra-specific behavioral guidance, selected at request time so model
//! switches cannot leave it on another model's prompt. API features belong
//! in the wire layer, not in instructions claiming tools we do not expose.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const prompts = @import("prompts.zig");

const guidance =
    \\
    \\# Astra working guidance
    \\Infer the user's intent and scope from the request and conversation. Treat
    \\"can you", "I want to", and "help me" as requests to act. Carry authorized
    \\work through to completion rather than stopping at a plan or acknowledgment.
    \\Fill routine gaps with reasonable assumptions. Ask a focused question only
    \\when the answer materially changes the outcome or a real ambiguity blocks
    \\progress; first complete independent, authorized work that makes the choice
    \\concrete and reviewable. Respect task boundaries, tool approval gates, and
    \\destructive-action restrictions. Do not invent additional approval flows,
    \\warnings, or checklists for hypothetical risks.
    \\
    \\Explicit user instructions take precedence over skill guidelines, subject
    \\to system and developer instructions. If a skill makes you ask permission,
    \\leave requested work unfinished, or change direction, name and link the
    \\exact SKILL.md, quote the relevant instruction, and explain how it applies.
    \\Distinguish the skill's actual requirement from your interpretation.
    \\
    \\Write clear, concise paragraphs with the main point early, familiar words,
    \\and active verbs. Use lists when they make steps or comparisons easier to
    \\read; avoid unnecessary nesting. Calibrate technical detail to the reader.
    \\Avoid stock transitions, invented compound labels, vague qualifiers, and
    \\unprompted contrastive framing. Avoid phrases such as "Bottom Line",
    \\"delve", "foster", "leverage", "it's worth noting", and "In short".
    \\Keep inter-agent messages and final answers legible, with proper spacing.
    \\
    \\Match testing to the change. Do not write implementation-mirroring tests
    \\for reversible, low-impact edits. Run meaningful verification and required
    \\project checks; after they pass, broaden or repeat testing only for new
    \\changes, failures, or unresolved concerns. Then finish the requested work.
;

const delegation =
    \\
    \\Delegate independent work when it saves time or improves quality, using
    \\the available collaboration tools. Keep the critical-path next step local.
    \\Respect this harness's delegation depth and tool limits; do not ask a
    \\subagent to spawn agents when that capability is unavailable.
;

pub fn append(self: *Agent, base: []const u8) ![]const u8 {
    const model = self.provider.model;
    const bare = model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| i + 1 else 0..];
    if (!std.mem.eql(u8, bare, "gpt-6-astra") and !std.mem.startsWith(u8, bare, "gpt-6-astra-")) return base;
    const fanout = !self.sub and prompts.detectCaps().subagents;
    return std.mem.concat(self.scratchAlloc(), u8, &.{ base, "\n", guidance, if (fanout) delegation else "" });
}

test "Astra guidance follows model switches, child limits and output schemas" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-astra", .context = 270_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "BASE",
    };
    const compose = @import("agent_request_body_responses.zig").schemaAwarePrompt;
    for ([_][]const u8{ "gpt-6-astra", "openai/gpt-6-astra", "gpt-6-astra-2026-09-03" }) |model| {
        agent.provider.model = model;
        const result = try compose(&agent);
        try std.testing.expect(std.mem.startsWith(u8, result, "BASE\n"));
        try std.testing.expect(std.mem.indexOf(u8, result, "# Astra working guidance") != null);
        try std.testing.expectEqual(prompts.detectCaps().subagents, std.mem.indexOf(u8, result, "Delegate independent work") != null);
    }
    agent.sub = true;
    agent.output_schema = "{\"type\":\"object\"}";
    const child = try compose(&agent);
    try std.testing.expect(std.mem.indexOf(u8, child, "# Astra working guidance") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "Delegate independent work") == null);
    try std.testing.expect(std.mem.indexOf(u8, child, "A JSON output schema is enforced") != null);
    agent.output_schema = null;
    agent.sub = false;
    for ([_][]const u8{ "gpt-5.6", "gemini-3.7-flash", "gpt-6-astraish" }) |model| {
        agent.provider.model = model;
        try std.testing.expectEqualStrings("BASE", try compose(&agent));
    }
}
