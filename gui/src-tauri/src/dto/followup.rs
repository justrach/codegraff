use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename = "FollowupKind")]
pub enum FollowupKind {
    Text,
    Single,
    Multi,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "FollowupOption")]
pub struct FollowupOptionDto {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "FollowupRequest")]
pub struct FollowupRequestDto {
    pub followup_id: String,
    pub workspace_path: String,
    pub conversation_id: String,
    pub request_id: String,
    pub kind: FollowupKind,
    pub question: String,
    pub options: Option<Vec<FollowupOptionDto>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "FollowupResponse")]
pub struct FollowupResponseDto {
    pub followup_id: String,
    pub cancelled: bool,
    pub text: Option<String>,
    pub selected_option_ids: Option<Vec<String>>,
}
