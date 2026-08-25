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
//!
//! #421: the root prompt is no longer one frozen wall of text. It is a list of
//! capability-scoped SEGMENTS whose full-capability concatenation is still the
//! comptime `main_system_prompt` (an Agent struct default, so it has to stay
//! comptime), while composeBase() drops the segments whose capability this
//! process does not have. A session is never handed instructions for a tool the
//! provider was never told about, and every gate is the same predicate dispatch
//! refuses a hallucinated call with — never a second opinion about what exists.
//!
//! #410: setRootSystemPrompts also composes the one line naming this session's
//! durable transcript. It rides in the funnel, not at the call site, so a
//! persona swap or a `set_system_prompt` cannot silently drop it.
//!
//! #445: ...but not from turn one. That line only helps a model recover
//! wording the live window no longer holds, so it waits for the first
//! compaction and rides that boundary — see transcriptLineWanted below.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const shapes = @import("shapes.zig");
const text = @import("prompt_text.zig"); // #421: the segment TEXT; this file owns their gates
const Agent = @import("agent.zig").Agent;
const playbook = @import("playbook.zig"); // #381: the user-constraint block composed onto the ROOT's base prompt
const compact_note = @import("compact_note.zig"); // #391: the pre-compaction note-to-self, composed the same way and for the same reason
const no_local_tools = @import("no_local_tools.zig"); // #330's subtractive gate — one half of every capability answer below
const tool_gates = @import("tool_gates.zig"); // #352's additive gate — the other half
const tool_surface = @import("tool_surface.zig");
const session_index = @import("session_index.zig"); // #410: where the durable transcript lives

/// The prompt text itself lives next door; this file owns when each part
/// of it is sent. `parallel_tools_note` is re-exported because
/// `sub_system_prompt` composes it as a comptime whole.
pub const parallel_tools_note = text.parallel_tools_note;

/// The capability a segment needs. `.always` is what survives every gate.
pub const Gate = enum { always, local_tools, subagents, todos, constraints, git_repo };

/// `name` exists for the snapshot tests: it lets an assertion say WHICH
/// segment a gate dropped instead of only how many bytes went missing.
pub const Segment = struct { name: []const u8, text: []const u8, gate: Gate };

/// THE root prompt, in order. This table is the single source of both the
/// comptime full-capability constant and the runtime gated composition, so the
/// two can never drift apart or reorder relative to each other.
pub const segments = [_]Segment{
    .{ .name = "intro", .text = text.intro_note, .gate = .always },
    .{ .name = "local_tools", .text = text.local_tools_note, .gate = .local_tools },
    .{ .name = "orchestration", .text = text.orchestration_note, .gate = .subagents },
    .{ .name = "todo", .text = text.todo_note, .gate = .todos },
    .{ .name = "trace", .text = text.trace_note, .gate = .local_tools },
    .{ .name = "harness_issue", .text = text.harness_issue_note, .gate = .local_tools },
    .{ .name = "git_authoring", .text = text.git_authoring_note, .gate = .git_repo },
    .{ .name = "git_safety", .text = text.git_safety_note, .gate = .always },
    .{ .name = "work", .text = text.work_note, .gate = .always },
    .{ .name = "headsup", .text = text.headsup_note, .gate = .always },
    .{ .name = "todo_progress", .text = text.todo_progress_note, .gate = .todos },
    .{ .name = "root_cause", .text = text.root_cause_note, .gate = .always },
    .{ .name = "constraint", .text = text.constraint_note, .gate = .constraints },
    .{ .name = "closing", .text = text.closing_note, .gate = .always },
    .{ .name = "parallel_core", .text = text.parallel_core_note, .gate = .always },
    .{ .name = "parallel_examples", .text = text.parallel_examples_note, .gate = .local_tools },
    .{ .name = "parallel_tail", .text = text.parallel_tail_note, .gate = .always },
};

pub const main_system_prompt = blk: {
    var out: []const u8 = "";
    for (segments) |seg| out = out ++ seg.text;
    break :blk out;
};

/// One-shot (-p) sessions have no user to approve tool calls. The gate's REAL
/// map (agent_tool_gate.zig): at the ROOT, bash/edit_file/write_file and
/// unapproved MCP are auto-denied; SUBAGENTS skip the approval gate entirely
/// (only destructive git and learn_candidate are blocked for them). Without
/// this note the model learns the map by trial: measured benchmark flips
/// between "subagent detour, task done" and "root edit denied, task
/// abandoned" on identical input — plus a retry tax of failed calls first.
/// Telling it UP FRONT makes the delegation deterministic. Appended by
/// startup.buildSystemPrompt only when the session is unattended AND not
/// --yolo (yolo pre-approves everything, so the note would be a lie there).
pub const unattended_note = "\n\nThis session is non-interactive: there is no user to approve tool calls, so YOUR approval-gated tools — bash, edit_file, write_file, unapproved MCP calls — are AUTO-DENIED at the root. Never retry a denial; it will not change. Subagents are NOT approval-gated: delegate implementation and command execution to a subagent (it can edit files and run tests itself), then report its result plainly. The user can also re-run with --yolo, or pre-approve tools in .harness/settings.json, to let the root act directly.";

/// #421: what this session can actually do, exactly as the tool catalog
/// reports it. Defaults are "everything", so a caller that only cares about
/// one gate names one field.
pub const Caps = struct {
    /// bash + the native file/index tools. Off under #330 `--no-local-tools`.
    local_tools: bool = true,
    /// The `subagent`/`workflow` fan-out pair.
    subagents: bool = true,
    /// `todo_write`.
    todos: bool = true,
    /// `note_constraint`.
    constraints: bool = true,
    /// The cwd is inside a git repository, so commit/PR authoring guidance
    /// has something to act on. Session state like the others: settled once
    /// at startup (probeGitRepo), before buildSystemPrompt composes.
    git_repo: bool = true,

    pub fn has(self: Caps, gate: Gate) bool {
        return switch (gate) {
            .always => true,
            .local_tools => self.local_tools,
            .subagents => self.subagents,
            .todos => self.todos,
            .constraints => self.constraints,
            .git_repo => self.git_repo,
        };
    }

    /// Nothing gated: composeBase may hand back the comptime constant.
    pub fn full(self: Caps) bool {
        return self.local_tools and self.subagents and self.todos and self.constraints and self.git_repo;
    }
};

/// Is this tool advertised to the provider this session? The two gates that
/// can remove a built-in, and nothing else — the same pair `exec.zig` refuses
/// a hallucinated call with, so the prompt can never disagree with dispatch.
pub fn toolAdvertised(name: []const u8) bool {
    return !no_local_tools.blocks(name) and !tool_gates.blocks(name) and !tool_surface.hideBuiltin(name);
}

/// The live gates. Every flag and env knob feeding them is settled before
/// startup.buildSystemPrompt runs (args.parse, then setupSkillsAndTheme).
pub fn detectCaps() Caps {
    // The lean halves agree: a tool the catalog filtered out (no_local_tools)
    // is also not a capability the prompt may instruct about.
    return .{
        .local_tools = toolAdvertised("edit_file") and toolAdvertised("bash"),
        .subagents = toolAdvertised("subagent") and !no_local_tools.lean, // lean: no fan-out essay
        .todos = toolAdvertised("todo_write") and !no_local_tools.lean,
        .constraints = toolAdvertised("note_constraint") and !no_local_tools.lean,
        .git_repo = g_git_repo and !no_local_tools.lean, // -p: no commit/PR essay
    };
}

/// Whether the cwd sits inside a git repository — the `git_repo` gate's
/// backing state. Defaults TRUE so an embedder (or a test) that never probes
/// keeps the full prompt; startup.buildSystemPrompt is the one prober.
pub var g_git_repo: bool = true;

/// Walk up from the cwd looking for `.git` — access(), not a dir stat,
/// because a worktree checkout keeps `.git` as a FILE. Bounded: 32 levels
/// covers any real checkout, and the filesystem root just fails access.
pub fn probeGitRepo(io: Io) void {
    var buf: [128]u8 = undefined;
    var prefix: usize = 0;
    g_git_repo = while (prefix + 4 <= buf.len) {
        @memcpy(buf[prefix..][0..4], ".git");
        if (Io.Dir.cwd().access(io, buf[0 .. prefix + 4], .{})) |_| break true else |_| {}
        @memcpy(buf[prefix..][0..3], "../");
        prefix += 3;
    } else false;
}

/// The segment list in `main_system_prompt` order, minus every segment whose
/// capability is absent. Always allocates; composeBase is the caller that
/// short-circuits. Kept public so the snapshot tests can prove the
/// full-capability composition IS `main_system_prompt`, byte for byte.
pub fn composeSegments(arena: Allocator, caps: Caps) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (segments) |seg| {
        if (!caps.has(seg.gate)) continue;
        const bytes = text.leanSegment(seg.name, seg.text, no_local_tools.lean) orelse continue;
        try aw.writer.writeAll(bytes);
    }
    return aw.writer.buffered();
}

/// The built-in base for `caps`. Full capability returns the comptime constant
/// itself, so the common path allocates nothing and stays byte-identical to the
/// prompt this harness has always sent (mirrors no_local_tools.filterRootSpecs).
pub fn composeBase(arena: Allocator, caps: Caps) ![]const u8 {
    if (caps.full()) return main_system_prompt;
    return composeSegments(arena, caps);
}

/// startup.buildSystemPrompt's entry point: the built-in base, gated on what
/// this process can actually do.
pub fn baseForSession(arena: Allocator) ![]const u8 {
    return composeBase(arena, detectCaps());
}

/// #410: the transcript line for THIS session, composed once by
/// setRootSystemPrompts and re-applied by every later setSystemPrompts call so
/// a persona swap cannot drop it. Empty for every non-root agent and every
/// unit test — the same arming discipline playbook.g_root_inject uses.
var g_transcript_note: []const u8 = "";
var g_goal_line: []const u8 = ""; // ADR 0005: one prefix line; essay is change-only

/// #445: has THIS process's root session compacted at least once? False at
/// startup, set once by noteSessionCompacted, never lowered again. Public only
/// so a test can save and restore it, exactly like playbook.g_root_inject —
/// noteSessionCompacted is the sole production writer.
pub var g_session_compacted: bool = false;

/// #391: the session whose pre-compaction notes ride the ROOT's prompt.
/// Empty for every non-root agent and every unit test — the arming discipline
/// g_transcript_note and playbook.g_root_inject both use, and what keeps a
/// bare `Agent` with an `undefined` Io out of the filesystem.
var g_note_session: []const u8 = "";

/// Backing store for the above. The global OWNS its name rather than borrowing
/// the caller's: in production every session name is arena-owned for the life
/// of the process, but a unit test hands over a short-lived buffer, and the
/// first test to arm one left every later composition dereferencing freed
/// memory — a segfault inside `compact_note.pathFor`, far from the cause.
/// Copying makes the hazard structurally impossible instead of a rule callers
/// must remember. Names longer than this disarm rather than truncate: a
/// truncated name would silently read a DIFFERENT session's notes.
var g_note_session_buf: [256]u8 = undefined;

/// Armed by setRootSystemPrompts, and re-armed by the note writer itself so a
/// `/save <name>` mid-session cannot leave the injection reading a store the
/// writer has stopped writing to.
/// Whether the note store currently points at a session. Exists so a test can
/// pin the funnel's purity (see the #391/#445 regression test) without making
/// the store itself public.
pub fn compactNotesArmed() bool {
    return g_note_session.len > 0;
}

pub fn armCompactNotes(session_name: []const u8) void {
    if (session_name.len == 0 or session_name.len > g_note_session_buf.len) {
        g_note_session = "";
        return;
    }
    @memcpy(g_note_session_buf[0..session_name.len], session_name);
    g_note_session = g_note_session_buf[0..session_name.len];
}

/// One line naming the durable transcript. Deliberately NOT described as
/// JSONL: `.graff/sessions/<name>.session.json` is a single JSON object (the
/// JSONL files are the `.graff/traces` event streams the paragraph above
/// covers), and it is not an archive of what compaction discarded either —
/// compaction rewrites the retained history and the next autosave persists
/// that. Promising either would cost the model turns discovering otherwise.
pub fn sessionTranscriptNote(arena: Allocator, session_name: []const u8) []const u8 {
    if (session_name.len == 0) return "";
    return std.fmt.allocPrint(
        arena,
        "\n\nThis session's durable transcript is {s}/{s}{s} — one JSON object whose \"messages\" array holds the retained conversation. It is rewritten only after a turn completes, so it always lags the turn in progress, and compaction rewrites it in place: it is the resume artifact, not an append-only archive. Read it when you need the exact earlier wording of something this conversation no longer shows you.",
        .{ session_index.sessions_dir, session_name, session_index.session_ext },
    ) catch "";
}

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
    \\(context / around / callpath / list_dir) before reaching for
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
///
/// #381: the base is also remembered verbatim on `sys_base`, and the live
/// user-constraint block is composed onto it here — inside the one funnel —
/// so a persona swap or a `set_system_prompt` can never drop the user's
/// standing "no"s on the floor. Gated on `playbook.g_root_inject` (armed only
/// by setRootSystemPrompts below) so this stays a pure string funnel for the
/// tests and for every non-root agent.
pub fn setSystemPrompts(agent: *Agent, base: []const u8, arena: Allocator) !void {
    agent.sys_base = base;
    const with_playbook = if (playbook.g_root_inject) playbook.composeRoot(agent.io, arena, base) else base;
    // #391: the pre-compaction note-to-self rides the SAME funnel, one rung
    // below the user's constraints — a rule outranks the agent's own working
    // state. Same arming discipline as the two blocks around it, so this stays
    // a pure string funnel for every non-root agent and every unit test.
    const with_notes = if (g_note_session.len == 0) with_playbook else compact_note.compose(agent.io, arena, with_playbook, g_note_session);
    // #410: the transcript line is a fact about the SESSION, not about the
    // persona, so it re-composes here rather than being baked into a base a
    // later set_agent/set_system_prompt would replace (the #326 staleness class).
    const composed = if (g_transcript_note.len == 0) with_notes else try std.fmt.allocPrint(arena, "{s}{s}", .{ with_notes, g_transcript_note });
    const with_goal = if (g_goal_line.len == 0) composed else try std.fmt.allocPrint(arena, "{s}{s}", .{ composed, g_goal_line });
    agent.sys_normal = with_goal;
    agent.sys_strict = try std.fmt.allocPrint(arena, "{s}{s}", .{ with_goal, strict_note });
    agent.sys_ultra = try std.fmt.allocPrint(arena, "{s}{s}", .{ with_goal, ultracode_system_note });
    agent.sys_ultra_strict = try std.fmt.allocPrint(arena, "{s}{s}", .{ agent.sys_strict, ultracode_system_note });
}

/// Pin the live objective into the system-prompt prefix. Empty / paused /
/// cleared goals disarm the line so a dead goal cannot keep paying tokens.
/// Re-compose is free at startup (before the first request) and at compact
/// (#445); a mid-session /goal change busts the prefix once, which is cheaper
/// than restating the essay every eighth user turn.
pub fn pinStandingGoal(agent: *Agent, arena: Allocator) void {
    g_goal_line = "";
    if (agent.goal) |g| {
        if (g.status == .active and g.objective.len > 0) {
            const obj = if (g.objective.len <= 120) g.objective else g.objective[0..120];
            g_goal_line = std.fmt.allocPrint(arena, "\n\n[standing goal: {s}]\n", .{obj}) catch "";
        }
    }
    if (agent.sys_base.len == 0) return;
    @import("prompt_cache_hud.zig").noteBust(.goal);
    setSystemPrompts(agent, agent.sys_base, arena) catch {};
}

/// The ROOT's entry to the same funnel, called once by session_run when the
/// root agent is built. Arming here rather than at a global switch keeps the
/// filesystem read strictly on the one code path that has a real session
/// behind it — subagents get their briefs' block from playbook.rideBrief, and
/// a bare `Agent` in a unit test gets neither.
pub fn setRootSystemPrompts(agent: *Agent, base: []const u8, arena: Allocator) !void {
    playbook.g_root_inject = true;
    // #410: only the root has a durable session, and only a session file this
    // process can still open is worth a line of context — with the native file
    // and shell tools removed (#330) the path is unreadable from here.
    // #445: and a session that has not compacted yet gets nothing at all. A
    // RESUMED session starts false too: the earlier compactions belong to a
    // dead process, and what that process left in the file is exactly the
    // context this one loaded, so the line would again describe what is here.
    armSessionTranscript(arena, agent.session_name, detectCaps(), g_session_compacted);
    // #391: same session, same one-time arming — but only outside test builds.
    // This is the IMPLICIT path, and a unit test reaching it with a stub Agent
    // drags prompt composition into a filesystem read through an `undefined`
    // io, segfaulting three tests away from the cause. That is exactly what
    // happened when #445's tests met #391 at integration. A test that WANTS the
    // note block calls armCompactNotes directly, as compact_note_glue_tests
    // does; the funnel stays the pure string function the rest of the suite
    // relies on. Same shape as #444's `emit_to_stderr = !builtin.is_test`.
    if (!builtin.is_test) armCompactNotes(agent.session_name);
    return setSystemPrompts(agent, base, arena);
}

/// #410's arming step, split out so the funnel is testable without the
/// filesystem read setRootSystemPrompts also performs (playbook.composeRoot).
/// An empty `session_name`, a session whose file this process cannot open, and
/// a session that has not compacted yet all arm to "" — the line is only worth
/// context when it is both actionable and not already redundant.
pub fn armSessionTranscript(arena: Allocator, session_name: []const u8, caps: Caps, compacted: bool) void {
    g_transcript_note = if (transcriptLineWanted(caps, compacted)) sessionTranscriptNote(arena, session_name) else "";
}

/// #445: the transcript line's gate, in one predicate, ANDing two conditions
/// that are different in kind and neither of which is sufficient alone:
///
///   - `caps.local_tools` is a CAPABILITY, read from the same catalog every
///     other segment gate is read from: with #330's native file and shell
///     tools removed, nothing in the session can open the path the line names.
///   - `compacted` is session STATE, and it is why this predicate exists.
///     Before the first compaction the live context is a SUPERSET of the
///     transcript file — the line can only point the model at wording it can
///     already see, and compaction rewrites the file in place anyway, so its
///     marginal value there is ~zero. Live A/B evals put the #421/#410 prompt
///     additions at +960 chars ≈ +240 input tokens on every single call at
///     full capability, which the overwhelming majority of sessions (the ones
///     that never compact at all) were paying for nothing. After a compaction
///     the file holds wording the window no longer does: the case #410 is for.
///
/// Deliberately NOT a `Caps` field. `Caps` is what the tool catalog reports,
/// and `detectCaps()` is settled before startup.buildSystemPrompt runs; this
/// flips mid-session, by definition after the first request. Folding it in
/// would make both of those statements false, and would put a non-segment
/// condition into the predicate `composeBase`/`full()` short-circuit on.
pub fn transcriptLineWanted(caps: Caps, compacted: bool) bool {
    return caps.has(.local_tools) and compacted;
}

/// #445: the compaction boundary — the one moment the line starts earning its
/// tokens, and the one moment mutating the system prompt is free. Compaction
/// has already replaced the history sitting behind any cached KV prefix, so
/// re-composing here adds no SECOND invalidation point; deferring to the next
/// turn boundary instead would throw away a live cache for the same text.
///
/// Root-only (a subagent has no durable session file of its own, and must not
/// flip the flag for the root) and idempotent: a session that compacts ten
/// times re-derives its prompt once. Best-effort, exactly like
/// playbook_glue.refreshRoot — a failed re-compose leaves the previous, still
/// valid prompt in place and the next mutation through the funnel picks it up.
pub fn noteSessionCompacted(agent: *Agent, arena: Allocator) void {
    if (agent.sub or g_session_compacted) return;
    g_session_compacted = true;
    armSessionTranscript(arena, agent.session_name, detectCaps(), true);
    if (agent.sys_base.len == 0) return; // never went through the funnel: nothing to re-derive from
    setSystemPrompts(agent, agent.sys_base, arena) catch {};
}

/// #445's inverse boundary, and it is NOT optional: one process can host
/// several root conversations. `/new` mints a fresh `session_name` and `/clear`
/// empties the history and saves immediately, so in both cases the durable file
/// again holds no more than the live window — the exact state the line is not
/// worth its tokens in. Without this, one compaction armed the line for the
/// remaining life of the process and a user who compacted, then hit `/new`,
/// paid for it forever pointing at a file with nothing to recover.
///
/// Same idiom as noteSessionCompacted: root-only, a no-op when already false,
/// and best-effort. Call it AFTER any `session_name` reassignment, so the
/// re-arm reads the conversation that actually exists now.
pub fn resetSessionCompacted(agent: *Agent, arena: Allocator) void {
    if (agent.sub) return;
    // #391 + #445 integration: BOTH armings key on session_name, and the three
    // doors that reach here (/new, /clear, /resume) can repoint it. The note
    // store has to follow even when this session never compacted — otherwise a
    // `/new` after a note was written leaves g_note_session on the PREVIOUS
    // name and injects the old conversation's notes into the new one, which is
    // the same stale-identity bug this function exists to prevent for the
    // transcript line, one store over.
    // An UNARMED store has not "moved" — it was never pointed anywhere. Without
    // this the predicate reads a fresh session as a move (`"" != name`) and
    // defeats #445's own no-op-when-already-false contract.
    const note_moved = g_note_session.len > 0 and !std.mem.eql(u8, g_note_session, agent.session_name);
    if (!builtin.is_test) armCompactNotes(agent.session_name); // implicit path, see setRootSystemPrompts
    if (!g_session_compacted and !note_moved) return;
    g_session_compacted = false;
    armSessionTranscript(arena, agent.session_name, detectCaps(), false);
    if (agent.sys_base.len == 0) return;
    setSystemPrompts(agent, agent.sys_base, arena) catch {};
}

pub const sub_system_prompt =
    \\You are a subagent spawned by an orchestrator agent inside a terminal
    \\harness. Complete only the assigned task; do not broaden scope or ask
    \\questions — make reasonable assumptions. Do not narrate tool calls.
    \\Your final message is returned verbatim to the orchestrator: a concise
    \\report of the concrete facts you found.
++ parallel_tools_note;

pub const compact_instruction =
    \\Summarize this entire conversation for a context handoff. Capture: the
    \\user's goals, all important facts and decisions, file paths and code
    \\that was created or modified, command results that matter, the current
    \\task checklist and each item's status, and any pending or unfinished
    \\work. Be thorough but compact. Reply with only the summary.
;

test { // #421/#410: prompt snapshots and goal-prefix behavior must stay reachable.
    _ = @import("prompt_snapshot_tests.zig");
    _ = @import("prompt_goal_tests.zig");
}

// The harness has always run a returned tool batch concurrently, for subagents
// exactly as for the root (agent_tools.zig dispatches every external call as a
// future before awaiting any). Nothing ASKED for a batch, though, so the
// capability rode entirely on the model's own initiative - openai/codex spells
// it out in its base instructions and graff did not. Pin it on BOTH prompts:
// the subagent one is the easier of the two to forget, since it is five lines
// long and does not share a base with the root.
test "both prompts ask for parallel tool calls, with the dependency caveat" {
    for ([_][]const u8{ main_system_prompt, sub_system_prompt, main_system_prompt_strict }) |p| {
        try std.testing.expect(std.mem.indexOf(u8, p, "Parallelize tool calls") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "ONE response") != null);
        // Without the caveat this instruction is actively harmful: graff runs
        // the whole batch concurrently, so two writes to one file would race.
        try std.testing.expect(std.mem.indexOf(u8, p, "same file") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "depends on an earlier") != null);
    }
    // Composing must not have cost either prompt its own identity.
    try std.testing.expect(std.mem.indexOf(u8, sub_system_prompt, "subagent spawned by an orchestrator") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_system_prompt, "do not broaden") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_system_prompt, "Do not narrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_system_prompt, "rlm(code)") == null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "Be direct and concise") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt_strict, "STRICT MODE") != null);
}

// #351: agent-authored PRs described only the diff, which a reviewer can already
// read. The rationale — the failure mode, why this design, what it trades off —
// exists only in the agent's head at authoring time and is unrecoverable later,
// so the prompt has to demand it. The proportionality clause is load-bearing in
// the other direction: without it a one-line typo fix grows four empty headings.
test "root prompt (#351) requires what+why rationale in PR descriptions, scaled to the change" {
    for ([_][]const u8{ "## What changed", "## Why", "Problem/failure mode", "Reason for this approach", "Constraints or trade-offs", "Rejected alternatives" }) |section|
        try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, section) != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "Scale the rationale to the change") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_system_prompt, "never pad a small change with boilerplate") != null);
}

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
