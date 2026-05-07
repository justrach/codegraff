use std::sync::Arc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use forge_domain::{
    ToolCallFull, ToolName, ToolResult, TrajectoryEvent, TrajectoryPayload, ToolValue,
};

use crate::TrajectoryRepo;

/// Sidecar that records one row per (sub)agent observable event into the
/// `trajectory_events` SQLite table.
///
/// The recorder owns:
///   - the `(conversation_id, agent_id, parent_agent_id)` scoping
///   - a monotonically increasing `seq` counter so reads observe the same
///     ordering the agent saw, even under concurrent writes
///
/// Recording is **best-effort**: every persistence call swallows errors and
/// emits a `tracing::warn!`. The orchestrator must never abort an agent run
/// because telemetry failed.
pub struct TrajectoryRecorder {
    repo: Arc<dyn TrajectoryRepo>,
    conversation_id: String,
    agent_id: String,
    parent_agent_id: Option<String>,
    seq: AtomicI32,
}

impl TrajectoryRecorder {
    pub fn new(
        repo: Arc<dyn TrajectoryRepo>,
        conversation_id: impl Into<String>,
        agent_id: impl Into<String>,
        parent_agent_id: Option<String>,
        initial_seq: i32,
    ) -> Self {
        Self {
            repo,
            conversation_id: conversation_id.into(),
            agent_id: agent_id.into(),
            parent_agent_id,
            seq: AtomicI32::new(initial_seq),
        }
    }
    /// "1" / "true" / "yes" enables it; everything else (including unset)
    /// disables. Callers should skip constructing the recorder when this
    /// returns false.
    pub fn enabled_from_env() -> bool {
        std::env::var("CODEGRAFF_TRACE")
            .ok()
            .map(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
            .unwrap_or(false)
    }

    /// Record a tool call about to be invoked. Returns the assigned `seq`
    /// so the caller can match the corresponding `record_tool_result`.
    pub async fn record_tool_call(&self, tool_call: &ToolCallFull) -> i32 {
        let seq = self.next_seq();
        let event = self.build_event(
            seq,
            TrajectoryPayload::ToolCall {
                tool_name: tool_call.name.clone(),
                call_id: tool_call_id(tool_call),
                arguments: tool_call
                    .arguments
                    .parse()
                    .unwrap_or(serde_json::Value::Null),
            },
        );
        self.persist(event).await;
        seq
    }

    /// Record a tool's result.
    pub async fn record_tool_result(&self, tool_call: &ToolCallFull, result: &ToolResult) {
        let seq = self.next_seq();
        let event = self.build_event(
            seq,
            TrajectoryPayload::ToolResult {
                tool_name: tool_call.name.clone(),
                call_id: tool_call_id(tool_call),
                is_error: tool_result_is_error(result),
                output: tool_result_output_to_json(result),
            },
        );
        self.persist(event).await;
    }

    /// Record the moment a (sub)agent chat run starts. Captures both the
    /// `requested_model` (whatever a Task-tool model override asked for, if
    /// anything) and the `resolved_model` actually used after validation
    /// against the agent's authenticated provider. Reading `/trace` then
    /// shows whether the override was honoured verbatim, normalised by the
    /// model list, or ignored — the diagnostic ground-truth for issues like
    /// "did the model id silently change between TaskInput and the run?"
    pub async fn record_agent_run(
        &self,
        requested_model: Option<String>,
        resolved_model: impl Into<String>,
        agent_version: Option<String>,
    ) {
        let seq = self.next_seq();
        let event = self.build_event(
            seq,
            TrajectoryPayload::AgentRun {
                agent_id: self.agent_id.clone(),
                parent_agent_id: self.parent_agent_id.clone(),
                requested_model,
                resolved_model: resolved_model.into(),
                agent_version,
            },
        );
        self.persist(event).await;
    }

    /// Record the end-of-run fitness vector for this (sub)agent. Pairs with
    /// the most recent `record_agent_run` on the same recorder. The fields
    /// are intentionally cheap aggregates (counts, sums, durations) so a
    /// rollup query over `(agent_id, agent_version)` can compute mean
    /// turns / success rate / tokens-per-success without re-walking the
    /// full event stream — i.e. the substrate for an empirical archive of
    /// agent variants à la Darwin Gödel Machine.
    #[allow(clippy::too_many_arguments)]
    pub async fn record_agent_run_end(
        &self,
        success: bool,
        turns: u32,
        prompt_tokens: u64,
        completion_tokens: u64,
        tool_calls: u32,
        tool_errors: u32,
        wall_ms: i64,
        interrupt_reason: Option<String>,
    ) {
        let seq = self.next_seq();
        let event = self.build_event(
            seq,
            TrajectoryPayload::AgentRunEnd {
                success,
                turns,
                prompt_tokens,
                completion_tokens,
                tool_calls,
                tool_errors,
                wall_ms,
                interrupt_reason,
            },
        );
        self.persist(event).await;
    }

    /// Record an orchestrator-level error not tied to a single tool call
    /// (model API failure, budget exceeded, etc.).
    pub async fn record_error(&self, message: impl Into<String>, source: Option<String>) {
        let seq = self.next_seq();
        let event = self.build_event(
            seq,
            TrajectoryPayload::Error { message: message.into(), source },
        );
        self.persist(event).await;
    }

    fn next_seq(&self) -> i32 {
        self.seq.fetch_add(1, Ordering::SeqCst)
    }

    fn build_event(&self, seq: i32, payload: TrajectoryPayload) -> TrajectoryEvent {
        TrajectoryEvent {
            conversation_id: self.conversation_id.clone(),
            agent_id: self.agent_id.clone(),
            parent_agent_id: self.parent_agent_id.clone(),
            seq,
            ts_ms: now_ms(),
            payload,
        }
    }

    async fn persist(&self, event: TrajectoryEvent) {
        let kind = event.payload.kind();
        let conv = event.conversation_id.clone();
        let agent = event.agent_id.clone();
        let seq = event.seq;
        if let Err(err) = self.repo.record(event).await {
            tracing::warn!(
                conversation = %conv,
                agent = %agent,
                seq,
                kind,
                error = %err,
                "trajectory record failed (telemetry only — agent run continues)"
            );
        }
    }
}

fn tool_call_id(tool_call: &ToolCallFull) -> String {
    tool_call
        .call_id
        .as_ref()
        .map(|id| id.as_str().to_string())
        .unwrap_or_else(|| format!("anon-{}", tool_name_str(&tool_call.name)))
}
fn tool_result_is_error(result: &ToolResult) -> bool {
    result.output.is_error
}

/// Serialize a tool's output to JSON for the trajectory payload. Text and
/// JSON variants round-trip naturally; image/binary variants are summarized
/// (we don't want to store base64 blobs in a debug log).
fn tool_result_output_to_json(result: &ToolResult) -> serde_json::Value {
    let values: Vec<serde_json::Value> = result
        .output
        .values
        .iter()
        .map(|v| match v {
            ToolValue::Text(t) => serde_json::Value::String(t.clone()),
            ToolValue::Json(j) => j.clone(),
            ToolValue::Image(_) => serde_json::json!({"_kind": "image", "_omitted": true}),
            ToolValue::AI { value, conversation_id } => serde_json::json!({
                "_kind": "ai",
                "value": value,
                "conversation_id": conversation_id.to_string(),
            }),
            ToolValue::Empty => serde_json::Value::Null,
        })
        .collect();
    serde_json::json!({
        "is_error": result.output.is_error,
        "values": values,
    })
}

fn tool_name_str(name: &ToolName) -> String {
    name.as_str().to_string()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use async_trait::async_trait;
    use forge_domain::{ToolCallArguments, ToolName, ToolOutput, ToolValue};
    use pretty_assertions::assert_eq;
    use serde_json::json;

    use super::*;

    /// Capture-everything fake repo for asserting on what the recorder
    /// emitted. Stores events in insertion order; `list` returns them
    /// filtered + sorted by `seq` to match the real repo's contract.
    #[derive(Default)]
    struct FakeRepo {
        events: Mutex<Vec<TrajectoryEvent>>,
    }

    #[async_trait]
    impl TrajectoryRepo for FakeRepo {
        async fn record(&self, event: TrajectoryEvent) -> anyhow::Result<()> {
            self.events.lock().unwrap().push(event);
            Ok(())
        }

        async fn list(
            &self,
            conversation_id: &str,
            agent_id: &str,
        ) -> anyhow::Result<Vec<TrajectoryEvent>> {
            let mut events: Vec<TrajectoryEvent> = self
                .events
                .lock()
                .unwrap()
                .iter()
                .filter(|e| e.conversation_id == conversation_id && e.agent_id == agent_id)
                .cloned()
                .collect();
            events.sort_by_key(|e| e.seq);
            events.sort_by_key(|e| e.seq);
            Ok(events)
        }

        async fn next_seq_for(
            &self,
            conversation_id: &str,
            agent_id: &str,
        ) -> anyhow::Result<i32> {
            let max_seq = self
                .events
                .lock()
                .unwrap()
                .iter()
                .filter(|e| e.conversation_id == conversation_id && e.agent_id == agent_id)
                .map(|e| e.seq)
                .max();
            Ok(max_seq.map(|s| s + 1).unwrap_or(0))
        }

        async fn list_for_conversation(
            &self,
            conversation_id: &str,
        ) -> anyhow::Result<Vec<TrajectoryEvent>> {
            let mut events: Vec<TrajectoryEvent> = self
                .events
                .lock()
                .unwrap()
                .iter()
                .filter(|e| e.conversation_id == conversation_id)
                .cloned()
                .collect();
            events.sort_by(|a, b| a.agent_id.cmp(&b.agent_id).then(a.seq.cmp(&b.seq)));
            Ok(events)
        }
    }

    fn make_tool_call(name: &str) -> ToolCallFull {
        ToolCallFull {
            name: ToolName::new(name),
            call_id: Some(forge_domain::ToolCallId::new("call-1")),
            arguments: ToolCallArguments::Parsed(json!({"path": "foo.txt"})),
            thought_signature: None,
        }
    }

    fn make_tool_result(name: &str, is_error: bool) -> ToolResult {
        ToolResult {
            name: ToolName::new(name),
            call_id: Some(forge_domain::ToolCallId::new("call-1")),
            output: ToolOutput {
                is_error,
                values: vec![ToolValue::Text("hi".into())],
            },
        }
    }

    #[tokio::test]
    async fn records_tool_call_then_result_with_increasing_seq() {
        let repo = Arc::new(FakeRepo::default());
        let recorder = TrajectoryRecorder::new(
            repo.clone(),
            "conv-1",
            "agent-A",
            None,
            0,
        );

        let tc = make_tool_call("read");
        let result = make_tool_result("read", false);
        let call_seq = recorder.record_tool_call(&tc).await;
        recorder.record_tool_result(&tc, &result).await;

        let events = repo.list("conv-1", "agent-A").await.unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].seq, call_seq);
        assert_eq!(events[1].seq, call_seq + 1);
        assert!(matches!(
            events[0].payload,
            TrajectoryPayload::ToolCall { .. }
        ));
        assert!(matches!(
            events[1].payload,
            TrajectoryPayload::ToolResult { .. }
        ));
    }

    #[tokio::test]
    async fn tool_result_propagates_is_error_flag() {
        let repo = Arc::new(FakeRepo::default());
        let recorder = TrajectoryRecorder::new(repo.clone(), "conv", "agent", None, 0);
        let tc = make_tool_call("read");
        recorder
            .record_tool_result(&tc, &make_tool_result("read", true))
            .await;

        let events = repo.list("conv", "agent").await.unwrap();
        let TrajectoryPayload::ToolResult { is_error, .. } = &events[0].payload else {
            panic!("expected ToolResult");
        };
        assert!(*is_error, "is_error should propagate from tool output");
    }

    #[tokio::test]
    async fn record_error_is_a_distinct_kind() {
        let repo = Arc::new(FakeRepo::default());
        let recorder = TrajectoryRecorder::new(repo.clone(), "conv", "agent", None, 0);
        recorder.record_error("model timed out", Some("openai".into())).await;

        let events = repo.list("conv", "agent").await.unwrap();
        let TrajectoryPayload::Error { message, source } = &events[0].payload else {
            panic!("expected Error");
        };
        assert_eq!(message, "model timed out");
        assert_eq!(source.as_deref(), Some("openai"));
    }

    #[tokio::test]
    async fn parent_agent_id_is_preserved_for_subagents() {
        let repo = Arc::new(FakeRepo::default());
        let recorder = TrajectoryRecorder::new(
            repo.clone(),
            "conv",
            "child",
            Some("root".into()),
            0,
        );
        recorder.record_tool_call(&make_tool_call("read")).await;
        let events = repo.list("conv", "child").await.unwrap();
        assert_eq!(events[0].parent_agent_id.as_deref(), Some("root"));
    }
}
