//! Tests of the prompt TEXT itself: what the root and subagent prompts must
//! say, and that the variants sliced from one string are the concatenations
//! they replace. Split out of prompts.zig (600-line ceiling).

const std = @import("std");
const prompts = @import("prompts.zig");

test "prompt variants sliced from one string equal their concatenations" {
    try std.testing.expectEqualStrings(prompts.main_system_prompt ++ prompts.strict_note, prompts.main_system_prompt_strict);
    try std.testing.expectEqualStrings(prompts.main_system_prompt_strict ++ prompts.ultracode_system_note, prompts.main_system_prompt_ultra_strict);
    const joined = comptime blk: {
        var out: []const u8 = "";
        for (prompts.segments) |seg| out = out ++ seg.text;
        break :blk out;
    };
    try std.testing.expectEqualStrings(prompts.main_system_prompt, joined);
    for (prompts.segments, prompts.segment_table) |shared, own| try std.testing.expectEqualStrings(own.text, shared.text);
}

// The harness has always run a returned tool batch concurrently, for subagents
// exactly as for the root (agent_tools.zig dispatches every external call as a
// future before awaiting any). Nothing ASKED for a batch, though, so the
// capability rode entirely on the model's own initiative - openai/codex spells
// it out in its base instructions and graff did not. Pin it on BOTH prompts:
// the subagent one is the easier of the two to forget, since it is five lines
// long and does not share a base with the root.
test "both prompts ask for parallel tool calls, with the dependency caveat" {
    for ([_][]const u8{ prompts.main_system_prompt, prompts.sub_system_prompt, prompts.main_system_prompt_strict }) |p| {
        try std.testing.expect(std.mem.indexOf(u8, p, "Parallelize tool calls") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "ONE response") != null);
        // Without the caveat this instruction is actively harmful: graff runs
        // the whole batch concurrently, so two writes to one file would race.
        try std.testing.expect(std.mem.indexOf(u8, p, "same file") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "depends on an earlier") != null);
    }
    // Composing must not have cost either prompt its own identity.
    try std.testing.expect(std.mem.indexOf(u8, prompts.sub_system_prompt, "subagent spawned by an orchestrator") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.sub_system_prompt, "do not broaden") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.sub_system_prompt, "Do not narrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.sub_system_prompt, "rlm(code)") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "Be direct and concise") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt_strict, "STRICT MODE") != null);
}

// #351: agent-authored PRs described only the diff, which a reviewer can already
// read. The rationale — the failure mode, why this design, what it trades off —
// exists only in the agent's head at authoring time and is unrecoverable later,
// so the prompt has to demand it. The proportionality clause is load-bearing in
// the other direction: without it a one-line typo fix grows four empty headings.
test "root prompt (#351) requires what+why rationale in PR descriptions, scaled to the change" {
    for ([_][]const u8{ "## What changed", "## Why", "Problem/failure mode", "Reason for this approach", "Constraints or trade-offs", "Rejected alternatives" }) |section|
        try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, section) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "Scale the rationale to the change") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "never pad a small change with boilerplate") != null);
}

test "root prompt permits explicit external targets without weakening confinement" {
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "explicitly names") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "permission-gated bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "not covered by /rewind") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "Do not claim a relaunch is required") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "Never extend") != null);
}
