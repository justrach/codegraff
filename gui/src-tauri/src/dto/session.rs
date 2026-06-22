use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::activity::{ToolCallDetailDto, ToolResultDetailDto};
use super::chat::StatusCategoryDto;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(tag = "kind", rename_all = "snake_case")]
#[ts(rename = "SessionMessage")]
#[allow(clippy::large_enum_variant)]
pub enum SessionMessageDto {
    User {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        text: String,
    },
    ContextCompacted {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        text: String,
    },
    Assistant {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        text: String,
    },
    Reasoning {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        text: String,
    },
    Status {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        title: String,
        subtitle: Option<String>,
        category: StatusCategoryDto,
    },
    StatusOutput {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        text: String,
    },
    ToolStart {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        name: String,
        #[serde(rename = "callId")]
        call_id: Option<String>,
        detail: ToolCallDetailDto,
    },
    ToolEnd {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        name: String,
        #[serde(rename = "callId")]
        call_id: Option<String>,
        summary: Option<String>,
        #[serde(rename = "isError")]
        is_error: bool,
        detail: Option<ToolResultDetailDto>,
    },
    Error {
        id: String,
        #[serde(rename = "requestId")]
        request_id: String,
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "SessionTodoStatus")]
pub enum SessionTodoStatusDto {
    Pending,
    InProgress,
    Completed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "SessionTodo")]
pub struct SessionTodoDto {
    pub id: String,
    pub content: String,
    pub status: SessionTodoStatusDto,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ConversationSessionSummary")]
pub struct ConversationSessionSummaryDto {
    pub conversation_id: String,
    pub title: String,
    pub updated_at: Option<String>,
    pub is_draft: bool,
    pub is_running: bool,
    pub has_pending_followup: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ChatBinding")]
pub struct ChatBindingDto {
    pub workspace_path: String,
    pub conversation_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ConversationViewSnapshot")]
pub struct ConversationViewSnapshotDto {
    pub workspace_path: String,
    pub conversation_id: String,
    pub messages: Vec<SessionMessageDto>,
    pub active_request_ids: Vec<String>,
    pub request_agent_ids: HashMap<String, String>,
    pub todos: Vec<SessionTodoDto>,
    /// Steering objective for this chat, set via `/goal`. Surfaced in the UI as
    /// the goal chip above the composer. Omitted from the payload when unset.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub goal: Option<String>,
    pub followup: Option<super::followup::FollowupRequestDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "WorkspaceKind")]
pub enum WorkspaceKindDto {
    Project,
    ManagedChat,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceSession")]
pub struct WorkspaceSessionDto {
    pub kind: WorkspaceKindDto,
    pub workspace_path: String,
    pub workspace_name: String,
    pub configured: bool,
    pub configuration_error: Option<String>,
    pub selected_conversation_id: Option<String>,
    pub conversations: Vec<ConversationSessionSummaryDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "SavedWorkspaceSummary")]
pub struct SavedWorkspaceSummaryDto {
    pub id: String,
    pub name: String,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "SavedWorkspaceDetail")]
pub struct SavedWorkspaceDetailDto {
    pub id: String,
    pub name: String,
    pub layout_json: String,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "SessionSnapshot")]
pub struct SessionSnapshotDto {
    pub active_workspace_path: Option<String>,
    pub active_conversation_id: Option<String>,
    pub visible_messages: Vec<SessionMessageDto>,
    pub visible_active_request_ids: Vec<String>,
    pub visible_request_agent_ids: HashMap<String, String>,
    pub visible_todos: Vec<SessionTodoDto>,
    /// Steering objective of the active chat, set via `/goal`. Mirrors
    /// `ConversationViewSnapshotDto::goal` for the visible conversation. Omitted
    /// from the payload when no goal is set.
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub visible_goal: Option<String>,
    pub visible_followup: Option<super::followup::FollowupRequestDto>,
    pub conversation_views: Vec<ConversationViewSnapshotDto>,
    pub ui_error: Option<String>,
    pub workspaces: Vec<WorkspaceSessionDto>,
    pub saved_workspaces: Vec<SavedWorkspaceSummaryDto>,
}
