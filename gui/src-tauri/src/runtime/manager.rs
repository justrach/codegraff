use std::collections::{HashMap, HashSet};
use std::fs;
use std::future::Future;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use bstr::ByteSlice;
use forge_api::API;
use forge_domain::{
    AgentId, AgentInfo, AnyProvider, AuthContextRequest, AuthContextResponse, AuthMethod,
    ConfigOperation, ConversationId, Effort, McpConfig, McpServerConfig, Model, ModelConfig, Node,
    NodeData, ProviderId, ProviderModels, Scope, SearchParams, ServerName, SyncProgress,
};
use futures::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, mpsc, oneshot};
use uuid::Uuid;

use crate::bridge::emitter::UiEventEmitter;
use crate::bridge::followup::FollowupBridge;
use crate::dto::{
    AgentSummaryDto, AgentsPayloadDto, ChatBindingDto, CommandDescriptorDto,
    CommandExecutionKindDto, CommandKindDto, CommandPayloadDto, CommandResultKindDto,
    CommandRunResultDto, CompleteProviderAuthInput, ConversationsPayloadDto,
    CreateSavedWorkspaceInput, FollowupRequestDto, FollowupResponseDto, McpImportInput,
    McpServerActionInput, McpServerSummaryDto, McpSettingsPayloadDto, PromptModelOptionDto,
    PromptSettingsDto, ProviderAuthMethodDto, ProviderAuthMethodKindDto, ProviderAuthSessionDto,
    ProviderAuthSessionKindDto, ProviderOAuthCallbackDto, ProviderSummaryDto, ProviderUrlParamDto,
    RemoveProviderInput, RuntimeStatusDto, SaveConversationLayoutInput, SendPromptInput,
    SessionMessageDto, SessionSnapshotDto, StartProviderAuthInput, UpdatePromptSettingsInput,
    UpdateSavedWorkspaceLayoutInput, WorkflowDraftInput, WorkflowDraftPayloadDto, WorkflowNodeDto,
    WorkspaceFileStatusDto, WorkspaceInfoPayloadDto, WorkspaceQueryInput,
    WorkspaceSearchPayloadDto, WorkspaceSearchResultDto, WorkspaceStatusPayloadDto,
    WorkspaceSyncPayloadDto,
};
use crate::persistence::project_store::ProjectStore;

use super::{
    ConversationSessionState, ForgeRuntime, MISSING_SESSION_MESSAGE, RuntimeFactory, RuntimeState,
    StreamChatRequest, WorkspaceKind, build_snapshot, canonicalize_workspace_path,
    configuration_error_message, create_conversation_record, create_message_id,
    derive_conversation_title_from_messages, format_error_chain, read_config,
    select_empty_draft_conversation_id, shared_runtime_state, user_prompt_text_for_display,
    workspace::{sync_workspace_session_state, update_workspace_identity},
    workspace_name,
};

#[derive(Clone)]
enum ProviderRuntimeScope {
    Workspace(String),
    Transient(PathBuf),
}

#[derive(Clone)]
struct PendingProviderAuthSession {
    auth_method_kind: ProviderAuthMethodKindDto,
    provider_id: ProviderId,
    request: AuthContextRequest,
    runtime_scope: ProviderRuntimeScope,
}

#[derive(Clone)]
struct ParsedProviderOAuthCallback {
    authorization_code: Option<String>,
    error_message: Option<String>,
    state: String,
}

#[derive(Default)]
struct ProviderOAuthCallbackListenerState {
    is_running: bool,
}

#[derive(Clone)]
pub struct RuntimeManager {
    pub(super) emitter: Arc<dyn UiEventEmitter>,
    pub(super) followups: Arc<FollowupBridge>,
    pub(super) projects: Arc<ProjectStore>,
    pub(super) state: Arc<Mutex<RuntimeState>>,
    pub(super) factory: Arc<RuntimeFactory>,
    pending_provider_auth_sessions: Arc<Mutex<HashMap<String, PendingProviderAuthSession>>>,
    provider_oauth_callback_listener: Arc<Mutex<ProviderOAuthCallbackListenerState>>,
    pub(super) stop_request_senders: Arc<Mutex<HashMap<String, oneshot::Sender<()>>>>,
}

impl RuntimeManager {
    pub(crate) fn new(
        emitter: Arc<dyn UiEventEmitter>,
        followups: Arc<FollowupBridge>,
        projects: Arc<ProjectStore>,
    ) -> Self {
        Self {
            emitter,
            followups: followups.clone(),
            projects,
            state: shared_runtime_state(),
            factory: Arc::new(RuntimeFactory::new(followups)),
            pending_provider_auth_sessions: Arc::new(Mutex::new(HashMap::new())),
            provider_oauth_callback_listener: Arc::new(Mutex::new(
                ProviderOAuthCallbackListenerState::default(),
            )),
            stop_request_senders: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn handle_followup_requests(
        self: Arc<Self>,
        mut receiver: mpsc::UnboundedReceiver<FollowupRequestDto>,
    ) {
        while let Some(request) = receiver.recv().await {
            {
                let mut state = self.state.lock().await;
                state
                    .pending_followups_by_conversation
                    .insert(request.conversation_id.clone(), request);
                state.ui_error = None;
            }

            let _ = self.emit_session_snapshot().await;
        }
    }

    pub async fn get_runtime_status(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<RuntimeStatusDto> {
        self.ensure_known_workspaces_loaded().await?;

        if let Some(workspace_path) = workspace_path {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            self.prepare_workspace(&workspace_path).await?;

            let state = self.state.lock().await;
            let workspace = state
                .workspaces
                .get(&workspace_path)
                .context("Workspace is not loaded.")?;
            return Ok(RuntimeStatusDto::new(
                Some(Path::new(&workspace_path)),
                workspace.configured,
                workspace.configuration_error.clone(),
            ));
        }

        let state = self.state.lock().await;
        if let Some(workspace_path) = state.active_workspace_path.as_ref() {
            let workspace = state
                .workspaces
                .get(workspace_path)
                .context("Active workspace is not loaded.")?;
            return Ok(RuntimeStatusDto::new(
                Some(Path::new(workspace_path)),
                workspace.configured,
                workspace.configuration_error.clone(),
            ));
        }

        let (config, configuration_error) = read_config();
        Ok(RuntimeStatusDto::new(
            None,
            config.session.is_some(),
            configuration_error_message(config.session.is_some(), configuration_error),
        ))
    }

    pub async fn get_session_snapshot(&self) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async { self.snapshot().await })
            .await
    }

    pub async fn get_prompt_settings(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<PromptSettingsDto> {
        self.with_recorded_ui_error(async {
            self.ensure_known_workspaces_loaded().await?;
            let requested_workspace_path = if let Some(workspace_path) = workspace_path {
                Some(canonicalize_workspace_path(PathBuf::from(workspace_path))?)
            } else {
                self.state.lock().await.active_workspace_path.clone()
            };
            let Some(workspace_path) = requested_workspace_path else {
                return Ok(PromptSettingsDto {
                    available_models: Vec::new(),
                    selected_provider_id: None,
                    selected_model_id: None,
                    selected_reasoning_effort: None,
                });
            };

            let runtime = self.prepare_workspace(&workspace_path).await?;
            let prompt_settings = build_prompt_settings(&runtime).await?;
            self.refresh_cached_runtime_config(&workspace_path).await;
            Ok(prompt_settings)
        })
        .await
    }

    pub async fn update_prompt_settings(
        &self,
        input: UpdatePromptSettingsInput,
    ) -> anyhow::Result<PromptSettingsDto> {
        self.with_recorded_ui_error(async {
            self.ensure_known_workspaces_loaded().await?;
            let workspace_path = if let Some(workspace_path) = input.workspace_path.clone() {
                canonicalize_workspace_path(PathBuf::from(workspace_path))?
            } else {
                self.state
                    .lock()
                    .await
                    .active_workspace_path
                    .clone()
                    .context("No active workspace.")?
            };
            let runtime = self.prepare_workspace(&workspace_path).await?;

            let provider_id = ProviderId::from(input.provider_id.clone());
            let all_provider_models = runtime.api.get_all_provider_models().await?;
            let selected_model = all_provider_models
                .iter()
                .find(|provider_models| provider_models.provider_id == provider_id)
                .and_then(|provider_models| {
                    provider_models
                        .models
                        .iter()
                        .find(|model| model.id.as_str() == input.model_id)
                })
                .cloned()
                .with_context(|| {
                    format!(
                        "Model '{}' is not available for provider '{}'.",
                        input.model_id, input.provider_id
                    )
                })?;

            let allowed_efforts = reasoning_efforts_for_model(&provider_id, &selected_model);
            let mut operations = vec![ConfigOperation::SetSessionConfig(ModelConfig::new(
                provider_id.clone(),
                input.model_id.clone(),
            ))];

            if let Some(reasoning_effort) = input.reasoning_effort.as_deref() {
                if !allowed_efforts
                    .iter()
                    .any(|candidate| candidate == reasoning_effort)
                {
                    anyhow::bail!(
                        "Reasoning effort '{}' is not available for model '{}'.",
                        reasoning_effort,
                        input.model_id
                    );
                }

                let effort = Effort::from_str(reasoning_effort).map_err(|_| {
                    anyhow::anyhow!("Invalid reasoning effort '{reasoning_effort}'.")
                })?;
                operations.push(ConfigOperation::SetReasoningEffort(effort));
            }

            runtime.api.update_config(operations).await?;
            self.refresh_cached_runtime_config(&workspace_path).await;
            build_prompt_settings(&runtime).await
        })
        .await
    }

    pub async fn list_providers(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<Vec<ProviderSummaryDto>> {
        self.with_recorded_ui_error(async {
            let runtime_scope = self.resolve_provider_runtime_scope(workspace_path).await?;
            let runtime = self.provider_runtime(&runtime_scope).await?;
            let mut providers = runtime.api.get_providers().await?;
            providers.sort_by(|left, right| {
                right
                    .is_configured()
                    .cmp(&left.is_configured())
                    .then_with(|| left.id().to_string().cmp(&right.id().to_string()))
            });

            Ok(providers.into_iter().map(map_provider_summary).collect())
        })
        .await
    }

    pub async fn start_provider_auth(
        &self,
        input: StartProviderAuthInput,
    ) -> anyhow::Result<ProviderAuthSessionDto> {
        self.with_recorded_ui_error(async {
            let runtime_scope = self
                .resolve_provider_runtime_scope(input.workspace_path.clone())
                .await?;
            let runtime = self.provider_runtime(&runtime_scope).await?;
            let provider_id = ProviderId::from(input.provider_id.clone());
            let provider = runtime.api.get_provider(&provider_id).await?;
            let auth_method = resolve_provider_auth_method(&provider, &input.auth_method)?;
            let request = runtime
                .api
                .init_provider_auth(provider_id.clone(), auth_method)
                .await?;
            let auth_session_id = Uuid::new_v4().to_string();

            self.pending_provider_auth_sessions.lock().await.insert(
                auth_session_id.clone(),
                PendingProviderAuthSession {
                    auth_method_kind: input.auth_method.clone(),
                    provider_id,
                    request: request.clone(),
                    runtime_scope,
                },
            );

            if matches!(request, AuthContextRequest::Code(_)) {
                self.ensure_provider_oauth_callback_listener().await;
            }

            Ok(map_provider_auth_session(
                auth_session_id,
                &input.auth_method,
                request,
            ))
        })
        .await
    }

    pub async fn complete_provider_auth(
        &self,
        input: CompleteProviderAuthInput,
    ) -> anyhow::Result<ProviderSummaryDto> {
        self.with_recorded_ui_error(async {
            let pending = self
                .pending_provider_auth_sessions
                .lock()
                .await
                .get(&input.auth_session_id)
                .cloned()
                .context("Provider setup expired. Start again.")?;

            let runtime = self.provider_runtime(&pending.runtime_scope).await?;
            let response = match pending.request.clone() {
                AuthContextRequest::ApiKey(request) => {
                    let api_key = match pending.auth_method_kind {
                        ProviderAuthMethodKindDto::GoogleAdc => "google_adc_marker".to_string(),
                        ProviderAuthMethodKindDto::AwsProfile => "aws_profile_marker".to_string(),
                        ProviderAuthMethodKindDto::ApiKey => input
                            .api_key
                            .clone()
                            .filter(|value| !value.trim().is_empty())
                            .context("Enter an API key.")?,
                        _ => anyhow::bail!("Unexpected auth method for API key setup."),
                    };
                    AuthContextResponse::api_key(
                        request,
                        api_key,
                        input
                            .url_parameters
                            .iter()
                            .map(|parameter| (parameter.name.clone(), parameter.value.clone()))
                            .collect::<HashMap<_, _>>(),
                    )
                }
                AuthContextRequest::DeviceCode(request) => {
                    AuthContextResponse::device_code(request)
                }
                AuthContextRequest::Code(request) => AuthContextResponse::code(
                    request,
                    input
                        .authorization_code
                        .clone()
                        .filter(|value| !value.trim().is_empty())
                        .context("Paste the authorization code to finish setup.")?,
                ),
            };

            runtime
                .api
                .complete_provider_auth(
                    pending.provider_id.clone(),
                    response,
                    Duration::from_secs(180),
                )
                .await?;

            self.pending_provider_auth_sessions
                .lock()
                .await
                .remove(&input.auth_session_id);

            self.ensure_provider_scope_default_session_config(&pending.runtime_scope, &runtime)
                .await?;

            let provider = runtime.api.get_provider(&pending.provider_id).await?;
            Ok(map_provider_summary(provider))
        })
        .await
    }

    async fn handle_provider_oauth_callback_url(&self, url: url::Url) -> bool {
        let Some(callback) = parse_provider_oauth_callback_url(&url) else {
            return false;
        };

        let pending = {
            let sessions = self.pending_provider_auth_sessions.lock().await;
            sessions
                .iter()
                .find_map(|(auth_session_id, pending)| match &pending.request {
                    AuthContextRequest::Code(request)
                        if request.state.as_str() == callback.state.as_str() =>
                    {
                        Some((
                            auth_session_id.clone(),
                            pending.provider_id.as_ref().to_string(),
                        ))
                    }
                    _ => None,
                })
        };

        let Some((auth_session_id, provider_id)) = pending else {
            return false;
        };

        let _ = self
            .emitter
            .emit_provider_oauth_callback(ProviderOAuthCallbackDto {
                auth_session_id,
                provider_id,
                authorization_code: callback.authorization_code.clone(),
                error_message: callback.error_message.clone(),
            });

        true
    }

    async fn ensure_provider_oauth_callback_listener(&self) {
        {
            let mut state = self.provider_oauth_callback_listener.lock().await;
            if state.is_running {
                return;
            }

            state.is_running = true;
        }

        let manager = self.clone();
        tokio::spawn(async move {
            manager.run_provider_oauth_callback_listener().await;
        });
    }

    async fn run_provider_oauth_callback_listener(self) {
        const CALLBACK_ADDRS: &[&str] = &["127.0.0.1:1455", "[::1]:1455"];

        let mut listeners = Vec::new();
        for addr in CALLBACK_ADDRS {
            match TcpListener::bind(addr).await {
                Ok(listener) => listeners.push(listener),
                Err(error) if error.kind() == ErrorKind::AddrInUse => {}
                Err(error) => {
                    log::warn!(
                        "Failed to bind provider OAuth callback listener on {addr}: {error}"
                    );
                }
            }
        }

        if listeners.is_empty() {
            self.provider_oauth_callback_listener
                .lock()
                .await
                .is_running = false;
            return;
        }

        for listener in listeners {
            let manager = self.clone();
            tokio::spawn(async move {
                manager
                    .accept_provider_oauth_callback_connections(listener)
                    .await;
            });
        }

        std::future::pending::<()>().await;
    }

    async fn accept_provider_oauth_callback_connections(self, listener: TcpListener) {
        loop {
            let (stream, _) = match listener.accept().await {
                Ok(accepted) => accepted,
                Err(error) => {
                    log::warn!("Failed to accept provider OAuth callback: {error}");
                    continue;
                }
            };

            let manager = self.clone();
            tokio::spawn(async move {
                manager.handle_provider_oauth_callback_stream(stream).await;
            });
        }
    }

    async fn handle_provider_oauth_callback_stream(&self, mut stream: TcpStream) {
        let mut buffer = vec![0_u8; 8192];
        let bytes_read = match stream.read(&mut buffer).await {
            Ok(bytes_read) => bytes_read,
            Err(error) => {
                log::warn!("Failed to read provider OAuth callback request: {error}");
                return;
            }
        };

        let request = buffer[..bytes_read].as_bstr().to_string();
        let request_target = request
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1));

        let Some(request_target) = request_target else {
            let _ = write_provider_oauth_callback_response(&mut stream, 400, false).await;
            return;
        };

        let callback_url = match url::Url::parse(&format!("http://localhost:1455{request_target}"))
        {
            Ok(url) => url,
            Err(error) => {
                log::warn!("Failed to parse provider OAuth callback URL: {error}");
                let _ = write_provider_oauth_callback_response(&mut stream, 400, false).await;
                return;
            }
        };

        let handled = self.handle_provider_oauth_callback_url(callback_url).await;
        let status = if handled { 200 } else { 400 };
        let _ = write_provider_oauth_callback_response(&mut stream, status, handled).await;
    }

    pub async fn remove_provider(
        &self,
        input: RemoveProviderInput,
    ) -> anyhow::Result<ProviderSummaryDto> {
        self.with_recorded_ui_error(async {
            let runtime_scope = self
                .resolve_provider_runtime_scope(input.workspace_path.clone())
                .await?;
            let runtime = self.provider_runtime(&runtime_scope).await?;
            let provider_id = ProviderId::from(input.provider_id);
            runtime.api.remove_provider(&provider_id).await?;
            let provider = runtime.api.get_provider(&provider_id).await?;
            Ok(map_provider_summary(provider))
        })
        .await
    }

    pub async fn open_workspace(&self, path: PathBuf) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(path)?;
            self.prepare_workspace(&workspace_path).await?;
            let selected_conversation_id = self.activate_workspace(&workspace_path).await;

            if let Some(conversation_id) = selected_conversation_id {
                self.ensure_conversation_loaded(&workspace_path, &conversation_id)
                    .await?;
            }

            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn select_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            self.prepare_workspace(&workspace_path).await?;
            self.ensure_conversation_loaded(&workspace_path, &conversation_id)
                .await?;
            self.select_workspace_conversation(&workspace_path, &conversation_id)
                .await;
            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn ensure_conversation_view(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            self.prepare_workspace(&workspace_path).await?;
            self.ensure_conversation_loaded_or_insert_empty(&workspace_path, &conversation_id)
                .await?;
            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn start_new_chat(
        &self,
        workspace_path: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            self.prepare_workspace(&workspace_path).await?;
            let (workspace_kind, workspace_name) =
                self.resolve_workspace_identity(&workspace_path)?;

            let mut state = self.state.lock().await;
            state.active_workspace_path = Some(workspace_path.clone());
            state.ui_error = None;
            let workspace = sync_workspace_session_state(
                &mut state,
                &workspace_path,
                workspace_kind,
                &workspace_name,
            );
            workspace.selected_conversation_id = None;
            drop(state);

            self.emit_current_snapshot().await
        })
        .await
    }

    /// Compacts the context of the given conversation (the `/compact` command)
    /// and reloads it so the snapshot reflects the compacted history.
    pub async fn compact_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            let runtime = self.ensure_workspace_runtime(&workspace_path).await?;
            let parsed = ConversationId::parse(&conversation_id)?;
            runtime.api.compact_conversation(&parsed).await?;
            self.reload_conversation_from_persistence(&workspace_path, &conversation_id, None)
                .await?;
            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn create_managed_chat(&self) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = self.projects.create_managed_chat_workspace()?;
            self.start_new_chat(workspace_path.to_string_lossy().into_owned())
                .await
        })
        .await
    }

    pub async fn rename_workspace(
        &self,
        workspace_path: String,
        display_name: Option<String>,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            self.projects
                .set_workspace_display_name(Path::new(&workspace_path), display_name.as_deref())?;
            let (workspace_kind, workspace_name) =
                self.resolve_workspace_identity(&workspace_path)?;

            {
                let mut state = self.state.lock().await;
                if let Some(workspace) = state.workspaces.get_mut(&workspace_path) {
                    update_workspace_identity(workspace, workspace_kind, &workspace_name);
                }
                state.ui_error = None;
            }

            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn send_prompt(&self, input: SendPromptInput) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path =
                canonicalize_workspace_path(PathBuf::from(input.workspace_path.trim()))?;

            let prompt = input.prompt.trim().to_string();
            if prompt.is_empty() {
                anyhow::bail!("Prompt cannot be empty.");
            }
            let display_prompt = user_prompt_text_for_display(&prompt);

            let runtime = self.prepare_workspace(&workspace_path).await?;
            let session_config = self
                .ensure_workspace_default_session_config(&workspace_path, &runtime)
                .await?;

            if session_config.is_none() {
                anyhow::bail!("{}", MISSING_SESSION_MESSAGE);
            }

            let mut conversation_id = if let Some(conversation_id) = input.conversation_id.clone() {
                conversation_id
            } else {
                let state = self.state.lock().await;
                state
                    .workspaces
                    .get(&workspace_path)
                    .and_then(|workspace| workspace.selected_conversation_id.clone())
                    .or_else(|| select_empty_draft_conversation_id(&state, &workspace_path))
                    .unwrap_or_default()
            };

            if conversation_id.is_empty() {
                let mut current = None;
                let created =
                    create_conversation_record(runtime.api.as_ref(), &mut current).await?;
                conversation_id = created.into_string();
                self.refresh_workspace_conversations(&workspace_path)
                    .await?;
            }

            self.ensure_conversation_loaded_or_insert_empty(&workspace_path, &conversation_id)
                .await?;

            let request_id = Uuid::new_v4().to_string();
            let request_agent_id = input
                .agent_id
                .clone()
                .unwrap_or_else(|| AgentId::FORGE.to_string());
            let (workspace_kind, workspace_name) =
                self.resolve_workspace_identity(&workspace_path)?;

            {
                let mut state = self.state.lock().await;
                let is_running = state
                    .conversations
                    .get(&conversation_id)
                    .map(|conversation| !conversation.active_request_ids.is_empty())
                    .unwrap_or(false);
                if is_running {
                    anyhow::bail!("This chat is already running.");
                }

                let order = state.allocate_order();
                let conversation = state
                    .conversations
                    .entry(conversation_id.clone())
                    .or_insert_with(|| ConversationSessionState {
                        workspace_path: workspace_path.clone(),
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

                conversation.workspace_path = workspace_path.clone();
                conversation
                    .request_agent_ids
                    .insert(request_id.clone(), request_agent_id);
                conversation.active_request_ids.push(request_id.clone());
                conversation.is_local_draft = false;
                conversation.order = order;
                conversation.messages.push(SessionMessageDto::User {
                    id: create_message_id("user", &request_id, conversation.messages.len()),
                    request_id: request_id.clone(),
                    text: display_prompt,
                });
                conversation.title = Some(derive_conversation_title_from_messages(
                    &conversation.messages,
                ));

                let workspace = sync_workspace_session_state(
                    &mut state,
                    &workspace_path,
                    workspace_kind,
                    &workspace_name,
                );
                workspace.selected_conversation_id = Some(conversation_id.clone());
                state.active_workspace_path = Some(workspace_path.clone());
                state
                    .pending_followups_by_conversation
                    .remove(&conversation_id);
                state.ui_error = None;
            }

            let snapshot = self.emit_current_snapshot().await?;
            let (stop_sender, stop_receiver) = oneshot::channel();
            self.stop_request_senders
                .lock()
                .await
                .insert(request_id.clone(), stop_sender);

            let manager = self.clone();
            tauri::async_runtime::spawn(async move {
                manager
                    .stream_chat(StreamChatRequest {
                        runtime,
                        workspace_path,
                        request_id,
                        conversation_id,
                        prompt,
                        agent_id: input.agent_id,
                        stop_receiver,
                    })
                    .await;
            });

            Ok(snapshot)
        })
        .await
    }

    pub async fn stop_prompt(&self, input: ChatBindingDto) -> anyhow::Result<()> {
        let workspace_path = canonicalize_workspace_path(PathBuf::from(input.workspace_path))?;

        let active_request_ids = {
            let state = self.state.lock().await;
            let Some(conversation) = state.conversations.get(&input.conversation_id) else {
                return Ok(());
            };
            if conversation.workspace_path != workspace_path {
                return Ok(());
            }
            conversation.active_request_ids.clone()
        };

        for request_id in active_request_ids {
            if let Some(sender) = self.take_stop_request_sender(&request_id).await {
                let _ = sender.send(());
            }
        }

        Ok(())
    }

    pub async fn respond_followup(
        &self,
        response: FollowupResponseDto,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            self.followups.respond(response.clone()).await?;

            {
                let mut state = self.state.lock().await;
                let conversation_id = state.pending_followups_by_conversation.iter().find_map(
                    |(conversation_id, request)| {
                        (request.followup_id == response.followup_id)
                            .then_some(conversation_id.clone())
                    },
                );
                if let Some(conversation_id) = conversation_id {
                    state
                        .pending_followups_by_conversation
                        .remove(&conversation_id);
                }
                state.ui_error = None;
            }

            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn archive_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            self.prepare_workspace(&workspace_path).await?;

            let should_delete_persisted = {
                let state = self.state.lock().await;
                let is_running = state
                    .conversations
                    .get(&conversation_id)
                    .map(|conversation| !conversation.active_request_ids.is_empty())
                    .unwrap_or(false);
                if is_running {
                    anyhow::bail!("Cannot archive a running chat.");
                }

                state
                    .workspaces
                    .get(&workspace_path)
                    .map(|workspace| {
                        workspace
                            .persisted_conversations
                            .iter()
                            .any(|conversation| conversation.conversation_id == conversation_id)
                    })
                    .unwrap_or(false)
            };

            if should_delete_persisted {
                let runtime = self.ensure_workspace_runtime(&workspace_path).await?;
                let conversation_id = ConversationId::parse(&conversation_id)?;
                runtime.api.delete_conversation(&conversation_id).await?;
                self.refresh_workspace_conversations(&workspace_path)
                    .await?;
            }

            self.projects.delete_conversation_layout(&conversation_id)?;

            {
                let mut state = self.state.lock().await;
                state.conversations.remove(&conversation_id);
                state
                    .pending_followups_by_conversation
                    .remove(&conversation_id);

                if let Some(workspace) = state.workspaces.get_mut(&workspace_path) {
                    workspace
                        .persisted_conversations
                        .retain(|conversation| conversation.conversation_id != conversation_id);
                    if workspace.selected_conversation_id.as_deref()
                        == Some(conversation_id.as_str())
                    {
                        workspace.selected_conversation_id = None;
                    }
                }
                state.ui_error = None;
            }

            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn archive_workspace(
        &self,
        workspace_path: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            let workspace_path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            let workspace_kind = self
                .projects
                .get_workspace_kind(Path::new(&workspace_path))?
                .unwrap_or(crate::persistence::project_store::RegisteredWorkspaceKind::Project);

            let conversation_ids = {
                let state = self.state.lock().await;
                let conversation_ids = state
                    .workspaces
                    .get(&workspace_path)
                    .into_iter()
                    .flat_map(|workspace| {
                        workspace
                            .persisted_conversations
                            .iter()
                            .map(|conversation| conversation.conversation_id.clone())
                    })
                    .chain(
                        state
                            .conversations
                            .iter()
                            .filter(|(_, conversation)| {
                                conversation.workspace_path == workspace_path.as_str()
                            })
                            .map(|(conversation_id, _)| conversation_id.clone()),
                    )
                    .collect::<HashSet<_>>();

                let has_running_conversation = conversation_ids.iter().any(|conversation_id| {
                    state
                        .conversations
                        .get(conversation_id)
                        .map(|conversation| !conversation.active_request_ids.is_empty())
                        .unwrap_or(false)
                });
                if has_running_conversation {
                    anyhow::bail!("Cannot archive a workspace with a running chat.");
                }

                conversation_ids.into_iter().collect::<Vec<_>>()
            };

            self.projects
                .archive_workspace(Path::new(&workspace_path))?;
            for conversation_id in &conversation_ids {
                self.projects.delete_conversation_layout(conversation_id)?;
            }

            if matches!(
                workspace_kind,
                crate::persistence::project_store::RegisteredWorkspaceKind::ManagedChat
            ) {
                match fs::remove_dir_all(&workspace_path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
            }

            {
                let mut state = self.state.lock().await;
                for conversation_id in &conversation_ids {
                    state.conversations.remove(conversation_id);
                    state
                        .pending_followups_by_conversation
                        .remove(conversation_id);
                }

                state.workspaces.remove(&workspace_path);
                state.workspace_order.retain(|path| path != &workspace_path);
                if state.active_workspace_path.as_deref() == Some(workspace_path.as_str()) {
                    state.active_workspace_path = state
                        .workspace_order
                        .iter()
                        .find(|path| state.workspaces.contains_key(*path))
                        .cloned();
                }
                state.ui_error = None;
            }

            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn save_conversation_layout(
        &self,
        input: SaveConversationLayoutInput,
    ) -> anyhow::Result<()> {
        self.projects
            .save_conversation_layout(&input.conversation_id, &input.layout_json)
    }

    pub async fn get_conversation_layout(
        &self,
        conversation_id: String,
    ) -> anyhow::Result<Option<String>> {
        self.projects.get_conversation_layout(&conversation_id)
    }

    pub async fn create_saved_workspace(
        &self,
        input: CreateSavedWorkspaceInput,
    ) -> anyhow::Result<crate::dto::SavedWorkspaceDetailDto> {
        let workspace_name = self.generate_saved_workspace_name(&input.chats).await?;
        let workspace_id = Uuid::new_v4().to_string();
        let record = self.projects.create_saved_workspace(
            &workspace_id,
            &workspace_name,
            &input.layout_json,
        )?;
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot)?;

        Ok(crate::dto::SavedWorkspaceDetailDto {
            id: record.id,
            name: record.name,
            layout_json: record.layout_json,
            updated_at: record.updated_at,
        })
    }

    pub async fn update_saved_workspace_layout(
        &self,
        input: UpdateSavedWorkspaceLayoutInput,
    ) -> anyhow::Result<crate::dto::SavedWorkspaceDetailDto> {
        let record = self
            .projects
            .update_saved_workspace_layout(&input.workspace_id, &input.layout_json)?;
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot)?;

        Ok(crate::dto::SavedWorkspaceDetailDto {
            id: record.id,
            name: record.name,
            layout_json: record.layout_json,
            updated_at: record.updated_at,
        })
    }

    pub async fn get_saved_workspace(
        &self,
        workspace_id: String,
    ) -> anyhow::Result<Option<crate::dto::SavedWorkspaceDetailDto>> {
        Ok(self
            .projects
            .get_saved_workspace(&workspace_id)?
            .map(|record| crate::dto::SavedWorkspaceDetailDto {
                id: record.id,
                name: record.name,
                layout_json: record.layout_json,
                updated_at: record.updated_at,
            }))
    }

    pub async fn rename_saved_workspace(
        &self,
        workspace_id: String,
        name: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            self.projects.rename_saved_workspace(&workspace_id, &name)?;
            {
                let mut state = self.state.lock().await;
                state.ui_error = None;
            }
            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn delete_saved_workspace(
        &self,
        workspace_id: String,
    ) -> anyhow::Result<SessionSnapshotDto> {
        self.with_recorded_ui_error(async {
            self.projects.delete_saved_workspace(&workspace_id)?;
            {
                let mut state = self.state.lock().await;
                state.ui_error = None;
            }
            self.emit_current_snapshot().await
        })
        .await
    }

    pub async fn cancel_pending_followups(&self) {
        self.followups.cancel_all().await;
        let mut state = self.state.lock().await;
        state.pending_followups_by_conversation.clear();
    }

    pub(super) async fn snapshot(&self) -> anyhow::Result<SessionSnapshotDto> {
        self.ensure_known_workspaces_loaded().await?;
        let state = self.state.lock().await;
        let saved_workspaces = self.projects.list_saved_workspaces()?;
        Ok(build_snapshot(&state, &saved_workspaces))
    }

    pub(super) async fn emit_session_snapshot(&self) -> anyhow::Result<()> {
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot)
    }

    pub(super) fn emit_snapshot(&self, snapshot: SessionSnapshotDto) -> anyhow::Result<()> {
        self.emitter.emit_session_updated(snapshot)
    }

    pub(super) async fn with_recorded_ui_error<T, F>(&self, operation: F) -> anyhow::Result<T>
    where
        F: Future<Output = anyhow::Result<T>>,
    {
        let result = operation.await;

        if let Err(error) = &result {
            let _ = self.record_ui_error(&format_error_chain(error)).await;
        }

        result
    }

    pub(super) async fn record_ui_error(&self, message: &str) -> anyhow::Result<()> {
        {
            let mut state = self.state.lock().await;
            state.ui_error = Some(message.to_string());
        }
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot)
    }

    pub(super) async fn clear_ui_error(&self) -> anyhow::Result<()> {
        {
            let mut state = self.state.lock().await;
            if state.ui_error.is_none() {
                return Ok(());
            }
            state.ui_error = None;
        }
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot)
    }

    pub(super) async fn take_stop_request_sender(
        &self,
        request_id: &str,
    ) -> Option<oneshot::Sender<()>> {
        self.stop_request_senders.lock().await.remove(request_id)
    }

    pub(super) async fn prepare_workspace(
        &self,
        workspace_path: &str,
    ) -> anyhow::Result<ForgeRuntime> {
        match self
            .projects
            .get_workspace_kind(Path::new(workspace_path))?
        {
            Some(crate::persistence::project_store::RegisteredWorkspaceKind::ManagedChat) => {
                self.projects
                    .touch_managed_chat_workspace(Path::new(workspace_path))?;
            }
            _ => {
                self.projects.add_project(Path::new(workspace_path))?;
            }
        }
        let runtime = self.ensure_workspace_runtime(workspace_path).await?;
        self.refresh_workspace_conversations(workspace_path).await?;
        Ok(runtime)
    }

    /// Returns the full set of autocompletable graff commands: the built-in
    /// REPL commands (sourced directly from `forge_main`'s `AppCommand` so the
    /// list never drifts) plus any dynamic workflow and agent commands for the
    /// active workspace. If no runtime can be resolved, only the built-ins are
    /// returned.
    pub async fn list_commands(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<Vec<CommandDescriptorDto>> {
        let mut commands: Vec<CommandDescriptorDto> = forge_main::builtin_command_catalog()
            .into_iter()
            .map(|spec| {
                // The REPL enum's canonical names for the agent-switch shortcuts
                // are `forge`/`muse`, but users know them by their command names
                // `act`/`plan`. Present those as primary in the GUI and keep the
                // enum name as the alias.
                let (name, aliases) = match spec.name.as_str() {
                    "forge" => ("act".to_string(), vec!["forge".to_string()]),
                    "muse" => ("plan".to_string(), vec!["muse".to_string()]),
                    _ => (spec.name, spec.aliases),
                };
                let metadata = command_metadata(&name, spec.is_agent_switch);
                CommandDescriptorDto {
                    name,
                    usage: spec.usage,
                    aliases,
                    kind: CommandKindDto::Builtin,
                    value: None,
                    is_agent_switch: spec.is_agent_switch,
                    execution_kind: metadata.execution_kind,
                    requires_workspace: metadata.requires_workspace,
                    requires_conversation: metadata.requires_conversation,
                    argument_hint: metadata.argument_hint,
                    result_kind: metadata.result_kind,
                }
            })
            .collect();

        if let Ok(scope) = self.resolve_provider_runtime_scope(workspace_path).await {
            if let Ok(runtime) = self.provider_runtime(&scope).await {
                if let Ok(workflow) = runtime.api.get_commands().await {
                    for command in workflow {
                        commands.push(CommandDescriptorDto {
                            name: command.name,
                            usage: command.description,
                            aliases: Vec::new(),
                            kind: CommandKindDto::Workflow,
                            value: command.prompt,
                            is_agent_switch: false,
                            execution_kind: CommandExecutionKindDto::Runnable,
                            requires_workspace: false,
                            requires_conversation: false,
                            argument_hint: None,
                            result_kind: CommandResultKindDto::Text,
                        });
                    }
                }

                if let Ok(agents) = runtime.api.get_agent_infos().await {
                    for agent in agents {
                        let id = agent.id.as_str().to_string();
                        let title = agent.title.clone().unwrap_or_else(|| id.clone());
                        commands.push(CommandDescriptorDto {
                            name: format!("agent-{id}"),
                            usage: format!("Switch to {title} agent"),
                            aliases: Vec::new(),
                            kind: CommandKindDto::Agent,
                            value: Some(id),
                            is_agent_switch: true,
                            execution_kind: CommandExecutionKindDto::Runnable,
                            requires_workspace: false,
                            requires_conversation: false,
                            argument_hint: None,
                            result_kind: CommandResultKindDto::Agents,
                        });
                    }
                }
            }
        }

        Ok(commands)
    }

    /// Executes a slash-command whose behaviour lives in the backend and returns
    /// a result the GUI can surface (informational text, a refreshed snapshot,
    /// or a saved-file path). Interactive commands are routed to GUI affordances
    /// on the frontend and never reach here.
    pub async fn run_command(
        &self,
        name: String,
        args: Vec<String>,
        workspace_path: Option<String>,
        conversation_id: Option<String>,
    ) -> anyhow::Result<CommandRunResultDto> {
        self.with_recorded_ui_error(async {
            let canonical_workspace = match workspace_path {
                Some(path) => Some(canonicalize_workspace_path(PathBuf::from(path))?),
                None => None,
            };

            let require_workspace = || -> anyhow::Result<String> {
                canonical_workspace
                    .clone()
                    .context("This command requires an open workspace.")
            };

            // Resolve an API handle (workspace runtime if available, else a
            // transient one) for read-only commands.
            let runtime = {
                let scope = self
                    .resolve_provider_runtime_scope(canonical_workspace.clone())
                    .await?;
                self.provider_runtime(&scope).await?
            };

            let text = |title: &str, body: String| CommandRunResultDto {
                title: title.to_string(),
                body: Some(body),
                snapshot: None,
                saved_path: None,
                result_kind: CommandResultKindDto::Text,
                payload: None,
            };

            let payload_result =
                |title: &str,
                 body: Option<String>,
                 result_kind: CommandResultKindDto,
                 payload: CommandPayloadDto| CommandRunResultDto {
                    title: title.to_string(),
                    body,
                    snapshot: None,
                    saved_path: None,
                    result_kind,
                    payload: Some(payload),
                };

            let result = match name.as_str() {
                "help" => text("Commands", format_command_catalog_markdown()),
                "usage" => {
                    let usage = runtime.api.user_usage().await?;
                    text("Usage", format!("{usage:#?}"))
                }
                "tools" => {
                    let tools = runtime.api.get_tools().await?;
                    text("Tools", format!("{tools:#?}"))
                }
                "skill" => {
                    let skills = runtime.api.get_skills().await?;
                    let body = if skills.is_empty() {
                        "No skills available.".to_string()
                    } else {
                        skills
                            .iter()
                            .map(|skill| format!("• {} — {}", skill.name, skill.description))
                            .collect::<Vec<_>>()
                            .join("\n")
                    };
                    text("Skills", body)
                }
                "info" => {
                    let config = runtime.api.get_session_config().await;
                    text("Info", format!("{config:#?}"))
                }
                "agent" | "agents" => {
                    let payload = self.build_agents_payload(&runtime).await?;
                    payload_result(
                        "Agents",
                        Some(format_agents_payload(&payload)),
                        CommandResultKindDto::Agents,
                        CommandPayloadDto::Agents(payload),
                    )
                }
                "sage" => {
                    let payload = self
                        .set_active_agent_for_runtime(&runtime, AgentId::SAGE.as_str())
                        .await?;
                    payload_result(
                        "Agent changed",
                        Some(format_agents_payload(&payload)),
                        CommandResultKindDto::Agents,
                        CommandPayloadDto::Agents(payload),
                    )
                }
                "reasoning-effort" => {
                    let effort = args.first().context(
                        "Usage: /reasoning-effort <none|minimal|low|medium|high|xhigh|max>",
                    )?;
                    let effort = Effort::from_str(effort)
                        .map_err(|_| anyhow::anyhow!("Invalid reasoning effort '{effort}'."))?;
                    runtime
                        .api
                        .update_config(vec![ConfigOperation::SetReasoningEffort(effort)])
                        .await?;
                    let payload = self.build_agents_payload(&runtime).await?;
                    payload_result(
                        "Reasoning effort changed",
                        Some(format_agents_payload(&payload)),
                        CommandResultKindDto::Agents,
                        CommandPayloadDto::Agents(payload),
                    )
                }
                "fast" => {
                    let enabled = args
                        .first()
                        .map(|value| matches!(value.as_str(), "on" | "true" | "1" | "yes"))
                        .unwrap_or(true);
                    runtime
                        .api
                        .update_config(vec![ConfigOperation::SetFastMode(enabled)])
                        .await?;
                    text(
                        "Fast mode",
                        format!("Fast mode is {}.", if enabled { "on" } else { "off" }),
                    )
                }
                name if name.starts_with("agent-") => {
                    let agent_id = name.trim_start_matches("agent-");
                    let payload = self
                        .set_active_agent_for_runtime(&runtime, agent_id)
                        .await?;
                    payload_result(
                        "Agent changed",
                        Some(format_agents_payload(&payload)),
                        CommandResultKindDto::Agents,
                        CommandPayloadDto::Agents(payload),
                    )
                }
                "conversation" | "resume" => {
                    let snapshot = self.snapshot().await?;
                    let workspace = canonical_workspace
                        .as_ref()
                        .and_then(|path| {
                            snapshot
                                .workspaces
                                .iter()
                                .find(|workspace| &workspace.workspace_path == path)
                        })
                        .or_else(|| {
                            snapshot.active_workspace_path.as_ref().and_then(|path| {
                                snapshot
                                    .workspaces
                                    .iter()
                                    .find(|workspace| &workspace.workspace_path == path)
                            })
                        });
                    let payload = ConversationsPayloadDto {
                        workspace_path: workspace.map(|workspace| workspace.workspace_path.clone()),
                        conversations: workspace
                            .map(|workspace| workspace.conversations.clone())
                            .unwrap_or_default(),
                    };
                    payload_result(
                        "Conversations",
                        Some(format!("{} conversations", payload.conversations.len())),
                        CommandResultKindDto::Conversations,
                        CommandPayloadDto::Conversations(payload),
                    )
                }
                "workspace-status" | "sync-status" => {
                    let path = require_workspace()?;
                    let statuses = runtime
                        .api
                        .get_workspace_status(PathBuf::from(path))
                        .await?;
                    let payload = WorkspaceStatusPayloadDto {
                        workspace_path: require_workspace()?,
                        files: statuses
                            .into_iter()
                            .map(|status| WorkspaceFileStatusDto {
                                path: status.path,
                                status: format!("{:?}", status.status),
                            })
                            .collect(),
                    };
                    payload_result(
                        "Workspace status",
                        Some(format_workspace_status(&payload)),
                        CommandResultKindDto::WorkspaceStatus,
                        CommandPayloadDto::WorkspaceStatus(payload),
                    )
                }
                "workspace-info" | "sync-info" => {
                    let path = require_workspace()?;
                    let payload = workspace_info_payload(
                        path.clone(),
                        runtime.api.get_workspace_info(PathBuf::from(path)).await?,
                    );
                    payload_result(
                        "Workspace info",
                        Some(format_workspace_info(&payload)),
                        CommandResultKindDto::WorkspaceInfo,
                        CommandPayloadDto::WorkspaceInfo(payload),
                    )
                }
                "workspace-init" | "sync-init" => {
                    let path = require_workspace()?;
                    let id = runtime.api.init_workspace(PathBuf::from(path)).await?;
                    text("Workspace initialized", format!("Workspace id: {id:?}"))
                }
                "workspace-sync" | "index" => {
                    let path = require_workspace()?;
                    let payload = self.workspace_sync_for_runtime(&runtime, path).await?;
                    payload_result(
                        "Workspace synced",
                        Some(payload.events.join("\n")),
                        CommandResultKindDto::WorkspaceSync,
                        CommandPayloadDto::WorkspaceSync(payload),
                    )
                }
                "workspace-query" | "workspace-search" => {
                    let path = require_workspace()?;
                    let query = args.join(" ").trim().to_string();
                    if query.is_empty() {
                        anyhow::bail!("Usage: /workspace-query <query>");
                    }
                    let payload = self
                        .workspace_query_for_runtime(
                            &runtime,
                            WorkspaceQueryInput {
                                workspace_path: path,
                                query,
                                use_case: None,
                                limit: Some(10),
                                starts_with: None,
                                ends_with: None,
                            },
                        )
                        .await?;
                    payload_result(
                        "Workspace search",
                        Some(format_workspace_search(&payload)),
                        CommandResultKindDto::WorkspaceSearch,
                        CommandPayloadDto::WorkspaceSearch(payload),
                    )
                }
                "workflow" => {
                    let goal = args.join(" ").trim().to_string();
                    if goal.is_empty() {
                        anyhow::bail!("Usage: /workflow <goal>");
                    }
                    let payload = self
                        .build_workflow_draft_for_runtime(&runtime, WorkflowDraftInput { goal })
                        .await?;
                    payload_result(
                        "Workflow review",
                        Some(payload.export_text.clone()),
                        CommandResultKindDto::WorkflowDraft,
                        CommandPayloadDto::WorkflowDraft(payload),
                    )
                }
                "mcp" => {
                    let subcommand = args.first().map(String::as_str).unwrap_or("list");
                    match subcommand {
                        "list" => {
                            let payload = self.mcp_settings_for_runtime(&runtime).await?;
                            payload_result(
                                "MCP servers",
                                Some(format_mcp_settings(&payload)),
                                CommandResultKindDto::Mcp,
                                CommandPayloadDto::Mcp(payload),
                            )
                        }
                        "show" => {
                            let name = args.get(1).context("Usage: /mcp show <name>")?;
                            let payload = self.mcp_settings_for_runtime(&runtime).await?;
                            let body = payload
                                .servers
                                .iter()
                                .find(|server| &server.name == name)
                                .map(format_mcp_server_summary)
                                .with_context(|| format!("MCP server '{name}' not found."))?;
                            payload_result(
                                "MCP server",
                                Some(body),
                                CommandResultKindDto::Mcp,
                                CommandPayloadDto::Mcp(payload),
                            )
                        }
                        "reload" => {
                            runtime.api.reload_mcp().await?;
                            let payload = self.mcp_settings_for_runtime(&runtime).await?;
                            payload_result(
                                "MCP reloaded",
                                Some(format_mcp_settings(&payload)),
                                CommandResultKindDto::Mcp,
                                CommandPayloadDto::Mcp(payload),
                            )
                        }
                        "login" => {
                            let name = args.get(1).context("Usage: /mcp login <name>")?;
                            self.mcp_login_for_runtime(&runtime, name).await?;
                            let payload = self.mcp_settings_for_runtime(&runtime).await?;
                            payload_result(
                                "MCP login",
                                Some(format_mcp_settings(&payload)),
                                CommandResultKindDto::Mcp,
                                CommandPayloadDto::Mcp(payload),
                            )
                        }
                        "logout" => {
                            let name = args.get(1).context("Usage: /mcp logout <name|all>")?;
                            self.mcp_logout_for_runtime(&runtime, name).await?;
                            let payload = self.mcp_settings_for_runtime(&runtime).await?;
                            payload_result(
                                "MCP logout",
                                Some(format_mcp_settings(&payload)),
                                CommandResultKindDto::Mcp,
                                CommandPayloadDto::Mcp(payload),
                            )
                        }
                        _ => anyhow::bail!("Usage: /mcp <list|show|reload|login|logout>"),
                    }
                }
                "trace" => {
                    let conversation_id = conversation_id
                        .clone()
                        .context("Open a conversation to trace it.")?;
                    let events = runtime
                        .api
                        .list_trajectory(&ConversationId::parse(&conversation_id)?)
                        .await?;
                    text("Trace", format!("{events:#?}"))
                }
                "dump" => {
                    let path = require_workspace()?;
                    let conversation_id = conversation_id
                        .clone()
                        .context("Open a conversation to dump it.")?;
                    let conversation = runtime
                        .api
                        .conversation(&ConversationId::parse(&conversation_id)?)
                        .await?
                        .context("Conversation not found.")?;
                    let json = serde_json::to_string_pretty(&conversation)?;
                    let file =
                        PathBuf::from(&path).join(format!("graff-dump-{conversation_id}.json"));
                    std::fs::write(&file, json)
                        .with_context(|| format!("Failed to write {}", file.display()))?;
                    CommandRunResultDto {
                        title: "Conversation dumped".to_string(),
                        body: None,
                        snapshot: None,
                        saved_path: Some(file.to_string_lossy().into_owned()),
                        result_kind: CommandResultKindDto::SavedFile,
                        payload: None,
                    }
                }
                "rename" => {
                    let path = require_workspace()?;
                    let conversation_id = conversation_id
                        .clone()
                        .context("Open a conversation to rename it.")?;
                    let title = args.join(" ").trim().to_string();
                    if title.is_empty() {
                        anyhow::bail!("Usage: /rename <name>");
                    }
                    runtime
                        .api
                        .rename_conversation(&ConversationId::parse(&conversation_id)?, title)
                        .await?;
                    self.reload_conversation_from_persistence(&path, &conversation_id, None)
                        .await?;
                    let snapshot = self.emit_current_snapshot().await?;
                    CommandRunResultDto {
                        title: "Conversation renamed".to_string(),
                        body: None,
                        snapshot: Some(snapshot),
                        saved_path: None,
                        result_kind: CommandResultKindDto::Snapshot,
                        payload: None,
                    }
                }
                other => {
                    anyhow::bail!("'/{other}' is not supported in the GUI yet.");
                }
            };

            Ok(result)
        })
        .await
    }

    /// Synchronizes the current workspace index and returns progress lines.
    ///
    /// # Arguments
    /// `workspace_path` is the local workspace path to synchronize.
    ///
    /// # Errors
    /// Returns an error when the workspace cannot be resolved or the indexing
    /// service fails.
    pub async fn workspace_sync(
        &self,
        workspace_path: String,
    ) -> anyhow::Result<WorkspaceSyncPayloadDto> {
        self.with_recorded_ui_error(async {
            let path = canonicalize_workspace_path(PathBuf::from(workspace_path))?;
            let runtime = self.prepare_workspace(&path).await?;
            self.workspace_sync_for_runtime(&runtime, path).await
        })
        .await
    }

    /// Queries the indexed workspace and returns normalized result rows.
    ///
    /// # Arguments
    /// `input` contains the workspace path, semantic query, and optional
    /// filters.
    ///
    /// # Errors
    /// Returns an error when the workspace cannot be resolved or the query
    /// request fails.
    pub async fn workspace_query(
        &self,
        input: WorkspaceQueryInput,
    ) -> anyhow::Result<WorkspaceSearchPayloadDto> {
        self.with_recorded_ui_error(async {
            let path = canonicalize_workspace_path(PathBuf::from(input.workspace_path.clone()))?;
            let runtime = self.prepare_workspace(&path).await?;
            self.workspace_query_for_runtime(
                &runtime,
                WorkspaceQueryInput { workspace_path: path, ..input },
            )
            .await
        })
        .await
    }

    /// Builds a workflow review draft for a goal.
    ///
    /// # Arguments
    /// `input` contains the workflow goal.
    ///
    /// # Errors
    /// Returns an error when runtime initialization fails.
    pub async fn build_workflow_draft(
        &self,
        input: WorkflowDraftInput,
    ) -> anyhow::Result<WorkflowDraftPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = self.resolve_provider_runtime_scope(None).await?;
            let runtime = self.provider_runtime(&scope).await?;
            self.build_workflow_draft_for_runtime(&runtime, input).await
        })
        .await
    }

    /// Exports a workflow draft to the same text submitted on approval.
    ///
    /// # Arguments
    /// `draft` is the current GUI workflow review state.
    pub fn export_workflow_draft(&self, draft: WorkflowDraftPayloadDto) -> String {
        approved_workflow_prompt(&draft)
    }

    /// Sets the active agent and returns updated agent status.
    ///
    /// # Arguments
    /// `agent_id` is the agent id to activate.
    /// `workspace_path` optionally selects a workspace runtime scope.
    ///
    /// # Errors
    /// Returns an error when the runtime cannot be resolved or the agent cannot
    /// be activated.
    pub async fn set_active_agent(
        &self,
        agent_id: String,
        workspace_path: Option<String>,
    ) -> anyhow::Result<AgentsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = self.resolve_provider_runtime_scope(workspace_path).await?;
            let runtime = self.provider_runtime(&scope).await?;
            self.set_active_agent_for_runtime(&runtime, &agent_id).await
        })
        .await
    }

    /// Lists MCP server settings and runtime status.
    ///
    /// # Arguments
    /// `workspace_path` optionally selects a workspace runtime scope.
    ///
    /// # Errors
    /// Returns an error when runtime or MCP config loading fails.
    pub async fn list_mcp_servers(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = self.resolve_provider_runtime_scope(workspace_path).await?;
            let runtime = self.provider_runtime(&scope).await?;
            self.mcp_settings_for_runtime(&runtime).await
        })
        .await
    }

    /// Imports MCP configuration into the selected scope.
    ///
    /// # Arguments
    /// `input` contains the target scope and MCP config JSON.
    ///
    /// # Errors
    /// Returns an error when the scope is invalid, JSON parsing fails, or the
    /// config cannot be written.
    pub async fn import_mcp_config(
        &self,
        input: McpImportInput,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = parse_mcp_scope(&input.scope)?;
            let runtime_scope = self.resolve_provider_runtime_scope(None).await?;
            let runtime = self.provider_runtime(&runtime_scope).await?;
            let incoming: McpConfig = serde_json::from_str(&input.json)
                .context("Failed to parse MCP configuration JSON.")?;
            let mut existing = runtime.api.read_mcp_config(Some(&scope)).await?;
            for (name, server) in incoming.mcp_servers {
                existing.mcp_servers.insert(name, server);
            }
            runtime.api.write_mcp_config(&scope, &existing).await?;
            runtime.api.reload_mcp().await?;
            self.mcp_settings_for_runtime(&runtime).await
        })
        .await
    }

    /// Removes an MCP server from a selected config scope.
    ///
    /// # Arguments
    /// `input` contains the server name and optional scope.
    ///
    /// # Errors
    /// Returns an error when the config cannot be loaded or written.
    pub async fn remove_mcp_server(
        &self,
        input: McpServerActionInput,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = parse_mcp_scope(input.scope.as_deref().unwrap_or("user"))?;
            let runtime_scope = self.resolve_provider_runtime_scope(None).await?;
            let runtime = self.provider_runtime(&runtime_scope).await?;
            let mut existing = runtime.api.read_mcp_config(Some(&scope)).await?;
            existing.mcp_servers.remove(&ServerName::from(input.name));
            runtime.api.write_mcp_config(&scope, &existing).await?;
            runtime.api.reload_mcp().await?;
            self.mcp_settings_for_runtime(&runtime).await
        })
        .await
    }

    /// Reloads MCP servers.
    ///
    /// # Arguments
    /// `workspace_path` optionally selects a workspace runtime scope.
    ///
    /// # Errors
    /// Returns an error when runtime reload fails.
    pub async fn reload_mcp_servers(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = self.resolve_provider_runtime_scope(workspace_path).await?;
            let runtime = self.provider_runtime(&scope).await?;
            runtime.api.reload_mcp().await?;
            self.mcp_settings_for_runtime(&runtime).await
        })
        .await
    }

    /// Starts OAuth login for an MCP server.
    ///
    /// # Arguments
    /// `input` contains the server name.
    ///
    /// # Errors
    /// Returns an error when the server is missing, unsupported, or auth fails.
    pub async fn login_mcp_server(
        &self,
        input: McpServerActionInput,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = self.resolve_provider_runtime_scope(None).await?;
            let runtime = self.provider_runtime(&scope).await?;
            self.mcp_login_for_runtime(&runtime, &input.name).await?;
            self.mcp_settings_for_runtime(&runtime).await
        })
        .await
    }

    /// Removes OAuth credentials for an MCP server or all servers.
    ///
    /// # Arguments
    /// `input` contains the server name, or `all`.
    ///
    /// # Errors
    /// Returns an error when the server is missing, unsupported, or logout
    /// fails.
    pub async fn logout_mcp_server(
        &self,
        input: McpServerActionInput,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        self.with_recorded_ui_error(async {
            let scope = self.resolve_provider_runtime_scope(None).await?;
            let runtime = self.provider_runtime(&scope).await?;
            self.mcp_logout_for_runtime(&runtime, &input.name).await?;
            self.mcp_settings_for_runtime(&runtime).await
        })
        .await
    }

    async fn build_agents_payload(
        &self,
        runtime: &ForgeRuntime,
    ) -> anyhow::Result<AgentsPayloadDto> {
        let active_agent = runtime
            .api
            .get_active_agent()
            .await
            .map(|agent| agent.to_string());
        let agents = runtime.api.get_agent_infos().await.unwrap_or_default();
        let prompt_settings = build_prompt_settings(runtime).await?;
        let mut summaries = Vec::new();
        for agent in agents {
            let id = agent.id.as_str().to_string();
            let model_id = runtime
                .api
                .get_agent_model(agent.id.clone())
                .await
                .map(|model| model.to_string());
            summaries.push(AgentSummaryDto {
                title: agent.title.clone().unwrap_or_else(|| id.clone()),
                description: agent.description.clone(),
                is_active: active_agent.as_ref().is_some_and(|active| active == &id),
                id,
                model_id,
            });
        }

        Ok(AgentsPayloadDto {
            active_agent_id: active_agent,
            selected_provider_id: prompt_settings.selected_provider_id,
            selected_model_id: prompt_settings.selected_model_id,
            selected_reasoning_effort: prompt_settings.selected_reasoning_effort,
            agents: summaries,
        })
    }

    async fn set_active_agent_for_runtime(
        &self,
        runtime: &ForgeRuntime,
        agent_id: &str,
    ) -> anyhow::Result<AgentsPayloadDto> {
        runtime.api.set_active_agent(AgentId::new(agent_id)).await?;
        self.build_agents_payload(runtime).await
    }

    async fn workspace_sync_for_runtime(
        &self,
        runtime: &ForgeRuntime,
        workspace_path: String,
    ) -> anyhow::Result<WorkspaceSyncPayloadDto> {
        let mut stream = runtime
            .api
            .sync_workspace(PathBuf::from(&workspace_path))
            .await?;
        let mut events = Vec::new();
        while let Some(event) = stream.next().await {
            events.push(format_sync_progress(&event?));
        }
        Ok(WorkspaceSyncPayloadDto { workspace_path, events })
    }

    async fn workspace_query_for_runtime(
        &self,
        runtime: &ForgeRuntime,
        input: WorkspaceQueryInput,
    ) -> anyhow::Result<WorkspaceSearchPayloadDto> {
        let mut params = SearchParams::new(
            &input.query,
            input
                .use_case
                .as_deref()
                .unwrap_or("GUI semantic workspace search"),
        )
        .limit(input.limit.unwrap_or(10));
        if let Some(starts_with) = input.starts_with.clone() {
            params = params.starts_with(starts_with);
        }
        if let Some(ends_with) = input.ends_with.clone() {
            params = params.ends_with(ends_with);
        }
        let results = runtime
            .api
            .query_workspace(PathBuf::from(&input.workspace_path), params)
            .await?
            .into_iter()
            .map(workspace_search_result)
            .collect();
        Ok(WorkspaceSearchPayloadDto {
            workspace_path: input.workspace_path,
            query: input.query,
            results,
        })
    }

    async fn build_workflow_draft_for_runtime(
        &self,
        runtime: &ForgeRuntime,
        input: WorkflowDraftInput,
    ) -> anyhow::Result<WorkflowDraftPayloadDto> {
        let agents = runtime.api.get_agent_infos().await.unwrap_or_default();
        Ok(build_workflow_draft_from_agents(&input.goal, &agents))
    }

    async fn mcp_settings_for_runtime(
        &self,
        runtime: &ForgeRuntime,
    ) -> anyhow::Result<McpSettingsPayloadDto> {
        let config = runtime.api.read_mcp_config(None).await?;
        let tools = runtime.api.get_tools().await.ok();
        let mut servers = Vec::new();
        for (name, server) in config.mcp_servers {
            let tool_names = tools
                .as_ref()
                .and_then(|overview| overview.mcp.get_servers().get(&name))
                .map(|tools| {
                    tools
                        .iter()
                        .map(|tool| tool.name.to_string())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let error = tools
                .as_ref()
                .and_then(|overview| overview.mcp.get_failures().get(&name))
                .cloned();
            let auth_status = match &server {
                McpServerConfig::Http(http) if !http.is_oauth_disabled() => {
                    Some(runtime.api.mcp_auth_status(&http.url).await?)
                }
                _ => None,
            };
            servers.push(McpServerSummaryDto {
                name: name.to_string(),
                server_type: server.server_type().to_string(),
                target: format_mcp_target(&server),
                is_disabled: server.is_disabled(),
                tool_count: tool_names.len(),
                tools: tool_names,
                error,
                auth_status,
            });
        }
        Ok(McpSettingsPayloadDto { servers })
    }

    async fn mcp_login_for_runtime(
        &self,
        runtime: &ForgeRuntime,
        name: &str,
    ) -> anyhow::Result<()> {
        let config = runtime.api.read_mcp_config(None).await?;
        let server = config
            .mcp_servers
            .get(&ServerName::from(name.to_string()))
            .with_context(|| format!("MCP server '{name}' not found."))?;
        let McpServerConfig::Http(http) = server else {
            anyhow::bail!("MCP server '{name}' is not an HTTP server.");
        };
        let _ = runtime.api.mcp_logout(Some(&http.url)).await;
        runtime.api.mcp_auth(&http.url).await?;
        runtime.api.reload_mcp().await
    }

    async fn mcp_logout_for_runtime(
        &self,
        runtime: &ForgeRuntime,
        name: &str,
    ) -> anyhow::Result<()> {
        if name == "all" {
            runtime.api.mcp_logout(None).await?;
            return runtime.api.reload_mcp().await;
        }
        let config = runtime.api.read_mcp_config(None).await?;
        let server = config
            .mcp_servers
            .get(&ServerName::from(name.to_string()))
            .with_context(|| format!("MCP server '{name}' not found."))?;
        let McpServerConfig::Http(http) = server else {
            anyhow::bail!("MCP server '{name}' is not an HTTP server.");
        };
        runtime.api.mcp_logout(Some(&http.url)).await?;
        runtime.api.reload_mcp().await
    }

    async fn resolve_provider_runtime_scope(
        &self,
        workspace_path: Option<String>,
    ) -> anyhow::Result<ProviderRuntimeScope> {
        self.ensure_known_workspaces_loaded().await?;

        let requested_workspace_path = if let Some(workspace_path) = workspace_path {
            Some(canonicalize_workspace_path(PathBuf::from(workspace_path))?)
        } else {
            self.state.lock().await.active_workspace_path.clone()
        };

        if let Some(workspace_path) = requested_workspace_path {
            return Ok(ProviderRuntimeScope::Workspace(workspace_path));
        }

        Ok(ProviderRuntimeScope::Transient(
            std::env::current_dir().context("Failed to resolve the current directory.")?,
        ))
    }

    async fn provider_runtime(
        &self,
        runtime_scope: &ProviderRuntimeScope,
    ) -> anyhow::Result<ForgeRuntime> {
        match runtime_scope {
            ProviderRuntimeScope::Workspace(workspace_path) => {
                self.ensure_workspace_runtime(workspace_path).await
            }
            ProviderRuntimeScope::Transient(cwd) => {
                let (config, configuration_error) = read_config();
                self.factory
                    .build_runtime(cwd.clone(), config, configuration_error)
                    .await
            }
        }
    }

    async fn activate_workspace(&self, workspace_path: &str) -> Option<String> {
        let mut state = self.state.lock().await;
        state.active_workspace_path = Some(workspace_path.to_string());
        state.ui_error = None;
        state
            .workspaces
            .get(workspace_path)
            .and_then(|workspace| workspace.selected_conversation_id.clone())
    }

    async fn select_workspace_conversation(&self, workspace_path: &str, conversation_id: &str) {
        let (workspace_kind, workspace_name) = self
            .resolve_workspace_identity(workspace_path)
            .unwrap_or_else(|_| {
                (
                    WorkspaceKind::Project,
                    workspace_name(Path::new(workspace_path)),
                )
            });
        let mut state = self.state.lock().await;
        state.active_workspace_path = Some(workspace_path.to_string());
        state.ui_error = None;
        let workspace = sync_workspace_session_state(
            &mut state,
            workspace_path,
            workspace_kind,
            &workspace_name,
        );
        workspace.selected_conversation_id = Some(conversation_id.to_string());
    }

    async fn emit_current_snapshot(&self) -> anyhow::Result<SessionSnapshotDto> {
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot.clone())?;
        Ok(snapshot)
    }

    async fn refresh_cached_runtime_config(&self, workspace_path: &str) {
        let (config, configuration_error) = read_config();
        let configured = config.session.is_some();
        let derived_error = configuration_error_message(configured, configuration_error.clone());

        let mut state = self.state.lock().await;
        if let Some(workspace) = state.workspaces.get_mut(workspace_path) {
            workspace.configured = configured;
            workspace.configuration_error = derived_error.clone();

            if let Some(runtime) = workspace.runtime.as_mut() {
                runtime.config = config;
                runtime.configuration_error = configuration_error;
            }
        }
    }

    async fn ensure_workspace_default_session_config(
        &self,
        workspace_path: &str,
        runtime: &ForgeRuntime,
    ) -> anyhow::Result<Option<ModelConfig>> {
        let session_config = ensure_default_session_config(runtime).await?;
        self.refresh_cached_runtime_config(workspace_path).await;
        Ok(session_config)
    }

    async fn ensure_provider_scope_default_session_config(
        &self,
        runtime_scope: &ProviderRuntimeScope,
        runtime: &ForgeRuntime,
    ) -> anyhow::Result<Option<ModelConfig>> {
        let session_config = ensure_default_session_config(runtime).await?;

        if let ProviderRuntimeScope::Workspace(workspace_path) = runtime_scope {
            self.refresh_cached_runtime_config(workspace_path).await;
        }

        Ok(session_config)
    }

    async fn generate_saved_workspace_name(
        &self,
        chats: &[crate::dto::ChatBindingDto],
    ) -> anyhow::Result<String> {
        if chats.is_empty() {
            anyhow::bail!("Saved workspaces need at least one chat.");
        }

        let mut ordered_names = Vec::new();
        for chat in chats {
            let workspace_path =
                canonicalize_workspace_path(PathBuf::from(chat.workspace_path.clone()))?;
            let derived_name = workspace_name(Path::new(&workspace_path));
            if !ordered_names.iter().any(|name| name == &derived_name) {
                ordered_names.push(derived_name);
            }
        }

        if ordered_names.len() == 1 {
            return Ok(format!("{} ({} chats)", ordered_names[0], chats.len()));
        }

        Ok(ordered_names.join(" + "))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommandMetadata {
    execution_kind: CommandExecutionKindDto,
    requires_workspace: bool,
    requires_conversation: bool,
    argument_hint: Option<String>,
    result_kind: CommandResultKindDto,
}

fn command_metadata(name: &str, is_agent_switch: bool) -> CommandMetadata {
    if is_agent_switch || name.starts_with("agent-") {
        return CommandMetadata {
            execution_kind: CommandExecutionKindDto::Runnable,
            requires_workspace: false,
            requires_conversation: false,
            argument_hint: None,
            result_kind: CommandResultKindDto::Agents,
        };
    }

    let runnable = |result_kind| CommandMetadata {
        execution_kind: CommandExecutionKindDto::Runnable,
        requires_workspace: false,
        requires_conversation: false,
        argument_hint: None,
        result_kind,
    };
    let modal = |result_kind| CommandMetadata {
        execution_kind: CommandExecutionKindDto::Modal,
        requires_workspace: false,
        requires_conversation: false,
        argument_hint: None,
        result_kind,
    };
    let terminal = || CommandMetadata {
        execution_kind: CommandExecutionKindDto::TerminalAssisted,
        requires_workspace: true,
        requires_conversation: false,
        argument_hint: None,
        result_kind: CommandResultKindDto::Text,
    };
    let unavailable = || CommandMetadata {
        execution_kind: CommandExecutionKindDto::Unavailable,
        requires_workspace: false,
        requires_conversation: false,
        argument_hint: None,
        result_kind: CommandResultKindDto::Text,
    };

    match name {
        "help" | "usage" | "tools" | "skill" | "info" | "fast" => {
            runnable(CommandResultKindDto::Text)
        }
        "agent" | "agents" | "sage" | "reasoning-effort" => {
            let mut metadata = runnable(CommandResultKindDto::Agents);
            if name == "reasoning-effort" {
                metadata.argument_hint =
                    Some("<none|minimal|low|medium|high|xhigh|max>".to_string());
            }
            metadata
        }
        "conversation" | "resume" => runnable(CommandResultKindDto::Conversations),
        "trace" => CommandMetadata {
            execution_kind: CommandExecutionKindDto::Runnable,
            requires_workspace: false,
            requires_conversation: true,
            argument_hint: None,
            result_kind: CommandResultKindDto::Trajectory,
        },
        "dump" => CommandMetadata {
            execution_kind: CommandExecutionKindDto::Runnable,
            requires_workspace: true,
            requires_conversation: true,
            argument_hint: None,
            result_kind: CommandResultKindDto::SavedFile,
        },
        "rename" => CommandMetadata {
            execution_kind: CommandExecutionKindDto::Runnable,
            requires_workspace: true,
            requires_conversation: true,
            argument_hint: Some("<name>".to_string()),
            result_kind: CommandResultKindDto::Snapshot,
        },
        "workspace-status" | "sync-status" => {
            let mut metadata = runnable(CommandResultKindDto::WorkspaceStatus);
            metadata.requires_workspace = true;
            metadata
        }
        "workspace-info" | "sync-info" => {
            let mut metadata = runnable(CommandResultKindDto::WorkspaceInfo);
            metadata.requires_workspace = true;
            metadata
        }
        "workspace-init" | "sync-init" => {
            let mut metadata = runnable(CommandResultKindDto::WorkspaceInfo);
            metadata.requires_workspace = true;
            metadata
        }
        "workspace-sync" | "index" => {
            let mut metadata = runnable(CommandResultKindDto::WorkspaceSync);
            metadata.requires_workspace = true;
            metadata
        }
        "workspace-query" | "workspace-search" => {
            let mut metadata = runnable(CommandResultKindDto::WorkspaceSearch);
            metadata.requires_workspace = true;
            metadata.argument_hint = Some("<query>".to_string());
            metadata
        }
        "workflow" => {
            let mut metadata = modal(CommandResultKindDto::WorkflowDraft);
            metadata.argument_hint = Some("<goal>".to_string());
            metadata
        }
        "mcp" => {
            let mut metadata = modal(CommandResultKindDto::Mcp);
            metadata.argument_hint = Some("<list|show|reload|login|logout>".to_string());
            metadata
        }
        "login" | "provider" | "logout" | "models" | "model" | "config" | "config-show"
        | "config-set" | "config-remove" => modal(CommandResultKindDto::Text),
        "logs" | "update" | "shell" | "zsh" | "suggest" | "commit-preview" => terminal(),
        _ => unavailable(),
    }
}

fn workspace_info_payload(
    workspace_path: String,
    info: Option<forge_domain::WorkspaceInfo>,
) -> WorkspaceInfoPayloadDto {
    WorkspaceInfoPayloadDto {
        workspace_path,
        workspace_id: info.as_ref().map(|info| info.workspace_id.to_string()),
        working_dir: info.as_ref().map(|info| info.working_dir.clone()),
        node_count: info.as_ref().and_then(|info| info.node_count),
        relation_count: info.as_ref().and_then(|info| info.relation_count),
        last_updated: info
            .as_ref()
            .and_then(|info| info.last_updated.map(|time| time.to_rfc3339())),
        created_at: info.as_ref().map(|info| info.created_at.to_rfc3339()),
    }
}

fn workspace_search_result(node: Node) -> WorkspaceSearchResultDto {
    let (kind, path, start_line, end_line, preview) = match node.node {
        NodeData::FileChunk(chunk) => (
            "fileChunk".to_string(),
            Some(chunk.file_path),
            Some(chunk.start_line),
            Some(chunk.end_line),
            truncate_preview(&chunk.content),
        ),
        NodeData::File(file) => (
            "file".to_string(),
            Some(file.file_path),
            None,
            None,
            truncate_preview(&file.content),
        ),
        NodeData::FileRef(file) => (
            "fileRef".to_string(),
            Some(file.file_path),
            None,
            None,
            file.file_hash,
        ),
        NodeData::Note(note) => (
            "note".to_string(),
            None,
            None,
            None,
            truncate_preview(&note.content),
        ),
        NodeData::Task(task) => ("task".to_string(), None, None, None, task.task),
    };
    WorkspaceSearchResultDto {
        node_id: node.node_id.to_string(),
        kind,
        path,
        start_line,
        end_line,
        preview,
        relevance: node.relevance,
        distance: node.distance,
    }
}

fn truncate_preview(value: &str) -> String {
    let compact = value.lines().map(str::trim).collect::<Vec<_>>().join("\n");
    if compact.len() <= 500 {
        return compact;
    }
    format!("{}...", &compact[..500])
}

fn format_sync_progress(progress: &SyncProgress) -> String {
    match progress {
        SyncProgress::Starting => "starting".to_string(),
        SyncProgress::WorkspaceCreated { workspace_id } => {
            format!("workspace created: {workspace_id}")
        }
        SyncProgress::DiscoveringFiles { path, .. } => {
            format!("discovering files: {}", path.display())
        }
        SyncProgress::FilesDiscovered { count } => format!("files discovered: {count}"),
        SyncProgress::ComparingFiles { remote_files, local_files } => {
            format!("comparing files: {local_files} local, {remote_files} remote")
        }
        SyncProgress::DiffComputed { added, deleted, modified } => {
            format!("diff: {added} added, {modified} modified, {deleted} deleted")
        }
        SyncProgress::Syncing { current, total } => format!("syncing: {current}/{total}"),
        SyncProgress::Completed { total_files, uploaded_files, failed_files } => {
            format!(
                "completed: {total_files} files, {uploaded_files} uploaded, {failed_files} failed"
            )
        }
    }
}

fn format_agents_payload(payload: &AgentsPayloadDto) -> String {
    let active = payload.active_agent_id.as_deref().unwrap_or("none");
    let model = payload.selected_model_id.as_deref().unwrap_or("none");
    let effort = payload
        .selected_reasoning_effort
        .as_deref()
        .unwrap_or("default");
    let agents = payload
        .agents
        .iter()
        .map(|agent| {
            let marker = if agent.is_active { "active" } else { "" };
            format!(
                "| `{}` | {} | {} |",
                markdown_table_cell(&agent.id),
                markdown_table_cell(&agent.title),
                marker
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "**Active:** `{active}`\n\n**Model:** `{model}`\n\n**Reasoning:** `{effort}`\n\n| Agent | Name | State |\n| --- | --- | --- |\n{agents}"
    )
}

fn format_workspace_status(payload: &WorkspaceStatusPayloadDto) -> String {
    if payload.files.is_empty() {
        return "No indexed file status is available.".to_string();
    }
    let rows = payload
        .files
        .iter()
        .map(|file| {
            format!(
                "| {} | `{}` |",
                markdown_table_cell(&file.status),
                markdown_table_cell(&file.path)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!("| Status | Path |\n| --- | --- |\n{rows}")
}

fn format_workspace_info(payload: &WorkspaceInfoPayloadDto) -> String {
    format!(
        "| Field | Value |\n| --- | --- |\n| Workspace | `{}` |\n| ID | `{}` |\n| Working dir | `{}` |\n| Nodes | {} |\n| Relations | {} |\n| Created | {} |\n| Updated | {} |",
        markdown_table_cell(&payload.workspace_path),
        markdown_table_cell(payload.workspace_id.as_deref().unwrap_or("not indexed")),
        markdown_table_cell(payload.working_dir.as_deref().unwrap_or("unknown")),
        payload
            .node_count
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".to_string()),
        payload
            .relation_count
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".to_string()),
        payload.created_at.as_deref().unwrap_or("unknown"),
        payload.last_updated.as_deref().unwrap_or("unknown")
    )
}

fn format_workspace_search(payload: &WorkspaceSearchPayloadDto) -> String {
    if payload.results.is_empty() {
        return "No results.".to_string();
    }
    payload
        .results
        .iter()
        .map(|result| {
            let location = result
                .path
                .as_ref()
                .map(|path| match (result.start_line, result.end_line) {
                    (Some(start), Some(end)) => format!("{path}:{start}-{end}"),
                    _ => path.clone(),
                })
                .unwrap_or_else(|| result.kind.clone());
            format!("### `{}`\n\n```text\n{}\n```", location, result.preview)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn format_mcp_target(server: &McpServerConfig) -> String {
    match server {
        McpServerConfig::Stdio(stdio) => {
            let args = if stdio.args.is_empty() {
                String::new()
            } else {
                format!(" {}", stdio.args.join(" "))
            };
            format!("{}{}", stdio.command, args)
        }
        McpServerConfig::Http(http) => http.url.clone(),
    }
}

fn format_mcp_settings(payload: &McpSettingsPayloadDto) -> String {
    if payload.servers.is_empty() {
        return "No MCP servers configured.".to_string();
    }
    let rows = payload
        .servers
        .iter()
        .map(|server| {
            let status = if server.is_disabled {
                "disabled"
            } else {
                "enabled"
            };
            let auth = server.auth_status.as_deref().unwrap_or("n/a");
            format!(
                "| `{}` | {} | `{}` | {} | {} | {} |",
                markdown_table_cell(&server.name),
                markdown_table_cell(&server.server_type),
                markdown_table_cell(&server.target),
                status,
                server.tool_count,
                markdown_table_cell(auth)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "| Server | Type | Target | Status | Tools | Auth |\n| --- | --- | --- | --- | ---: | --- |\n{rows}"
    )
}

fn format_mcp_server_summary(server: &McpServerSummaryDto) -> String {
    let status = if server.is_disabled {
        "disabled"
    } else {
        "enabled"
    };
    let auth = server.auth_status.as_deref().unwrap_or("n/a");
    let error = server
        .error
        .as_ref()
        .map(|error| format!("\nerror: {error}"))
        .unwrap_or_default();
    format!(
        "| Field | Value |\n| --- | --- |\n| Server | `{}` |\n| Type | {} |\n| Target | `{}` |\n| Status | {} |\n| Tools | {} |\n| Auth | {} |{}",
        markdown_table_cell(&server.name),
        markdown_table_cell(&server.server_type),
        markdown_table_cell(&server.target),
        status,
        server.tool_count,
        markdown_table_cell(auth),
        error
            .strip_prefix('\n')
            .map(|value| format!("\n\n**Error:** {value}"))
            .unwrap_or_default()
    )
}

fn format_command_catalog_markdown() -> String {
    let rows = forge_main::builtin_command_catalog()
        .into_iter()
        .map(|spec| {
            let (name, aliases) = match spec.name.as_str() {
                "forge" => ("act".to_string(), vec!["forge".to_string()]),
                "muse" => ("plan".to_string(), vec!["muse".to_string()]),
                _ => (spec.name, spec.aliases),
            };
            let aliases = if aliases.is_empty() {
                String::new()
            } else {
                aliases
                    .iter()
                    .map(|alias| format!("`/{}`", markdown_table_cell(alias)))
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            format!(
                "| `/{}` | {} | {} |",
                markdown_table_cell(&name),
                markdown_table_cell(&spec.usage),
                aliases
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!("| Command | Description | Aliases |\n| --- | --- | --- |\n{rows}")
}

fn markdown_table_cell(value: &str) -> String {
    value.replace('|', "\\|").replace('\n', "<br>")
}

fn parse_mcp_scope(value: &str) -> anyhow::Result<Scope> {
    match value {
        "user" | "User" => Ok(Scope::User),
        "local" | "Local" => Ok(Scope::Local),
        _ => anyhow::bail!("MCP scope must be 'user' or 'local'."),
    }
}

fn build_workflow_draft_from_agents(goal: &str, agents: &[AgentInfo]) -> WorkflowDraftPayloadDto {
    let nodes = build_workflow(goal, agents);
    let summary = workflow_summary(&nodes);
    let mut draft = WorkflowDraftPayloadDto {
        goal: goal.to_string(),
        summary,
        nodes,
        export_text: String::new(),
        approved_prompt: String::new(),
        trace: Vec::new(),
    };
    draft.export_text = export_workflow(&draft);
    draft.approved_prompt = approved_workflow_prompt(&draft);
    draft.trace = workflow_start_trace(&draft);
    draft
}

fn build_workflow(goal: &str, agents: &[AgentInfo]) -> Vec<WorkflowNodeDto> {
    let lower = goal.to_ascii_lowercase();
    let include_research = contains_any(
        &lower,
        &["investigate", "debug", "failing", "find", "research"],
    );
    let include_plan = contains_any(&lower, &["plan", "design", "strategy", "roadmap"]);
    let include_test = contains_any(&lower, &["test", "verify", "check", "failing", "parser"]);
    let include_review = contains_any(&lower, &["review", "diff", "pr", "risk"]);

    let mut specs = Vec::new();
    if include_research {
        specs.push((
            "research",
            "sage",
            format!(
                "Investigate the codebase and relevant context for: {goal}. Identify constraints, files, and risks before changes."
            ),
            "findings and candidate files",
            "key constraints and evidence are documented",
        ));
    }
    if include_plan || include_research {
        specs.push((
            "plan",
            "muse",
            format!(
                "Turn the findings and goal into an implementation plan for: {goal}. Include dependencies, risks, and verification commands."
            ),
            "implementation plan",
            "plan lists dependencies, risks, and verification commands",
        ));
    }
    specs.push((
        "implement",
        "forge",
        format!(
            "Apply the approved code changes for: {goal}. Keep edits scoped and explain blockers."
        ),
        "code changes",
        "changes are applied with no known incomplete edits",
    ));
    if include_test {
        specs.push((
            "test",
            "forge",
            format!("Run targeted verification for: {goal}. Capture failures and next steps if checks fail."),
            "verification log",
            "targeted checks pass or blockers are explicitly reported",
        ));
    }
    if include_review {
        specs.push((
            "review",
            "sage",
            format!("Review the resulting diff and execution trace for: {goal}. Call out risks and follow-ups."),
            "review summary",
            "diff risks and follow-ups are called out",
        ));
    }

    let mut prior_names: Vec<String> = Vec::new();
    specs
        .into_iter()
        .map(|(name, preferred_worker, task, artifact, stop_condition)| {
            let dependencies = prior_names.last().cloned().into_iter().collect::<Vec<_>>();
            let access = prior_names.clone();
            prior_names.push(name.to_string());
            WorkflowNodeDto {
                name: name.to_string(),
                worker: workflow_worker(preferred_worker, agents),
                task,
                dependencies,
                access,
                artifact: artifact.to_string(),
                stop_condition: stop_condition.to_string(),
            }
        })
        .collect()
}

fn contains_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| text.contains(needle))
}

fn workflow_worker(preferred: &str, agents: &[AgentInfo]) -> String {
    if agents.iter().any(|agent| agent.id.as_str() == preferred) {
        return preferred.to_string();
    }

    let fallback: &[&str] = match preferred {
        "sage" => &["review", "research", "analyze", "sage"],
        "muse" => &["plan", "design", "muse", "strategy"],
        _ => &["forge", "implement", "code", "dev"],
    };

    agents
        .iter()
        .find(|agent| {
            let id = agent.id.as_str().to_ascii_lowercase();
            let title = agent
                .title
                .as_deref()
                .unwrap_or_default()
                .to_ascii_lowercase();
            let description = agent
                .description
                .as_deref()
                .unwrap_or_default()
                .to_ascii_lowercase();
            fallback.iter().any(|needle| {
                id.contains(needle) || title.contains(needle) || description.contains(needle)
            })
        })
        .map(|agent| agent.id.as_str().to_string())
        .unwrap_or_else(|| preferred.to_string())
}

fn workflow_summary(nodes: &[WorkflowNodeDto]) -> String {
    nodes
        .iter()
        .map(|node| format!("{}({})", node.name, node.worker))
        .collect::<Vec<_>>()
        .join(" -> ")
}

fn export_workflow(draft: &WorkflowDraftPayloadDto) -> String {
    let mut output = format!(
        "workflow:\n  goal: {}\n  topology: {}",
        draft.goal,
        workflow_summary(&draft.nodes)
    );
    for (index, node) in draft.nodes.iter().enumerate() {
        output.push_str(&format!(
            "\n  - node: {}\n    name: {}\n    worker: {}\n    task: {}\n    dependencies: {}\n    access: {}\n    artifact: {}\n    stop: {}",
            index + 1,
            node.name,
            node.worker,
            node.task,
            list_or_none(&node.dependencies),
            list_or_none(&node.access),
            node.artifact,
            node.stop_condition
        ));
    }
    output
}

fn workflow_start_trace(draft: &WorkflowDraftPayloadDto) -> Vec<String> {
    let mut trace = vec![
        format!("goal: {}", draft.goal),
        format!("topology: {}", workflow_summary(&draft.nodes)),
    ];
    trace.extend(draft.nodes.iter().enumerate().map(|(index, node)| {
        format!(
            "node {}: {}({}) - artifact: {} - stop: {}",
            index + 1,
            node.name,
            node.worker,
            node.artifact,
            node.stop_condition
        )
    }));
    trace
}

fn approved_workflow_prompt(draft: &WorkflowDraftPayloadDto) -> String {
    format!(
        "Run this approved CodeGraff workflow topology. Execute the nodes in dependency order, respect each node's access list, and log each produced artifact.\n\n{}",
        export_workflow(draft)
    )
}

fn list_or_none(values: &[String]) -> String {
    if values.is_empty() {
        "none".to_string()
    } else {
        values.join(", ")
    }
}

async fn build_prompt_settings(runtime: &ForgeRuntime) -> anyhow::Result<PromptSettingsDto> {
    let current_config = runtime.api.get_session_config().await;
    let current_effort = runtime.api.get_reasoning_effort().await?;
    let mut all_provider_models = runtime.api.get_all_provider_models().await?;
    sort_provider_models(&mut all_provider_models);

    let current_config =
        ensure_default_session_config_from_models(runtime, current_config, &all_provider_models)
            .await?;

    let available_models = all_provider_models
        .into_iter()
        .flat_map(|provider_models| {
            let provider_name = provider_models.provider_id.to_string();
            let provider_id = provider_models.provider_id.as_ref().to_string();

            provider_models
                .models
                .into_iter()
                .map(move |model| PromptModelOptionDto {
                    provider_id: provider_id.clone(),
                    provider_name: provider_name.clone(),
                    model_id: model.id.to_string(),
                    model_name: model.name.clone(),
                    context_length: model.context_length,
                    supports_reasoning: model.supports_reasoning == Some(true),
                    reasoning_efforts: reasoning_efforts_for_model(
                        &provider_models.provider_id,
                        &model,
                    ),
                })
        })
        .collect::<Vec<_>>();

    let selected_provider_id = current_config
        .as_ref()
        .map(|config| config.provider.as_ref().to_string())
        .filter(|provider_id| {
            available_models
                .iter()
                .any(|model| &model.provider_id == provider_id)
        });
    let selected_model_id = current_config
        .as_ref()
        .map(|config| config.model.to_string())
        .filter(|model_id| {
            selected_provider_id
                .as_ref()
                .and_then(|provider_id| {
                    available_models.iter().find(|model| {
                        &model.provider_id == provider_id && &model.model_id == model_id
                    })
                })
                .is_some()
        });
    let selected_reasoning_effort =
        current_effort
            .map(|effort| effort.to_string())
            .filter(|effort| {
                selected_provider_id
                    .as_ref()
                    .zip(selected_model_id.as_ref())
                    .and_then(|(provider_id, model_id)| {
                        available_models.iter().find(|model| {
                            &model.provider_id == provider_id && &model.model_id == model_id
                        })
                    })
                    .is_some_and(|model| {
                        model
                            .reasoning_efforts
                            .iter()
                            .any(|candidate| candidate == effort)
                    })
            });

    Ok(PromptSettingsDto {
        available_models,
        selected_provider_id,
        selected_model_id,
        selected_reasoning_effort,
    })
}

async fn ensure_default_session_config(
    runtime: &ForgeRuntime,
) -> anyhow::Result<Option<ModelConfig>> {
    let current_config = runtime.api.get_session_config().await;
    let mut all_provider_models = runtime.api.get_all_provider_models().await?;
    sort_provider_models(&mut all_provider_models);

    ensure_default_session_config_from_models(runtime, current_config, &all_provider_models).await
}

fn sort_provider_models(all_provider_models: &mut [ProviderModels]) {
    all_provider_models.iter_mut().for_each(|provider_models| {
        provider_models
            .models
            .sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()))
    });
    all_provider_models
        .sort_by(|left, right| left.provider_id.as_ref().cmp(right.provider_id.as_ref()));
}

async fn ensure_default_session_config_from_models(
    runtime: &ForgeRuntime,
    current_config: Option<ModelConfig>,
    all_provider_models: &[ProviderModels],
) -> anyhow::Result<Option<ModelConfig>> {
    if let Some(current_config) = current_config
        && session_config_is_available(&current_config, all_provider_models)
    {
        return Ok(Some(current_config));
    }

    let Some(default_config) = all_provider_models.iter().find_map(|provider_models| {
        provider_models
            .models
            .first()
            .map(|model| ModelConfig::new(provider_models.provider_id.clone(), model.id.clone()))
    }) else {
        return Ok(None);
    };

    runtime
        .api
        .update_config(vec![ConfigOperation::SetSessionConfig(
            default_config.clone(),
        )])
        .await?;

    Ok(Some(default_config))
}

fn session_config_is_available(
    config: &ModelConfig,
    all_provider_models: &[ProviderModels],
) -> bool {
    all_provider_models.iter().any(|provider_models| {
        provider_models.provider_id == config.provider
            && provider_models
                .models
                .iter()
                .any(|model| model.id == config.model)
    })
}

fn reasoning_efforts_for_model(provider_id: &ProviderId, model: &Model) -> Vec<String> {
    if model.supports_reasoning != Some(true) {
        return Vec::new();
    }

    let provider_key: &str = provider_id.as_ref().as_ref();
    let supported = match provider_key {
        "anthropic" | "anthropic_compatible" | "vertex_ai_anthropic" | "claude_code" => {
            &["low", "medium", "high", "max"][..]
        }
        "openai"
        | "open_router"
        | "requesty"
        | "github_copilot"
        | "openai_compatible"
        | "openai_responses_compatible"
        | "forge"
        | "codex" => &["none", "minimal", "low", "medium", "high", "xhigh"][..],
        "xai" | "zai" | "zai_coding" | "vertex_ai" | "google_ai_studio" => &[][..],
        _ => &["low", "medium", "high"][..],
    };

    supported
        .iter()
        .map(|effort| (*effort).to_string())
        .collect()
}

fn parse_provider_oauth_callback_url(url: &url::Url) -> Option<ParsedProviderOAuthCallback> {
    let is_localhost_callback = url.scheme() == "http"
        && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"))
        && url.port_or_known_default() == Some(1455)
        && url.path() == "/auth/callback";

    if !is_localhost_callback {
        return None;
    }

    let mut authorization_code = None;
    let mut error = None;
    let mut error_description = None;
    let mut state = None;

    for (name, value) in url.query_pairs() {
        match name.as_ref() {
            "code" => authorization_code = Some(value.into_owned()),
            "error" => error = Some(value.into_owned()),
            "error_description" => error_description = Some(value.into_owned()),
            "state" => state = Some(value.into_owned()),
            _ => {}
        }
    }

    let state = state?;
    let authorization_code = authorization_code.filter(|value| !value.trim().is_empty());
    let error_message = match (error, error_description) {
        (Some(error), Some(description)) if !description.trim().is_empty() => {
            Some(format!("{error}: {description}"))
        }
        (Some(error), _) => Some(error),
        (None, Some(description))
            if authorization_code.is_none() && !description.trim().is_empty() =>
        {
            Some(description)
        }
        _ if authorization_code.is_none() => {
            Some("OAuth callback did not include an authorization code.".to_string())
        }
        _ => None,
    };

    Some(ParsedProviderOAuthCallback { authorization_code, error_message, state })
}

async fn write_provider_oauth_callback_response(
    stream: &mut TcpStream,
    status_code: u16,
    success: bool,
) -> std::io::Result<()> {
    let (status_text, title, message) = if success {
        (
            "OK",
            "Authentication complete",
            "Authentication completed. You can return to Codegraff to finish setup.",
        )
    } else {
        (
            "Bad Request",
            "Authentication not completed",
            "Codegraff could not match this authentication response. Return to the app and try again.",
        )
    };
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>{title}</title><style>body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:3rem;line-height:1.5;color:#111827}}main{{max-width:42rem}}</style></head><body><main><h1>{title}</h1><p>{message}</p></main></body></html>"
    );
    let response = format!(
        "HTTP/1.1 {status_code} {status_text}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );

    stream.write_all(response.as_bytes()).await
}

fn map_provider_summary(provider: AnyProvider) -> ProviderSummaryDto {
    ProviderSummaryDto {
        id: provider.id().as_ref().to_string(),
        name: provider.id().to_string(),
        configured: provider.is_configured(),
        auth_methods: provider
            .auth_methods()
            .iter()
            .map(map_provider_auth_method)
            .collect(),
    }
}

fn map_provider_auth_method(method: &AuthMethod) -> ProviderAuthMethodDto {
    let kind = map_provider_auth_method_kind(method);
    ProviderAuthMethodDto { label: provider_auth_method_label(&kind).to_string(), kind }
}

fn map_provider_auth_method_kind(method: &AuthMethod) -> ProviderAuthMethodKindDto {
    match method {
        AuthMethod::ApiKey => ProviderAuthMethodKindDto::ApiKey,
        AuthMethod::OAuthDevice(_) => ProviderAuthMethodKindDto::OAuthDevice,
        AuthMethod::OAuthCode(_) => ProviderAuthMethodKindDto::OAuthCode,
        AuthMethod::GoogleAdc => ProviderAuthMethodKindDto::GoogleAdc,
        AuthMethod::AwsProfile => ProviderAuthMethodKindDto::AwsProfile,
        AuthMethod::CodexDevice(_) => ProviderAuthMethodKindDto::CodexDevice,
        AuthMethod::CodegraffDevice(_) => ProviderAuthMethodKindDto::CodegraffDevice,
    }
}

fn provider_auth_method_label(kind: &ProviderAuthMethodKindDto) -> &'static str {
    match kind {
        ProviderAuthMethodKindDto::ApiKey => "API key",
        ProviderAuthMethodKindDto::OAuthDevice => "OAuth device",
        ProviderAuthMethodKindDto::OAuthCode => "OAuth",
        ProviderAuthMethodKindDto::GoogleAdc => "Google ADC",
        ProviderAuthMethodKindDto::AwsProfile => "AWS profile",
        ProviderAuthMethodKindDto::CodexDevice => "OpenAI device",
        ProviderAuthMethodKindDto::CodegraffDevice => "Codegraff device",
    }
}

fn resolve_provider_auth_method(
    provider: &AnyProvider,
    requested_kind: &ProviderAuthMethodKindDto,
) -> anyhow::Result<AuthMethod> {
    provider
        .auth_methods()
        .iter()
        .find(|candidate| map_provider_auth_method_kind(candidate) == *requested_kind)
        .cloned()
        .with_context(|| {
            format!(
                "Provider '{}' does not support {} authentication.",
                provider.id(),
                provider_auth_method_label(requested_kind)
            )
        })
}

fn map_provider_auth_session(
    auth_session_id: String,
    auth_method_kind: &ProviderAuthMethodKindDto,
    request: AuthContextRequest,
) -> ProviderAuthSessionDto {
    match request {
        AuthContextRequest::ApiKey(request) => ProviderAuthSessionDto {
            kind: ProviderAuthSessionKindDto::ApiKey,
            auth_session_id,
            requires_api_key: matches!(auth_method_kind, ProviderAuthMethodKindDto::ApiKey),
            api_key_hint: if matches!(auth_method_kind, ProviderAuthMethodKindDto::ApiKey) {
                request.api_key.as_ref().map(ToString::to_string)
            } else {
                None
            },
            url_parameters: request
                .required_params
                .iter()
                .map(|parameter| ProviderUrlParamDto {
                    name: parameter.name.as_str().to_string(),
                    value: request
                        .existing_params
                        .as_ref()
                        .and_then(|values| values.get(&parameter.name))
                        .map(|value| value.as_str().to_string()),
                    options: parameter.options.clone(),
                })
                .collect(),
            verification_uri: None,
            verification_uri_complete: None,
            user_code: None,
            expires_in_seconds: None,
            authorization_url: None,
        },
        AuthContextRequest::DeviceCode(request) => ProviderAuthSessionDto {
            kind: ProviderAuthSessionKindDto::DeviceCode,
            auth_session_id,
            requires_api_key: false,
            api_key_hint: None,
            url_parameters: Vec::new(),
            verification_uri: Some(request.verification_uri.to_string()),
            verification_uri_complete: request
                .verification_uri_complete
                .map(|value| value.to_string()),
            user_code: Some(request.user_code.to_string()),
            expires_in_seconds: Some(request.expires_in),
            authorization_url: None,
        },
        AuthContextRequest::Code(request) => ProviderAuthSessionDto {
            kind: ProviderAuthSessionKindDto::OAuthCode,
            auth_session_id,
            requires_api_key: false,
            api_key_hint: None,
            url_parameters: Vec::new(),
            verification_uri: None,
            verification_uri_complete: None,
            user_code: None,
            expires_in_seconds: None,
            authorization_url: Some(request.authorization_url.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use forge_domain::{FileChunk, NodeId};
    use pretty_assertions::assert_eq;

    use super::*;

    fn agent_fixture(id: &str, title: &str, description: &str) -> AgentInfo {
        AgentInfo::default()
            .id(AgentId::new(id))
            .title(title)
            .description(description)
    }

    #[test]
    fn test_command_metadata_maps_workspace_query() {
        let setup = "workspace-query";
        let actual = command_metadata(setup, false);
        let expected = CommandMetadata {
            execution_kind: CommandExecutionKindDto::Runnable,
            requires_workspace: true,
            requires_conversation: false,
            argument_hint: Some("<query>".to_string()),
            result_kind: CommandResultKindDto::WorkspaceSearch,
        };
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_command_metadata_maps_terminal_assisted_logs() {
        let setup = "logs";
        let actual = command_metadata(setup, false);
        let expected = CommandMetadata {
            execution_kind: CommandExecutionKindDto::TerminalAssisted,
            requires_workspace: true,
            requires_conversation: false,
            argument_hint: None,
            result_kind: CommandResultKindDto::Text,
        };
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_workflow_draft_includes_research_plan_test_review_nodes() {
        let setup = vec![
            agent_fixture("analysis", "Research analyst", "Investigate code"),
            agent_fixture("planner", "Design planner", "Plan changes"),
            agent_fixture("forge", "Forge", "Implement code"),
        ];
        let actual = build_workflow_draft_from_agents(
            "debug failing parser test and review the diff",
            &setup,
        );
        let expected = vec![
            "research".to_string(),
            "plan".to_string(),
            "implement".to_string(),
            "test".to_string(),
            "review".to_string(),
        ];
        assert_eq!(
            actual
                .nodes
                .iter()
                .map(|node| node.name.clone())
                .collect::<Vec<_>>(),
            expected
        );
        assert!(actual.export_text.contains("workflow:"));
        assert!(
            actual
                .approved_prompt
                .contains("Run this approved CodeGraff workflow topology.")
        );
    }

    #[test]
    fn test_workspace_search_result_maps_file_chunk() {
        let setup = Node {
            node_id: NodeId::new("node-1"),
            node: NodeData::FileChunk(FileChunk {
                file_path: "src/main.rs".to_string(),
                content: "fn main() {}".to_string(),
                start_line: 3,
                end_line: 4,
            }),
            relevance: Some(0.9),
            distance: Some(0.1),
        };
        let actual = workspace_search_result(setup);
        let expected = WorkspaceSearchResultDto {
            node_id: "node-1".to_string(),
            kind: "fileChunk".to_string(),
            path: Some("src/main.rs".to_string()),
            start_line: Some(3),
            end_line: Some(4),
            preview: "fn main() {}".to_string(),
            relevance: Some(0.9),
            distance: Some(0.1),
        };
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_command_catalog_formats_as_markdown_table() {
        let setup = format_command_catalog_markdown();
        let actual = (
            setup.starts_with("| Command | Description | Aliases |"),
            setup.contains("| `/config` | Display effective resolved configuration |"),
            setup.contains("max-diff\\|preview"),
        );
        let expected = (true, true, true);
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_workspace_info_formats_as_markdown_table() {
        let setup = WorkspaceInfoPayloadDto {
            workspace_path: "/tmp/example|workspace".to_string(),
            workspace_id: Some("workspace-1".to_string()),
            working_dir: Some("/tmp/example|workspace".to_string()),
            node_count: Some(12),
            relation_count: Some(3),
            last_updated: Some("today".to_string()),
            created_at: Some("yesterday".to_string()),
        };
        let actual = format_workspace_info(&setup);
        let expected = "| Field | Value |\n| --- | --- |\n| Workspace | `/tmp/example\\|workspace` |\n| ID | `workspace-1` |\n| Working dir | `/tmp/example\\|workspace` |\n| Nodes | 12 |\n| Relations | 3 |\n| Created | yesterday |\n| Updated | today |";
        assert_eq!(actual, expected);
    }
}
