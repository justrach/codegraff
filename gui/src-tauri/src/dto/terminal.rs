use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalOpenInput")]
pub struct TerminalOpenInput {
    pub terminal_id: String,
    pub workspace_path: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalWriteInput")]
pub struct TerminalWriteInput {
    pub terminal_id: String,
    pub data: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalResizeInput")]
pub struct TerminalResizeInput {
    pub terminal_id: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalCloseInput")]
pub struct TerminalCloseInput {
    pub terminal_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalSession")]
pub struct TerminalSessionDto {
    pub terminal_id: String,
    pub workspace_path: String,
    pub shell: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalOutputEvent")]
pub struct TerminalOutputEventDto {
    pub terminal_id: String,
    pub data: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalExitEvent")]
pub struct TerminalExitEventDto {
    pub terminal_id: String,
    pub exit_code: Option<u32>,
    pub signal: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "TerminalErrorEvent")]
pub struct TerminalErrorEventDto {
    pub terminal_id: String,
    pub message: String,
}
