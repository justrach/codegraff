use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::session::{ConversationSessionSummaryDto, SessionSnapshotDto};

/// Where a slash-command originates, mirroring how the REPL groups its
/// completion entries.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CommandKind")]
pub enum CommandKindDto {
    /// A built-in command from the `AppCommand` enum.
    Builtin,
    /// A per-agent switch command (`agent-<id>`).
    Agent,
    /// A user-defined workflow command (`⚙`).
    Workflow,
}

/// How the GUI should execute or route a slash-command.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CommandExecutionKind")]
pub enum CommandExecutionKindDto {
    /// The command can run directly in the GUI backend.
    Runnable,
    /// The command opens or focuses a GUI modal/pane.
    Modal,
    /// The command is represented by a terminal/setup action in the GUI.
    TerminalAssisted,
    /// The command is known but not currently available in the GUI.
    Unavailable,
}

/// The high-level shape of a command result.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CommandResultKind")]
pub enum CommandResultKindDto {
    /// Plain text output.
    Text,
    /// A refreshed session snapshot.
    Snapshot,
    /// A path to a saved file.
    SavedFile,
    /// Agent list or active-agent details.
    Agents,
    /// Conversation list or operation result.
    Conversations,
    /// Conversation trajectory details.
    Trajectory,
    /// Workspace indexing status.
    WorkspaceStatus,
    /// Workspace indexing metadata.
    WorkspaceInfo,
    /// Workspace semantic search results.
    WorkspaceSearch,
    /// Workspace sync progress summary.
    WorkspaceSync,
    /// Workflow review/export payload.
    WorkflowDraft,
    /// MCP server/config payload.
    Mcp,
}

/// A single autocompletable graff command, surfaced to the GUI prompt.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CommandDescriptor")]
pub struct CommandDescriptorDto {
    /// Canonical command name (without the leading slash).
    pub name: String,
    /// Short, human-readable usage description.
    pub usage: String,
    /// Alternate names that also resolve to this command.
    pub aliases: Vec<String>,
    /// Origin of the command.
    pub kind: CommandKindDto,
    /// Optional payload: agent id for `Agent`, prompt text for `Workflow`.
    pub value: Option<String>,
    /// True for the agent-switch shorthands (`act`/`plan`/`sage`).
    pub is_agent_switch: bool,
    /// Execution route the GUI should use for this command.
    pub execution_kind: CommandExecutionKindDto,
    /// Whether the command requires an open workspace.
    pub requires_workspace: bool,
    /// Whether the command requires an active conversation.
    pub requires_conversation: bool,
    /// Optional argument hint shown in autocomplete and palettes.
    pub argument_hint: Option<String>,
    /// Expected result shape when the command runs.
    pub result_kind: CommandResultKindDto,
}

/// Lightweight agent metadata for GUI status and picker surfaces.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "AgentSummary")]
pub struct AgentSummaryDto {
    /// Stable agent identifier.
    pub id: String,
    /// Human-readable title.
    pub title: String,
    /// Human-readable description when configured.
    pub description: Option<String>,
    /// Whether this agent is currently active.
    pub is_active: bool,
    /// Model configured for this agent when resolvable.
    pub model_id: Option<String>,
}

/// Agent picker payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "AgentsPayload")]
pub struct AgentsPayloadDto {
    /// Active agent id when one is selected.
    pub active_agent_id: Option<String>,
    /// Selected provider id for the current session.
    pub selected_provider_id: Option<String>,
    /// Selected model id for the current session.
    pub selected_model_id: Option<String>,
    /// Selected reasoning effort for the current model.
    pub selected_reasoning_effort: Option<String>,
    /// Available agents.
    pub agents: Vec<AgentSummaryDto>,
}

/// Conversation operation payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "ConversationsPayload")]
pub struct ConversationsPayloadDto {
    /// Workspace path the conversations belong to.
    pub workspace_path: Option<String>,
    /// Serialized conversation summaries compatible with existing snapshots.
    pub conversations: Vec<ConversationSessionSummaryDto>,
}

/// A single indexed-workspace file status.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceFileStatus")]
pub struct WorkspaceFileStatusDto {
    /// Relative path.
    pub path: String,
    /// Sync status label.
    pub status: String,
}

/// Workspace indexing status payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceStatusPayload")]
pub struct WorkspaceStatusPayloadDto {
    /// Workspace path queried.
    pub workspace_path: String,
    /// File status entries.
    pub files: Vec<WorkspaceFileStatusDto>,
}

/// Workspace indexing metadata payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceInfoPayload")]
pub struct WorkspaceInfoPayloadDto {
    /// Workspace path queried.
    pub workspace_path: String,
    /// Remote workspace id if indexed.
    pub workspace_id: Option<String>,
    /// Indexed working directory if known.
    pub working_dir: Option<String>,
    /// Indexed node count.
    pub node_count: Option<u64>,
    /// Indexed relation count.
    pub relation_count: Option<u64>,
    /// Last update timestamp as RFC3339 text.
    pub last_updated: Option<String>,
    /// Created timestamp as RFC3339 text.
    pub created_at: Option<String>,
}

/// Input for workspace semantic search.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceQueryInput")]
pub struct WorkspaceQueryInput {
    /// Workspace path to query.
    pub workspace_path: String,
    /// Semantic query text.
    pub query: String,
    /// Search use case for reranking.
    pub use_case: Option<String>,
    /// Maximum number of results.
    pub limit: Option<usize>,
    /// Optional path prefix filter.
    pub starts_with: Option<String>,
    /// Optional suffix filters.
    pub ends_with: Option<Vec<String>>,
}

/// A normalized semantic search result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceSearchResult")]
pub struct WorkspaceSearchResultDto {
    /// Node id returned by the index service.
    pub node_id: String,
    /// Result kind.
    pub kind: String,
    /// File path when applicable.
    pub path: Option<String>,
    /// Starting line when applicable.
    pub start_line: Option<u32>,
    /// Ending line when applicable.
    pub end_line: Option<u32>,
    /// Text preview.
    pub preview: String,
    /// Relevance score when returned.
    pub relevance: Option<f32>,
    /// Distance score when returned.
    pub distance: Option<f32>,
}

/// Workspace semantic search payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceSearchPayload")]
pub struct WorkspaceSearchPayloadDto {
    /// Workspace path queried.
    pub workspace_path: String,
    /// Original query.
    pub query: String,
    /// Results in backend rank order.
    pub results: Vec<WorkspaceSearchResultDto>,
}

/// Workspace sync summary payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkspaceSyncPayload")]
pub struct WorkspaceSyncPayloadDto {
    /// Workspace path synced.
    pub workspace_path: String,
    /// Human-readable progress events.
    pub events: Vec<String>,
}

/// Input for building a GUI workflow draft.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkflowDraftInput")]
pub struct WorkflowDraftInput {
    /// Goal the workflow should accomplish.
    pub goal: String,
}

/// A single workflow review node.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkflowNode")]
pub struct WorkflowNodeDto {
    /// Stable node name.
    pub name: String,
    /// Worker agent id.
    pub worker: String,
    /// Task assigned to the worker.
    pub task: String,
    /// Node dependencies.
    pub dependencies: Vec<String>,
    /// Prior node outputs this node may inspect.
    pub access: Vec<String>,
    /// Expected artifact.
    pub artifact: String,
    /// Stop condition.
    pub stop_condition: String,
}

/// Workflow draft payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "WorkflowDraftPayload")]
pub struct WorkflowDraftPayloadDto {
    /// Goal the workflow should accomplish.
    pub goal: String,
    /// Compact topology summary.
    pub summary: String,
    /// Review nodes.
    pub nodes: Vec<WorkflowNodeDto>,
    /// Exportable YAML-like representation.
    pub export_text: String,
    /// Prompt submitted when the workflow is approved.
    pub approved_prompt: String,
    /// Initial trace lines.
    pub trace: Vec<String>,
}

/// A single MCP server in settings.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "McpServerSummary")]
pub struct McpServerSummaryDto {
    /// MCP server name.
    pub name: String,
    /// Server transport type.
    pub server_type: String,
    /// Command or URL.
    pub target: String,
    /// Whether the server is disabled.
    pub is_disabled: bool,
    /// Number of tools currently loaded.
    pub tool_count: usize,
    /// Tool names currently loaded.
    pub tools: Vec<String>,
    /// Initialization error when available.
    pub error: Option<String>,
    /// OAuth auth status for HTTP servers when known.
    pub auth_status: Option<String>,
}

/// MCP settings payload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "McpSettingsPayload")]
pub struct McpSettingsPayloadDto {
    /// Configured servers.
    pub servers: Vec<McpServerSummaryDto>,
}

/// Input for importing MCP configuration JSON.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "McpImportInput")]
pub struct McpImportInput {
    /// Configuration scope: `user` or `local`.
    pub scope: String,
    /// JSON text containing `mcpServers`.
    pub json: String,
}

/// Input for an MCP server action.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "McpServerActionInput")]
pub struct McpServerActionInput {
    /// MCP server name.
    pub name: String,
    /// Configuration scope: `user` or `local` when the action edits config.
    pub scope: Option<String>,
}

/// Structured command payloads used by GUI-first surfaces.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, TS)]
#[serde(tag = "kind", rename_all = "camelCase")]
#[ts(rename = "CommandPayload")]
pub enum CommandPayloadDto {
    /// Agent picker/status payload.
    Agents(AgentsPayloadDto),
    /// Conversation operation payload.
    Conversations(ConversationsPayloadDto),
    /// Workspace status payload.
    WorkspaceStatus(WorkspaceStatusPayloadDto),
    /// Workspace info payload.
    WorkspaceInfo(WorkspaceInfoPayloadDto),
    /// Workspace search payload.
    WorkspaceSearch(WorkspaceSearchPayloadDto),
    /// Workspace sync payload.
    WorkspaceSync(WorkspaceSyncPayloadDto),
    /// Workflow draft payload.
    WorkflowDraft(WorkflowDraftPayloadDto),
    /// MCP settings payload.
    Mcp(McpSettingsPayloadDto),
}

/// The outcome of executing a command via `run_command`. Exactly one of the
/// payload fields is populated, telling the GUI how to surface the result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, TS)]
#[serde(rename_all = "camelCase")]
#[ts(rename = "CommandRunResult")]
pub struct CommandRunResultDto {
    /// Heading for the result dialog.
    pub title: String,
    /// Informational text to display in a dialog (monospace). `None` when the
    /// command mutated state instead of producing output.
    pub body: Option<String>,
    /// A refreshed session snapshot to apply when the command changed state
    /// (e.g. compaction, rename).
    pub snapshot: Option<SessionSnapshotDto>,
    /// A filesystem path the command wrote to (e.g. `/dump`), surfaced to the
    /// user so they can locate the output.
    pub saved_path: Option<String>,
    /// High-level result shape.
    pub result_kind: CommandResultKindDto,
    /// Structured payload for first-class GUI surfaces.
    pub payload: Option<CommandPayloadDto>,
}
