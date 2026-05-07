use derive_setters::Setters;
use serde::{Deserialize, Serialize};

use crate::{ConversationId, Event, ModelId};

#[derive(Debug, Serialize, Deserialize, Clone, Setters)]
#[setters(into, strip_option)]
pub struct ChatRequest {
    pub event: Event,
    pub conversation_id: ConversationId,
    /// Optional per-request model override. When set, the chat run uses this
    /// model instead of the agent's configured default. Used by the Task
    /// subagent dispatcher to honour `TaskInput::model`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub model_override: Option<ModelId>,
}

impl ChatRequest {
    pub fn new(content: Event, conversation_id: ConversationId) -> Self {
        Self { event: content, conversation_id, model_override: None }
    }
}
