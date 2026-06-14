use crate::{
    bridge::emitter::UiEventEmitter, desktop_open, dto::*,
    persistence::project_store::ProjectStore, terminal::TerminalManager,
};
use anyhow::{Context, Result};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
};
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Clone, Default)]
struct ConversationState {
    workspace_path: String,
    conversation_id: String,
    title: String,
    messages: Vec<SessionMessageDto>,
    active_request_ids: Vec<String>,
}

#[derive(Default)]
struct RuntimeState {
    active_workspace_path: Option<String>,
    active_conversation_id: Option<String>,
    workspaces: Vec<String>,
    conversations: HashMap<String, ConversationState>,
    selected_by_workspace: HashMap<String, String>,
    active_agent_id: Option<String>,
}

/// Coordinates the copied desktop GUI with the Zig-native codegraff binary.
pub struct RuntimeManager {
    emitter: Arc<dyn UiEventEmitter>,
    projects: Arc<ProjectStore>,
    state: Arc<Mutex<RuntimeState>>,
}

impl RuntimeManager {
    /// Creates a runtime manager backed by the copied GUI project registry.
    pub fn new(emitter: Arc<dyn UiEventEmitter>, projects: Arc<ProjectStore>) -> Self {
        Self {
            emitter,
            projects,
            state: Arc::new(Mutex::new(RuntimeState {
                active_agent_id: Some("forge".into()),
                ..RuntimeState::default()
            })),
        }
    }

    /// Cancels pending follow-up prompts.
    pub async fn cancel_pending_followups(&self) {}

    /// Returns the current GUI session snapshot.
    pub async fn get_session_snapshot(&self) -> Result<SessionSnapshotDto> {
        self.snapshot().await
    }

    /// Opens a workspace and records it in the GUI registry.
    pub async fn open_workspace(&self, path: PathBuf) -> Result<SessionSnapshotDto> {
        let workspace_path = canonicalize_workspace_path(path)?;
        self.projects.add_project(Path::new(&workspace_path))?;
        let mut state = self.state.lock().await;
        set_active_workspace(&mut state, &workspace_path);
        drop(state);
        self.snapshot().await
    }

    /// Returns basic runtime status for a workspace.
    pub async fn get_runtime_status(
        &self,
        workspace_path: Option<String>,
    ) -> Result<RuntimeStatusDto> {
        let active = self.state.lock().await.active_workspace_path.clone();
        Ok(RuntimeStatusDto::new(
            workspace_path.or(active).as_deref().map(Path::new),
            true,
            None,
        ))
    }

    /// Returns minimal prompt settings for local testing.
    pub async fn get_prompt_settings(&self, _: Option<String>) -> Result<PromptSettingsDto> {
        Ok(PromptSettingsDto {
            available_models: vec![PromptModelOptionDto {
                provider_id: "codegraff".into(),
                provider_name: "Codegraff".into(),
                model_id: "default".into(),
                model_name: Some("Default".into()),
                context_length: None,
                supports_reasoning: false,
                reasoning_efforts: vec![],
            }],
            selected_provider_id: Some("codegraff".into()),
            selected_model_id: Some("default".into()),
            selected_reasoning_effort: None,
        })
    }

    /// Updates prompt settings.
    pub async fn update_prompt_settings(
        &self,
        input: UpdatePromptSettingsInput,
    ) -> Result<PromptSettingsDto> {
        self.get_prompt_settings(input.workspace_path).await
    }

    /// Lists providers supported by the Zig-native codegraff binary.
    pub async fn list_providers(&self, _: Option<String>) -> Result<Vec<ProviderSummaryDto>> {
        list_codegraff_providers().await
    }

    /// Starts provider auth using the target repo's native credential flows.
    pub async fn start_provider_auth(
        &self,
        input: StartProviderAuthInput,
    ) -> Result<ProviderAuthSessionDto> {
        match input.auth_method {
            ProviderAuthMethodKindDto::ApiKey => Ok(ProviderAuthSessionDto {
                kind: ProviderAuthSessionKindDto::ApiKey,
                auth_session_id: auth_session_id(&input.provider_id),
                requires_api_key: true,
                api_key_hint: provider_env_key(&input.provider_id)
                    .map(|env_key| format!("Paste an API key. Equivalent env var: {env_key}."))
                    .or_else(|| Some("Paste an API key for this provider.".into())),
                url_parameters: vec![],
                verification_uri: None,
                verification_uri_complete: None,
                user_code: None,
                expires_in_seconds: None,
                authorization_url: None,
            }),
            ProviderAuthMethodKindDto::CodegraffDevice => {
                launch_codegraff_login(None).await?;
                Ok(cli_login_session(
                    &input.provider_id,
                    "Codegraff login launched in Terminal. Complete the device-code flow there, then finish setup here.",
                ))
            }
            ProviderAuthMethodKindDto::CodexDevice => {
                launch_codegraff_login(Some("codex")).await?;
                Ok(cli_login_session(
                    &input.provider_id,
                    "Codex login launched in Terminal. Complete the browser OAuth flow there, then finish setup here.",
                ))
            }
            _ => anyhow::bail!("Unsupported auth method for {}", input.provider_id),
        }
    }

    /// Completes provider auth by delegating to `graff key set` for API keys.
    pub async fn complete_provider_auth(
        &self,
        input: CompleteProviderAuthInput,
    ) -> Result<ProviderSummaryDto> {
        let provider_id = provider_from_auth_session_id(&input.auth_session_id);
        if let Some(api_key) = input
            .api_key
            .as_deref()
            .map(str::trim)
            .filter(|key| !key.is_empty())
        {
            run_codegraff_key_set(provider_id, api_key).await?;
        }
        provider_summary(provider_id).await
    }

    /// Reports provider auth removal guidance for the target CLI store.
    pub async fn remove_provider(&self, input: RemoveProviderInput) -> Result<ProviderSummaryDto> {
        anyhow::bail!(
            "Removing stored credentials is not exposed by graff yet. Clear {provider}_API_KEY, remove the stored key from the macOS Keychain, or edit ~/.simple-harness-keys.json.",
            provider = input.provider_id.to_uppercase()
        )
    }

    /// Lists slash commands available in the MVP adapter.
    pub async fn list_commands(&self, _: Option<String>) -> Result<Vec<CommandDescriptorDto>> {
        Ok(vec![
            command("help", "Show available commands.", false),
            command("agent", "Show active agent.", false),
            command("compact", "Compact current conversation.", true),
            command("workspace-status", "Show git status.", true),
        ])
    }

    /// Sends a prompt through the local Zig-native codegraff binary.
    pub async fn send_prompt(&self, input: SendPromptInput) -> Result<SessionSnapshotDto> {
        let conversation_id = input
            .conversation_id
            .clone()
            .unwrap_or_else(|| format!("chat-{}", Uuid::new_v4().simple()));
        let request_id = format!("request-{}", Uuid::new_v4().simple());
        {
            let mut state = self.state.lock().await;
            set_active_workspace(&mut state, &input.workspace_path);
            state.active_conversation_id = Some(conversation_id.clone());
            state
                .selected_by_workspace
                .insert(input.workspace_path.clone(), conversation_id.clone());
            let conversation = state
                .conversations
                .entry(conversation_id.clone())
                .or_insert_with(|| ConversationState {
                    workspace_path: input.workspace_path.clone(),
                    conversation_id: conversation_id.clone(),
                    title: title_from_prompt(&input.prompt),
                    messages: vec![],
                    active_request_ids: vec![],
                });
            conversation.messages.push(SessionMessageDto::User {
                id: format!("{request_id}-user"),
                request_id: request_id.clone(),
                text: input.prompt.clone(),
            });
            conversation.active_request_ids.push(request_id.clone());
        }
        let _ = self.emitter.emit_session_updated(self.snapshot().await?);
        let response = run_codegraff_prompt(&input.workspace_path, &input.prompt).await;
        {
            let mut state = self.state.lock().await;
            if let Some(conversation) = state.conversations.get_mut(&conversation_id) {
                conversation
                    .active_request_ids
                    .retain(|id| id != &request_id);
                match response {
                    Ok(text) => conversation.messages.push(SessionMessageDto::Assistant {
                        id: format!("{request_id}-assistant"),
                        request_id,
                        text,
                    }),
                    Err(error) => conversation.messages.push(SessionMessageDto::Error {
                        id: format!("{request_id}-error"),
                        request_id,
                        message: format_error_chain(&error),
                    }),
                }
            }
        }
        let snapshot = self.snapshot().await?;
        let _ = self.emitter.emit_session_updated(snapshot.clone());
        Ok(snapshot)
    }

    /// Runs an MVP slash command.
    pub async fn run_command(
        &self,
        name: String,
        args: Vec<String>,
        workspace_path: Option<String>,
        conversation_id: Option<String>,
    ) -> Result<CommandRunResultDto> {
        match name.as_str() {
            "agent" => Ok(CommandRunResultDto {
                title: "/agent".into(),
                body: Some("Active agent: Forge".into()),
                snapshot: None,
                saved_path: None,
                result_kind: CommandResultKindDto::Agents,
                payload: Some(CommandPayloadDto::Agents(self.agents_payload().await)),
            }),
            "compact" => Ok(CommandRunResultDto {
                title: "/compact".into(),
                body: None,
                snapshot: Some(
                    self.compact_conversation(
                        workspace_path.context("Missing workspace")?,
                        conversation_id.context("Missing conversation")?,
                    )
                    .await?,
                ),
                saved_path: None,
                result_kind: CommandResultKindDto::Snapshot,
                payload: None,
            }),
            "workspace-status" => {
                let workspace = workspace_path.unwrap_or_default();
                Ok(CommandRunResultDto {
                    title: "/workspace-status".into(),
                    body: Some("Workspace status loaded.".into()),
                    snapshot: None,
                    saved_path: None,
                    result_kind: CommandResultKindDto::WorkspaceStatus,
                    payload: Some(CommandPayloadDto::WorkspaceStatus(
                        WorkspaceStatusPayloadDto {
                            workspace_path: workspace.clone(),
                            files: git_status_files(&workspace).unwrap_or_default(),
                        },
                    )),
                })
            }
            _ => Ok(CommandRunResultDto {
                title: format!("/{name}"),
                body: Some(format!(
                    "Available MVP commands: /help, /agent, /compact, /workspace-status. Args: {}",
                    args.join(" ")
                )),
                snapshot: None,
                saved_path: None,
                result_kind: CommandResultKindDto::Text,
                payload: None,
            }),
        }
    }

    /// Returns a simple workspace sync payload.
    pub async fn workspace_sync(&self, workspace_path: String) -> Result<WorkspaceSyncPayloadDto> {
        Ok(WorkspaceSyncPayloadDto {
            workspace_path,
            events: vec!["Zig-native GUI MVP does not maintain a workspace index yet.".into()],
        })
    }

    /// Returns empty workspace query results.
    pub async fn workspace_query(
        &self,
        input: WorkspaceQueryInput,
    ) -> Result<WorkspaceSearchPayloadDto> {
        Ok(WorkspaceSearchPayloadDto {
            workspace_path: input.workspace_path,
            query: input.query,
            results: vec![],
        })
    }

    /// Builds a placeholder workflow draft.
    pub async fn build_workflow_draft(
        &self,
        input: WorkflowDraftInput,
    ) -> Result<WorkflowDraftPayloadDto> {
        Ok(WorkflowDraftPayloadDto {
            goal: input.goal.clone(),
            summary: "Workflow drafting is stubbed in the Zig-native GUI MVP.".into(),
            nodes: vec![],
            export_text: format!("goal: {}\nnodes: []", input.goal),
            approved_prompt: input.goal,
            trace: vec![],
        })
    }

    /// Exports a workflow draft.
    pub fn export_workflow_draft(&self, draft: WorkflowDraftPayloadDto) -> String {
        draft.export_text
    }

    /// Sets the active agent.
    pub async fn set_active_agent(
        &self,
        agent_id: String,
        _: Option<String>,
    ) -> Result<AgentsPayloadDto> {
        self.state.lock().await.active_agent_id = Some(agent_id);
        Ok(self.agents_payload().await)
    }

    /// Lists MCP servers; unsupported in the MVP adapter.
    pub async fn list_mcp_servers(&self, _: Option<String>) -> Result<McpSettingsPayloadDto> {
        Ok(McpSettingsPayloadDto { servers: vec![] })
    }
    /// Imports MCP config; unsupported in the MVP adapter.
    pub async fn import_mcp_config(&self, _: McpImportInput) -> Result<McpSettingsPayloadDto> {
        self.list_mcp_servers(None).await
    }
    /// Removes an MCP server; unsupported in the MVP adapter.
    pub async fn remove_mcp_server(
        &self,
        _: McpServerActionInput,
    ) -> Result<McpSettingsPayloadDto> {
        self.list_mcp_servers(None).await
    }
    /// Reloads MCP servers; unsupported in the MVP adapter.
    pub async fn reload_mcp_servers(&self, _: Option<String>) -> Result<McpSettingsPayloadDto> {
        self.list_mcp_servers(None).await
    }
    /// Logs into an MCP server; unsupported in the MVP adapter.
    pub async fn login_mcp_server(&self, _: McpServerActionInput) -> Result<McpSettingsPayloadDto> {
        self.list_mcp_servers(None).await
    }
    /// Logs out of an MCP server; unsupported in the MVP adapter.
    pub async fn logout_mcp_server(
        &self,
        _: McpServerActionInput,
    ) -> Result<McpSettingsPayloadDto> {
        self.list_mcp_servers(None).await
    }

    /// Compacts a conversation marker in local state.
    pub async fn compact_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> Result<SessionSnapshotDto> {
        let mut state = self.state.lock().await;
        set_active_workspace(&mut state, &workspace_path);
        if let Some(conversation) = state.conversations.get_mut(&conversation_id) {
            let request_id = format!("compact-{}", Uuid::new_v4().simple());
            conversation
                .messages
                .push(SessionMessageDto::ContextCompacted {
                    id: request_id.clone(),
                    request_id,
                    text: "Conversation compacted for the Zig-native GUI session.".into(),
                });
        }
        drop(state);
        self.snapshot().await
    }

    /// Stops a prompt in the local GUI state.
    pub async fn stop_prompt(&self, input: ChatBindingDto) -> Result<()> {
        if let Some(conversation) = self
            .state
            .lock()
            .await
            .conversations
            .get_mut(&input.conversation_id)
        {
            conversation.active_request_ids.clear();
        }
        Ok(())
    }

    /// Selects a conversation.
    pub async fn select_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> Result<SessionSnapshotDto> {
        let mut state = self.state.lock().await;
        set_active_workspace(&mut state, &workspace_path);
        state.active_conversation_id = Some(conversation_id.clone());
        state
            .selected_by_workspace
            .insert(workspace_path, conversation_id);
        drop(state);
        self.snapshot().await
    }

    /// Ensures a conversation view exists.
    pub async fn ensure_conversation_view(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> Result<SessionSnapshotDto> {
        self.select_conversation(workspace_path, conversation_id)
            .await
    }

    /// Starts a new chat in a workspace.
    pub async fn start_new_chat(&self, workspace_path: String) -> Result<SessionSnapshotDto> {
        let conversation_id = format!("chat-{}", Uuid::new_v4().simple());
        let mut state = self.state.lock().await;
        set_active_workspace(&mut state, &workspace_path);
        state.active_conversation_id = Some(conversation_id.clone());
        state
            .selected_by_workspace
            .insert(workspace_path.clone(), conversation_id.clone());
        state.conversations.insert(
            conversation_id.clone(),
            ConversationState {
                workspace_path,
                conversation_id,
                title: "New chat".into(),
                messages: vec![],
                active_request_ids: vec![],
            },
        );
        drop(state);
        self.snapshot().await
    }

    /// Creates a managed chat workspace.
    pub async fn create_managed_chat(&self) -> Result<SessionSnapshotDto> {
        self.open_workspace(self.projects.create_managed_chat_workspace()?)
            .await
    }

    /// Handles chat handoff as a no-op in the MVP adapter.
    pub async fn handoff_chat(&self, _: HandoffChatInput) -> Result<SessionSnapshotDto> {
        self.snapshot().await
    }

    /// Handles follow-up responses as a no-op in the MVP adapter.
    pub async fn respond_followup(&self, _: FollowupResponseDto) -> Result<SessionSnapshotDto> {
        self.snapshot().await
    }

    /// Archives a conversation from local state.
    pub async fn archive_conversation(
        &self,
        _: String,
        conversation_id: String,
    ) -> Result<SessionSnapshotDto> {
        self.state
            .lock()
            .await
            .conversations
            .remove(&conversation_id);
        self.snapshot().await
    }

    /// Archives a workspace from the local registry.
    pub async fn archive_workspace(&self, workspace_path: String) -> Result<SessionSnapshotDto> {
        self.projects
            .archive_workspace(Path::new(&workspace_path))?;
        self.state
            .lock()
            .await
            .workspaces
            .retain(|path| path != &workspace_path);
        self.snapshot().await
    }

    /// Renames a workspace display name.
    pub async fn rename_workspace(
        &self,
        workspace_path: String,
        display_name: Option<String>,
    ) -> Result<SessionSnapshotDto> {
        self.projects
            .set_workspace_display_name(Path::new(&workspace_path), display_name.as_deref())?;
        self.snapshot().await
    }

    /// Checks out a git branch.
    pub async fn checkout_git_branch(
        &self,
        workspace_path: String,
        branch_name: String,
    ) -> Result<RuntimeStatusDto> {
        run_git(&workspace_path, &["checkout", &branch_name])?;
        self.get_runtime_status(Some(workspace_path)).await
    }

    /// Creates a git branch.
    pub async fn create_git_branch(
        &self,
        workspace_path: String,
        branch_name: String,
    ) -> Result<RuntimeStatusDto> {
        run_git(&workspace_path, &["checkout", "-b", &branch_name])?;
        self.get_runtime_status(Some(workspace_path)).await
    }

    /// Commits git changes.
    pub async fn commit_git_changes(
        &self,
        workspace_path: String,
        message: String,
    ) -> Result<RuntimeStatusDto> {
        run_git(&workspace_path, &["add", "-A"])?;
        run_git(&workspace_path, &["commit", "-m", &message])?;
        self.get_runtime_status(Some(workspace_path)).await
    }

    /// Pushes the current git branch.
    pub async fn push_git_branch(&self, workspace_path: String) -> Result<RuntimeStatusDto> {
        run_git(&workspace_path, &["push", "-u", "origin", "HEAD"])?;
        self.get_runtime_status(Some(workspace_path)).await
    }

    /// Opens a workspace in the default app.
    pub async fn open_in_target(&self, workspace_path: String, _: String) -> Result<()> {
        desktop_open::open_path_default(Path::new(&workspace_path))
    }

    /// Opens a path in the default app.
    pub async fn open_path_in_target(
        &self,
        workspace_path: String,
        _: String,
        path: String,
    ) -> Result<()> {
        desktop_open::open_path_default(&Path::new(&workspace_path).join(path))
    }

    /// Saves a conversation layout.
    pub async fn save_conversation_layout(&self, input: SaveConversationLayoutInput) -> Result<()> {
        self.projects
            .save_conversation_layout(&input.conversation_id, &input.layout_json)
    }

    /// Returns a conversation layout.
    pub async fn get_conversation_layout(&self, conversation_id: String) -> Result<Option<String>> {
        self.projects.get_conversation_layout(&conversation_id)
    }

    /// Creates a saved workspace.
    pub async fn create_saved_workspace(
        &self,
        input: CreateSavedWorkspaceInput,
    ) -> Result<SavedWorkspaceDetailDto> {
        let record = self.projects.create_saved_workspace(
            &Uuid::new_v4().to_string(),
            "Saved workspace",
            &input.layout_json,
        )?;
        Ok(saved_detail(
            record.id,
            record.name,
            record.layout_json,
            record.updated_at,
        ))
    }

    /// Updates a saved workspace layout.
    pub async fn update_saved_workspace_layout(
        &self,
        input: UpdateSavedWorkspaceLayoutInput,
    ) -> Result<SavedWorkspaceDetailDto> {
        let record = self
            .projects
            .update_saved_workspace_layout(&input.workspace_id, &input.layout_json)?;
        Ok(saved_detail(
            record.id,
            record.name,
            record.layout_json,
            record.updated_at,
        ))
    }

    /// Returns a saved workspace.
    pub async fn get_saved_workspace(
        &self,
        workspace_id: String,
    ) -> Result<Option<SavedWorkspaceDetailDto>> {
        Ok(self
            .projects
            .get_saved_workspace(&workspace_id)?
            .map(|record| {
                saved_detail(
                    record.id,
                    record.name,
                    record.layout_json,
                    record.updated_at,
                )
            }))
    }

    /// Renames a saved workspace.
    pub async fn rename_saved_workspace(
        &self,
        workspace_id: String,
        name: String,
    ) -> Result<SessionSnapshotDto> {
        self.projects.rename_saved_workspace(&workspace_id, &name)?;
        self.snapshot().await
    }

    /// Deletes a saved workspace.
    pub async fn delete_saved_workspace(&self, workspace_id: String) -> Result<SessionSnapshotDto> {
        self.projects.delete_saved_workspace(&workspace_id)?;
        self.snapshot().await
    }

    async fn agents_payload(&self) -> AgentsPayloadDto {
        let active = self
            .state
            .lock()
            .await
            .active_agent_id
            .clone()
            .unwrap_or_else(|| "forge".into());
        AgentsPayloadDto {
            active_agent_id: Some(active.clone()),
            selected_provider_id: Some("codegraff".into()),
            selected_model_id: Some("default".into()),
            selected_reasoning_effort: None,
            agents: vec![AgentSummaryDto {
                id: "forge".into(),
                title: "Forge".into(),
                description: Some("Default Codegraff assistant.".into()),
                is_active: active == "forge",
                model_id: Some("default".into()),
            }],
        }
    }

    async fn snapshot(&self) -> Result<SessionSnapshotDto> {
        let mut state = self.state.lock().await;
        for workspace in self.projects.list_workspaces().unwrap_or_default() {
            let path = workspace.path.to_string_lossy().into_owned();
            if !state.workspaces.contains(&path) {
                state.workspaces.push(path);
            }
        }
        let active_conversation_id = state.active_conversation_id.clone();
        let visible = active_conversation_id
            .as_ref()
            .and_then(|id| state.conversations.get(id))
            .cloned();
        let conversation_views = state
            .conversations
            .values()
            .map(conversation_view)
            .collect();
        let workspaces = state
            .workspaces
            .iter()
            .map(|path| {
                let conversations = state
                    .conversations
                    .values()
                    .filter(|conversation| &conversation.workspace_path == path)
                    .map(|conversation| ConversationSessionSummaryDto {
                        conversation_id: conversation.conversation_id.clone(),
                        title: conversation.title.clone(),
                        updated_at: None,
                        is_draft: conversation.messages.is_empty(),
                        is_running: !conversation.active_request_ids.is_empty(),
                        has_pending_followup: false,
                    })
                    .collect();
                WorkspaceSessionDto {
                    kind: WorkspaceKindDto::Project,
                    workspace_path: path.clone(),
                    workspace_name: workspace_name(path),
                    configured: true,
                    configuration_error: None,
                    selected_conversation_id: state.selected_by_workspace.get(path).cloned(),
                    conversations,
                }
            })
            .collect();
        let saved_workspaces = self
            .projects
            .list_saved_workspaces()
            .unwrap_or_default()
            .into_iter()
            .map(|record| SavedWorkspaceSummaryDto {
                id: record.id,
                name: record.name,
                updated_at: record.updated_at,
            })
            .collect();
        Ok(SessionSnapshotDto {
            active_workspace_path: state.active_workspace_path.clone(),
            active_conversation_id,
            visible_messages: visible
                .as_ref()
                .map(|c| c.messages.clone())
                .unwrap_or_default(),
            visible_active_request_ids: visible
                .as_ref()
                .map(|c| c.active_request_ids.clone())
                .unwrap_or_default(),
            visible_request_agent_ids: HashMap::new(),
            visible_todos: vec![],
            visible_followup: None,
            conversation_views,
            ui_error: None,
            workspaces,
            saved_workspaces,
        })
    }
}

/// Shared Tauri desktop state.
pub struct DesktopState {
    pub manager: Arc<RuntimeManager>,
    pub terminal_manager: Arc<TerminalManager>,
}

impl DesktopState {
    /// Creates desktop state for the copied GUI.
    pub fn new(emitter: Arc<dyn UiEventEmitter>, projects: Arc<ProjectStore>) -> Self {
        Self {
            manager: Arc::new(RuntimeManager::new(emitter.clone(), projects)),
            terminal_manager: Arc::new(TerminalManager::new(emitter)),
        }
    }
}

pub(crate) fn canonicalize_workspace_path(path: PathBuf) -> Result<String> {
    Ok(path
        .canonicalize()
        .with_context(|| format!("Failed to open workspace {}", path.display()))?
        .to_string_lossy()
        .into_owned())
}

pub(crate) fn format_error_chain(error: &anyhow::Error) -> String {
    error
        .chain()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}

fn set_active_workspace(state: &mut RuntimeState, workspace_path: &str) {
    state.active_workspace_path = Some(workspace_path.into());
    if !state.workspaces.iter().any(|path| path == workspace_path) {
        state.workspaces.insert(0, workspace_path.into());
    }
}

fn conversation_view(conversation: &ConversationState) -> ConversationViewSnapshotDto {
    ConversationViewSnapshotDto {
        workspace_path: conversation.workspace_path.clone(),
        conversation_id: conversation.conversation_id.clone(),
        messages: conversation.messages.clone(),
        active_request_ids: conversation.active_request_ids.clone(),
        request_agent_ids: HashMap::new(),
        todos: vec![],
        followup: None,
    }
}

fn command(name: &str, usage: &str, requires_workspace: bool) -> CommandDescriptorDto {
    CommandDescriptorDto {
        name: name.into(),
        usage: usage.into(),
        aliases: vec![],
        kind: CommandKindDto::Builtin,
        value: None,
        is_agent_switch: false,
        execution_kind: CommandExecutionKindDto::Runnable,
        requires_workspace,
        requires_conversation: name == "compact",
        argument_hint: None,
        result_kind: CommandResultKindDto::Text,
    }
}

async fn run_codegraff_prompt(workspace_path: &str, prompt: &str) -> Result<String> {
    let output = tokio::process::Command::new(codegraff_binary())
        .arg("--print")
        .arg(prompt)
        .arg("--yolo")
        .current_dir(workspace_path)
        .output()
        .await
        .context("Failed to launch Zig-native codegraff binary")?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().into())
    } else {
        anyhow::bail!(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn codegraff_binary() -> String {
    std::env::var("CODEGRAFF_GUI_BINARY").unwrap_or_else(|_| {
        let candidate = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/graff");
        if candidate.exists() {
            candidate.to_string_lossy().into_owned()
        } else {
            "graff".into()
        }
    })
}

#[derive(Debug, Clone)]
struct CodegraffProvider {
    id: &'static str,
    name: &'static str,
    env_key: Option<&'static str>,
    auth_method: ProviderAuthMethodKindDto,
}

const CODEGRAFF_PROVIDERS: &[CodegraffProvider] = &[
    CodegraffProvider {
        id: "codegraff",
        name: "Codegraff",
        env_key: Some("CODEGRAFF_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::CodegraffDevice,
    },
    CodegraffProvider {
        id: "anthropic",
        name: "Anthropic",
        env_key: Some("ANTHROPIC_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "deepseek",
        name: "DeepSeek",
        env_key: Some("DEEPSEEK_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "openai",
        name: "OpenAI",
        env_key: Some("OPENAI_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "minimax",
        name: "MiniMax",
        env_key: Some("MINIMAX_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "xiaomi",
        name: "Xiaomi",
        env_key: Some("XIAOMI_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "kimi",
        name: "Kimi",
        env_key: Some("KIMI_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "xai",
        name: "xAI",
        env_key: Some("XAI_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "zai",
        name: "Z.ai",
        env_key: Some("ZAI_API_KEY"),
        auth_method: ProviderAuthMethodKindDto::ApiKey,
    },
    CodegraffProvider {
        id: "codex",
        name: "Codex / ChatGPT",
        env_key: None,
        auth_method: ProviderAuthMethodKindDto::CodexDevice,
    },
];

async fn list_codegraff_providers() -> Result<Vec<ProviderSummaryDto>> {
    let key_list = codegraff_key_list().await.unwrap_or_default();
    Ok(CODEGRAFF_PROVIDERS
        .iter()
        .map(|provider| provider_summary_with_key_list(provider, &key_list))
        .collect())
}

async fn provider_summary(provider_id: &str) -> Result<ProviderSummaryDto> {
    let key_list = codegraff_key_list().await.unwrap_or_default();
    let provider = CODEGRAFF_PROVIDERS
        .iter()
        .find(|provider| provider.id == provider_id)
        .with_context(|| format!("Unknown provider {provider_id}"))?;
    Ok(provider_summary_with_key_list(provider, &key_list))
}

fn provider_summary_with_key_list(
    provider: &CodegraffProvider,
    key_list: &str,
) -> ProviderSummaryDto {
    ProviderSummaryDto {
        id: provider.id.into(),
        name: provider.name.into(),
        configured: provider_configured(provider, key_list),
        auth_methods: vec![ProviderAuthMethodDto {
            kind: provider.auth_method.clone(),
            label: provider_auth_label(provider),
        }],
    }
}

fn provider_auth_label(provider: &CodegraffProvider) -> String {
    match provider.auth_method {
        ProviderAuthMethodKindDto::ApiKey => provider
            .env_key
            .map(|env_key| format!("API key ({env_key} or graff key set {})", provider.id))
            .unwrap_or_else(|| "API key".into()),
        ProviderAuthMethodKindDto::CodegraffDevice => "Codegraff device login".into(),
        ProviderAuthMethodKindDto::CodexDevice => "Codex browser login".into(),
        _ => "Unsupported".into(),
    }
}

fn provider_configured(provider: &CodegraffProvider, key_list: &str) -> bool {
    if provider
        .env_key
        .and_then(|env_key| std::env::var(env_key).ok())
        .filter(|value| !value.trim().is_empty())
        .is_some()
    {
        return true;
    }

    match provider.id {
        "codegraff" => {
            home_file_exists("forge/.credentials.json")
                || key_list_mentions_provider(key_list, provider.id)
        }
        "codex" => home_file_exists(".codex/auth.json"),
        _ => key_list_mentions_provider(key_list, provider.id),
    }
}

fn key_list_mentions_provider(key_list: &str, provider_id: &str) -> bool {
    key_list
        .lines()
        .any(|line| line.split_whitespace().any(|part| part == provider_id))
}

fn home_file_exists(relative_path: &str) -> bool {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(relative_path).exists())
        .unwrap_or(false)
}

fn provider_env_key(provider_id: &str) -> Option<&'static str> {
    CODEGRAFF_PROVIDERS
        .iter()
        .find(|provider| provider.id == provider_id)
        .and_then(|provider| provider.env_key)
}

fn auth_session_id(provider_id: &str) -> String {
    format!("codegraff-provider:{provider_id}")
}

fn provider_from_auth_session_id(auth_session_id: &str) -> &str {
    auth_session_id
        .strip_prefix("codegraff-provider:")
        .unwrap_or(auth_session_id)
}

fn cli_login_session(provider_id: &str, message: &str) -> ProviderAuthSessionDto {
    ProviderAuthSessionDto {
        kind: ProviderAuthSessionKindDto::DeviceCode,
        auth_session_id: auth_session_id(provider_id),
        requires_api_key: false,
        api_key_hint: Some(message.into()),
        url_parameters: vec![],
        verification_uri: None,
        verification_uri_complete: None,
        user_code: None,
        expires_in_seconds: None,
        authorization_url: None,
    }
}

async fn codegraff_key_list() -> Result<String> {
    let output = tokio::process::Command::new(codegraff_binary())
        .args(["key", "list"])
        .output()
        .await
        .context("Failed to run graff key list")?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        anyhow::bail!(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

async fn run_codegraff_key_set(provider_id: &str, api_key: &str) -> Result<()> {
    let output = tokio::process::Command::new(codegraff_binary())
        .args(["key", "set", provider_id, api_key])
        .output()
        .await
        .with_context(|| format!("Failed to store {provider_id} API key with graff key set"))?;
    if output.status.success() {
        Ok(())
    } else {
        anyhow::bail!(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

async fn launch_codegraff_login(login_target: Option<&str>) -> Result<()> {
    let binary = codegraff_binary();
    #[cfg(target_os = "macos")]
    {
        let mut command = tokio::process::Command::new("open");
        command.args(["-a", "Terminal", &binary, "--args", "login"]);
        if let Some(target) = login_target {
            command.arg(target);
        }
        command
            .spawn()
            .context("Failed to launch Terminal for graff login")?;
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let mut command = tokio::process::Command::new(binary);
        command.arg("login");
        if let Some(target) = login_target {
            command.arg(target);
        }
        command.spawn().context("Failed to launch graff login")?;
        Ok(())
    }
}

fn title_from_prompt(prompt: &str) -> String {
    let title = prompt
        .split_whitespace()
        .take(8)
        .collect::<Vec<_>>()
        .join(" ");
    if title.is_empty() {
        "New chat".into()
    } else {
        title
    }
}

fn git_status_files(workspace_path: &str) -> Result<Vec<WorkspaceFileStatusDto>> {
    let output = Command::new("git")
        .args(["status", "--short"])
        .current_dir(workspace_path)
        .output()?;
    if !output.status.success() {
        return Ok(vec![]);
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| WorkspaceFileStatusDto {
            status: line.get(..2).unwrap_or("??").trim().into(),
            path: line.get(3..).unwrap_or(line).into(),
        })
        .collect())
}

fn run_git(workspace_path: &str, args: &[&str]) -> Result<()> {
    let output = Command::new("git")
        .args(args)
        .current_dir(workspace_path)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        anyhow::bail!(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn workspace_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.into())
}

fn saved_detail(
    id: String,
    name: String,
    layout_json: String,
    updated_at: i64,
) -> SavedWorkspaceDetailDto {
    SavedWorkspaceDetailDto {
        id,
        name,
        layout_json,
        updated_at,
    }
}
