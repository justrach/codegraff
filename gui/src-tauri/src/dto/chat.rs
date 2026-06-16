use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::activity::{ToolCallDetailDto, ToolResultDetailDto};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "StatusCategory")]
pub enum StatusCategoryDto {
    Action,
    Info,
    Debug,
    Error,
    Completion,
    Warning,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum ChatEventKind {
    Started,
    AssistantMarkdown {
        text: String,
    },
    Reasoning {
        text: String,
    },
    Status {
        title: String,
        subtitle: Option<String>,
        category: StatusCategoryDto,
    },
    StatusOutput {
        text: String,
    },
    ToolStart {
        name: String,
        #[serde(rename = "callId")]
        call_id: Option<String>,
        detail: ToolCallDetailDto,
    },
    ToolEnd {
        name: String,
        #[serde(rename = "callId")]
        call_id: Option<String>,
        summary: Option<String>,
        #[serde(rename = "isError")]
        is_error: bool,
        detail: Option<ToolResultDetailDto>,
    },
    Retry {
        cause: String,
        #[serde(rename = "durationMs")]
        duration_ms: u64,
    },
    Interrupt {
        reason: String,
    },
    Complete,
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ChatEventDto {
    pub request_id: String,
    pub conversation_id: String,
    pub event: ChatEventKind,
}

impl ChatEventDto {
    pub fn new(
        request_id: impl Into<String>,
        conversation_id: impl Into<String>,
        event: ChatEventKind,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            conversation_id: conversation_id.into(),
            event,
        }
    }
}
