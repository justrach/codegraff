use std::sync::Arc;

use diesel::prelude::*;
use forge_app::TrajectoryRepo;
use forge_domain::TrajectoryEvent;

use crate::database::schema::trajectory_events;
use crate::database::{DatabasePool, PooledSqliteConnection};
use crate::trajectory::trajectory_record::{NewTrajectoryEventRecord, TrajectoryEventRecord};

pub struct TrajectoryRepositoryImpl {
    pool: Arc<DatabasePool>,
}

impl TrajectoryRepositoryImpl {
    pub fn new(pool: Arc<DatabasePool>) -> Self {
        Self { pool }
    }

    async fn run_with_connection<F, T>(&self, operation: F) -> anyhow::Result<T>
    where
        F: FnOnce(&mut PooledSqliteConnection) -> anyhow::Result<T> + Send + 'static,
        T: Send + 'static,
    {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let mut connection = pool.get_connection()?;
            operation(&mut connection)
        })
        .await
        .map_err(|e| anyhow::anyhow!("Trajectory repository task failed: {e}"))?
    }
}

#[async_trait::async_trait]
impl TrajectoryRepo for TrajectoryRepositoryImpl {
    async fn record(&self, event: TrajectoryEvent) -> anyhow::Result<()> {
        let new_record: NewTrajectoryEventRecord = event.try_into()?;
        self.run_with_connection(move |connection| {
            diesel::insert_into(trajectory_events::table)
                .values(&new_record)
                .execute(connection)?;
            Ok(())
        })
        .await
    }

    async fn list(
        &self,
        conversation_id: &str,
        agent_id: &str,
    ) -> anyhow::Result<Vec<TrajectoryEvent>> {
        let conv_id = conversation_id.to_string();
        let agent_id = agent_id.to_string();
        self.run_with_connection(move |connection| {
            let records: Vec<TrajectoryEventRecord> = trajectory_events::table
                .filter(trajectory_events::conversation_id.eq(conv_id))
                .filter(trajectory_events::agent_id.eq(agent_id))
                .order(trajectory_events::seq.asc())
                .select(TrajectoryEventRecord::as_select())
                .load(connection)?;
            records
                .into_iter()
                .map(TrajectoryEvent::try_from)
                .collect::<Result<Vec<_>, _>>()
        })
        .await
    }

    async fn next_seq_for(
        &self,
        conversation_id: &str,
        agent_id: &str,
    ) -> anyhow::Result<i32> {
        let conv_id = conversation_id.to_string();
        let agent_id = agent_id.to_string();
        self.run_with_connection(move |connection| {
            // diesel::dsl::max returns Option<i32>; None means no rows for the
            // (conv, agent) pair. The caller treats `0` as the initial seq.
            use diesel::dsl::max;
            let current: Option<i32> = trajectory_events::table
                .filter(trajectory_events::conversation_id.eq(conv_id))
                .filter(trajectory_events::agent_id.eq(agent_id))
                .select(max(trajectory_events::seq))
                .first(connection)?;
            Ok(current.map(|c| c + 1).unwrap_or(0))
        })
        .await
    }

    async fn list_for_conversation(
        &self,
        conversation_id: &str,
    ) -> anyhow::Result<Vec<TrajectoryEvent>> {
        // Single SELECT across all agents for this conversation. Order by
        // (agent_id, seq) so each agent's events stay grouped and in order;
        // /trace can then re-render them as a parent → child tree.
        let conv_id = conversation_id.to_string();
        self.run_with_connection(move |connection| {
            let records: Vec<TrajectoryEventRecord> = trajectory_events::table
                .filter(trajectory_events::conversation_id.eq(conv_id))
                .order((trajectory_events::agent_id.asc(), trajectory_events::seq.asc()))
                .select(TrajectoryEventRecord::as_select())
                .load(connection)?;
            records
                .into_iter()
                .map(TrajectoryEvent::try_from)
                .collect::<Result<Vec<_>, _>>()
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use forge_domain::{TrajectoryEvent, TrajectoryPayload, ToolName};
    use pretty_assertions::assert_eq;
    use serde_json::json;

    use super::*;
    use crate::database::DatabasePool;

    fn in_memory_repo() -> TrajectoryRepositoryImpl {
        // Each test gets its own isolated SQLite — `:memory:` databases are
        // not shared across pool connections, but DatabasePool::in_memory()
        // pins the pool to a single connection so all queries see the same
        // schema and data.
        let pool = Arc::new(DatabasePool::in_memory().expect("in-memory pool"));
        TrajectoryRepositoryImpl::new(pool)
    }

    fn tool_call(seq: i32, agent_id: &str, conv_id: &str, call_id: &str) -> TrajectoryEvent {
        TrajectoryEvent {
            conversation_id: conv_id.to_string(),
            agent_id: agent_id.to_string(),
            parent_agent_id: None,
            seq,
            ts_ms: 1000 + seq as i64,
            payload: TrajectoryPayload::ToolCall {
                tool_name: ToolName::new("read"),
                call_id: call_id.to_string(),
                arguments: json!({"path": "foo.txt"}),
            },
        }
    }

    fn tool_result(seq: i32, agent_id: &str, conv_id: &str, call_id: &str) -> TrajectoryEvent {
        TrajectoryEvent {
            conversation_id: conv_id.to_string(),
            agent_id: agent_id.to_string(),
            parent_agent_id: None,
            seq,
            ts_ms: 1000 + seq as i64,
            payload: TrajectoryPayload::ToolResult {
                tool_name: ToolName::new("read"),
                call_id: call_id.to_string(),
                is_error: false,
                output: json!({"contents": "hello"}),
            },
        }
    }

    #[tokio::test]
    async fn record_then_list_roundtrips_in_seq_order() {
        let repo = in_memory_repo();
        let conv = "conv-1";
        let agent = "agent-A";
        // Insert out of seq order to ensure the query (not the insert order)
        // is what guarantees the returned ordering.
        repo.record(tool_result(2, agent, conv, "c1")).await.unwrap();
        repo.record(tool_call(1, agent, conv, "c1")).await.unwrap();

        let events = repo.list(conv, agent).await.unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].seq, 1);
        assert_eq!(events[1].seq, 2);
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
    async fn list_scopes_by_conversation_and_agent() {
        let repo = in_memory_repo();
        // Same agent_id under two different conversations; same conversation
        // with two different agents. Each `list` call should see only the
        // events matching its (conv, agent) tuple.
        repo.record(tool_call(1, "agent-A", "conv-1", "c1")).await.unwrap();
        repo.record(tool_call(1, "agent-A", "conv-2", "c2")).await.unwrap();
        repo.record(tool_call(1, "agent-B", "conv-1", "c3")).await.unwrap();

        let conv1_a = repo.list("conv-1", "agent-A").await.unwrap();
        let conv1_b = repo.list("conv-1", "agent-B").await.unwrap();
        let conv2_a = repo.list("conv-2", "agent-A").await.unwrap();

        assert_eq!(conv1_a.len(), 1);
        assert_eq!(conv1_b.len(), 1);
        assert_eq!(conv2_a.len(), 1);
        let TrajectoryPayload::ToolCall { call_id, .. } = &conv1_a[0].payload else {
            panic!("expected ToolCall");
        };
        assert_eq!(call_id, "c1");
    }

    #[tokio::test]
    async fn list_returns_empty_when_no_events_match() {
        let repo = in_memory_repo();
        let events = repo.list("missing", "missing").await.unwrap();
        assert!(events.is_empty());
    }

    #[tokio::test]
    async fn record_preserves_parent_agent_id_for_subagents() {
        let repo = in_memory_repo();
        let mut event = tool_call(1, "child-agent", "conv-1", "c1");
        event.parent_agent_id = Some("root-agent".to_string());
        repo.record(event).await.unwrap();

        let events = repo.list("conv-1", "child-agent").await.unwrap();
        assert_eq!(events[0].parent_agent_id.as_deref(), Some("root-agent"));
    }

    /// End-to-end: drive the production `TrajectoryRecorder` against the
    /// production `TrajectoryRepositoryImpl` (in-memory SQLite) and assert
    /// the rows come back in the expected order. This is the only test in
    /// the workspace that exercises the full recorder→repo→SQLite path —
    /// the other tests stub one side or the other.
    #[tokio::test]
    async fn recorder_drives_diesel_repo_end_to_end() {
        use forge_app::TrajectoryRecorder;
        use forge_domain::{
            ToolCallArguments, ToolCallId, ToolName, ToolOutput, ToolValue,
        };

        let repo: Arc<dyn forge_app::TrajectoryRepo> = Arc::new(in_memory_repo());
        let recorder = TrajectoryRecorder::new(repo.clone(), "conv-e2e", "agent-X", None, 0);

        let tool_call = forge_domain::ToolCallFull {
            name: ToolName::new("read"),
            call_id: Some(ToolCallId::new("call-42")),
            arguments: ToolCallArguments::Parsed(serde_json::json!({"path": "x"})),
            thought_signature: None,
        };
        let tool_result = forge_domain::ToolResult {
            name: ToolName::new("read"),
            call_id: Some(ToolCallId::new("call-42")),
            output: ToolOutput {
                is_error: false,
                values: vec![ToolValue::Text("contents".into())],
            },
        };

        recorder.record_tool_call(&tool_call).await;
        recorder.record_tool_result(&tool_call, &tool_result).await;
        recorder.record_error("budget exceeded", None).await;

        let events = repo.list("conv-e2e", "agent-X").await.unwrap();
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].seq, 0);
        assert_eq!(events[1].seq, 1);
        assert_eq!(events[2].seq, 2);
        assert!(matches!(
            events[0].payload,
            TrajectoryPayload::ToolCall { .. }
        ));
        assert!(matches!(
            events[1].payload,
            TrajectoryPayload::ToolResult { .. }
        ));
        assert!(matches!(
            events[2].payload,
            TrajectoryPayload::Error { .. }
        ));
    }
}
