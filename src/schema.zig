//! Tool-schema + provider-tool JSON emission: the built-in/meta ToolSpec
//! catalog, the per-provider tool-array renderers (anthropic/openai/responses),
//! and emitSchema (the --schema / `graff serve` /v1/schema document). Split out
//! of main.zig (#123). Back-imports main for Provider (.Kind) and the
//! provider_specs catalog; pulls model_table straight from pricing.zig. main
//! re-exports emitSchema + schema_version so serve.zig stays untouched.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const pricing = @import("pricing.zig");
const model_table = pricing.model_table;
const learn_store = @import("learn_store.zig");

const root = @import("main.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const provider_specs = provider_mod.provider_specs;

/// Documentation of the `--json` stdio protocol, embedded verbatim in
/// `--schema` output so SDK generators/users know the request/event contract.
const schema_protocol_json =
    \\{
    \\  "transport": "newline-delimited JSON over stdin/stdout (--json)",
    \\  "request": "one JSON object per line: {\"type\":\"user\",\"text\":\"...\"} sends a user turn; {\"type\":\"answer\",\"text\":\"...\",\"cancelled\":false,\"call_id\":\"optional\"} answers an active ask_user event; {\"type\":\"set_system_prompt\",\"text\":\"...\",\"append\":false} replaces (or with append=true extends) the system prompt between turns and acks with a system_prompt event; {\"type\":\"set_model\",\"model\":\"gpt-5.5\",\"provider\":\"codex\"}, {\"type\":\"compact\"}, {\"type\":\"set_mode\",\"mode\":\"plan|normal\"}, and {\"type\":\"set_agent\",\"id\":\"reviewer\"}, {\"type\":\"set_effort\",\"level\":\"low|medium|high|xhigh|max|ultra\"}, and {\"type\":\"set_fast\",\"on\":true} are live control requests acked by model/compact/mode/agent/effort/fast/ultracode events. For compatibility, set_model also accepts legacy {\"name\":\"provider model|model\"}. NOTE: the system prompt heads the KV-cached prefix, so any mutation invalidates the cache for the whole conversation (per Manus context-engineering lessons) — set it at spawn when possible and mutate only at task boundaries",
    \\  "score_request": "{\"type\":\"score\",\"prompt_sha\":\"<16 hex>\",\"score\":0.7,\"notes\":\"...\",\"parent_sha\":\"<16 hex, optional>\"} appends an evaluation record for an agent/prompt variant to this run's file under .graff/trajectories (the aggregate append-only DGM-style archive; prompt_sha = first 8 bytes of SHA-256 of the system prompt, hex; parent_sha records which prompt this variant was mutated from — the lineage edge DGM parent selection counts children with) and acks with a score event",
    \\  "events": [
    \\    {"type": "text", "text": "assistant text delta"},
    \\    {"type": "reasoning", "text": "reasoning/thinking delta (GUI shows a collapsible Thinking block)"},
    \\    {"type": "started", "provider": "provider", "model": "model"},
    \\    {"type": "model_call_started", "provider": "provider", "model": "model"},
    \\    {"type": "model_call_finished", "provider": "provider", "model": "model", "ok": true, "ms": 0},
    \\    {"type": "tool_call", "name": "tool", "input": {}},
    \\    {"type": "tool_call_started", "name": "tool", "input": {}},
    \\    {"type": "tool_rejected", "name": "tool", "reason": "budget|duplicate", "input": {}, "message": "..."},
    \\    {"type": "ask_user", "call_id": "...", "question": "...", "input": {"question": "...", "options": ["..."]}},
    \\    {"type": "tool_result", "name": "tool", "is_error": false, "text": "..."},
    \\    {"type": "tool_call_finished", "name": "tool", "is_error": false, "ms": 0},
    \\    {"type": "finalizing"},
    \\    {"type": "turn", "text": "final assistant text", "context_tokens": 0, "cost_usd": 0.0, "complete": true, "metadata_complete": true},
    \\    {"type": "system_prompt", "ok": true, "append": false, "chars": 0},
    \\    {"type": "model", "ok": true, "provider": "provider", "model": "model", "context": 0, "note": "context kept"},
    \\    {"type": "compact", "ok": true, "chars": 0},
    \\    {"type": "mode", "ok": true, "mode": "plan"},
    \\    {"type": "agent", "ok": true, "id": "reviewer", "chars": 0},
    \\    {"type": "effort", "ok": true, "level": "medium", "applies": true},
    \\    {"type": "fast", "ok": true, "on": true, "applies": true},
    \\    {"type": "score", "ok": true, "prompt_sha": "..."},
    \\    {"type": "error", "message": "..."}
    \\  ]
    \\}
;

/// Documentation of the `harness serve` HTTP bridge, embedded verbatim in
/// `--schema` output. Same request/event contract as the stdio protocol —
/// one POST = one protocol request, streamed back as NDJSON until that
/// request's terminal event (turn/error for user turns; the ack for others).
const schema_serve_json =
    \\{
    \\  "transport": "HTTP/1.1 (graff serve, default 127.0.0.1:8787); auth via Authorization: Bearer <token> when --token/HARNESS_SERVE_TOKEN is set (required on non-loopback binds)",
    \\  "endpoints": [
    \\    {"method": "GET", "path": "/healthz", "description": "liveness + version, no auth"},
    \\    {"method": "GET", "path": "/v1/schema", "description": "this schema document"},
    \\    {"method": "POST", "path": "/v1/sessions", "description": "create a session (a graff --json child); optional JSON body {\"model\",\"yolo\",\"system_prompt\",\"append_system_prompt\",\"maxToolCalls\",\"maxModelCalls\",\"dedupeToolCalls\"} overrides serve-level defaults; responds {\"session_id\":\"<16 hex>\"}"},
    \\    {"method": "POST", "path": "/v1/sessions/{id}", "description": "body is ONE stdio-protocol request object (user / set_system_prompt / set_model / compact / set_mode / set_agent / score / answer); non-answer requests stream application/x-ndjson events until the request's terminal event (turn/error, or the request-specific ack); answer requests return JSON ack while the original user stream continues; one non-answer request in flight per session at a time"},
    \\    {"method": "DELETE", "path": "/v1/sessions/{id}", "description": "graceful close: waits for any in-flight request, then EOFs the child's stdin"}
    \\  ]
    \\}
;

/// Launch flags relevant to SDK clients, embedded verbatim in `--schema`
/// output so generated clients can surface them as first-class options.
const schema_flags_json =
    \\[
    \\  {"flag": "--model", "arg": "name", "description": "start on this model (same fuzzy resolution as /model)"},
    \\  {"flag": "--yolo", "arg": null, "description": "skip all permission prompts for the session"},
    \\  {"flag": "--system-prompt", "arg": "text", "description": "replace the built-in system prompt (cwd project-instructions file is still appended)"},
    \\  {"flag": "--append-system-prompt", "arg": "text", "description": "append extra text to the end of the system prompt"},
    \\  {"flag": "--json", "arg": null, "description": "structured stdio protocol (JSON in, JSONL events out)"},
    \\  {"flag": "--max-tool-calls", "arg": "N", "description": "hard per-turn root tool-call budget; rejected calls emit tool_rejected/tool_result"},
    \\  {"flag": "--max-model-calls", "arg": "N", "description": "invocation-wide provider-call ceiling shared by root, subagents, retries, title, compaction, and judges; default 256"},
    \\  {"flag": "--dedupe-tool-calls", "arg": null, "description": "reject duplicate root tool name+normalized-input calls per turn"},
    \\  {"flag": "--no-telemetry", "arg": null, "description": "disable anonymous OTEL usage telemetry for this run"},
    \\  {"flag": "--learning-privacy", "arg": "local|aggregate|templates|examples", "description": "set the prompt-learning egress ceiling; default local, and template text still requires exact interactive approval"}
    \\]
;
const ToolSpec = struct {
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
        .desc = "Run a shell command via /bin/sh -c in the current working directory. Returns stdout, stderr, and the exit code. For long-running commands (dev servers, watchers) set run_in_background true: it returns a job id immediately; poll output with bash_output and stop it with bash_kill.",
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
        .desc = "Replace your task list. Use to plan and track multi-step work. Each item has content and status (pending|in_progress|completed).",
        .schema =
        \\{"type": "object", "properties": {"todos": {"type": "array", "items": {"type": "object", "properties": {"content": {"type": "string"}, "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]}}, "required": ["content", "status"]}}}, "required": ["todos"]}
        ,
    },
    .{
        .name = "todo_read",
        .desc = "Read your current task list.",
        .schema = empty_schema,
    },
    .{
        .name = "eval",
        .desc = "Run the configured scoring command (graff --eval) on the current output and record the result. The HARNESS runs it and logs the score to .graff/eval-log.tsv - do not run the eval command yourself via bash. Returns the score (0-100), best so far, target, and whether the target is met. Call after each focused change in an eval-driven loop. Pass `note` describing what you just changed.",
        .schema =
        \\{"type": "object", "properties": {"note": {"type": "string", "description": "What you changed since the last eval"}}}
        ,
    },
    .{
        .name = "ask_user",
        .desc = "Ask the human a question and wait for their typed reply, which is returned as this tool's result. Use when you need a decision, clarification, or missing information. This routes the human turn through the tool channel — the user is just another tool you can call.",
        .schema =
        \\{"type": "object", "properties": {"question": {"type": "string", "description": "The question to ask the user"}, "options": {"type": "array", "items": {"type": "string"}, "description": "Optional suggested answers, shown numbered"}}, "required": ["question"]}
        ,
    },
    .{
        .name = "attempt_completion",
        .desc = "Signal that the task is complete. Put your final answer to the user in the result field. In strict mode this is the only way to end a turn.",
        .schema =
        \\{"type": "object", "properties": {"result": {"type": "string", "description": "Final answer to present to the user"}}, "required": ["result"]}
        ,
    },
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
    .desc = "Delegate a self-contained task to a subagent. It has bash, read_file, edit_file, write_file, and codedb (code search); it cannot spawn further subagents and does NOT share your context — the prompt must be self-contained. Returns the subagent final report. Call several times in one response to run tasks in parallel. Pick a persona with agent (builtins: reviewer, researcher, implementer, skeptic — plus any in .harness/agents/), or give the child a custom system_prompt; the trajectory log records the lineage either way.",
    .schema =
    \\{"type": "object", "properties": {"description": {"type": "string", "description": "Short label for logs, 3-5 words"}, "prompt": {"type": "string", "description": "Complete, self-contained task description"}, "agent": {"type": "string", "description": "Optional: a named agent type (reviewer, researcher, implementer, skeptic, or a .harness/agents/ name) whose persona the child runs with"}, "system_prompt": {"type": "string", "description": "Optional: replace the child's system prompt with a custom one (overrides agent)"}}, "required": ["description", "prompt"]}
    ,
};

const workflow_spec = ToolSpec{
    .name = "workflow",
    .desc = "Run a workflow of parallel subagents (dynamic workflows as data). Two shapes. PHASES (fan-out + synthesis): phases run sequentially; tasks inside a phase run in parallel as isolated subagents with no shared context, so every prompt must be self-contained; from phase 2 on, {{prev}} in a task prompt is replaced with the labeled results of the previous phase (appended if omitted); a phase may carry `when` to run only if a substring appears in {{prev}} (conditional / early-exit). Returns the final phase results. Use for audits, multi-perspective review, parallel research. Tasks may carry their own system_prompt to run prompt variants side by side; when the fleet is on, a phase with 2+ variants is auto-scored by an LLM judge and each variant's fitness feeds back to the fleet (a tournament doubles as a DGM scoring round). PIPELINE (no barrier): pass {pipeline:{items,stages}} instead to map each item through the stages independently — item A can reach stage 3 while item B is still on stage 1; {{item}} is the item and {{prev}} is this item's previous-stage result. Use for per-item work like transform/verify each file.",
    .schema =
    \\{"type": "object", "properties": {"phases": {"type": "array", "description": "Fan-out + synthesis mode (barrier between phases).", "items": {"type": "object", "properties": {"title": {"type": "string", "description": "Short phase label for logs"}, "when": {"type": "string", "description": "Optional (phase 2+): run this phase only if this substring appears (case-insensitive) in the previous phase's results — gate a synthesis/exit phase on a sentinel"}, "tasks": {"type": "array", "items": {"type": "object", "properties": {"description": {"type": "string", "description": "Short label, 3-5 words"}, "prompt": {"type": "string", "description": "Complete, self-contained task; may contain {{prev}}"}, "agent": {"type": "string", "description": "Optional: a named agent type (reviewer, researcher, implementer, skeptic, or a .harness/agents/ name)"}, "system_prompt": {"type": "string", "description": "Optional: replace this task's system prompt (overrides agent)"}}, "required": ["description", "prompt"]}}}, "required": ["tasks"]}}, "pipeline": {"type": "object", "description": "No-barrier mode: map each item through the stages independently.", "properties": {"items": {"type": "array", "items": {"type": "string"}, "description": "Things to process, one independent chain each (e.g. file paths)"}, "stages": {"type": "array", "items": {"type": "object", "properties": {"description": {"type": "string", "description": "Short stage label"}, "prompt": {"type": "string", "description": "Self-contained; {{item}} = the item, {{prev}} = this item's previous-stage result"}, "agent": {"type": "string", "description": "Optional named agent type"}, "system_prompt": {"type": "string", "description": "Optional: replace this stage's system prompt"}}, "required": ["description", "prompt"]}}}, "required": ["items", "stages"]}}}
    ,
};

const learn_candidate_spec = ToolSpec{
    .name = "learn_candidate",
    .desc = "Bundle the workspace's pinned prompt-policy mutation, paired evaluation, immutable evidence, and signed aggregate grade submission into one action. Grade telemetry excludes prompt/genome text, but configured adapters may send it to their declared model provider. In Local privacy mode this requires a separate one-shot confirmation that --yolo cannot bypass; Aggregate or higher uses normal tool approval. This never promotes or changes the active policy and is root-only.",
    .schema =
    \\{"type": "object", "properties": {"candidates": {"type": "integer", "minimum": 1, "maximum": 16, "description": "Optional candidate count; defaults to the learning config"}, "repetitions": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Optional repetitions per evaluation case; defaults to the learning config"}}}
    ,
};

pub const root_specs = base_specs ++ meta_specs ++ [_]ToolSpec{ subagent_spec, workflow_spec, learn_candidate_spec };

// The common catalog (clock_sleep off) is static too. Previously every root
// startup allocated and filled a filtered ToolSpec array before rendering even
// one provider catalog.
const root_specs_without_clock = blk: {
    var out: [root_specs.len - 1]ToolSpec = undefined;
    var len: usize = 0;
    for (root_specs) |tool| {
        if (std.mem.eql(u8, tool.name, "clock_sleep")) continue;
        out[len] = tool;
        len += 1;
    }
    if (len != out.len) @compileError("root tool catalog must contain exactly one clock_sleep entry");
    break :blk out;
};

const root_specs_without_learning = blk: {
    var out: [root_specs.len - 1]ToolSpec = undefined;
    var len: usize = 0;
    for (root_specs) |tool| {
        if (std.mem.eql(u8, tool.name, "learn_candidate")) continue;
        out[len] = tool;
        len += 1;
    }
    if (len != out.len) @compileError("root tool catalog must contain exactly one learn_candidate entry");
    break :blk out;
};

const root_specs_without_optional = blk: {
    var out: [root_specs.len - 2]ToolSpec = undefined;
    var len: usize = 0;
    for (root_specs) |tool| {
        if (std.mem.eql(u8, tool.name, "clock_sleep") or std.mem.eql(u8, tool.name, "learn_candidate")) continue;
        out[len] = tool;
        len += 1;
    }
    if (len != out.len) @compileError("root tool catalog optional entries changed");
    break :blk out;
};

pub fn isMetaName(name: []const u8) bool {
    return std.mem.eql(u8, name, "todo_write") or
        std.mem.eql(u8, name, "todo_read") or
        std.mem.eql(u8, name, "ask_user") or
        std.mem.eql(u8, name, "eval") or
        std.mem.eql(u8, name, "attempt_completion") or
        std.mem.eql(u8, name, "clock_sleep");
}

// Comptime-rendered tool lists for subagents (base only, both formats).
pub const tools_anthropic_sub = anthropicToolsJson(&base_specs);
pub const tools_openai_sub = openaiToolsJson(&base_specs);
pub const tools_responses_sub = responsesToolsJson(&base_specs);

fn anthropicToolsJson(comptime specs: []const ToolSpec) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"name\":\"" ++ t.name ++ "\",\"description\":\"" ++ t.desc ++
                "\",\"input_schema\":" ++ t.schema ++ "}";
        }
        return out ++ "]";
    }
}

fn openaiToolsJson(comptime specs: []const ToolSpec) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"type\":\"function\",\"function\":{\"name\":\"" ++ t.name ++
                "\",\"description\":\"" ++ t.desc ++ "\",\"parameters\":" ++ t.schema ++ "}}";
        }
        return out ++ "]";
    }
}

fn responsesToolsJson(comptime specs: []const ToolSpec) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (specs, 0..) |t, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"type\":\"function\",\"name\":\"" ++ t.name ++
                "\",\"description\":\"" ++ t.desc ++ "\",\"parameters\":" ++ t.schema ++
                ",\"strict\":false}";
        }
        return out ++ "]";
    }
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
    for (specs) |t| try writeToolEntry(&s, kind, t.name, t.desc, .{ .raw = t.schema });
    for (mcp_tools) |m| try writeToolEntry(&s, kind, m.qualified_name, m.description, .{ .value = m.input_schema });
    try s.endArray();
    return aw.toOwnedSlice();
}

/// Root tool catalog for the current session: optional tools are absent unless
/// enabled and usable, avoiding schema tokens for calls that cannot succeed.
pub fn effectiveRootSpecs(arena: Allocator) ![]const ToolSpec {
    _ = arena;
    if (root.g_clock_sleep) return if (learn_store.active_agent_loaded) &root_specs else &root_specs_without_learning;
    return if (learn_store.active_agent_loaded) &root_specs_without_clock else &root_specs_without_optional;
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
pub const schema_version = "0.6";

/// Emit the machine-readable interface description for `harness --schema`:
/// providers, models, built-in tools (name/description/parameters), and the
/// --json protocol contract. This is the single source of truth that SDK
/// codegen consumes. Comptime data only — no keys, network, or MCP needed.
/// Human-facing provider name for the `--schema` providers array (consumed by
/// the GUI settings page so its provider list stays tied to the harness).
fn providerDisplayName(id: []const u8) []const u8 {
    const names = .{
        .{ "codegraff", "Codegraff" },   .{ "anthropic", "Anthropic" },
        .{ "deepseek", "DeepSeek" },     .{ "openai", "OpenAI" },
        .{ "minimax", "MiniMax" },       .{ "xiaomi", "Xiaomi" },
        .{ "kimi", "Kimi" },             .{ "xai", "xAI" },
        .{ "moonshot", "Moonshot" },     .{ "zai", "Z.AI" },
        .{ "codex", "Codex (ChatGPT)" },
    };
    inline for (names) |n| {
        if (std.mem.eql(u8, id, n[0])) return n[1];
    }
    return id;
}

/// How a provider's credential is acquired, for the GUI settings page:
/// `codegraff`/`codex` use device/OAuth login flows; everything else is a
/// drop-in API key (env var or `graff key set <id>`).
fn providerLoginKind(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "codegraff")) return "codegraff_device";
    if (std.mem.eql(u8, id, "codex")) return "codex_device";
    if (std.mem.eql(u8, id, "kimi")) return "kimi_device";
    return "api_key";
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
        std.mem.eql(u8, id, "codegraff") or
        std.mem.eql(u8, id, "deepseek");
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
    for (provider_specs) |p| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(p.id);
        try s.objectField("name");
        try s.write(providerDisplayName(p.id));
        try s.objectField("kind");
        try s.write(@tagName(p.kind));
        try s.objectField("auth");
        try s.write(@tagName(p.auth));
        try s.objectField("env_key");
        try s.write(p.env_key);
        try s.objectField("login");
        try s.write(providerLoginKind(p.id));
        try s.objectField("default_model");
        try s.write(p.default_model);
        if (std.mem.eql(u8, p.id, "kimi")) {
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
    for (model_table) |m| {
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
    try s.write("codex");
    try s.write("kimi");
    try s.endArray();
    try s.objectField("tools");
    try s.beginArray();
    for (root_specs) |t| {
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
test "providerDisplayName & providerLoginKind: id mapping with sane fallbacks" {
    try std.testing.expectEqualStrings("OpenAI", providerDisplayName("openai"));
    try std.testing.expectEqualStrings("Codex (ChatGPT)", providerDisplayName("codex"));
    try std.testing.expectEqualStrings("mystery", providerDisplayName("mystery")); // unknown -> echoed id
    try std.testing.expectEqualStrings("codegraff_device", providerLoginKind("codegraff"));
    try std.testing.expectEqualStrings("codex_device", providerLoginKind("codex"));
    try std.testing.expectEqualStrings("kimi_device", providerLoginKind("kimi"));
    try std.testing.expectEqualStrings("api_key", providerLoginKind("openai"));
}
test "isMetaName: the five orchestrator-handled meta tools" {
    try std.testing.expect(isMetaName("todo_write"));
    try std.testing.expect(isMetaName("todo_read"));
    try std.testing.expect(isMetaName("ask_user"));
    try std.testing.expect(isMetaName("attempt_completion"));
    try std.testing.expect(isMetaName("clock_sleep"));
    try std.testing.expect(!isMetaName("bash"));
    try std.testing.expect(!isMetaName("subagent"));
    try std.testing.expect(!isMetaName("codedb"));
}

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
