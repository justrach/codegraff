//! Embedded documentation for Graff's newline-delimited JSON protocol, plus
//! the launch-flag list `--schema` publishes alongside it (schema.zig aliases
//! both back; they live here to keep schema.zig under the 600-line ceiling).

/// Launch flags relevant to SDK clients, embedded verbatim in `--schema`
/// output so generated clients can surface them as first-class options.
/// Pinned against learning_privacy.default_mode by a test there: the SDKs are
/// generated from this text, so a stale default here is a promise the binary
/// does not keep.
pub const flags =
    \\[
    \\  {"flag": "--model", "arg": "name", "description": "start on this model (same fuzzy resolution as /model)"},
    \\  {"flag": "--subagent-model", "arg": "name", "description": "pin direct subagents, workflow workers/retries, and judges to this model on the root provider; GRAFF_SUBAGENT_MODEL is the lower-precedence equivalent; overrides the default tier ladder"},
    \\  {"flag": "--subagent-provider", "arg": "id", "description": "route pinned workers through this explicit provider; GRAFF_SUBAGENT_PROVIDER is the lower-precedence equivalent"},
    \\  {"flag": "--allow-cross-provider-subagents", "arg": null, "description": "explicitly consent to sending worker prompts, code, and tool results to a provider different from the root"},
    \\  {"flag": "--no-subagent-tier", "arg": null, "description": "opt out of the default worker tier ladder; workers inherit the root model unless an explicit --subagent-model is given"},
    \\  {"flag": "--yolo", "arg": null, "description": "skip all permission prompts for the session"},
    \\  {"flag": "--lean", "arg": null, "description": "slim the tool surface to 8 core tools and connect MCP servers DEFERRED behind the load_tool_schemas meta tool (names + one-line descriptions up front, full schemas on demand) instead of paying every server's schemas in every model turn. DEFAULT for -p one-shots; GRAFF_LEAN=1 forces it on anywhere"},
    \\  {"flag": "--no-lean", "arg": null, "description": "opt a one-shot out of the implied --lean: full tool surface and eager MCP schemas, the pre-default -p behavior"},
    \\  {"flag": "--add-dir", "arg": "path", "description": "extra workspace root file tools may touch (repeatable, max 16). Complementary to workspace switch; extra roots do not contribute skills or sessions"},
    \\  {"flag": "--context-limit", "arg": "name=N", "description": "named prefix byte cap: skill_catalog_bytes, mcp_schema_bytes, or agents_md_bytes (repeatable). GRAFF_CONTEXT_LIMIT is the env form"},
    \\  {"flag": "--no-local-tools", "arg": null, "description": "embedder mode: hard-disable the built-in bash/bash_output/bash_kill/read_file/edit_file/write_file/codedb tools for the whole process, so the harness can run outside the sandbox and source its coding tools from an MCP server instead; webfetch, orchestration and MCP tools are unaffected, and subagents inherit the gate. GRAFF_NO_LOCAL_TOOLS=1 is the equivalent"},
    \\  {"flag": "--system-prompt", "arg": "text", "description": "replace the built-in system prompt (cwd project-instructions file is still appended)"},
    \\  {"flag": "--append-system-prompt", "arg": "text", "description": "append extra text to the end of the system prompt"},
    \\  {"flag": "--json", "arg": null, "description": "structured stdio protocol (JSON in, JSONL events out)"},
    \\  {"flag": "--max-tool-calls", "arg": "N", "description": "hard per-turn root tool-call budget; rejected calls emit tool_rejected/tool_result"},
    \\  {"flag": "--max-model-calls", "arg": "N", "description": "opt-in invocation-wide provider-call ceiling shared by root, review, subagents, retries, title, compaction, and judges; default unlimited"},
    \\  {"flag": "--dedupe-tool-calls", "arg": null, "description": "reject duplicate root tool name+normalized-input calls per turn"},
    \\  {"flag": "--no-telemetry", "arg": null, "description": "disable anonymous OTEL usage telemetry for this run"},
    \\  {"flag": "--learning-privacy", "arg": "local|aggregate|templates|examples", "description": "set the prompt-learning egress ceiling; default aggregate (signed prompt-free grades), local sends nothing, and template text still requires exact interactive approval"}
    \\]
;

pub const json =
    \\{
    \\  "transport": "newline-delimited JSON over stdin/stdout (--json)",
    \\  "request": "one JSON object per line: {\"type\":\"user\",\"text\":\"...\"} sends a user turn; {\"type\":\"review\",\"text\":\"target or instructions\"} runs one isolated read-only review turn with fresh model-visible history and no edits, delegation, workflows, or web access; {\"type\":\"answer\",\"text\":\"...\",\"cancelled\":false,\"call_id\":\"optional\"} answers an active ask_user event; {\"type\":\"cancel\"} interrupts an active turn; {\"type\":\"set_system_prompt\",\"text\":\"...\",\"append\":false} replaces (or with append=true extends) the system prompt between turns and acks with a system_prompt event; {\"type\":\"set_model\",\"model\":\"gpt-5.5\",\"provider\":\"codex\"}, {\"type\":\"compact\"}, {\"type\":\"set_mode\",\"mode\":\"plan|normal\"}, and {\"type\":\"set_agent\",\"id\":\"reviewer\"}, {\"type\":\"set_effort\",\"level\":\"low|medium|high|xhigh|max|ultra\"}, {\"type\":\"set_fast\",\"on\":true}, and {\"type\":\"set_ultracode\",\"on\":true} are live control requests acked by model/compact/mode/agent/effort/fast/ultracode events. For compatibility, set_model also accepts legacy {\"name\":\"provider model|model\"}. NOTE: the system prompt heads the KV-cached prefix, so any mutation invalidates the cache for the whole conversation (per Manus context-engineering lessons) — set it at spawn when possible and mutate only at task boundaries",
    \\  "score_request": "{\"type\":\"score\",\"prompt_sha\":\"<16 hex>\",\"score\":0.7,\"notes\":\"...\",\"parent_sha\":\"<16 hex, optional>\"} appends an evaluation record for an agent/prompt variant to this run's file under .graff/trajectories (the aggregate append-only DGM-style archive; prompt_sha = first 8 bytes of SHA-256 of the system prompt, hex; parent_sha records which prompt this variant was mutated from — the lineage edge DGM parent selection counts children with) and acks with a score event",
    \\  "sequencing": "every event object below carries a monotonic per-session \"seq\" as its FIRST field: 1-based, gap-free, one id per emitted line. It survives a resume - the counter is persisted with the conversation as event_seq and restored by --resume, so a REPLACEMENT process continues the numbering instead of reissuing ids a consumer already saw. `graff serve` forwards the child's seq unchanged and uses it for ?from=N replay",
    \\  "events": [
    \\    {"type": "text", "text": "assistant text delta"},
    \\    {"type": "reasoning", "text": "reasoning/thinking delta (GUI shows a collapsible Thinking block)"},
    \\    {"type": "started", "provider": "provider", "model": "model"},
    \\    {"type": "model_call_started", "provider": "provider", "model": "model"},
    \\    {"type": "model_call_finished", "provider": "provider", "model": "model", "ok": true, "ms": 0},
    \\    {"type": "tool_call", "name": "tool", "input": {}, "id": "sa-… on workflow subagent rows only; pairs with tool_result/agent_usage"},
    \\    {"type": "tool_call_started", "name": "tool", "input": {}},
    \\    {"type": "tool_rejected", "name": "tool", "reason": "budget|duplicate", "input": {}, "message": "..."},
    \\    {"type": "ask_user", "call_id": "...", "question": "...", "input": {"question": "...", "options": ["..."]}},
    \\    {"type": "tool_result", "name": "tool", "is_error": false, "text": "...", "id": "sa-… on workflow subagent rows only"},
    \\    {"type": "tool_call_finished", "name": "tool", "is_error": false, "ms": 0},
    \\    {"type": "agent_usage", "id": "sa-...", "ok": true, "duration_ms": 0, "tool_calls": 0, "context_tokens": 0, "cache_read_tokens": 0},
    \\    {"type": "finalizing"},
    \\    {"type": "session_recap", "text": "one-line session summary", "status": "needs_input|completed|failed", "source": "heuristic|model (heuristic precedes every completed turn's terminal event; a model recap may follow later)"},
    \\    {"type": "turn", "text": "final assistant text", "context_tokens": 0, "cost_usd": 0.0, "input_tokens": 0, "uncached_input_tokens": 0, "cache_read_tokens": 0, "output_tokens": 0, "api_calls": 0, "subscription_calls": 0, "unpriced_calls": 0, "complete": true, "metadata_complete": true},
    \\    {"type": "system_prompt", "ok": true, "append": false, "chars": 0},
    \\    {"type": "model", "ok": true, "provider": "provider", "model": "model", "context": 0, "note": "context kept"},
    \\    {"type": "compact", "ok": true, "chars": 0},
    \\    {"type": "mode", "ok": true, "mode": "plan"},
    \\    {"type": "agent", "ok": true, "id": "reviewer", "chars": 0},
    \\    {"type": "effort", "ok": true, "level": "medium", "applies": true},
    \\    {"type": "fast", "ok": true, "on": true, "applies": true},
    \\    {"type": "ultracode", "ok": true, "on": true},
    \\    {"type": "score", "ok": true, "prompt_sha": "..."},
    \\    {"type": "error", "message": "..."}
    \\  ]
    \\}
;
