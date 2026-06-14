use std::collections::HashMap;

use anyhow::Context;
use forge_api::API;
use forge_domain::ConversationId;

use crate::dto::{SessionMessageDto, ToolResultDetailDto};

use super::{
    ConversationSessionState, PersistedConversationSummary, RuntimeManager,
    hydrate_conversation_state,
};

impl RuntimeManager {
    pub(super) async fn ensure_conversation_loaded(
        &self,
        workspace_path: &str,
        conversation_id: &str,
    ) -> anyhow::Result<()> {
        let existing = self
            .state
            .lock()
            .await
            .conversations
            .get(conversation_id)
            .cloned();
        if existing.as_ref().is_some_and(|conversation| {
            !conversation.active_request_ids.is_empty() || conversation.is_local_draft
        }) {
            return Ok(());
        }

        let existing_order = existing.map(|conversation| conversation.order);
        self.reload_conversation_from_persistence(workspace_path, conversation_id, existing_order)
            .await
    }

    pub(super) async fn reload_conversation_from_persistence(
        &self,
        workspace_path: &str,
        conversation_id: &str,
        order_hint: Option<u64>,
    ) -> anyhow::Result<()> {
        let runtime = self.ensure_workspace_runtime(workspace_path).await?;
        let parsed = ConversationId::parse(conversation_id)?;
        let conversation = runtime
            .api
            .conversation(&parsed)
            .await?
            .with_context(|| format!("Conversation not found: {conversation_id}"))?;
        let persisted = PersistedConversationSummary::from_conversation(&conversation);

        let mut state = self.state.lock().await;
        let existing_order = state
            .conversations
            .get(conversation_id)
            .map(|current| current.order);
        let transient_details = state
            .conversations
            .get(conversation_id)
            .map(|current| collect_transient_tool_result_details(&current.messages))
            .unwrap_or_default();
        let request_agent_ids = state
            .conversations
            .get(conversation_id)
            .map(|current| current.request_agent_ids.clone())
            .unwrap_or_default();
        let order = order_hint
            .or(existing_order)
            .unwrap_or_else(|| state.allocate_order());
        let mut next_state =
            hydrate_conversation_state(workspace_path, conversation, persisted, order);
        next_state.request_agent_ids = request_agent_ids;
        apply_transient_tool_result_details(&mut next_state.messages, &transient_details);
        state
            .conversations
            .insert(conversation_id.to_string(), next_state);
        Ok(())
    }

    pub(super) async fn ensure_conversation_loaded_or_insert_empty(
        &self,
        workspace_path: &str,
        conversation_id: &str,
    ) -> anyhow::Result<()> {
        let exists = self
            .state
            .lock()
            .await
            .conversations
            .contains_key(conversation_id);
        if exists {
            return Ok(());
        }

        match self
            .ensure_conversation_loaded(workspace_path, conversation_id)
            .await
        {
            Ok(()) => Ok(()),
            Err(_) => {
                let mut state = self.state.lock().await;
                let order = state.allocate_order();
                state
                    .conversations
                    .entry(conversation_id.to_string())
                    .or_insert_with(|| ConversationSessionState {
                        workspace_path: workspace_path.to_string(),
                        messages: Vec::new(),
                        todos: Vec::new(),
                        pending_file_updates: Default::default(),
                        pending_anonymous_file_updates: Default::default(),
                        title: Some("New chat".to_string()),
                        updated_at: None,
                        active_request_ids: Vec::new(),
                        request_agent_ids: Default::default(),
                        is_local_draft: true,
                        order,
                    });
                Ok(())
            }
        }
    }
}

pub(crate) fn select_empty_draft_conversation_id(
    state: &super::RuntimeState,
    workspace_path: &str,
) -> Option<String> {
    state
        .conversations
        .iter()
        .filter(|(_, conversation)| {
            conversation.workspace_path == workspace_path
                && conversation.is_local_draft
                && conversation.messages.is_empty()
                && conversation.active_request_ids.is_empty()
        })
        .max_by_key(|(_, conversation)| conversation.order)
        .map(|(conversation_id, _)| conversation_id.clone())
}

fn collect_transient_tool_result_details(
    messages: &[SessionMessageDto],
) -> HashMap<String, ToolResultDetailDto> {
    messages
        .iter()
        .filter_map(|message| match message {
            SessionMessageDto::ToolEnd {
                id,
                detail: Some(detail @ ToolResultDetailDto::FileDiff { .. }),
                ..
            } => Some((id.clone(), detail.clone())),
            _ => None,
        })
        .collect()
}

fn apply_transient_tool_result_details(
    messages: &mut [SessionMessageDto],
    transient_details: &HashMap<String, ToolResultDetailDto>,
) {
    for message in messages {
        let SessionMessageDto::ToolEnd { id, detail, .. } = message else {
            continue;
        };
        let Some(transient_detail) = transient_details.get(id) else {
            continue;
        };

        *detail = Some(transient_detail.clone());
    }
}
