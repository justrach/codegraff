use serde::{Deserialize, Serialize};

use crate::ToolName;

/// One observable event from a (sub)agent's run.
///
/// Trajectory events are recorded into the `trajectory_events` SQLite table
/// alongside the conversation context blob, but indexed and queryable by
/// `(conversation_id, agent_id, seq)` so subagents can be inspected
/// independently of their parent.
///
/// `seq` is monotonically increasing per `(conversation_id, agent_id)` —
/// the recorder is responsible for assigning it; the repo persists whatever
/// it gets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrajectoryEvent {
    pub conversation_id: String,
    pub agent_id: String,
    pub parent_agent_id: Option<String>,
    pub seq: i32,
    pub ts_ms: i64,
    pub payload: TrajectoryPayload,
}

/// Kind-specific payload. Serialized to JSON in the SQLite `payload` column;
/// the SQL `kind` column mirrors the variant tag for index-friendly lookups
/// without needing to parse JSON.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TrajectoryPayload {
    /// Recorded immediately before a tool is invoked.
    ToolCall {
        tool_name: ToolName,
        /// Stable identifier for matching `ToolCall` to its `ToolResult`.
        call_id: String,
        /// Tool arguments as the model sent them.
        arguments: serde_json::Value,
    },
    /// Recorded after the tool returns (whether ok or error).
    ToolResult {
        tool_name: ToolName,
        /// Matches the `call_id` from the corresponding `ToolCall`.
        call_id: String,
        /// True when the tool itself signaled failure.
        is_error: bool,
        /// Tool output serialized to JSON for inspection.
        output: serde_json::Value,
    },
    /// Recorded when the orchestrator catches an error not tied to a single
    /// tool call (e.g. a model API failure, a budget exceeded).
    Error { message: String, source: Option<String> },
    /// Optional bookend event marking a model-turn boundary. Useful when
    /// reading a trajectory to know which tool calls came from which turn.
    ModelTurn { turn: i32 },
    /// Recorded the moment a (sub)agent's chat run starts, capturing the
    /// agent identity and the model that was actually selected — including
    /// the diagnostic round-trip for `model_override`:
    ///   - `requested_model` is what the caller asked for (if anything),
    ///   - `resolved_model` is what the orchestrator ended up using.
    ///
    /// When these differ (or `requested_model` is `None`), it pins down
    /// whether a Task-tool override was honoured, normalised, or ignored —
    /// without having to grep streaming tool-call logs. Fires for both
    /// top-level chats (parent_agent_id None) and Task-spawned subagents
    /// (parent_agent_id Some), so the variant covers any agent run start.
    AgentRun {
        agent_id: String,
        parent_agent_id: Option<String>,
        requested_model: Option<String>,
        resolved_model: String,
        /// Stable hash of the agent's definition (frontmatter + body) at the
        /// moment of the spawn. Lets a /trace or rollup query group runs by
        /// the *exact* agent variant — distinct from `agent_id` because two
        /// edits to `forge.md` are still both `forge` but produce different
        /// hashes. None when hashing fails or isn't available.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agent_version: Option<String>,
    },
    /// Recorded when an agent run terminates. Carries the per-spawn fitness
    /// vector — turns, tokens, tool-call counts, errors, wall-clock — so a
    /// rollup over `(agent_id, agent_version)` reveals which variants are
    /// efficient vs wasteful. Pairs with `AgentRun` via being the matching
    /// "end" event for the most recent agent_run on this conversation+agent.
    ///
    /// This is the substrate for Darwin-Gödel-Machine-style sampling: an
    /// archive of agents whose fitness is observed empirically rather than
    /// guessed. No mutation logic lives here yet — just the observation.
    AgentRunEnd {
        /// Run completed without an Interrupt or hard error.
        success: bool,
        /// Number of model requests issued during the run (turns).
        turns: u32,
        /// Sum of `prompt_tokens` across all assistant messages observed.
        prompt_tokens: u64,
        /// Sum of `completion_tokens` across all assistant messages observed.
        completion_tokens: u64,
        /// Total tool calls dispatched by the orchestrator during the run.
        tool_calls: u32,
        /// Tool calls whose result.is_error was true.
        tool_errors: u32,
        /// Wall-clock duration of the run in milliseconds.
        wall_ms: i64,
        /// Set when the run terminated with an Interrupt or surface error;
        /// short string so /trace can render it without parsing the payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        interrupt_reason: Option<String>,
    },
}

impl TrajectoryPayload {
    /// Wire-stable kind discriminator written to the SQLite `kind` column.
    /// Must match the serde rename above so JSON `kind` and SQL `kind` agree.
    pub fn kind(&self) -> &'static str {
        match self {
            TrajectoryPayload::ToolCall { .. } => "tool_call",
            TrajectoryPayload::ToolResult { .. } => "tool_result",
            TrajectoryPayload::Error { .. } => "error",
            TrajectoryPayload::ModelTurn { .. } => "model_turn",
            TrajectoryPayload::AgentRun { .. } => "agent_run",
            TrajectoryPayload::AgentRunEnd { .. } => "agent_run_end",
        }
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;
    use serde_json::json;

    use super::*;

    #[test]
    fn payload_kind_matches_serde_tag() {
        // Lock in the invariant that `kind()` (used for the SQL column)
        // agrees with the `#[serde(tag = "kind")]` rename. If these diverge,
        // queries like `SELECT WHERE kind = 'tool_call'` silently miss rows.
        let cases = vec![
            (
                TrajectoryPayload::ToolCall {
                    tool_name: ToolName::new("read"),
                    call_id: "c1".into(),
                    arguments: json!({}),
                },
                "tool_call",
            ),
            (
                TrajectoryPayload::ToolResult {
                    tool_name: ToolName::new("read"),
                    call_id: "c1".into(),
                    is_error: false,
                    output: json!({}),
                },
                "tool_result",
            ),
            (
                TrajectoryPayload::Error { message: "boom".into(), source: None },
                "error",
            ),
            (TrajectoryPayload::ModelTurn { turn: 1 }, "model_turn"),
            (
                TrajectoryPayload::AgentRun {
                    agent_id: "forge".into(),
                    parent_agent_id: Some("forge".into()),
                    requested_model: Some("gpt-5.5".into()),
                    resolved_model: "gpt-5.5".into(),
                    agent_version: Some("blake3:abc123".into()),
                },
                "agent_run",
            ),
            (
                TrajectoryPayload::AgentRunEnd {
                    success: true,
                    turns: 3,
                    prompt_tokens: 1000,
                    completion_tokens: 200,
                    tool_calls: 5,
                    tool_errors: 0,
                    wall_ms: 1234,
                    interrupt_reason: None,
                },
                "agent_run_end",
            ),
        ];
        for (payload, expected_kind) in cases {
            let serialized = serde_json::to_value(&payload).unwrap();
            assert_eq!(payload.kind(), expected_kind, "kind() returns wire string");
            assert_eq!(
                serialized.get("kind").and_then(|v| v.as_str()),
                Some(expected_kind),
                "serde tag matches kind() for {expected_kind}"
            );
        }
    }
}
