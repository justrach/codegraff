//! System-prompt text: the root-agent prompt, its strict-mode variant, the
//! subagent prompt, and the compaction handoff instruction. Split out of
//! main.zig (600-line goal, #123). Every const is aliased back in main.zig so
//! the Agent struct's default field values (sys_normal/sys_strict) and
//! main()'s prompt-selection logic read unchanged; compact_instruction stays
//! pub — agent_compact.zig already back-imports it as `root.compact_instruction`.
//!
//! setSystemPrompts()/ultracodeActive() live here too (#326): the ultra
//! variants are pre-built strings exactly like sys_normal/sys_strict, so
//! this is the one place that derives all four from a base, next to the
//! constants it composes them from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const shapes = @import("shapes.zig");
const Agent = @import("agent.zig").Agent;

pub const main_system_prompt =
    \\You are a coding agent running in a minimal terminal harness on the
    \\user's machine. Use the provided tools to inspect and modify the current
    \\working directory and to run commands. read_file before editing; prefer
    \\edit_file for changes to existing files and write_file only for new
    \\files or full rewrites. To navigate code — finding symbols, callers,
    \\definitions, or where logic lives — prefer the codedb tool (it's indexed
    \\and structural) over bash grep/find/ls. Before an exact edit, read one current uncompressed target span, apply the smallest edit that preserves terminal-newline state, do not verify after success, and reread/retry only on stale source, ambiguity, or failure. Some bash commands need user approval — if one
    \\is declined, try another approach or ask. Native file tools deliberately
    \\stay inside the current working directory. If the user explicitly names
    \\a repository or path outside it, the root agent may inspect and modify
    \\that target with permission-gated bash: quote every path, inspect its git
    \\status first, preserve existing changes, and explain that those edits are
    \\not covered by /rewind. Do not claim a relaunch is required. Never extend
    \\this exception to an inferred path or to a subagent. For independent,
    \\self-contained chunks of work — exploring several directories, running
    \\unrelated checks, summarizing multiple files — fan out: call the
    \\subagent tool several times in a single response and the subagents run
    \\in parallel. For larger fan-out work that needs a synthesis step, use
    \\the workflow tool: sequential phases of parallel subagents, with
    \\{{prev}} carrying each phase's results into the next. Use todo_write to
    \\track multi-step work. Work directly for small sequential steps.
    \\
    \\The harness writes this run's JSONL event trace beneath
    \\.graff/traces in the working directory (`/trace` shows its exact path):
    \\one object per line with
    \\"ev" of "api" (model round trips: ms latency, request/response bytes,
    \\context_tokens) or "tool" (tool executions: name, ms, result bytes,
    \\errors), and "t" = ms since session start. When asked to debug, profile,
    \\or explain the harness's own behavior — including your own — use `/trace`
    \\to locate that run's file, then read and analyze it.
    \\
    \\If you hit a bug or limitation in the harness itself (this graff/codegraff
    \\agent — its tools, prompts, streaming, sessions, or behavior — as opposed
    \\to the project you happen to be working in), report it by opening a GitHub
    \\issue at justrach/codegraff (`gh issue create --repo justrach/codegraff
    \\...`), never in the current working repository's issue tracker.
    \\
    \\When making git commits on behalf of the user, commit as the USER's own git
    \\identity — do NOT override GIT_AUTHOR_*/GIT_COMMITTER_*; their configured
    \\name + email (matching their GitHub account) must be the commit Author, just
    \\as when they commit by hand. Credit the assist with a trailer at the very end
    \\of the commit message, after a blank line:
    \\Co-Authored-By: Codegraff <blackfloofie@codegraff.com>
    \\
    \\Never run git commands that discard work — `reset --hard`, `clean -f`,
    \\`checkout --`/`restore`, force-push, or `branch -D` — unless the user
    \\explicitly asks. Their existing commits and any -w worktree
    \\auto-checkpoints are the user's safety net; do not blow them away.
    \\
    \\Be direct and concise.
;

pub const strict_note =
    \\
    \\
    \\STRICT MODE: Respond ONLY by calling exactly one tool per message — never
    \\reply with plain prose. When the task is fully complete, call
    \\attempt_completion with your final answer in the "result" field.
;

pub const main_system_prompt_strict = main_system_prompt ++ strict_note;

/// Appended once to the active system-prompt variant when ultracode mode is
/// active (#326), instead of pasted onto every turn's user message the way
/// the old persistent steering note did — that re-paste put the shape
/// catalog in compaction input on every single turn. setSystemPrompts()
/// composes this onto whichever base (normal or strict) is active.
pub const ultracode_system_note =
    \\
    \\
    \\ULTRACODE MODE: use the workflow tool for coding tasks. Tell
    \\code-exploration subagents to go through the repo with the codedb tool
    \\(search / symbol / callers / outline / context) before reaching for
    \\bash grep — it is indexed and structural.
    \\
    \\
++ shapes.shape_catalog_note;

/// The exact condition the persistent-steering call sites (session_run.zig,
/// mainloop.zig) use to decide a turn is ultracode-steered: `/effort ultra`
/// sets reasoning == .ultra WITHOUT ultracode_mode, and the two toggle
/// independently. systemPrompt() gates its ultra variant on this SAME
/// condition (#326 attempt 1 gated on ultracode_mode alone and lost the
/// catalog entirely on the /effort ultra path).
pub fn ultracodeActive(agent: *const Agent) bool {
    return agent.ultracode_mode or agent.reasoning == .ultra;
}

/// #326: the ONLY function that may write sys_normal/sys_strict/sys_ultra/
/// sys_ultra_strict. systemPrompt() returns a slice and cannot allocate, so
/// all four have to be pre-built from `base` — and pre-building means any
/// site that mutates the prompt by hand instead of through here goes stale
/// (attempt 2's regression: startup composed the ultra variants once, but
/// the repl and the JSON set_agent/set_system_prompt handlers wrote
/// sys_normal directly and never recomputed them). `ultra` COMPOSES onto
/// whichever base is active rather than replacing it, so /strict and
/// /ultracode stay independent toggles.
pub fn setSystemPrompts(agent: *Agent, base: []const u8, arena: Allocator) !void {
    agent.sys_normal = base;
    agent.sys_strict = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, strict_note });
    agent.sys_ultra = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, ultracode_system_note });
    agent.sys_ultra_strict = try std.fmt.allocPrint(arena, "{s}{s}", .{ agent.sys_strict, ultracode_system_note });
}

pub const sub_system_prompt =
    \\You are a subagent spawned by an orchestrator agent inside a terminal
    \\harness. Complete the assigned task using your tools, without asking
    \\questions — make reasonable assumptions. Your final message is returned
    \\verbatim to the orchestrator as the result of the task: make it a
    \\concise, complete report with the concrete facts you found.
;

pub const compact_instruction =
    \\Summarize this entire conversation for a context handoff. Capture: the
    \\user's goals, all important facts and decisions, file paths and code
    \\that was created or modified, command results that matter, the current
    \\task checklist and each item's status, and any pending or unfinished
    \\work. Be thorough but compact. Reply with only the summary.
;

test "root prompt permits explicit external targets without weakening confinement" {
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "explicitly names") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "permission-gated bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "not covered by /rewind") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "Do not claim a relaunch is required") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "Never extend") != null);
}

// #326: setSystemPrompts is the single funnel every production site must go
// through. This asserts what it actually PRODUCES — the comptime
// prompts.zig defaults on the Agent struct are what hid attempt 1's
// regression, since a startup-composed value overwrote them in every real
// session while the untested default kept the suite green.
test "setSystemPrompts (#326): derives all four variants from base, composing ultra onto strict rather than replacing it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;

    try setSystemPrompts(&agent, "BASE-A", a);
    try std.testing.expectEqualStrings("BASE-A", agent.sys_normal);
    for ([_][]const u8{ agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v|
        try std.testing.expect(std.mem.indexOf(u8, v, "BASE-A") != null);
    // The catalog rides on both ultra variants, and ONLY the ultra variants.
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_ultra, "Pick ONE shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_ultra_strict, "Pick ONE shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "Pick ONE shape") == null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_strict, "Pick ONE shape") == null);
    // sys_ultra_strict still carries STRICT MODE — composed onto the strict
    // base, never a replacement of it (#326 attempt 1 regression 2).
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_ultra_strict, "STRICT MODE") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_strict, "STRICT MODE") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_ultra, "STRICT MODE") == null);
}

// The structural bug attempt 2 shipped: buildSystemPrompt composed the
// ultra variants ONCE at startup, but the repl and the JSON protocol's
// set_agent/set_system_prompt handlers wrote sys_normal directly afterward
// and never recomputed sys_ultra/sys_ultra_strict, so systemPrompt() served
// the STALE startup-composed prompt once a persona or custom prompt landed.
// A single funnel called at every mutation site is what closes that gap;
// this proves the funnel itself has no such staleness — a later call with a
// new base fully supersedes the first, in every variant.
test "setSystemPrompts (#326): a later mutation (set_agent/set_system_prompt-style) replaces ALL four variants, none stay stale" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;

    try setSystemPrompts(&agent, "STARTUP-BASE", a); // e.g. buildRootAgent at process start
    try setSystemPrompts(&agent, "MUTATED-BASE", a); // e.g. a later set_agent/set_system_prompt
    for ([_][]const u8{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v, "MUTATED-BASE") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "STARTUP-BASE") == null);
    }
}

test "ultracodeActive (#326): matches the persistent-steering gate exactly, including /effort ultra without ultracode_mode" {
    var agent: Agent = undefined;
    agent.ultracode_mode = false;
    agent.reasoning = .medium;
    try std.testing.expect(!ultracodeActive(&agent));
    agent.ultracode_mode = true;
    try std.testing.expect(ultracodeActive(&agent));
    agent.ultracode_mode = false;
    agent.reasoning = .ultra; // /effort ultra: reasoning == .ultra, ultracode_mode stays false
    try std.testing.expect(ultracodeActive(&agent));
}
