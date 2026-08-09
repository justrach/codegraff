//! Tool-schema + provider-tool JSON emission: the built-in/meta ToolSpec
//! catalog, the per-provider tool-array renderers (anthropic/openai/responses),
//! and emitSchema (the --schema / `graff serve` /v1/schema document). Split out
//! of main.zig (#123). Back-imports main for Provider (.Kind) and the
//! provider catalog and the active model table. main
//! re-exports emitSchema + schema_version so serve.zig stays untouched.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const pricing = @import("pricing.zig");
const learn_store = @import("learn_store.zig");
const skill_docs = @import("skill_docs.zig"); // SKILL.md playbooks: the `skill` tool's name/desc/schema live there
const peer_channel = @import("peer_channel.zig"); // #469: the peer_message tool's name/desc/schema live there
const no_local_tools = @import("no_local_tools.zig"); // #330: the hard --no-local-tools gate (layer 1 lives here, layer 2 in exec.zig)
const tool_gates = @import("tool_gates.zig"); // #352: the additive twin — optional tools that only exist when startup found their backing capability
const imagegen = @import("imagegen.zig"); // #352: name/desc/schema as plain strings, like skill_docs, so this catalog needs one entry and no import cycle
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: which MCP tools are served schema-first vs description-only, and the `load_tool_schemas` strings
const native_fold = @import("native_fold.zig"); // folded native power tools: same two-phase pattern for the harness's own catalog
const render = @import("schema_render.zig"); // the comptime provider-tool renderers moved out when #352's optional-tool catalogs doubled the number held here (600-line ceiling)
const anthropicToolsJson = render.anthropicToolsJson;
const openaiToolsJson = render.openaiToolsJson;
const responsesToolsJson = render.responsesToolsJson;

const root = @import("main.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;

/// Documentation of the `--json` stdio protocol, embedded verbatim in
/// `--schema` output so SDK generators/users know the request/event contract.
const schema_protocol_json = @import("schema_protocol.zig").json;
/// Documentation of the `harness serve` HTTP bridge, embedded verbatim in
/// `--schema` output. Same request/event contract as the stdio protocol —
/// one POST = one protocol request, streamed back as NDJSON until that
/// request's terminal event (turn/error for user turns; the ack for others) —
/// plus the #330 resumability surface (seq, ?from=N, durable session names).
const schema_serve_json = @import("schema_serve.zig").json;
/// Launch flags for SDK clients (schema_protocol.zig, alongside the protocol
/// doc it is emitted with), re-exported here as the `--schema` field name.
pub const schema_flags_json = @import("schema_protocol.zig").flags;
pub const ToolSpec = struct {
    name: []const u8,
    desc: []const u8, // no characters needing JSON escapes
    schema: []const u8, // raw JSON Schema string
};

const empty_schema =
    \\{"type": "object", "properties": {}}
;

const base_specs = [_]ToolSpec{
    .{
        .name = "bash",
        .desc = "Run a shell command via /bin/sh -c in the current working directory. Returns stdout, stderr, and the exit code. A user-cancelled command reports cancelled (its whole local process group is killed; a remote process started over ssh may survive on the remote host). For long-running commands (dev servers, watchers) set run_in_background true: it returns a job id immediately; poll output with bash_output and stop it with bash_kill.",
        .schema =
        \\{"type": "object", "properties": {"command": {"type": "string", "description": "Shell command to execute"}, "run_in_background": {"type": "boolean", "description": "Start as a background job and return its id immediately instead of waiting (default false)"}}, "required": ["command"]}
        ,
    },
    .{
        .name = "bash_output",
        .desc = "Read new output from a background bash job (everything since the last bash_output call) plus its status: running, exited with code, or killed. Set wait_ms to block until new output or exit.",
        .schema =
        \\{"type": "object", "properties": {"id": {"type": "integer", "description": "Job id returned by bash with run_in_background"}, "wait_ms": {"type": "integer", "description": "Max milliseconds to wait for new output or exit (0-30000, default 0)"}}, "required": ["id"]}
        ,
    },
    .{
        .name = "bash_kill",
        .desc = "Terminate a background bash job. Unread output stays readable via bash_output afterwards.",
        .schema =
        \\{"type": "object", "properties": {"id": {"type": "integer", "description": "Job id to terminate"}}, "required": ["id"]}
        ,
    },
    .{
        .name = "read_file",
        .desc = "Read a UTF-8 text file. Call this before editing any file. Whole-file reads over 256 KiB return a short preview; pass start_line/end_line (1-based, inclusive) for a byte-exact window from any size file.",
        .schema =
        \\{"type": "object", "properties": {"path": {"type": "string", "description": "File path, relative to the working directory"}, "start_line": {"type": "integer", "description": "Optional 1-based first line to return (byte-exact slice; omit for whole file)"}, "end_line": {"type": "integer", "description": "Optional 1-based last line to return, inclusive"}, "compact": {"type": "boolean", "description": "Exploratory only: return a comment/blank-stripped view via codedb (line numbers shown). NEVER use before an edit — re-read without compact to copy exact text."}}, "required": ["path"]}
        ,
    },
    .{
        .name = "edit_file",
        .desc = "Replace an exact string in a file. old_string must match exactly one spot unless replace_all is set. Prefer this over write_file when changing an existing file.",
        .schema =
        \\{"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string", "description": "Exact existing text to find"}, "new_string": {"type": "string", "description": "Replacement text"}, "replace_all": {"type": "boolean", "description": "Replace every occurrence (default: require a unique match)"}}, "required": ["path", "old_string", "new_string"]}
        ,
    },
    .{
        .name = "write_file",
        .desc = "Create or overwrite a file with the given contents.",
        .schema =
        \\{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}
        ,
    },
    .{
        .name = "webfetch",
        .desc = "Fetch an http(s) URL and return the page content. When the kuri fetcher is installed (and not disabled) the page arrives as markdown; otherwise — or whenever kuri fails or returns nothing — a plain HTTP GET returns the raw HTML/text. Output is size-capped.",
        .schema =
        \\{"type": "object", "properties": {"url": {"type": "string", "description": "Absolute http:// or https:// URL to fetch"}}, "required": ["url"]}
        ,
    },
    // Progressive disclosure: the system prompt carries skill names +
    // descriptions, this tool fetches one body on demand (skill_docs.zig).
    .{ .name = skill_docs.tool_name, .desc = skill_docs.tool_desc, .schema = skill_docs.tool_schema },
    .{
        .name = "codedb",
        .desc = "Query codedb (github.com/justrach/codedb) — the code-intelligence index for this repo (fast & structural; prefer over grep/bash for navigating code). `command` is a codedb subcommand line: search <query> | symbol <name> [--body] | callers <name> | outline <path> | find <name> | deps <path> | tree | context <task...> | read <path>.",
        .schema =
        \\{"type": "object", "properties": {"command": {"type": "string", "description": "codedb subcommand + args, e.g. \"search parseHeader\", \"symbol buildBody --body\", \"callers switchProvider\""}}, "required": ["command"]}
        ,
    },
};

// Meta tools act on the agent's own state, not the outside world; the
// orchestrator handles them inline (never on a pool thread).
const meta_specs = [_]ToolSpec{
    .{
        .name = "todo_write",
        .desc = "Replace the task list for the current standing goal (items from a replaced, cleared or completed goal are parked - kept in the session, but not part of this list and not replaced by this call). An item you already marked completed is kept as history when you leave it out, for as long as the current request is being worked; list it again (with any status) to change or remove it that way. Once every item is completed, the next thing the user asks starts a clean list - finished work is not carried into it. Omitted pending/in_progress items are dropped. Every call needs at least one item: a call with none leaves the list untouched. Use to plan and track multi-step work; skip it for trivial single-step tasks. Each item has content and status (pending|in_progress|completed). Write steps small enough to verify individually; keep exactly ONE item in_progress at a time — mark it in_progress when you start and completed as it lands, never a batch flipped at the end.",
        .schema =
        \\{"type": "object", "properties": {"todos": {"type": "array", "items": {"type": "object", "properties": {"content": {"type": "string"}, "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}}, "required": ["content", "status"]}}}, "required": ["todos"]}
        ,
    },
    .{
        .name = "todo_read",
        .desc = "Read your current task list (the current goal's items; work parked by an earlier goal, and finished lists retired by a later request, are not included).",
        .schema = empty_schema,
    },
    .{
        .name = "eval",
        .desc = "Run the configured scoring command (graff --eval) alone and record the result. The HARNESS runs it and logs the score to .graff/eval-log.tsv - do not run it via bash. Returns score, best, target, and gate state. Red drops the current plan and grants a repair turn: make ONE focused repair, then re-evaluate before completion (a repeatedly-red eval eventually surfaces the hard stop). In `note`, describe the focused change and label new CONFIRMED/GUESS/HYPOTHESIS/FACT beliefs.",
        .schema =
        \\{"type": "object", "properties": {"note": {"type": "string", "description": "What you changed since the last eval"}}}
        ,
    },
    // #381: the durable-rejection capture surface. Root-only, and APPEND-ONLY
    // by construction — there is no retire/edit/list operation here at all,
    // so a model that finds a constraint inconvenient has no mechanism to
    // widen it; only the user can, with /never rm <id>.
    .{ .name = "note_constraint", .desc = "Record a standing user constraint in this project's playbook (.graff/playbook.jsonl). Call it the moment the user rejects, forbids or vetoes something, passing ONE short imperative line stating what must not happen (e.g. never add scroll hints or progress dots). The recorded line is injected verbatim into every later subagent, workflow and pipeline brief and into your own system context, in this session and in future ones, so it survives compaction and reaches fresh agents that never saw the rejection. Append-only: this tool cannot edit, retire or list items - only the user can, with /never. Recording the same constraint twice is harmless and does nothing.", .schema = "{\"type\": \"object\", \"properties\": {\"text\": {\"type\": \"string\", \"description\": \"One short imperative line in the user's own terms, stating what must not happen\"}}, \"required\": [\"text\"]}" },
    .{
        .name = "ask_user",
        .desc = "Ask the human a question and wait for their typed reply, which is returned as this tool's result. Use when you need a decision, clarification, or missing information. This routes the human turn through the tool channel — the user is just another tool you can call.",
        .schema =
        \\{"type": "object", "properties": {"question": {"type": "string", "description": "The question to ask the user"}, "options": {"type": "array", "items": {"type": "string"}, "description": "Optional suggested answers, shown numbered"}}, "required": ["question"]}
        ,
    },
    .{
        .name = "attempt_completion",
        .desc = "Signal that the task is complete. Put your final answer to the user in the result field. In strict mode this is the only way to end a turn. Completing also closes the standing /goal; if its checklist still has open items you will be asked once to finish or confirm.",
        .schema =
        \\{"type": "object", "properties": {"result": {"type": "string", "description": "Final answer to present to the user"}}, "required": ["result"]}
        ,
    },
    // #416, the MCP half of progressive disclosure: an expensive server is
    // registered by name + one line per tool, and this loads the real schemas
    // (and enables those tools) on demand. Meta because it mutates the root's
    // own tool catalog; renderRootTools drops it while nothing is deferred.
    .{ .name = mcp_schema_gate.tool_name, .desc = mcp_schema_gate.tool_desc, .schema = mcp_schema_gate.tool_schema },
    .{
        .name = "clock_sleep",
        .desc = "Pause the current turn for up to 12 hours of wall-clock time; interruptible by user input, and reported as a normal (non-error) result either way. For autonomous /loop runs that need to wait before re-checking something (e.g. a long external job). Root-only; off unless --clock-sleep/GRAFF_CLOCK_SLEEP=1 is set.",
        .schema =
        \\{"type": "object", "properties": {"ms": {"type": "integer", "description": "Milliseconds to sleep (0 returns immediately; clamped to the 12h/43200000ms cap)"}, "reason": {"type": "string", "description": "Optional: why you're sleeping, for the trace/UX"}}, "required": ["ms"]}
        ,
    },
};

const subagent_spec = ToolSpec{
    .name = "subagent",
    .desc = "Delegate a self-contained task to a subagent. It has bash, read_file, edit_file, write_file, codedb (code search), and skill (load an installed playbook); it cannot spawn further subagents and does NOT share your context — the prompt must be self-contained. Returns the subagent final report. Call several times in one response to run tasks in parallel. Pick a persona with agent (builtins: reviewer, researcher, implementer, skeptic — plus any in .harness/agents/), or give the child a custom system_prompt; the trajectory log records the lineage either way. Set run_in_background true to launch it asynchronously instead: you get the agent id back immediately and keep working, then fetch the result with agent_output. Which model this child runs on is decided in this order: model/tier given on THIS call > the chosen persona's own model:/tier: frontmatter > the session default (--subagent-model, else the default tier ladder) > the root model; within one level an exact model wins over tier. The child's reasoning effort is pinned the same way: effort on THIS call > the persona's effort: frontmatter > the worker default (medium) — an independent axis, so an effort-only override keeps the persona's model pin. Exact model pins resolve provider-locally first — a name the child's own provider serves always wins; one it does not serve falls through to a logged-in flat-rate subscription serving that exact name (never a fuzzy match). An explicit tier ask is the portable lever: when the child's own provider has no such rung, sub-first routing checks every logged-in flat-rate subscription and seats the worker on the best sub serving that rung (the login is the standing consent; metered cross-provider routing still needs --subagent-provider + --allow-cross-provider-subagents). A pin that cannot be honored is ignored (the spawn still runs on the session default) rather than failing.",
    .schema =
    \\{"type": "object", "properties": {"description": {"type": "string", "description": "Short label for logs, 3-5 words"}, "prompt": {"type": "string", "description": "Complete, self-contained task description"}, "agent": {"type": "string", "description": "Optional: a named agent type (reviewer, researcher, implementer, skeptic, or a .harness/agents/ name) whose persona the child runs with"}, "system_prompt": {"type": "string", "description": "Optional: replace the child's system prompt with a custom one (overrides agent)"}, "model": {"type": "string", "description": "Optional: run THIS child on an exact model name available on the current provider (e.g. \"gpt-5.6-luna\"). Highest precedence — beats the persona's own pin and the session default. Ignored (spawn still runs on the session default, with a trace note) if the name is unknown, ambiguous, or not served by this provider — except that a logged-in flat-rate subscription serving the exact name honors it (sub-first routing; the login is the standing consent). For a portable 'cheapest seat' ask, tier is still the better lever."}, "tier": {"type": "string", "enum": ["frontier", "mid", "small"], "description": "Optional: run THIS child on a rung of the current provider's model ladder instead of an exact name — frontier (planner/judge class), mid (reviewers, implementers, researchers), small (mechanical transform/extract/label). Prefer this over model: it stays correct when the root model changes. If the provider has no ladder or no model at that rung, sub-first routing seats the child on a logged-in flat-rate subscription's rung when one exists (no login → the pin is ignored); model wins if both are given."}, "effort": {"type": "string", "enum": ["low", "medium", "high", "xhigh", "max"], "description": "Optional: reasoning effort for THIS child — beats the persona's effort: frontmatter; unpinned children run at medium. An axis independent of model/tier: an effort-only override keeps the persona's model pin. An off-vocabulary value is ignored with a trace note."}, "isolation": {"type": "string", "enum": ["shared_cwd", "worktree"], "description": "Optional: \"worktree\" gives this child its own scratch git worktree (auto-removed if it finishes with no changes, kept + reported if it has any) instead of the shared working tree — use for parallel agents that edit files. Default shared_cwd (today's behavior), unless the chosen agent persona sets its own default."}, "isolation_fallback": {"type": "boolean", "description": "Optional: if isolation:\"worktree\" fails to set up (not a git repo, git error), run in the shared working tree instead of failing the spawn. Default false (fails the spawn on setup failure)."}, "run_in_background": {"type": "boolean", "description": "Optional: start this subagent asynchronously and return its agent id immediately instead of waiting for it to finish (default false). Poll status/result with agent_output (id, optional wait_ms). A spawn beyond the concurrency cap is queued, never failed."}}, "required": ["description", "prompt"]}
    ,
};

const agent_output_spec = ToolSpec{
    .name = "agent_output",
    .desc = "Fetch a background subagent's status/result (one started with subagent run_in_background:true). Running: a brief status line. Completed: the full report — the same text a synchronous subagent call would have returned, including any kept-worktree note — plus a usage summary (duration, tool-call count, context tokens, cache-read tokens). Failed: an is_error result explaining why; failures are always reported, never silent. Set wait_ms to block while still running. Calling again after completion re-returns the same result — nothing is consumed.",
    .schema =
    \\{"type": "object", "properties": {"id": {"type": "integer", "description": "Agent id returned by subagent with run_in_background:true"}, "wait_ms": {"type": "integer", "description": "Max milliseconds to wait while still running (0-30000, default 0)"}}, "required": ["id"]}
    ,
};

const workflow_spec = ToolSpec{
    .name = "workflow",
    .desc = "Run a workflow of parallel subagents (dynamic workflows as data). Two shapes. PHASES (fan-out + synthesis): phases run sequentially; tasks inside a phase run in parallel as isolated subagents with no shared context, so every prompt must be self-contained; from phase 2 on, {{prev}} in a task prompt is replaced with the labeled results of the previous phase (appended if omitted); a phase may carry `when` to run only if a substring appears in {{prev}} (conditional / early-exit). Returns the final phase results. Use for audits, multi-perspective review, parallel research. Tasks may carry their own system_prompt to run prompt variants side by side; when the fleet is on, a phase with 2+ variants is auto-scored by an LLM judge and each variant's fitness feeds back to the fleet (a tournament doubles as a DGM scoring round). PIPELINE (no barrier): pass {pipeline:{items,stages}} instead to map each item through the stages independently — item A can reach stage 3 while item B is still on stage 1; {{item}} is the item and {{prev}} is this item's previous-stage result. Use for per-item work like transform/verify each file. Optional top-level \"context\" (also settable on the pipeline object): one shared string prepended once, plus a blank line, to every task/stage prompt before {{prev}} substitution, so repo/task boilerplate is stated once instead of repeated in every task.",
    .schema =
    \\{"type": "object", "properties": {"phases": {"type": "array", "description": "Fan-out + synthesis mode (barrier between phases).", "items": {"type": "object", "properties": {"title": {"type": "string", "description": "Short phase label for logs"}, "when": {"type": "string", "description": "Optional (phase 2+): run this phase only if this substring appears (case-insensitive) in the previous phase's results — gate a synthesis/exit phase on a sentinel"}, "tasks": {"type": "array", "items": {"type": "object", "properties": {"description": {"type": "string", "description": "Short label, 3-5 words"}, "prompt": {"type": "string", "description": "Complete, self-contained task; may contain {{prev}}"}, "agent": {"type": "string", "description": "Optional: a named agent type (reviewer, researcher, implementer, skeptic, or a .harness/agents/ name)"}, "system_prompt": {"type": "string", "description": "Optional: replace this task's system prompt (overrides agent)"}, "isolation": {"type": "string", "enum": ["shared_cwd", "worktree"], "description": "Optional: \"worktree\" gives this task its own scratch git worktree (auto-removed if it finishes with no changes, kept + reported if it has any) instead of the shared working tree. Default shared_cwd, unless the chosen agent persona sets its own default."}, "isolation_fallback": {"type": "boolean", "description": "Optional: if isolation:\"worktree\" fails to set up, run in the shared working tree instead of failing this task. Default false."}}, "required": ["description", "prompt"]}}}, "required": ["tasks"]}}, "context": {"type": "string", "description": "Optional: prepended once, plus a blank line, to every task prompt before {{prev}} substitution."}, "pipeline": {"type": "object", "description": "No-barrier mode: map each item through the stages independently.", "properties": {"items": {"type": "array", "items": {"type": "string"}, "description": "Things to process, one independent chain each (e.g. file paths)"}, "stages": {"type": "array", "items": {"type": "object", "properties": {"description": {"type": "string", "description": "Short stage label"}, "prompt": {"type": "string", "description": "Self-contained; {{item}} = the item, {{prev}} = this item's previous-stage result"}, "agent": {"type": "string", "description": "Optional named agent type"}, "system_prompt": {"type": "string", "description": "Optional: replace this stage's system prompt"}, "isolation": {"type": "string", "enum": ["shared_cwd", "worktree"], "description": "Optional: \"worktree\" gives this stage its own scratch git worktree (auto-removed if it finishes with no changes, kept + reported if it has any) instead of the shared working tree. Default shared_cwd, unless the chosen agent persona sets its own default."}, "isolation_fallback": {"type": "boolean", "description": "Optional: if isolation:\"worktree\" fails to set up, run in the shared working tree instead of failing this stage. Default false."}}, "required": ["description", "prompt"]}}, "context": {"type": "string", "description": "Optional: prepended once, plus a blank line, to every stage prompt before {{item}}/{{prev}} substitution."}}, "required": ["items", "stages"]}}}
    ,
};

const learn_candidate_spec = ToolSpec{
    .name = "learn_candidate",
    .desc = "Bundle the workspace's pinned prompt-policy mutation, paired evaluation, immutable evidence, and signed aggregate grade submission into one action. Grade telemetry excludes prompt/genome text, but configured adapters may send it to their declared model provider. In Local privacy mode this requires a separate one-shot confirmation that --yolo cannot bypass; Aggregate or higher uses normal tool approval. This never promotes or changes the active policy and is root-only.",
    .schema =
    \\{"type": "object", "properties": {"candidates": {"type": "integer", "minimum": 1, "maximum": 16, "description": "Optional candidate count; defaults to the learning config"}, "repetitions": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Optional repetitions per evaluation case; defaults to the learning config"}}}
    ,
};

pub const root_specs = base_specs ++ meta_specs ++ [_]ToolSpec{ subagent_spec, workflow_spec, agent_output_spec, learn_candidate_spec, peer_spec };
const peer_spec = ToolSpec{ .name = peer_channel.tool_name, .desc = peer_channel.tool_desc, .schema = peer_channel.tool_schema };

// The common catalog (clock_sleep off) is static too. Previously every root
// startup allocated and filled a filtered ToolSpec array before rendering even
// one provider catalog.
/// The root catalog minus the named optional entries, built once at compile
/// time. The length check is the guard: each name must match EXACTLY one
/// spec, so a rename or a duplicated entry is a compile error rather than a
/// silently-wrong catalog.
fn rootSpecsWithout(comptime drop: []const []const u8) [root_specs.len - drop.len]ToolSpec {
    var out: [root_specs.len - drop.len]ToolSpec = undefined;
    var len: usize = 0;
    entry: for (root_specs) |tool| {
        for (drop) |name| if (std.mem.eql(u8, tool.name, name)) continue :entry;
        out[len] = tool;
        len += 1;
    }
    if (len != out.len) @compileError("root tool catalog optional entries changed");
    return out;
}

const root_specs_without_clock = rootSpecsWithout(&.{"clock_sleep"});
const root_specs_without_learning = rootSpecsWithout(&.{"learn_candidate"});
const root_specs_without_optional = rootSpecsWithout(&.{ "clock_sleep", "learn_candidate" });

pub const meta_names = [_][]const u8{ "todo_write", "todo_read", "ask_user", "eval", "attempt_completion", "clock_sleep", "note_constraint", mcp_schema_gate.tool_name, peer_channel.tool_name };

pub fn isMetaName(name: []const u8) bool {
    for (meta_names) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

// #352: optional built-ins — advertised only while tool_gates says they are
// available. They live in `base_specs`' orbit rather than the root-only block
// because a subagent has to be able to call them: the documented way to make
// several images is one subagent per image, each calling `imagegen` once.
const optional_specs = [_]ToolSpec{
    .{ .name = imagegen.tool_name, .desc = imagegen.tool_desc, .schema = imagegen.tool_schema },
};

// Comptime-rendered tool lists for subagents (base only, both formats).
pub const tools_anthropic_sub = anthropicToolsJson(&base_specs);
pub const tools_openai_sub = openaiToolsJson(&base_specs);
pub const tools_responses_sub = responsesToolsJson(&base_specs);

// #330 layer 1, subagent half: the same three catalogs with the host-touching
// tools filtered out at compile time. agent.zig picks between the twins on
// no_local_tools.enabled, so a child is never even told bash exists.
const base_specs_remote = no_local_tools.remoteSpecs(ToolSpec, &base_specs);
pub const tools_anthropic_sub_remote = anthropicToolsJson(base_specs_remote);
pub const tools_openai_sub_remote = openaiToolsJson(base_specs_remote);
pub const tools_responses_sub_remote = responsesToolsJson(base_specs_remote);

// #352 layer 1, subagent half: the same catalogs WITH the optional tools. A
// child's catalog is a comptime constant, so every combination is built once
// at compile time and merely selected at runtime by subToolsJson.
const base_specs_optional = base_specs ++ optional_specs;
const base_specs_optional_remote = no_local_tools.remoteSpecs(ToolSpec, &base_specs_optional);
pub const tools_anthropic_sub_optional = anthropicToolsJson(&base_specs_optional);
pub const tools_openai_sub_optional = openaiToolsJson(&base_specs_optional);
pub const tools_responses_sub_optional = responsesToolsJson(&base_specs_optional);
pub const tools_anthropic_sub_optional_remote = anthropicToolsJson(base_specs_optional_remote);
pub const tools_openai_sub_optional_remote = openaiToolsJson(base_specs_optional_remote);
pub const tools_responses_sub_optional_remote = responsesToolsJson(base_specs_optional_remote);

/// The catalog a SUBAGENT is served, across both gates: `--no-local-tools`
/// subtracts, an available optional tool adds. Sole caller is Agent.toolsJson.
pub fn subToolsJson(kind: Provider.Kind, gated: bool) []const u8 {
    const optional = tool_gates.anyAvailable();
    return switch (kind) {
        .anthropic => if (gated)
            (if (optional) tools_anthropic_sub_optional_remote else tools_anthropic_sub_remote)
        else
            (if (optional) tools_anthropic_sub_optional else tools_anthropic_sub),
        .openai => if (gated)
            (if (optional) tools_openai_sub_optional_remote else tools_openai_sub_remote)
        else
            (if (optional) tools_openai_sub_optional else tools_openai_sub),
        .responses => if (gated)
            (if (optional) tools_responses_sub_optional_remote else tools_responses_sub_remote)
        else
            (if (optional) tools_responses_sub_optional else tools_responses_sub),
    };
}

/// Render built-in specs + discovered MCP tools into one provider-specific
/// tools array (allocated with `out`). Used for the root agent at startup.
pub fn renderRootTools(
    out: Allocator,
    kind: Provider.Kind,
    specs: []const ToolSpec,
    mcp_tools: []const mcp.Tool,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(out);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    for (specs) |t| {
        if (mcp_schema_gate.hiddenSpec(t.name, mcp_tools) and !native_fold.anyFolded()) continue; // #416: load_tool_schemas hides only with nothing deferred OR folded
        if (native_fold.blocked(t.name)) continue; // zero-stub like the MCP half: folded natives ride the meta tool's listing (#476)
        if (std.mem.eql(u8, t.name, mcp_schema_gate.tool_name))
            try writeToolEntry(&s, kind, t.name, try mcp_schema_gate.descWithListing(out, mcp_tools), .{ .raw = t.schema })
        else
            try writeToolEntry(&s, kind, t.name, t.desc, .{ .raw = t.schema });
    }
    // Deferred tools ship no catalog entries at all (codex tool_search
    // pattern): the meta tool's description lists what exists, exec.zig's
    // layer-2 refusal still guards a call that arrives before its load.
    for (mcp_tools) |m| if (!mcp_schema_gate.isDeferred(mcp_tools, m))
        try writeToolEntry(&s, kind, m.qualified_name, m.description, .{ .value = m.input_schema });
    try s.endArray();
    return aw.toOwnedSlice();
}

/// Root tool catalog for the current session: optional tools are absent unless
/// enabled and usable, avoiding schema tokens for calls that cannot succeed.
/// #330 layer 1, root half: the gate then drops the host-touching tools from
/// whichever catalog was chosen, so they are never advertised to a provider.
/// MCP tools are appended afterwards by renderRootTools and stay untouched.
/// #352 layer 1, root half: the additive gate then appends each optional tool
/// whose backing capability startup actually found on this machine.
pub fn effectiveRootSpecs(arena: Allocator) ![]const ToolSpec {
    const chosen: []const ToolSpec = if (root.g_clock_sleep)
        (if (learn_store.active_agent_loaded) &root_specs else &root_specs_without_learning)
    else
        (if (learn_store.active_agent_loaded) &root_specs_without_clock else &root_specs_without_optional);
    // Optionals are appended BEFORE the #330 filter, never after (optional ≠ exempt); the --lean token filter chains last.
    return no_local_tools.compactLeanSpecs(ToolSpec, arena, try no_local_tools.filterLeanSpecs(ToolSpec, arena, try no_local_tools.filterRootSpecs(ToolSpec, arena, try tool_gates.withAvailable(ToolSpec, arena, chosen, &optional_specs))));
}

const Schema = union(enum) { raw: []const u8, value: Value };

fn writeSchema(s: *std.json.Stringify, schema: Schema) !void {
    switch (schema) {
        .raw => |r| try s.print("{s}", .{r}),
        .value => |v| try s.write(v),
    }
}

fn writeToolEntry(s: *std.json.Stringify, kind: Provider.Kind, name: []const u8, desc: []const u8, schema: Schema) !void {
    switch (kind) {
        .anthropic => {
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("description");
            try s.write(desc);
            try s.objectField("input_schema");
            try writeSchema(s, schema);
            try s.endObject();
        },
        .openai => {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("description");
            try s.write(desc);
            try s.objectField("parameters");
            try writeSchema(s, schema);
            try s.endObject();
            try s.endObject();
        },
        .responses => {
            // Responses API: flat function tool (no nested "function" object).
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("name");
            try s.write(name);
            try s.objectField("description");
            try s.write(desc);
            try s.objectField("parameters");
            try writeSchema(s, schema);
            try s.objectField("strict");
            try s.write(false);
            try s.endObject();
        },
    }
}

/// Version of the `--schema`/`--json` *interface contract*, embedded in
/// generated SDKs. Deliberately not the build version (`harness_version`,
/// a per-commit git describe) — bump this only when the schema or JSONL
/// protocol changes shape, so SDK regeneration stays byte-stable across
/// commits.
pub const schema_version = "0.11"; // #419: session_recap event (one-line session summary + status, heuristic/model)

/// Emit the machine-readable interface description for `harness --schema`:
/// providers, models, built-in tools (name/description/parameters), and the
/// --json protocol contract. This is the single source of truth that SDK
/// codegen consumes. Comptime data only — no keys, network, or MCP needed.
/// Human-facing provider name for the `--schema` providers array (consumed by
/// the GUI settings page so its provider list stays tied to the harness).
fn providerDisplayName(id: []const u8) []const u8 {
    return if (provider_mod.specFor(id)) |spec| spec.display_name else id;
}

/// How a provider's credential is acquired, for the GUI settings page:
/// `codegraff`/`codex` use device/OAuth login flows; everything else is a
/// drop-in API key (env var or `graff key set <id>`).
fn providerLoginKind(id: []const u8) []const u8 {
    return if (provider_mod.specFor(id)) |spec| @tagName(spec.login) else "api_key";
}

/// Whether a model exposes a user-selectable reasoning effort. Kimi maps the
/// setting through its live effort list into `thinking`; the other listed
/// providers use reasoning_effort / Responses reasoning.effort.
/// Grok models reject the hint even through the codegraff gateway, so they are
/// excluded up front (mirrors how opencode gates effort per-model) — the
/// reactive drop-and-retry in request() still covers any other model that
/// turns out to reject it.
pub fn providerTakesEffort(kind: Provider.Kind, id: []const u8, model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "grok")) return false;
    return kind == .responses or
        (std.mem.eql(u8, id, "kimi") and pricing.kimiSupportsThinking(model)) or
        (if (provider_mod.specFor(id)) |spec| spec.takes_effort else false);
}

pub fn emitSchema(w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("harness");
    try s.write("simple-harness");
    try s.objectField("version");
    try s.write(schema_version);
    try s.objectField("providers");
    try s.beginArray();
    for (0..provider_mod.specCount()) |i| {
        const p = provider_mod.specAt(i).?;
        try s.beginObject();
        try s.objectField("id");
        try s.write(p.id);
        try s.objectField("name");
        try s.write(p.display_name);
        try s.objectField("kind");
        try s.write(@tagName(p.kind));
        try s.objectField("auth");
        try s.write(@tagName(p.auth));
        try s.objectField("env_key");
        try s.write(p.env_key);
        try s.objectField("login");
        try s.write(@tagName(p.login));
        try s.objectField("default_model");
        try s.write(p.default_model);
        if (p.catalog == .kimi) {
            try s.objectField("protocol_source");
            try s.write("live_model_catalog");
            try s.objectField("anthropic_auth");
            try s.write("x_api_key");
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("models");
    try s.beginArray();
    for (pricing.models()) |m| {
        try s.beginObject();
        try s.objectField("provider");
        try s.write(m.provider);
        try s.objectField("name");
        try s.write(m.name);
        try s.objectField("context");
        try s.write(m.context);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("dynamic_model_providers");
    try s.beginArray();
    for (0..provider_mod.specCount()) |i| {
        const p = provider_mod.specAt(i).?;
        if (p.catalog != .baked) try s.write(p.id);
    }
    try s.endArray();
    try s.objectField("tools");
    try s.beginArray();
    // Optional tools (#352) are listed unconditionally even though they are
    // advertised only when available: this document is the SDK codegen
    // contract and must stay byte-identical across machines. Each such tool's
    // description states what it needs in order to exist.
    for (root_specs ++ optional_specs) |t| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.name);
        try s.objectField("description");
        try s.write(t.desc);
        try s.objectField("parameters");
        try s.print("{s}", .{t.schema});
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("flags");
    try s.print("{s}", .{schema_flags_json});
    try s.objectField("protocol");
    try s.print("{s}", .{schema_protocol_json});
    try s.objectField("serve");
    try s.print("{s}", .{schema_serve_json});
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();
}
test { // #330/#352: each gate's own tests (advertising, dispatch, env) live with it
    _ = no_local_tools;
    _ = tool_gates;
    _ = render;
}
test "providerDisplayName & providerLoginKind: id mapping with sane fallbacks" {
    try std.testing.expectEqualStrings("OpenAI", providerDisplayName("openai"));
    try std.testing.expectEqualStrings("Codex (ChatGPT)", providerDisplayName("codex"));
    try std.testing.expectEqualStrings("mystery", providerDisplayName("mystery")); // unknown -> echoed id
    try std.testing.expectEqualStrings("codegraff_device", providerLoginKind("codegraff"));
    try std.testing.expectEqualStrings("codex_device", providerLoginKind("codex"));
    try std.testing.expectEqualStrings("kimi_device", providerLoginKind("kimi"));
    try std.testing.expectEqualStrings("api_key", providerLoginKind("openai"));
}
// isMetaName's own coverage, and #381's note_constraint catalog contract,
// live in tool_schema_tests.zig — this file is at the 600-line ceiling.

test "effectiveRootSpecs: drops clock_sleep from the root tool catalog unless the flag is on (#225)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = root.g_clock_sleep;
    const saved_learning = learn_store.active_agent_loaded;
    defer {
        root.g_clock_sleep = saved;
        learn_store.active_agent_loaded = saved_learning;
    }
    learn_store.active_agent_loaded = true;

    root.g_clock_sleep = false;
    const off_specs = try effectiveRootSpecs(a);
    try std.testing.expectEqual(root_specs.len - 1, off_specs.len);
    for (off_specs) |t| try std.testing.expect(!std.mem.eql(u8, t.name, "clock_sleep"));
    try std.testing.expectEqual(@as(usize, 0), arena_state.queryCapacity());

    root.g_clock_sleep = true;
    const on_specs = try effectiveRootSpecs(a);
    try std.testing.expectEqual(root_specs.len, on_specs.len);
    var found = false;
    for (on_specs) |t| {
        if (std.mem.eql(u8, t.name, "clock_sleep")) found = true;
    }
    try std.testing.expect(found);

    root.g_clock_sleep = false;
    learn_store.active_agent_loaded = false;
    const minimal_specs = try effectiveRootSpecs(a);
    try std.testing.expectEqual(root_specs.len - 2, minimal_specs.len);
    for (minimal_specs) |tool| try std.testing.expect(!std.mem.eql(u8, tool.name, "learn_candidate"));
}
test "learn_candidate is root-only and cannot become a subagent tool" {
    var found = false;
    for (root_specs) |tool| if (std.mem.eql(u8, tool.name, "learn_candidate")) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expect(std.mem.indexOf(u8, learn_candidate_spec.desc, "adapters may send it") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_openai_sub, "learn_candidate") == null);
}
test "providerTakesEffort: effort-honoring providers, but never for grok models" {
    try std.testing.expect(providerTakesEffort(.responses, "codex", "gpt-5.5"));
    try std.testing.expect(providerTakesEffort(.openai, "codegraff", "deepseek-v4-pro"));
    try std.testing.expect(providerTakesEffort(.openai, "deepseek", "deepseek-v4-pro"));
    try std.testing.expect(providerTakesEffort(.openai, "kimi", "k3"));
    try std.testing.expect(!providerTakesEffort(.openai, "openai", "gpt-5.5")); // direct openai chat
    try std.testing.expect(!providerTakesEffort(.openai, "xai", "grok-4.3")); // xai not in the list
    // grok via the codegraff gateway must NOT get reasoning_effort (grok rejects it)
    try std.testing.expect(!providerTakesEffort(.openai, "codegraff", "grok-build"));
}
test "agent_output: root-only (subagent/workflow's run_in_background has nothing to poll from inside a child), never doubles as a meta tool" {
    var found_root = false;
    for (root_specs) |t| if (std.mem.eql(u8, t.name, "agent_output")) {
        found_root = true;
    };
    try std.testing.expect(found_root);
    try std.testing.expect(!isMetaName("agent_output")); // dispatched like bash_output, not handled inline

    // Subagents can't spawn subagents (execSubagent's from_sub gate), so they
    // can never mint an agent id to poll — keep it out of their own catalog
    // (tools_anthropic_sub is built from base_specs only).
    try std.testing.expect(std.mem.indexOf(u8, tools_anthropic_sub, "agent_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools_anthropic_sub, "subagent") == null);
}

test "subagent_spec: run_in_background is a boolean, optional (not in required), valid JSON alongside the rest of the schema" {
    try std.testing.expect(std.mem.indexOf(u8, subagent_spec.schema, "\"run_in_background\": {\"type\": \"boolean\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, subagent_spec.schema, .{});
    defer parsed.deinit();
    const required = parsed.value.object.get("required").?.array.items;
    for (required) |r| try std.testing.expect(!std.mem.eql(u8, r.string, "run_in_background"));
}
