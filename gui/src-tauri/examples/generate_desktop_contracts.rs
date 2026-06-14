use std::fs;
use std::path::PathBuf;

use anyhow::Context;
use codegraff_gui_lib::dto::{
    AgentSummaryDto, AgentsPayloadDto, ChatBindingDto, ChatHandoffTargetDto,
    CheckoutGitBranchInput, CloneRepositoryInput, CommandDescriptorDto, CommandExecutionKindDto,
    CommandKindDto, CommandPayloadDto, CommandResultKindDto, CommandRunResultDto,
    CommitGitChangesInput, CompleteProviderAuthInput, ConversationSessionSummaryDto,
    ConversationViewSnapshotDto, ConversationsPayloadDto, CreateGitBranchInput,
    CreateSavedWorkspaceInput, FileOperationDto, FollowupKind, FollowupOptionDto,
    FollowupRequestDto, FollowupResponseDto, GitWorkspaceKindDto, HandoffChatInput, McpImportInput,
    McpServerActionInput, McpServerSummaryDto, McpSettingsPayloadDto, OutputPreviewDto,
    PromptModelOptionDto, PromptSettingsDto, ProviderAuthMethodDto, ProviderAuthMethodKindDto,
    ProviderAuthSessionDto, ProviderAuthSessionKindDto, ProviderOAuthCallbackDto,
    ProviderSummaryDto, ProviderUrlParamDto, ProviderUrlParamValueDto, QuickStartProjectInput,
    QuickStartVisibility, RemoveProviderInput, RuntimeStatusDto, SaveConversationLayoutInput,
    SavedWorkspaceDetailDto, SavedWorkspaceSummaryDto, SendPromptInput, SessionMessageDto,
    SessionSnapshotDto, SessionTodoDto, SessionTodoStatusDto, StartProviderAuthInput,
    StatusCategoryDto, TerminalCloseInput, TerminalErrorEventDto, TerminalExitEventDto,
    TerminalOpenInput, TerminalOutputEventDto, TerminalResizeInput, TerminalSessionDto,
    TerminalWriteInput, ToolCallDetailDto, ToolResultDetailDto, UpdatePromptSettingsInput,
    UpdateSavedWorkspaceLayoutInput, WorkflowDraftInput, WorkflowDraftPayloadDto, WorkflowNodeDto,
    WorkspaceFileStatusDto, WorkspaceInfoPayloadDto, WorkspaceKindDto, WorkspaceQueryInput,
    WorkspaceSearchPayloadDto, WorkspaceSearchResultDto, WorkspaceSessionDto,
    WorkspaceStatusPayloadDto, WorkspaceSyncPayloadDto,
};
use ts_rs::{Config, TS};

fn main() -> anyhow::Result<()> {
    let output_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../src/services/desktop/types/contracts.generated.ts");
    let config = Config::default();

    let declarations = [
        export_decl::<StatusCategoryDto>(&config),
        export_decl::<FileOperationDto>(&config),
        export_decl::<OutputPreviewDto>(&config),
        export_decl::<ToolCallDetailDto>(&config),
        export_decl::<ToolResultDetailDto>(&config),
        export_decl::<FollowupKind>(&config),
        export_decl::<FollowupOptionDto>(&config),
        export_decl::<FollowupRequestDto>(&config),
        export_decl::<FollowupResponseDto>(&config),
        export_decl::<SessionMessageDto>(&config),
        export_decl::<SessionTodoStatusDto>(&config),
        export_decl::<SessionTodoDto>(&config),
        export_decl::<ConversationSessionSummaryDto>(&config),
        export_decl::<ChatBindingDto>(&config),
        export_decl::<ConversationViewSnapshotDto>(&config),
        export_decl::<WorkspaceKindDto>(&config),
        export_decl::<WorkspaceSessionDto>(&config),
        export_decl::<SavedWorkspaceSummaryDto>(&config),
        export_decl::<SavedWorkspaceDetailDto>(&config),
        export_decl::<SessionSnapshotDto>(&config),
        export_decl::<PromptModelOptionDto>(&config),
        export_decl::<PromptSettingsDto>(&config),
        export_decl::<UpdatePromptSettingsInput>(&config),
        export_decl::<ProviderAuthMethodKindDto>(&config),
        export_decl::<ProviderAuthMethodDto>(&config),
        export_decl::<ProviderSummaryDto>(&config),
        export_decl::<ProviderUrlParamDto>(&config),
        export_decl::<ProviderUrlParamValueDto>(&config),
        export_decl::<ProviderAuthSessionKindDto>(&config),
        export_decl::<ProviderAuthSessionDto>(&config),
        export_decl::<ProviderOAuthCallbackDto>(&config),
        export_decl::<StartProviderAuthInput>(&config),
        export_decl::<CompleteProviderAuthInput>(&config),
        export_decl::<RemoveProviderInput>(&config),
        export_decl::<SendPromptInput>(&config),
        export_decl::<ChatHandoffTargetDto>(&config),
        export_decl::<HandoffChatInput>(&config),
        export_decl::<RuntimeStatusDto>(&config),
        export_decl::<GitWorkspaceKindDto>(&config),
        export_decl::<CloneRepositoryInput>(&config),
        export_decl::<QuickStartVisibility>(&config),
        export_decl::<QuickStartProjectInput>(&config),
        export_decl::<CheckoutGitBranchInput>(&config),
        export_decl::<CreateGitBranchInput>(&config),
        export_decl::<CommitGitChangesInput>(&config),
        export_decl::<CreateSavedWorkspaceInput>(&config),
        export_decl::<UpdateSavedWorkspaceLayoutInput>(&config),
        export_decl::<SaveConversationLayoutInput>(&config),
        export_decl::<TerminalOpenInput>(&config),
        export_decl::<TerminalWriteInput>(&config),
        export_decl::<TerminalResizeInput>(&config),
        export_decl::<TerminalCloseInput>(&config),
        export_decl::<TerminalSessionDto>(&config),
        export_decl::<TerminalOutputEventDto>(&config),
        export_decl::<TerminalExitEventDto>(&config),
        export_decl::<TerminalErrorEventDto>(&config),
        export_decl::<CommandKindDto>(&config),
        export_decl::<CommandExecutionKindDto>(&config),
        export_decl::<CommandResultKindDto>(&config),
        export_decl::<CommandDescriptorDto>(&config),
        export_decl::<AgentSummaryDto>(&config),
        export_decl::<AgentsPayloadDto>(&config),
        export_decl::<ConversationsPayloadDto>(&config),
        export_decl::<WorkspaceFileStatusDto>(&config),
        export_decl::<WorkspaceStatusPayloadDto>(&config),
        export_decl::<WorkspaceInfoPayloadDto>(&config),
        export_decl::<WorkspaceQueryInput>(&config),
        export_decl::<WorkspaceSearchResultDto>(&config),
        export_decl::<WorkspaceSearchPayloadDto>(&config),
        export_decl::<WorkspaceSyncPayloadDto>(&config),
        export_decl::<WorkflowDraftInput>(&config),
        export_decl::<WorkflowNodeDto>(&config),
        export_decl::<WorkflowDraftPayloadDto>(&config),
        export_decl::<McpServerSummaryDto>(&config),
        export_decl::<McpSettingsPayloadDto>(&config),
        export_decl::<McpImportInput>(&config),
        export_decl::<McpServerActionInput>(&config),
        export_decl::<CommandPayloadDto>(&config),
        export_decl::<CommandRunResultDto>(&config),
    ];

    let body = declarations
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .join("\n\n");

    let contents = format!(
        "// This file is generated by `cargo run --manifest-path src-tauri/Cargo.toml --bin generate_desktop_contracts`.\n// Do not edit it by hand.\n\n{body}\n"
    );

    fs::write(&output_path, contents)
        .with_context(|| format!("Failed to write {}", output_path.display()))?;

    Ok(())
}

fn export_decl<T: TS>(config: &Config) -> anyhow::Result<String> {
    let declaration = T::decl(config);
    let trimmed = declaration.trim();
    let declaration = if trimmed.starts_with("export ") {
        trimmed.to_string()
    } else {
        format!("export {trimmed}")
    };

    Ok(trim_trailing_whitespace(&declaration))
}

fn trim_trailing_whitespace(value: &str) -> String {
    value
        .lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
}
