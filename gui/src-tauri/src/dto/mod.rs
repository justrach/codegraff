// Copied GUI scaffolding: the tool-output parsing helpers in `activity` are
// superseded by the simple adapter's own mapping; kept for future parity.
#[allow(dead_code)]
mod activity;
mod chat;
mod command;
mod followup;
mod runtime;
mod session;
mod terminal;

pub use activity::{FileOperationDto, OutputPreviewDto, ToolCallDetailDto, ToolResultDetailDto};
pub use chat::{ChatEventDto, ChatEventKind, StatusCategoryDto};
pub use command::{
    AgentSummaryDto, AgentsPayloadDto, CommandDescriptorDto, CommandExecutionKindDto,
    CommandKindDto, CommandPayloadDto, CommandResultKindDto, CommandRunResultDto,
    ConversationsPayloadDto, McpImportInput, McpServerActionInput, McpServerSummaryDto,
    McpSettingsPayloadDto, WorkflowDraftInput, WorkflowDraftPayloadDto, WorkflowNodeDto,
    WorkspaceFileStatusDto, WorkspaceInfoPayloadDto, WorkspaceQueryInput,
    WorkspaceSearchPayloadDto, WorkspaceSearchResultDto, WorkspaceStatusPayloadDto,
    WorkspaceSyncPayloadDto,
};
pub use followup::{FollowupKind, FollowupOptionDto, FollowupRequestDto, FollowupResponseDto};
pub use runtime::{
    ChatHandoffTargetDto, CheckoutGitBranchInput, CloneRepositoryInput, CommitGitChangesInput,
    CompleteProviderAuthInput, CreateGitBranchInput, CreateSavedWorkspaceInput,
    GitWorkspaceKindDto, HandoffChatInput, ProviderEnvOverrideDto, PromptModelOptionDto,
    PromptSettingsDto, ProviderAuthMethodDto, ProviderAuthMethodKindDto, ProviderAuthSessionDto,
    ProviderAuthSessionKindDto, ProviderOAuthCallbackDto, ProviderSummaryDto, ProviderUrlParamDto,
    ProviderUrlParamValueDto, QuickStartProjectInput, QuickStartVisibility, RemoveProviderInput,
    RuntimeStatusDto, SaveConversationLayoutInput, SendPromptInput, StartProviderAuthInput,
    UpdatePromptSettingsInput, UpdateSavedWorkspaceLayoutInput,
};
pub use session::{
    ChatBindingDto, ConversationSessionSummaryDto, ConversationViewSnapshotDto,
    SavedWorkspaceDetailDto, SavedWorkspaceSummaryDto, SessionMessageDto, SessionSnapshotDto,
    SessionTodoDto, SessionTodoStatusDto, WorkspaceKindDto, WorkspaceSessionDto,
};
pub use terminal::{
    TerminalCloseInput, TerminalErrorEventDto, TerminalExitEventDto, TerminalOpenInput,
    TerminalOutputEventDto, TerminalResizeInput, TerminalSessionDto, TerminalWriteInput,
};
