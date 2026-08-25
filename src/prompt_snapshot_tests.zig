//! #421 + #410: prompt-snapshot tests. The root system prompt is now assembled
//! from capability-scoped segments (prompts.zig), which makes two things
//! testable that never were:
//!
//!   1. an absent capability contributes ZERO instruction text — not "less"
//!      text, none, asserted by exact length AND by the dropped segment's own
//!      bytes being unfindable in the result;
//!   2. the full-capability prompt is pinned to an inline golden below, so the
//!      next person who changes the wording has to change this file too. Prompt
//!      drift becomes a conscious choice instead of a diff nobody reviewed.
//!
//! The golden is the WHOLE prompt on purpose. A hash would catch drift just as
//! well and teach a reviewer nothing; this way the diff of a prompt change is
//! readable in review, right next to the assertion that it was intended.

const std = @import("std");
const prompts = @import("prompts.zig");
const skills = @import("skills.zig");
const skill_docs = @import("skill_docs.zig");
const imagegen = @import("imagegen.zig");
const tool_gates = @import("tool_gates.zig");
const no_local_tools = @import("no_local_tools.zig");
const repl_glue = @import("repl_glue.zig");
const session_index = @import("session_index.zig");
const agent_mod = @import("agent.zig");

/// The FULL-capability root prompt, verbatim. Regenerate by reading
/// `prompts.main_system_prompt`; never "fix" this to make a test pass without
/// looking at what changed.
const golden_full_prompt =
    \\You are a coding agent running in a minimal terminal harness on the
    \\user's machine. Use the provided tools to inspect and modify the current
    \\working directory and to run commands.
    \\Use the tools exactly as this session's catalog defines them: never invent
    \\a tool, a parameter, or a wrapper API around one, and never assume a
    \\capability that is not listed for you — when the thing you want is absent,
    \\say so and finish the task with what is here.
    \\Inspect before you commit to an architecture: say what you found, then
    \\what you will do, then do it. Do not announce a solution and hunt for
    \\confirmation of it.
    \\read_file before editing; prefer
    \\edit_file for changes to existing files and write_file only for new
    \\files or full rewrites. For a read-only exact-key lookup in one known file,
    \\call read_file once with contains set to the exact key and answer from its
    \\output; do not request the whole file first. To navigate code — finding symbols,
    \\definitions, or where logic lives — prefer the codedb tool (it's indexed
    \\and structural) over bash grep/find/ls. The codedb commands are context <task>, around <name>, callpath A B, list_dir <path>, and status — one call, not a chain. List a folder with codedb list_dir <path> (in-process; no index required). Before an exact edit, read one current uncompressed target span, apply the smallest edit that preserves terminal-newline state, do not verify after success, and reread/retry only on stale source, ambiguity, or failure. Some bash commands need user approval — if one
    \\is declined, try another approach or ask. Native file tools deliberately
    \\stay inside the current working directory. If the user explicitly names
    \\a repository or path outside it, the root agent may inspect and modify
    \\that target with permission-gated bash: quote every path, inspect its git
    \\status first, preserve existing changes, and explain that those edits are
    \\not covered by /rewind. Do not claim a relaunch is required. Never extend
    \\this exception to an inferred path or to a subagent.
    \\For independent,
    \\self-contained chunks of work — exploring several directories, running
    \\unrelated checks, summarizing multiple files — fan out: call the
    \\subagent tool several times in a single response and the subagents run
    \\in parallel. For larger fan-out work that needs a synthesis step, use
    \\the workflow tool: sequential phases of parallel subagents, with
    \\{{prev}} carrying each phase's results into the next.
    \\Use todo_write to
    \\track multi-step work. Work directly for small sequential steps.
    \\
    \\The harness writes this run's JSONL event trace beneath .graff/traces
    \\(`/trace` shows its exact path): one object per line, "ev" of "api" (ms
    \\latency, request/response bytes, context_tokens) or "tool" (name, ms,
    \\result bytes, errors), "t" = ms since session start. When asked to debug,
    \\profile, or explain the harness's own behavior, `/trace` and analyze it.
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
    \\A pull request description you author must explain WHY, not only what —
    \\a reviewer cannot reconstruct the reasoning from the diff. Under
    \\## What changed / ## Why, cover: Problem/failure mode;
    \\Reason for this approach; Constraints or trade-offs;
    \\Rejected alternatives when relevant.
    \\Scale the rationale to the change: a subtle change earns the full
    \\sections, a trivial one (typo, version bump) a single sentence —
    \\never pad a small change with boilerplate headings. Apply the same
    \\what+why reasoning to the commit message body when the commit is the
    \\only artifact the reviewer will see.
    \\
    \\Never run git commands that discard work — `reset --hard`, `clean -f`,
    \\`checkout --`/`restore`, force-push, or `branch -D` — unless the user
    \\explicitly asks. Their existing commits and any -w worktree
    \\auto-checkpoints are the user's safety net; do not blow them away.
    \\
    \\Assume the user wants the work done, not described. Keep going until the
    \\task is genuinely handled: the change applied, verified with the
    \\project's own build, test, or lint commands in its OWN environment —
    \\a green run anywhere else is not evidence — and the failure you were
    \\chasing gone. Never stop at a plan, a half-applied edit, or an untested
    \\guess, and never leave the last step for the user. If a real ambiguity
    \\blocks you, ask; otherwise decide and go. When a task names files or
    \\failing tests, use the named target directly instead of probing unrelated
    \\indexes first; that dice roll makes every run of the same task different.
    \\Match the verification to the
    \\ask: make the requested thing work and prove it — do not add unrequested
    \\tests, coverage, or review passes; thoroughness past the ask is turns,
    \\tokens, and diff noise the user did not order. And never repeat a tool
    \\call with identical parameters once you have a usable result — the answer
    \\will not change; reread only on stale source, ambiguity, or failure.
    \\When a Project layout segment is present, it is the tree — read the
    \\files you need straight from it instead of ls/find exploration turns.
    \\When a named SPEC.md (or equivalent contract) is in the task, satisfy
    \\every clause — a green public test is not the whole spec. Empty input
    \\includes whitespace-only: yield nothing, do not raise. A required
    \\record delimiter applies to records that exist; a payload with no
    \\records is empty, not malformed.
    \\
    \\Before a large chunk of work, give a one- or two-sentence heads-up on what
    \\you are about to do; on long tasks, drop a brief note as each phase lands.
    \\With todo_write, mark an item in_progress when you start it and completed
    \\as it lands, not in a batch at the end.
    \\
    \\Fix root causes, not symptoms — a patch that only hides a failure is not a
    \\fix. Match the surrounding file's style and keep diffs minimal: no drive-by
    \\refactors, renames, or reformatting the task did not require.
    \\
    \\The moment the user rejects, forbids, or vetoes something ("no dots", "not vanilla JS", "stop adding scroll hints"), call note_constraint with one short imperative line recording it, then carry on — recorded constraints are injected into every later subagent, workflow and pipeline brief and survive compaction, so a rejection you leave unrecorded is one your fresh workers will repeat.
    \\
    \\Write the final message as an update to a teammate who has not seen your
    \\screen. Cite evidence as `path:line` — never dump large file contents into
    \\an answer — and backtick-wrap commands, paths, and identifiers. Scale it
    \\to the change: a typo fix is one sentence, a feature a short structured
    \\summary. Close with the next steps that genuinely exist, and nothing more.
    \\Be direct and concise.
    \\
    \\Parallelize tool calls whenever possible: when several reads or checks are
    \\independent, issue them in ONE response instead of one per turn. Reads and
    \\searches are the common case (read_file, codedb, grep-style bash) and they
    \\run concurrently. Keep a call in its own turn when it depends on an earlier
    \\call's result, or when two calls would write to the same file.
;

/// Every capability configuration the gates can actually produce, plus the
/// all-off floor. `.{}` is full capability (the Caps defaults).
const matrix = [_]struct { name: []const u8, caps: prompts.Caps }{
    .{ .name = "full", .caps = .{} },
    .{ .name = "no-local-tools (#330 embedder)", .caps = .{ .local_tools = false } },
    .{ .name = "no-subagents", .caps = .{ .subagents = false } },
    .{ .name = "no-todos", .caps = .{ .todos = false } },
    .{ .name = "no-constraints", .caps = .{ .constraints = false } },
    .{ .name = "no-git-repo (scratch cwd)", .caps = .{ .git_repo = false } },
    .{ .name = "floor", .caps = .{ .local_tools = false, .subagents = false, .todos = false, .constraints = false, .git_repo = false } },
};

test "#421 golden: the full-capability root prompt is exactly this, byte for byte" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    try std.testing.expectEqualStrings(golden_full_prompt, prompts.main_system_prompt);
    // The segment table composes to the same bytes the comptime constant does,
    // so a reordered or forgotten segment cannot hide behind the fast path.
    try std.testing.expectEqualStrings(golden_full_prompt, try prompts.composeSegments(a, .{}));
    // ...and the fast path really is a fast path: full capability allocates nothing.
    var b_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer b_state.deinit();
    try std.testing.expectEqualStrings(golden_full_prompt, try prompts.composeBase(b_state.allocator(), .{}));
    try std.testing.expectEqual(@as(usize, 0), b_state.queryCapacity());

    // The strict/ultra variants still compose ONTO this base rather than
    // replacing it (#326), which the segmentation must not have disturbed.
    try std.testing.expect(std.mem.startsWith(u8, prompts.main_system_prompt_strict, golden_full_prompt));
}

test "#421: an absent capability contributes ZERO instruction text, in every configuration" {
    for (matrix) |row| {
        var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a_state.deinit();
        const out = try prompts.composeSegments(a_state.allocator(), row.caps);

        var expected: usize = 0;
        for (prompts.segments) |seg| {
            if (row.caps.has(seg.gate)) expected += seg.text.len;
        }
        std.testing.expectEqual(expected, out.len) catch |err| {
            std.debug.print("config '{s}': composed {d} bytes, expected {d}\n", .{ row.name, out.len, expected });
            return err;
        };
        // Exact length is necessary but not sufficient: prove each dropped
        // segment's own bytes are unfindable, and each kept one is still there.
        for (prompts.segments) |seg| {
            const present = std.mem.indexOf(u8, out, seg.text) != null;
            std.testing.expectEqual(row.caps.has(seg.gate), present) catch |err| {
                std.debug.print("config '{s}': segment '{s}' present={} expected={}\n", .{ row.name, seg.name, present, row.caps.has(seg.gate) });
                return err;
            };
        }
    }
}

test "#421: a gated-off capability's tool names disappear from the prompt entirely" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    // #330 embedder mode: bash, read_file, edit_file, write_file and codedb are
    // hard-removed from every catalog, so no sentence may still name them.
    const embedder = try prompts.composeSegments(a, .{ .local_tools = false });
    // "Treat that path as the result" is #440's handle contract: a session with
    // no way to OPEN a path is never told to slice one.
    for ([_][]const u8{ "read_file", "edit_file", "write_file", "codedb", "bash grep", "/trace", "gh issue create", ".graff/traces", "Treat that path as the result" }) |dead|
        try std.testing.expect(std.mem.indexOf(u8, embedder, dead) == null);

    const no_subs = try prompts.composeSegments(a, .{ .subagents = false });
    for ([_][]const u8{ "subagent tool", "workflow tool", "{{prev}}" }) |dead|
        try std.testing.expect(std.mem.indexOf(u8, no_subs, dead) == null);

    const no_todos = try prompts.composeSegments(a, .{ .todos = false });
    try std.testing.expect(std.mem.indexOf(u8, no_todos, "todo_write") == null);

    const no_constraints = try prompts.composeSegments(a, .{ .constraints = false });
    try std.testing.expect(std.mem.indexOf(u8, no_constraints, "note_constraint") == null);

    // Outside a git repo, the AUTHORING guidance goes — commit identity and
    // PR discipline have nothing to act on — while the safety rail stays.
    const no_git = try prompts.composeSegments(a, .{ .git_repo = false });
    for ([_][]const u8{ "## What changed", "Co-Authored-By: Codegraff", "GIT_AUTHOR_" }) |dead|
        try std.testing.expect(std.mem.indexOf(u8, no_git, dead) == null);

    // What survives EVERY gate: identity, the two prompt-doctrine lines, the
    // do-not-discard-work rail, and the closing style.
    for (matrix) |row| {
        const out = try prompts.composeSegments(a, row.caps);
        for ([_][]const u8{
            "You are a coding agent",
            "never invent", // #421 doctrine 1: no wrapper APIs, no assumed capabilities
            "its OWN environment", // #421 doctrine 2: verify where the project lives
            "Never run git commands that discard work",
            "Parallelize tool calls",
            "Be direct and concise",
        }) |keep| {
            std.testing.expect(std.mem.indexOf(u8, out, keep) != null) catch |err| {
                std.debug.print("config '{s}' lost '{s}'\n", .{ row.name, keep });
                return err;
            };
        }
    }
}

test "#421: detectCaps reads the same gates dispatch refuses a call with" {
    const saved = no_local_tools.enabled;
    defer no_local_tools.enabled = saved;

    no_local_tools.enabled = false;
    try std.testing.expect(prompts.detectCaps().full());

    no_local_tools.enabled = true;
    const caps = prompts.detectCaps();
    try std.testing.expect(!caps.local_tools);
    // #330 keeps the orchestration and meta tools: the CHILD inherits the gate,
    // so the fan-out guidance is still guidance for a tool that exists.
    try std.testing.expect(caps.subagents);
    try std.testing.expect(caps.todos);
    try std.testing.expect(caps.constraints);

    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const gated = try prompts.baseForSession(a_state.allocator());
    try std.testing.expect(gated.len < prompts.main_system_prompt.len);
    try std.testing.expect(std.mem.indexOf(u8, gated, "read_file") == null);
}

test "#410: the transcript line appears exactly when a durable session exists" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    // No durable session (a subagent, a stub, a future --no-session): no line.
    try std.testing.expectEqualStrings("", prompts.sessionTranscriptNote(a, ""));

    const note = prompts.sessionTranscriptNote(a, "session-1750000000000");
    // The path is the one session_index actually writes, not a hand-written twin.
    try std.testing.expect(std.mem.indexOf(u8, note, try session_index.sessionPath(a, "session-1750000000000")) != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "lags") != null); // the caveat #410 asks for
    try std.testing.expect(std.mem.indexOf(u8, note, "JSON object") != null);
    // NOT JSONL: that is the .graff/traces event stream, a different file. A
    // wrong format claim costs the model a turn discovering it.
    try std.testing.expect(std.mem.indexOf(u8, note, "JSONL") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "durable transcript") == null); // session-scoped, never comptime
}

test "#410: the transcript line rides the funnel, so a persona swap cannot drop it" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    var agent: agent_mod.Agent = undefined;
    defer prompts.armSessionTranscript(a, "", .{}, false); // leave the global as the rest of the suite expects it

    // Armed as #445 arms it in production: after the first compaction.
    prompts.armSessionTranscript(a, "session-42", .{}, true);
    try prompts.setSystemPrompts(&agent, "BASE", a);
    for ([_][]const u8{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v, "BASE") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "session-42.session.json") != null);
    }
    // A later /agent persona or set_system_prompt goes through the same funnel
    // and keeps it — the #326 staleness class, closed by construction.
    try prompts.setSystemPrompts(&agent, "PERSONA", a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-42.session.json") != null);
    // sys_base stays the pure base: the next refresh composes from it, once.
    try std.testing.expectEqualStrings("PERSONA", agent.sys_base);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, agent.sys_normal, "session-42.session.json"));

    // Unreadable session file (#330 removed read_file/bash): no line at all,
    // compacted or not — the capability half of the gate is independent.
    prompts.armSessionTranscript(a, "session-42", .{ .local_tools = false }, true);
    try prompts.setSystemPrompts(&agent, "BASE", a);
    try std.testing.expectEqualStrings("BASE", agent.sys_normal);
}

// #445: the measured cost of the #421/#410 prompt additions was ~240 input
// tokens on EVERY call, and the transcript line's share of it buys nothing
// until the live window stops being a superset of the file it names. So the
// line is deferred to the first compaction, and this pins both ends of that:
// absent on a fresh session, present once the boundary has been crossed.
test "#445: the transcript line is absent until the first compaction, then rides every variant" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const saved = prompts.g_session_compacted;
    defer prompts.g_session_compacted = saved;
    defer prompts.armSessionTranscript(a, "", .{}, false); // leave the global as the rest of the suite expects it
    defer prompts.armCompactNotes(""); // #391's store is a process global: never leak an armed session into another test

    var agent: agent_mod.Agent = undefined;
    agent.sub = false;
    agent.session_name = "session-445";
    prompts.g_session_compacted = false;

    // A fresh session: setRootSystemPrompts arms with the flag as it stands,
    // so every variant is exactly the base and the session pays nothing.
    prompts.armSessionTranscript(a, agent.session_name, .{}, prompts.g_session_compacted);
    try prompts.setSystemPrompts(&agent, "BASE", a);
    try std.testing.expectEqualStrings("BASE", agent.sys_normal);
    for ([_][]const u8{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v|
        try std.testing.expect(std.mem.indexOf(u8, v, "session-445.session.json") == null);

    // The compaction boundary re-derives all four, in place, from sys_base.
    prompts.noteSessionCompacted(&agent, a);
    try std.testing.expect(prompts.g_session_compacted);
    for ([_][]const u8{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v, "BASE") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "session-445.session.json") != null);
    }
    try std.testing.expectEqualStrings("BASE", agent.sys_base); // still the pure base

    // Idempotent: a session that compacts ten times still carries ONE line.
    prompts.noteSessionCompacted(&agent, a);
    prompts.noteSessionCompacted(&agent, a);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, agent.sys_normal, "session-445.session.json"));
    // And a later persona swap keeps it — the #326 staleness class stays closed.
    try prompts.setSystemPrompts(&agent, "PERSONA", a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-445.session.json") != null);

    // A compacting SUBAGENT has no durable session of its own, and must not
    // spend the root's tokens on a line about a file it never wrote.
    prompts.g_session_compacted = false;
    prompts.armSessionTranscript(a, "", .{}, false);
    var child: agent_mod.Agent = undefined;
    child.sub = true;
    child.session_name = "session-child";
    child.sys_base = "CHILD-BASE";
    prompts.noteSessionCompacted(&child, a);
    try std.testing.expect(!prompts.g_session_compacted);
    try prompts.setSystemPrompts(&child, "CHILD-BASE", a);
    try std.testing.expectEqualStrings("CHILD-BASE", child.sys_normal);
}

// #445: one PROCESS can host several root conversations. /new mints a fresh
// session_name and /clear empties the history and saves over the file, so both
// put the durable file back to holding no more than the live window. A flag
// that only ever went true made one compaction arm the line for the rest of
// the process — the exact per-call waste this issue exists to remove, walked
// back in through the commonest flow there is.
test "#445: /new and /clear disarm the transcript line again, and a later compaction re-arms it" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const saved = prompts.g_session_compacted;
    defer prompts.g_session_compacted = saved;
    defer prompts.armSessionTranscript(a, "", .{}, false); // leave the global as the rest of the suite expects it
    defer prompts.armCompactNotes(""); // #391's store is a process global: never leak an armed session into another test

    var agent: agent_mod.Agent = undefined;
    agent.sub = false;
    agent.session_name = "session-long";
    prompts.g_session_compacted = false;
    prompts.armSessionTranscript(a, agent.session_name, .{}, false);
    try prompts.setSystemPrompts(&agent, "BASE", a);

    // A long session compacts: the line arms, as #445's forward boundary says.
    prompts.noteSessionCompacted(&agent, a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-long.session.json") != null);

    // /new: a brand-new conversation under a brand-new name, in the SAME
    // process. commands_session calls the reset AFTER the rename, so the
    // re-arm reads the session that exists now — and finds nothing to say.
    agent.session_name = "session-new";
    prompts.resetSessionCompacted(&agent, a);
    try std.testing.expect(!prompts.g_session_compacted);
    try std.testing.expectEqualStrings("BASE", agent.sys_normal);
    for ([_][]const u8{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v, "session-long.session.json") == null); // no stale name either
        try std.testing.expect(std.mem.indexOf(u8, v, "session-new.session.json") == null);
    }

    // ...and the new conversation earns the line back on its own first
    // compaction, naming ITS file. The flag is a boundary, not a one-way latch.
    prompts.noteSessionCompacted(&agent, a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-new.session.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-long.session.json") == null);

    // /clear: same name, but the immediate saveSession rewrites the durable
    // file down to an empty history, so the line again describes nothing.
    prompts.resetSessionCompacted(&agent, a);
    try std.testing.expect(!prompts.g_session_compacted);
    try std.testing.expectEqualStrings("BASE", agent.sys_normal);

    // Already false: a second /clear must not touch the prompt at all.
    agent.sys_normal = "SENTINEL";
    prompts.resetSessionCompacted(&agent, a);
    try std.testing.expectEqualStrings("SENTINEL", agent.sys_normal);

    // A subagent's own /clear-equivalent can never disarm the ROOT's line.
    prompts.g_session_compacted = true;
    var child: agent_mod.Agent = undefined;
    child.sub = true;
    child.session_name = "session-child";
    child.sys_base = "CHILD-BASE";
    child.sys_normal = "CHILD-SENTINEL";
    prompts.resetSessionCompacted(&child, a);
    try std.testing.expect(prompts.g_session_compacted);
    try std.testing.expectEqualStrings("CHILD-SENTINEL", child.sys_normal);
}

// #445: /resume is the third door onto the same state. loadSession replaces
// the live history with a COPY of the file it just read, so the transcript
// line is redundant for exactly the reason it is redundant on a fresh session
// — and worse than redundant if left armed, since it would still be naming the
// conversation the user resumed AWAY from.
test "#445: /resume disarms the transcript line and leaves no stale session path" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const saved = prompts.g_session_compacted;
    defer prompts.g_session_compacted = saved;
    defer prompts.armSessionTranscript(a, "", .{}, false); // leave the global as the rest of the suite expects it
    defer prompts.armCompactNotes(""); // #391's store is a process global: never leak an armed session into another test

    var agent: agent_mod.Agent = undefined;
    agent.sub = false;
    agent.session_name = "session-before";
    prompts.g_session_compacted = false;
    prompts.armSessionTranscript(a, agent.session_name, .{}, false);
    try prompts.setSystemPrompts(&agent, "BASE", a);

    // The conversation the user is about to leave compacted, so it is armed.
    prompts.noteSessionCompacted(&agent, a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-before.session.json") != null);

    // /resume: commands_misc assigns the new name, THEN resets — the ordering
    // the reset's doc comment requires, so the re-arm sees the resumed session.
    agent.session_name = "session-resumed";
    prompts.resetSessionCompacted(&agent, a);
    try std.testing.expect(!prompts.g_session_compacted);
    try std.testing.expectEqualStrings("BASE", agent.sys_normal);
    for ([_][]const u8{ agent.sys_normal, agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v, "session-before.session.json") == null); // the stale path is gone
        try std.testing.expect(std.mem.indexOf(u8, v, "session-resumed.session.json") == null); // and the new one is not owed one yet
    }

    // The resumed conversation earns the line back on its OWN first compaction.
    prompts.noteSessionCompacted(&agent, a);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-resumed.session.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "session-before.session.json") == null);
}

test "#421: MCP, skill and optional-tool guidance all cost zero when absent" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    // MCP: startup.buildSystemPrompt injects a server's note only when that
    // server actually connected, and nothing is baked into the base prompt.
    for (skills.mcp_notes) |mn| {
        try std.testing.expect(!skills.mcpServerConnected(&.{}, mn.server));
        try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, mn.note) == null);
    }
    // Markdown skills: an empty catalog is the empty string, not a header.
    try std.testing.expectEqualStrings("", skill_docs.promptCatalog(a, &.{}));
    // #352 optional tools: no availability, no advertisement, and the base
    // prompt never mentions imagegen either way (its guidance is the skill).
    const saved = imagegen.available;
    defer imagegen.available = saved;
    imagegen.available = false;
    try std.testing.expect(!tool_gates.advertised(imagegen.tool_name));
    try std.testing.expect(std.mem.indexOf(u8, prompts.main_system_prompt, "imagegen") == null);
}

test "#421: goal steering is empty outside a goal run" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    try std.testing.expectEqualStrings("", try repl_glue.goalSteeringNote(a, null));
    // ...and a goal that is no longer active steers nobody either (#223).
    try std.testing.expectEqualStrings("", try repl_glue.goalSteeringNote(a, .{ .objective = "ship it", .status = .complete }));
    try std.testing.expect((try repl_glue.goalSteeringNote(a, .{ .objective = "ship it", .status = .active })).len > 0);
}

// #391 + #445 regression. The two features collided at integration in a way
// neither suite could see: #391's note store is a PROCESS global whose
// composition reads the filesystem through `agent.io`, and #445's tests drive
// the funnel with stub Agents whose `io` is `undefined`. Once anything armed
// the store, every later composition in the binary segfaulted inside
// compact_note.pathFor — three tests away from the cause.
//
// The fix is that the funnel's IMPLICIT arming is gated on `!builtin.is_test`,
// so a test can only arm the store by asking for it. This pins that: remove the
// gate and this goes red instead of the segfault coming back.
test "#391/#445: the prompt funnel never arms the note store in a test build" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    const saved = prompts.g_session_compacted;
    defer prompts.g_session_compacted = saved;
    defer prompts.armCompactNotes("");
    defer prompts.armSessionTranscript(a, "", .{}, false);

    prompts.armCompactNotes(""); // start disarmed, as a fresh process would
    try std.testing.expect(!prompts.compactNotesArmed());

    var agent: agent_mod.Agent = undefined;
    agent.sub = false;
    agent.session_name = "session-purity";
    agent.io = std.testing.io; // a real io: this test is about arming, not about io
    try prompts.setRootSystemPrompts(&agent, "BASE", a);

    // Production arms here. A test build must not, or the funnel stops being
    // the pure string function the rest of this suite depends on.
    try std.testing.expect(!prompts.compactNotesArmed());
}

test "lean drops the todo/constraint capabilities from the prompt, never the local tools" {
    const saved = no_local_tools.lean;
    defer no_local_tools.lean = saved;
    no_local_tools.lean = false;
    const full = prompts.detectCaps();
    try std.testing.expect(full.todos and full.constraints and full.local_tools);
    no_local_tools.lean = true;
    const lean = prompts.detectCaps();
    try std.testing.expect(!lean.todos and !lean.constraints);
    try std.testing.expect(lean.local_tools and lean.subagents); // the lean seven keep both
    // …and the composition carries it: the dropped segments' bytes are gone.
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const lean_prompt = try prompts.composeBase(a, lean);
    try std.testing.expect(lean_prompt.len < prompts.main_system_prompt.len);
}

test "unattended one-shots are told the REAL approval map up front; attended sessions hear nothing" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const startup = @import("startup.zig");
    const saved_img = imagegen.available;
    defer imagegen.available = saved_img;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const Io = std.Io;
    var aw: Io.Writer.Allocating = .init(a);
    const attended = try startup.buildSystemPrompt(std.testing.io, a, &aw.writer, null, null, true, false, &.{}, false, null, env);
    try std.testing.expect(std.mem.indexOf(u8, attended, "AUTO-DENIED") == null);
    var aw2: Io.Writer.Allocating = .init(a);
    const unattended = try startup.buildSystemPrompt(std.testing.io, a, &aw2.writer, null, null, true, true, &.{}, false, null, env);
    try std.testing.expect(std.mem.indexOf(u8, unattended, "AUTO-DENIED") != null);
    // The map the denial text alone could not teach: the root is gated,
    // subagents are the ungated path, and --yolo/settings are the user's.
    try std.testing.expect(std.mem.indexOf(u8, unattended, "Subagents are NOT approval-gated") != null);
    try std.testing.expect(std.mem.indexOf(u8, unattended, "--yolo") != null);
    try std.testing.expect(std.mem.indexOf(u8, unattended, ".harness/settings.json") != null);
}
