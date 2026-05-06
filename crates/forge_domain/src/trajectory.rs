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
