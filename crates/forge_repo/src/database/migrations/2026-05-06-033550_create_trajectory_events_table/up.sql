-- Trajectory events: per-tool-call observability for (sub)agent runs.
--
-- Each row records one observable event from an agent's run — a tool call,
-- its result, an error, or a model turn boundary. Scoped by
-- (conversation_id, agent_id) so subagent runs are addressable independently
-- of the parent conversation's opaque context blob.
--
-- Intentionally NOT foreign-keyed to `conversations(conversation_id)`:
-- trajectory rows are debug telemetry that should survive conversation
-- deletion, and the `(conversation_id, agent_id, seq)` index already gives
-- us efficient lookups.
CREATE TABLE IF NOT EXISTS trajectory_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    parent_agent_id TEXT,
    seq INTEGER NOT NULL,
    ts_ms BIGINT NOT NULL,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_trajectory_lookup
    ON trajectory_events(conversation_id, agent_id, seq);
