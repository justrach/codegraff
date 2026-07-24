//! Embedded documentation for Graff's newline-delimited JSON protocol.

pub const json =
    \\{
    \\  "transport": "newline-delimited JSON over stdin/stdout (--json)",
    \\  "request": "one JSON object per line: {\"type\":\"user\",\"text\":\"...\"} sends a user turn; {\"type\":\"review\",\"text\":\"target or instructions\"} runs one isolated read-only review turn with fresh model-visible history and no edits, delegation, workflows, or web access; {\"type\":\"answer\",\"text\":\"...\",\"cancelled\":false,\"call_id\":\"optional\"} answers an active ask_user event; {\"type\":\"set_system_prompt\",\"text\":\"...\",\"append\":false} replaces (or with append=true extends) the system prompt between turns and acks with a system_prompt event; {\"type\":\"set_model\",\"model\":\"gpt-5.5\",\"provider\":\"codex\"}, {\"type\":\"compact\"}, {\"type\":\"set_mode\",\"mode\":\"plan|normal\"}, and {\"type\":\"set_agent\",\"id\":\"reviewer\"}, {\"type\":\"set_effort\",\"level\":\"low|medium|high|xhigh|max|ultra\"}, and {\"type\":\"set_fast\",\"on\":true} are live control requests acked by model/compact/mode/agent/effort/fast/ultracode events. For compatibility, set_model also accepts legacy {\"name\":\"provider model|model\"}. NOTE: the system prompt heads the KV-cached prefix, so any mutation invalidates the cache for the whole conversation (per Manus context-engineering lessons) — set it at spawn when possible and mutate only at task boundaries",
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
    \\    {"type": "agent_usage", "id": "sa-...", "ok": true, "duration_ms": 0, "tool_calls": 0, "context_tokens": 0, "cache_read_tokens": 0},
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
