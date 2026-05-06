use diesel::prelude::*;
use forge_domain::{TrajectoryEvent, TrajectoryPayload};

use crate::database::schema::trajectory_events;

/// Diesel-side row shape for `trajectory_events`. Mirrors the table schema
/// 1:1 — `kind` is the wire-stable discriminator copied from the payload's
/// serde tag so SQL queries can filter without parsing JSON.
#[derive(Debug, Clone, Insertable)]
#[diesel(table_name = trajectory_events)]
pub struct NewTrajectoryEventRecord {
    pub conversation_id: String,
    pub agent_id: String,
    pub parent_agent_id: Option<String>,
    pub seq: i32,
    pub ts_ms: i64,
    pub kind: String,
    pub payload: String,
}

#[derive(Debug, Clone, Queryable, Selectable)]
#[diesel(table_name = trajectory_events)]
pub struct TrajectoryEventRecord {
    pub id: i32,
    pub conversation_id: String,
    pub agent_id: String,
    pub parent_agent_id: Option<String>,
    pub seq: i32,
    pub ts_ms: i64,
    pub kind: String,
    pub payload: String,
}

impl TryFrom<TrajectoryEvent> for NewTrajectoryEventRecord {
    type Error = serde_json::Error;

    fn try_from(event: TrajectoryEvent) -> Result<Self, Self::Error> {
        let kind = event.payload.kind().to_string();
        let payload = serde_json::to_string(&event.payload)?;
        Ok(Self {
            conversation_id: event.conversation_id,
            agent_id: event.agent_id,
            parent_agent_id: event.parent_agent_id,
            seq: event.seq,
            ts_ms: event.ts_ms,
            kind,
            payload,
        })
    }
}

impl TryFrom<TrajectoryEventRecord> for TrajectoryEvent {
    type Error = anyhow::Error;

    fn try_from(record: TrajectoryEventRecord) -> Result<Self, Self::Error> {
        let payload: TrajectoryPayload = serde_json::from_str(&record.payload).map_err(|e| {
            anyhow::anyhow!(
                "trajectory_events.payload for id={} is not valid JSON: {e}",
                record.id
            )
        })?;
        // Cross-check: the SQL `kind` column should always agree with the
        // payload's serde tag. If they diverge we trust the JSON (single
        // source of truth) but log so the corruption is greppable.
        if payload.kind() != record.kind {
            tracing::warn!(
                row_id = record.id,
                sql_kind = %record.kind,
                payload_kind = %payload.kind(),
                "trajectory_events row has mismatched kind/payload — trusting payload"
            );
        }
        Ok(TrajectoryEvent {
            conversation_id: record.conversation_id,
            agent_id: record.agent_id,
            parent_agent_id: record.parent_agent_id,
            seq: record.seq,
            ts_ms: record.ts_ms,
            payload,
        })
    }
}
