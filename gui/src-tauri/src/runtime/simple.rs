use crate::{
    bridge::emitter::UiEventEmitter,
    desktop_open,
    dto::*,
    persistence::project_store::{ProjectStore, RegisteredWorkspaceKind},
    terminal::TerminalManager,
};
use anyhow::{Context, Result};
#[cfg(target_os = "macos")]
use std::os::unix::fs::PermissionsExt;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Clone)]
struct QueuedPrompt {
    agent_id: Option<String>,
    engine_prompt: String,
    request_id: String,
}

#[derive(Clone, Default)]
struct ConversationState {
    workspace_path: String,
    conversation_id: String,
    title: String,
    messages: Vec<SessionMessageDto>,
    active_request_ids: Vec<String>,
    /// Maps a request id to the agent label ("muse"/"forge") it was sent under,
    /// so the GUI's plan-decision card can key off the planning-mode request.
    request_agent_ids: HashMap<String, String>,
    queued_prompts: VecDeque<QueuedPrompt>,
    active_agent_id: Option<String>,
    plan_mode: bool,
    /// Live task list, replaced wholesale on every `todo_write` tool call
    /// (harness semantics). Surfaced to the GUI's task-progress dock.
    todos: Vec<SessionTodoDto>,
    goal: Option<String>,
    /// Persistent ultracode (multi-agent workflow) mode, scoped to this chat.
    ultracode_enabled: bool,
    updated_at: i64,
}

#[derive(Default)]
struct RuntimeState {
    active_workspace_path: Option<String>,
    active_conversation_id: Option<String>,
    workspaces: Vec<String>,
    conversations: HashMap<String, ConversationState>,
    selected_by_workspace: HashMap<String, String>,
    active_agent_id: Option<String>,
    /// UI model selection, applied as `--model` when a session is spawned.
    selected_provider: Option<String>,
    selected_model: Option<String>,
    /// Thinking controls (set via the GUI), applied on session spawn and
    /// forwarded live to running sessions. None effort = the binary default.
    selected_effort: Option<String>,
    fast_enabled: bool,
    /// Last successful `graff --schema` model list. Refreshed when the prompt
    /// settings endpoint is read so the GUI picks up newly shipped models
    /// without an app restart.
    model_catalog: Option<Vec<ModelOption>>,
    /// Live `ask_user` prompts awaiting a GUI answer, keyed by conversation.
    /// Surfaced as the conversation's `followup` so the FollowupComposer renders.
    pending_followups: HashMap<String, FollowupRequestDto>,
}

/// One model the `graff` CLI advertises in `--schema`.
#[derive(Clone)]
struct ModelOption {
    provider: String,
    provider_name: Option<String>,
    name: String,
    context: Option<u64>,
    is_default: bool,
}

/// A persistent `graff --json` child bound to one conversation. Keeping the
/// process alive across turns preserves conversation context (and the model's
/// KV cache).
struct GraffSession {
    child: tokio::process::Child,
    /// Shared so an `ask_user` answer can be written to stdin (via
    /// `respond_followup`) while a turn is mid-stream — the turn only holds the
    /// reader, the stdin handle stays reachable here.
    stdin: Arc<Mutex<tokio::process::ChildStdin>>,
    /// Taken out for the duration of an in-flight turn so only one request
    /// streams per session at a time (the protocol's contract).
    reader: Option<tokio::io::Lines<BufReader<tokio::process::ChildStdout>>>,
}

struct GraffSessionIo {
    stdin: Arc<Mutex<tokio::process::ChildStdin>>,
    reader: tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
}

/// Coordinates the copied desktop GUI with the Zig-native codegraff binary.
#[derive(Clone)]
pub struct RuntimeManager {
    emitter: Arc<dyn UiEventEmitter>,
    projects: Arc<ProjectStore>,
    state: Arc<Mutex<RuntimeState>>,
    sessions: Arc<Mutex<HashMap<String, GraffSession>>>,
}

impl RuntimeManager {
    /// Creates a runtime manager backed by the copied GUI project registry.
    pub fn new(emitter: Arc<dyn UiEventEmitter>, projects: Arc<ProjectStore>) -> Self {
        let persisted_prompt = load_persisted_prompt_settings();
        Self {
            emitter,
            projects,
            state: Arc::new(Mutex::new(RuntimeState {
                active_agent_id: Some("forge".into()),
                conversations: load_persisted_conversations(),
                selected_provider: persisted_prompt.selected_provider,
                selected_model: persisted_prompt.selected_model,
                selected_effort: persisted_prompt.selected_effort,
                fast_enabled: persisted_prompt.fast_enabled,
                ..RuntimeState::default()
            })),
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Cancels pending follow-up prompts.
    pub async fn cancel_pending_followups(&self) {
        self.state.lock().await.pending_followups.clear();
    }

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

    /// Returns the model picker, populated from `graff --schema`.
    pub async fn get_prompt_settings(&self, _: Option<String>) -> Result<PromptSettingsDto> {
        let catalog = self.refresh_model_catalog().await;
        let configured_provider_ids = configured_provider_ids().await;
        let (selected_provider, selected_model, selected_effort, fast_enabled) = {
            let state = self.state.lock().await;
            (
                state.selected_provider.clone(),
                state.selected_model.clone(),
                state.selected_effort.clone(),
                state.fast_enabled,
            )
        };

        Ok(build_prompt_settings_from_catalog(
            &catalog,
            &configured_provider_ids,
            selected_provider.as_deref(),
            selected_model.as_deref(),
            selected_effort,
            fast_enabled,
        ))
    }

    async fn selected_model_arg(&self) -> Option<String> {
        let catalog = self.ensure_model_catalog().await;
        let configured_provider_ids = configured_provider_ids().await;
        let (selected_provider, selected_model) = {
            let state = self.state.lock().await;
            (
                state.selected_provider.clone(),
                state.selected_model.clone(),
            )
        };
        selected_prompt_model_pair(
            &catalog,
            &configured_provider_ids,
            selected_provider.as_deref(),
            selected_model.as_deref(),
        )
        .map(|(provider, model)| prompt_model_arg(&provider, &model))
    }

    /// Generates a short chat title with the active model (a one-shot graff run)
    /// and updates the conversation. Best-effort and fire-and-forget: failures
    /// just leave the prompt-derived title in place.
    async fn generate_and_set_title(
        &self,
        conversation_id: String,
        prompt: String,
        model_arg: Option<String>,
    ) {
        let title_prompt = format!(
            "Output a concise 2 to 4 word topic label in Title Case for the user's \
             first chat message. Describe the topic literally — do NOT interpret, \
             correct, rephrase, or expand the message. Examples: \"hey there\" -> \
             Greeting; \"go through the repo\" -> Repo Walkthrough; \"fix the login \
             bug\" -> Login Bug Fix. Reply with ONLY the label, nothing else.\n\nMessage: {prompt}"
        );
        let mut command = tokio::process::Command::new(codegraff_binary());
        command.arg("-p").arg(&title_prompt).arg("--yolo");
        if let Some(model) = &model_arg {
            command.arg("--model").arg(model);
        }
        let Ok(output) = command.output().await else {
            return;
        };
        if !output.status.success() {
            return;
        }
        let title = clean_title(&String::from_utf8_lossy(&output.stdout));
        if title.is_empty() {
            return;
        }
        {
            let mut state = self.state.lock().await;
            if let Some(conversation) = state.conversations.get_mut(&conversation_id) {
                conversation.title = title;
            }
        }
        self.persist_conversations().await;
        let _ = self.emit().await;
    }

    /// Writes the current model/effort/fast selection to disk so it persists
    /// across app restarts and seeds new chats.
    async fn persist_prompt_settings(&self) {
        let settings = {
            let state = self.state.lock().await;
            PersistedPromptSettings {
                selected_provider: state.selected_provider.clone(),
                selected_model: state.selected_model.clone(),
                selected_effort: state.selected_effort.clone(),
                fast_enabled: state.fast_enabled,
            }
        };
        save_prompt_settings(&settings);
    }

    /// Persists the model selection and applies it to the live session when possible.
    pub async fn update_prompt_settings(
        &self,
        input: UpdatePromptSettingsInput,
    ) -> Result<PromptSettingsDto> {
        let catalog = self.refresh_model_catalog().await;
        let configured_provider_ids = configured_provider_ids().await;
        let available_catalog = filtered_catalog_models(&catalog, &configured_provider_ids);
        let selected_model = available_catalog
            .iter()
            .copied()
            .find(|model| model.provider == input.provider_id && model.name == input.model_id)
            .with_context(|| {
                format!(
                    "{} is not available for provider {}. Choose a configured provider/model from the picker.",
                    input.model_id, input.provider_id
                )
            })?;
        let live_conversation_id = {
            let mut state = self.state.lock().await;
            state.selected_provider = Some(selected_model.provider.clone());
            state.selected_model = Some(selected_model.name.clone());
            if let Some(effort) = &input.reasoning_effort {
                state.selected_effort = Some(effort.clone());
            }
            state.active_conversation_id.clone()
        };
        if let Some(conversation_id) = live_conversation_id {
            if self.session_exists(&conversation_id).await {
                self.send_control(
                    &conversation_id,
                    serde_json::json!({
                        "type": "set_model",
                        "model": selected_model.name.as_str(),
                        "provider": selected_model.provider.as_str(),
                    }),
                )
                .await?;
                if let Some(effort) = &input.reasoning_effort {
                    self.send_control(
                        &conversation_id,
                        serde_json::json!({ "type": "set_effort", "level": effort }),
                    )
                    .await?;
                }
            }
        }
        self.persist_prompt_settings().await;
        self.get_prompt_settings(input.workspace_path).await
    }

    /// Returns the cached model catalog, fetching `graff --schema` on first use.
    async fn ensure_model_catalog(&self) -> Vec<ModelOption> {
        {
            let state = self.state.lock().await;
            if let Some(catalog) = &state.model_catalog {
                return catalog.clone();
            }
        }
        self.refresh_model_catalog().await
    }

    /// Re-reads `graff --schema` so prompt-settings reflects the current binary's
    /// provider/model list. If the schema read fails after a successful earlier
    /// read, keep showing the last known catalog rather than blanking the picker.
    async fn refresh_model_catalog(&self) -> Vec<ModelOption> {
        let catalog = codegraff_schema_models().await;
        let mut state = self.state.lock().await;
        if catalog.is_empty() {
            return state.model_catalog.clone().unwrap_or_default();
        }
        state.model_catalog = Some(catalog.clone());
        catalog
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
            ProviderAuthMethodKindDto::KimiDevice => {
                launch_codegraff_login(Some("kimi")).await?;
                Ok(cli_login_session(
                    &input.provider_id,
                    "Kimi login launched in Terminal. Complete the device-code flow there, then finish setup here.",
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
        let submitted_api_key = input
            .api_key
            .as_deref()
            .map(str::trim)
            .filter(|key| !key.is_empty());
        if let Some(api_key) = submitted_api_key {
            run_codegraff_key_set(provider_id, api_key).await?;
        }
        let summary = provider_summary(provider_id).await?;
        validate_provider_auth_completion(&summary, submitted_api_key.is_some())?;
        Ok(summary)
    }

    /// Deletes a provider's stored credential from the same locations the CLI
    /// writes (macOS Keychain / `~/.simple-harness-keys.json`, plus the codegraff
    /// and codex login files). A matching `<PROVIDER>_API_KEY` env var, if set,
    /// still takes precedence and will keep the provider configured.
    pub async fn remove_provider(&self, input: RemoveProviderInput) -> Result<ProviderSummaryDto> {
        remove_stored_credential(&input.provider_id)?;
        let summary = provider_summary(&input.provider_id).await?;
        // If it's still configured after deleting stored creds, an env var is
        // overriding it — surface that instead of appearing to do nothing.
        if summary.configured {
            if let Some(env_key) = provider_env_key(&input.provider_id) {
                if std::env::var(&env_key)
                    .ok()
                    .filter(|value| !value.trim().is_empty())
                    .is_some()
                {
                    match find_env_definition(&env_key) {
                        Some((path, line)) => anyhow::bail!(
                            "Stored {provider} credential removed. ${env_key} is still set in {path}:{line}, so it is still being used.",
                            provider = input.provider_id
                        ),
                        None => anyhow::bail!(
                            "Stored {provider} credential removed. ${env_key} is still inherited by the running Codegraff app, so it is still being used.",
                            provider = input.provider_id
                        ),
                    }
                }
            }
        }
        Ok(summary)
    }

    /// Lists slash commands available in the MVP adapter.
    pub async fn list_commands(&self, _: Option<String>) -> Result<Vec<CommandDescriptorDto>> {
        Ok(vec![
            command("help", "Show available commands.", false),
            command("agent", "Show active agent.", false),
            command("goal", "Set/show the current objective.", true),
            command("loop", "Run an autonomous plan→act→verify pass.", true),
            bash_command(),
            command("compact", "Compact current conversation.", true),
            command("workspace-status", "Show git status.", true),
            command(
                "ultracode",
                "Toggle persistent ultracode (multi-agent workflow) mode.",
                true,
            ),
        ])
    }

    /// Sends a prompt and streams the reply from a persistent `graff --json`
    /// session bound to the conversation. Incremental session snapshots are
    /// emitted as text/tool events arrive, so the UI renders tokens live.
    pub async fn send_prompt(&self, input: SendPromptInput) -> Result<SessionSnapshotDto> {
        let conversation_id = input
            .conversation_id
            .clone()
            .unwrap_or_else(|| format!("chat-{}", Uuid::new_v4().simple()));
        let request_id = format!("request-{}", Uuid::new_v4().simple());
        let plan_mode = input.agent_id.as_deref() == Some("muse");
        let loop_mode = input.agent_id.as_deref() == Some("loop");
        let title_model_arg = self.selected_model_arg().await;
        let is_first_turn;
        let engine_prompt;
        let should_queue;
        {
            let mut state = self.state.lock().await;
            set_active_workspace(&mut state, &input.workspace_path);
            state.active_conversation_id = Some(conversation_id.clone());
            state
                .selected_by_workspace
                .insert(input.workspace_path.clone(), conversation_id.clone());
            let active_agent_id = state.active_agent_id.clone();
            let conversation = state
                .conversations
                .entry(conversation_id.clone())
                .or_insert_with(|| ConversationState {
                    workspace_path: input.workspace_path.clone(),
                    conversation_id: conversation_id.clone(),
                    title: title_from_prompt(&input.prompt),
                    messages: vec![],
                    active_request_ids: vec![],
                    request_agent_ids: HashMap::new(),
                    queued_prompts: VecDeque::new(),
                    active_agent_id,
                    plan_mode,
                    ultracode_enabled: false,
                    todos: Vec::new(),
                    goal: None,
                    updated_at: now_millis(),
                });
            conversation.plan_mode = plan_mode;
            conversation.updated_at = now_millis();
            let goal_prompt = conversation
                .goal
                .as_ref()
                .map(|goal| format!("{}\n\n[harness goal: {}]", input.prompt, goal))
                .unwrap_or_else(|| input.prompt.clone());
            engine_prompt = if loop_mode {
                format!(
                    "{goal_prompt}\n\n[harness note: /loop was used. Work autonomously until the prompt is satisfied: make a brief plan, execute it with tools, verify the result, and only stop when you can report completion or you need a required human decision. Keep iterations tight and avoid asking for confirmation between routine steps.]"
                )
            } else {
                goal_prompt
            };
            is_first_turn = conversation.messages.is_empty();
            if is_first_turn && is_placeholder_title(&conversation.title) {
                conversation.title = title_from_prompt(&input.prompt);
            }
            conversation.messages.push(SessionMessageDto::User {
                id: format!("{request_id}-user"),
                request_id: request_id.clone(),
                text: input.prompt.clone(),
            });
            // Remember which agent ("muse" planning / "forge" normal) this
            // request ran under so the GUI's plan-decision card can light up
            // after a planning-mode turn completes (gate keys off "muse").
            conversation.request_agent_ids.insert(
                request_id.clone(),
                input
                    .agent_id
                    .clone()
                    .unwrap_or_else(|| "forge".to_string()),
            );
            should_queue = !conversation.active_request_ids.is_empty();
            if should_queue {
                conversation.queued_prompts.push_back(QueuedPrompt {
                    agent_id: input.agent_id.clone(),
                    engine_prompt: engine_prompt.clone(),
                    request_id: request_id.clone(),
                });
            } else {
                conversation.active_request_ids.push(request_id.clone());
            }
        }

        // Managed chats are auto-created `chat_<id>` folders; once a chat has a
        // prompt, give the workspace a readable name derived from it (unless the
        // user already named it). Projects keep their folder/display name.
        if let Ok(Some(registration)) = self
            .projects
            .get_workspace_registration(Path::new(&input.workspace_path))
        {
            if registration.kind == RegisteredWorkspaceKind::ManagedChat
                && registration.display_name.is_none()
            {
                let _ = self.projects.set_workspace_display_name(
                    Path::new(&input.workspace_path),
                    Some(&title_from_prompt(&input.prompt)),
                );
            }
        }

        self.emit().await?;

        if should_queue {
            return self.snapshot().await;
        }

        if is_first_turn {
            let manager = self.clone();
            let conversation_id = conversation_id.clone();
            let prompt = input.prompt.clone();
            tokio::spawn(async move {
                manager
                    .generate_and_set_title(conversation_id, prompt, title_model_arg)
                    .await;
            });
        }

        if self.session_exists(&conversation_id).await {
            self.send_control(
                &conversation_id,
                serde_json::json!({
                    "type": "set_mode",
                    "mode": if plan_mode { "plan" } else { "normal" },
                }),
            )
            .await?;
        }

        if let Err(error) = self
            .stream_turn(
                &conversation_id,
                &request_id,
                &input.workspace_path,
                &engine_prompt,
            )
            .await
        {
            let message = format_error_chain(&error);
            let id = format!("{request_id}-error");
            let rid = request_id.clone();
            self.mutate_conversation(&conversation_id, move |conversation| {
                conversation.messages.push(SessionMessageDto::Error {
                    id,
                    request_id: rid,
                    message,
                });
            })
            .await;
        }

        let mut completed_request_id = request_id;
        loop {
            let next_prompt = {
                let mut state = self.state.lock().await;
                let Some(conversation) = state.conversations.get_mut(&conversation_id) else {
                    break;
                };
                conversation
                    .active_request_ids
                    .retain(|id| id != &completed_request_id);
                let next = conversation.queued_prompts.pop_front();
                if let Some(next) = &next {
                    conversation.plan_mode = next.agent_id.as_deref() == Some("muse");
                    conversation.updated_at = now_millis();
                    conversation
                        .active_request_ids
                        .push(next.request_id.clone());
                }
                next
            };

            let Some(next_prompt) = next_prompt else {
                break;
            };

            self.emit().await?;

            let next_plan_mode = next_prompt.agent_id.as_deref() == Some("muse");
            if self.session_exists(&conversation_id).await {
                self.send_control(
                    &conversation_id,
                    serde_json::json!({
                        "type": "set_mode",
                        "mode": if next_plan_mode { "plan" } else { "normal" },
                    }),
                )
                .await?;
            }

            if let Err(error) = self
                .stream_turn(
                    &conversation_id,
                    &next_prompt.request_id,
                    &input.workspace_path,
                    &next_prompt.engine_prompt,
                )
                .await
            {
                let message = format_error_chain(&error);
                let id = format!("{}-error", next_prompt.request_id);
                let rid = next_prompt.request_id.clone();
                self.mutate_conversation(&conversation_id, move |conversation| {
                    conversation.messages.push(SessionMessageDto::Error {
                        id,
                        request_id: rid,
                        message,
                    });
                })
                .await;
            }

            completed_request_id = next_prompt.request_id;
        }

        let snapshot = self.snapshot().await?;
        let _ = self.emitter.emit_session_updated(snapshot.clone());
        self.persist_conversations().await;
        Ok(snapshot)
    }

    /// Drives one user turn over the conversation's `graff --json` session,
    /// translating JSONL events into session messages and emitting after each.
    async fn stream_turn(
        &self,
        conversation_id: &str,
        request_id: &str,
        workspace_path: &str,
        prompt: &str,
    ) -> Result<()> {
        let mut io = self
            .acquire_session_io(conversation_id, workspace_path)
            .await?;

        let line = serde_json::json!({ "type": "user", "text": prompt }).to_string();
        if let Err(error) = write_session_line(&io.stdin, &line).await {
            self.drop_session(conversation_id).await;
            return Err(anyhow::Error::new(error).context("Failed to send prompt to graff session"));
        }

        let mut current_assistant: Option<String> = None;
        let mut assistant_seq: usize = 0;
        let mut current_reasoning: Option<String> = None;
        let mut reasoning_seq: usize = 0;
        loop {
            let next = io.reader.next_line().await;
            let line = match next {
                Ok(Some(line)) => line,
                // EOF: the child exited (a stop_prompt kill, or it crashed).
                // End the turn keeping whatever streamed so far; the dead
                // session is dropped so the next prompt respawns it.
                Ok(None) => {
                    self.drop_session(conversation_id).await;
                    return Ok(());
                }
                Err(error) => {
                    self.drop_session(conversation_id).await;
                    return Err(
                        anyhow::Error::new(error).context("Failed reading graff session output")
                    );
                }
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let event: serde_json::Value = match serde_json::from_str(trimmed) {
                Ok(event) => event,
                Err(_) => continue,
            };
            match event.get("type").and_then(serde_json::Value::as_str) {
                Some("text") => {
                    let delta = event
                        .get("text")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    if delta.is_empty() {
                        continue;
                    }
                    current_reasoning = None;
                    let id = current_assistant.get_or_insert_with(|| {
                        let id = format!("{request_id}-assistant-{assistant_seq}");
                        assistant_seq += 1;
                        id
                    });
                    let id = id.clone();
                    let rid = request_id.to_string();
                    let delta = delta.to_string();
                    self.mutate_conversation(conversation_id, move |conversation| {
                        let existing =
                            conversation.messages.iter_mut().rev().find_map(
                                |message| match message {
                                    SessionMessageDto::Assistant { id: mid, text, .. }
                                        if *mid == id =>
                                    {
                                        Some(text)
                                    }
                                    _ => None,
                                },
                            );
                        match existing {
                            Some(text) => text.push_str(&delta),
                            None => conversation.messages.push(SessionMessageDto::Assistant {
                                id,
                                request_id: rid,
                                text: delta,
                            }),
                        }
                    })
                    .await;
                    self.emit().await?;
                }
                Some("reasoning") => {
                    let delta = event
                        .get("text")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("");
                    if delta.is_empty() {
                        continue;
                    }
                    current_assistant = None;
                    let id = current_reasoning.get_or_insert_with(|| {
                        let id = format!("{request_id}-reasoning-{reasoning_seq}");
                        reasoning_seq += 1;
                        id
                    });
                    let id = id.clone();
                    let rid = request_id.to_string();
                    let delta = delta.to_string();
                    self.mutate_conversation(conversation_id, move |conversation| {
                        let existing =
                            conversation.messages.iter_mut().rev().find_map(
                                |message| match message {
                                    SessionMessageDto::Reasoning { id: mid, text, .. }
                                        if *mid == id =>
                                    {
                                        Some(text)
                                    }
                                    _ => None,
                                },
                            );
                        match existing {
                            Some(text) => text.push_str(&delta),
                            None => conversation.messages.push(SessionMessageDto::Reasoning {
                                id,
                                request_id: rid,
                                text: delta,
                            }),
                        }
                    })
                    .await;
                    self.emit().await?;
                }
                Some("tool_call") => {
                    current_assistant = None;
                    let name = event
                        .get("name")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("tool")
                        .to_string();
                    let input = event.get("input");
                    // Older graff binaries surfaced ask_user as a normal
                    // tool_call and expected a plain answer line. Keep that
                    // fallback distinct from the structured ask_user event.
                    if name == "ask_user" {
                        let followup = build_followup_request(
                            conversation_id,
                            request_id,
                            workspace_path,
                            input,
                            Some(format!("legacy-{}", Uuid::new_v4().simple())),
                        );
                        let id = format!("{request_id}-tool-{}", Uuid::new_v4().simple());
                        let rid = request_id.to_string();
                        let call_id = None;
                        let question = followup.question.clone();
                        self.mutate_conversation(conversation_id, move |conversation| {
                            conversation.messages.push(SessionMessageDto::ToolStart {
                                id,
                                request_id: rid,
                                name: "ask_user".to_string(),
                                call_id,
                                detail: ToolCallDetailDto::Followup { question },
                            });
                        })
                        .await;
                        self.state
                            .lock()
                            .await
                            .pending_followups
                            .insert(conversation_id.to_string(), followup);
                        self.emit().await?;
                        continue;
                    }
                    let detail = tool_call_detail(&name, input);
                    // A `todo_write` replaces the whole task list (harness
                    // semantics). Capture the items so the task-progress dock
                    // can render them; the op itself stays hidden in the feed.
                    let todos = if name == "todo_write" {
                        Some(parse_todo_items(input))
                    } else {
                        None
                    };
                    let id = format!("{request_id}-tool-{}", Uuid::new_v4().simple());
                    let rid = request_id.to_string();
                    self.mutate_conversation(conversation_id, move |conversation| {
                        if let Some(todos) = todos {
                            conversation.todos = todos;
                        }
                        conversation.messages.push(SessionMessageDto::ToolStart {
                            id,
                            request_id: rid,
                            name,
                            call_id: None,
                            detail,
                        });
                    })
                    .await;
                    self.emit().await?;
                }
                Some("ask_user") => {
                    current_assistant = None;
                    let input = event.get("input");
                    let call_id = event
                        .get("call_id")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_string)
                        .filter(|id| !id.is_empty())
                        .unwrap_or_else(|| format!("ask-user-{}", Uuid::new_v4().simple()));
                    let followup = build_followup_request(
                        conversation_id,
                        request_id,
                        workspace_path,
                        input,
                        Some(call_id.clone()),
                    );
                    let id = format!("{request_id}-tool-{}", Uuid::new_v4().simple());
                    let rid = request_id.to_string();
                    let question = followup.question.clone();
                    self.mutate_conversation(conversation_id, move |conversation| {
                        conversation.messages.push(SessionMessageDto::ToolStart {
                            id,
                            request_id: rid,
                            name: "ask_user".to_string(),
                            call_id: Some(call_id),
                            detail: ToolCallDetailDto::Followup { question },
                        });
                    })
                    .await;
                    self.state
                        .lock()
                        .await
                        .pending_followups
                        .insert(conversation_id.to_string(), followup);
                    self.emit().await?;
                }
                Some("tool_result") => {
                    current_assistant = None;
                    let name = event
                        .get("name")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("tool")
                        .to_string();
                    let is_error = event
                        .get("is_error")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false);
                    let text = event
                        .get("text")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let summary = tool_result_summary(&text);
                    let detail = if text.is_empty() {
                        None
                    } else {
                        Some(ToolResultDetailDto::Text { text })
                    };
                    let id = format!("{request_id}-toolend-{}", Uuid::new_v4().simple());
                    let rid = request_id.to_string();
                    self.mutate_conversation(conversation_id, move |conversation| {
                        conversation.messages.push(SessionMessageDto::ToolEnd {
                            id,
                            request_id: rid,
                            name,
                            call_id: None,
                            summary,
                            is_error,
                            detail,
                        });
                    })
                    .await;
                    self.emit().await?;
                }
                Some("turn") => break,
                Some("error") => {
                    let message = event
                        .get("message")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("graff error")
                        .to_string();
                    let id = format!("{request_id}-error-{}", Uuid::new_v4().simple());
                    let rid = request_id.to_string();
                    self.mutate_conversation(conversation_id, move |conversation| {
                        conversation.messages.push(SessionMessageDto::Error {
                            id,
                            request_id: rid,
                            message,
                        });
                    })
                    .await;
                    break;
                }
                // system_prompt / score acks and anything unrecognized: ignore.
                _ => {}
            }
        }

        // Turn completed cleanly; hand the IO back to the session for reuse.
        self.release_session_io(conversation_id, io).await;
        Ok(())
    }

    /// Sends one non-user control request to a live `graff --json` session and returns its ack event.
    async fn send_control(
        &self,
        conversation_id: &str,
        request: serde_json::Value,
    ) -> Result<serde_json::Value> {
        let mut sessions = self.sessions.lock().await;
        let session = sessions
            .get_mut(conversation_id)
            .context("No live graff session for this conversation")?;
        let reader = session
            .reader
            .take()
            .context("a prompt is already running for this conversation")?;
        let mut io = GraffSessionIo {
            stdin: session.stdin.clone(),
            reader,
        };
        drop(sessions);

        if let Err(error) = write_session_line(&io.stdin, &request.to_string()).await {
            self.drop_session(conversation_id).await;
            return Err(anyhow::Error::new(error)
                .context("Failed to send control request to graff session"));
        }

        let ack = loop {
            let line = match io.reader.next_line().await {
                Ok(Some(line)) => line,
                Ok(None) => {
                    self.drop_session(conversation_id).await;
                    anyhow::bail!("graff session exited before acknowledging control request");
                }
                Err(error) => {
                    self.drop_session(conversation_id).await;
                    return Err(
                        anyhow::Error::new(error).context("Failed reading graff control response")
                    );
                }
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let Ok(event) = serde_json::from_str::<serde_json::Value>(trimmed) else {
                continue;
            };
            match event.get("type").and_then(serde_json::Value::as_str) {
                Some("model" | "compact" | "mode" | "agent" | "effort" | "fast" | "ultracode") => {
                    break event;
                }
                Some("error") => {
                    let message = event
                        .get("message")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("graff control request failed");
                    self.release_session_io(conversation_id, io).await;
                    anyhow::bail!(message.to_string());
                }
                _ => {}
            }
        };

        self.release_session_io(conversation_id, io).await;
        Ok(ack)
    }

    /// Builds the current snapshot and pushes it to the UI.
    async fn emit(&self) -> Result<()> {
        let snapshot = self.snapshot().await?;
        let _ = self.emitter.emit_session_updated(snapshot);
        Ok(())
    }

    /// Writes non-empty transcripts to disk so chats survive a restart.
    /// Called at turn boundaries / structural changes, not per token.
    async fn persist_conversations(&self) {
        let items: Vec<PersistedConversation> = {
            let state = self.state.lock().await;
            state
                .conversations
                .values()
                .filter(|conversation| !conversation.messages.is_empty())
                .map(|conversation| PersistedConversation {
                    workspace_path: conversation.workspace_path.clone(),
                    conversation_id: conversation.conversation_id.clone(),
                    title: conversation.title.clone(),
                    messages: conversation.messages.clone(),
                    active_agent_id: conversation.active_agent_id.clone(),
                    plan_mode: conversation.plan_mode,
                    ultracode_enabled: conversation.ultracode_enabled,
                    goal: conversation.goal.clone(),
                    updated_at: conversation.updated_at,
                })
                .collect()
        };
        let Some(path) = conversations_store_path() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(text) = serde_json::to_string(&items) {
            let _ = std::fs::write(&path, text);
        }
    }

    /// Applies a mutation to one conversation under the state lock.
    async fn mutate_conversation<F: FnOnce(&mut ConversationState)>(
        &self,
        conversation_id: &str,
        f: F,
    ) {
        let mut state = self.state.lock().await;
        if let Some(conversation) = state.conversations.get_mut(conversation_id) {
            f(conversation);
        }
    }

    /// Returns the conversation's session IO, spawning the `graff --json` child
    /// on first use. Errors if a turn is already streaming for the conversation.
    async fn acquire_session_io(
        &self,
        conversation_id: &str,
        workspace_path: &str,
    ) -> Result<GraffSessionIo> {
        let model_arg = self.selected_model_arg().await;
        let mut sessions = self.sessions.lock().await;
        if !sessions.contains_key(conversation_id) {
            let (active_agent_id, plan_mode, effort, fast, ultracode) = {
                let state = self.state.lock().await;
                let conversation = state.conversations.get(conversation_id);
                (
                    conversation
                        .and_then(|conversation| conversation.active_agent_id.clone())
                        .or_else(|| state.active_agent_id.clone()),
                    conversation
                        .map(|conversation| conversation.plan_mode)
                        .unwrap_or(false),
                    state.selected_effort.clone(),
                    state.fast_enabled,
                    conversation.map(|c| c.ultracode_enabled).unwrap_or(false),
                )
            };
            let session =
                spawn_graff_session(workspace_path, model_arg.as_deref(), conversation_id)?;
            sessions.insert(conversation_id.to_string(), session);
            drop(sessions);
            if let Some(agent_id) = active_agent_id.filter(|id| id != "forge") {
                self.send_control(
                    conversation_id,
                    serde_json::json!({ "type": "set_agent", "id": agent_id }),
                )
                .await?;
            }
            if plan_mode {
                self.send_control(
                    conversation_id,
                    serde_json::json!({ "type": "set_mode", "mode": "plan" }),
                )
                .await?;
            }
            if let Some(level) = effort {
                self.send_control(
                    conversation_id,
                    serde_json::json!({ "type": "set_effort", "level": level }),
                )
                .await?;
            }
            if fast {
                self.send_control(
                    conversation_id,
                    serde_json::json!({ "type": "set_fast", "on": true }),
                )
                .await?;
            }
            if ultracode {
                self.send_control(
                    conversation_id,
                    serde_json::json!({ "type": "set_ultracode", "on": true }),
                )
                .await?;
            }
            sessions = self.sessions.lock().await;
        }
        let session = sessions
            .get_mut(conversation_id)
            .expect("session inserted above");
        let reader = session
            .reader
            .take()
            .context("a prompt is already running for this conversation")?;
        Ok(GraffSessionIo {
            stdin: session.stdin.clone(),
            reader,
        })
    }

    /// Returns the session reader so the next turn on the conversation can reuse
    /// it. The stdin handle stays in the session map, so this only restores the
    /// reader.
    async fn release_session_io(&self, conversation_id: &str, io: GraffSessionIo) {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.get_mut(conversation_id) {
            session.reader = Some(io.reader);
        }
    }

    /// Kills and forgets the conversation's session (used by stop / on failure).
    /// Any unanswered `ask_user` prompt dies with the child, so clear it too.
    async fn drop_session(&self, conversation_id: &str) {
        let mut sessions = self.sessions.lock().await;
        if let Some(mut session) = sessions.remove(conversation_id) {
            let _ = session.child.start_kill();
        }
        drop(sessions);
        self.state
            .lock()
            .await
            .pending_followups
            .remove(conversation_id);
    }

    /// Returns whether a live session exists for the conversation.
    async fn session_exists(&self, conversation_id: &str) -> bool {
        self.sessions.lock().await.contains_key(conversation_id)
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
            "ultracode" => {
                let conversation_id = conversation_id.context("Missing conversation")?;
                let now_on = {
                    let mut state = self.state.lock().await;
                    let conversation = state
                        .conversations
                        .get_mut(&conversation_id)
                        .context("Conversation not found")?;
                    conversation.ultracode_enabled = !conversation.ultracode_enabled;
                    conversation.ultracode_enabled
                };
                self.persist_conversations().await;
                if self.session_exists(&conversation_id).await {
                    self.send_control(
                        &conversation_id,
                        serde_json::json!({ "type": "set_ultracode", "on": now_on }),
                    )
                    .await?;
                }
                let body = if now_on {
                    "Ultracode mode enabled for this chat."
                } else {
                    "Ultracode mode disabled for this chat."
                };
                Ok(CommandRunResultDto {
                    title: "/ultracode".into(),
                    body: Some(body.into()),
                    snapshot: None,
                    saved_path: None,
                    result_kind: CommandResultKindDto::Text,
                    payload: None,
                })
            }
            "goal" => {
                let _workspace = workspace_path.context("Missing workspace")?;
                let conversation_id = conversation_id.context("Missing conversation")?;
                let text = args.join(" ").trim().to_string();
                let body = if text.is_empty() {
                    let current = {
                        let state = self.state.lock().await;
                        state
                            .conversations
                            .get(&conversation_id)
                            .and_then(|conversation| conversation.goal.clone())
                    };
                    current
                        .map(|goal| format!("Current goal: {goal}\n\nClear it with /goal clear."))
                        .unwrap_or_else(|| "No active goal. Set one with /goal <objective>.".into())
                } else if text.eq_ignore_ascii_case("clear") || text.eq_ignore_ascii_case("off") {
                    self.mutate_conversation(&conversation_id, |conversation| {
                        conversation.goal = None;
                    })
                    .await;
                    self.persist_conversations().await;
                    "Goal cleared. Future turns will not get goal steering.".into()
                } else {
                    let goal = text.clone();
                    self.mutate_conversation(&conversation_id, move |conversation| {
                        conversation.goal = Some(goal);
                    })
                    .await;
                    self.persist_conversations().await;
                    format!(
                        "Goal set: {text}\n\nFuture turns in this chat will include this objective as steering."
                    )
                };
                let snapshot = self.snapshot().await?;
                let _ = self.emitter.emit_session_updated(snapshot.clone());
                Ok(CommandRunResultDto {
                    title: "/goal".into(),
                    body: Some(body),
                    snapshot: Some(snapshot),
                    saved_path: None,
                    result_kind: CommandResultKindDto::Text,
                    payload: None,
                })
            }
            "loop" => {
                let prompt = args.join(" ").trim().to_string();
                if prompt.is_empty() {
                    return Ok(CommandRunResultDto {
                        title: "/loop".into(),
                        body: Some(
                            "Usage: /loop <prompt> — run an autonomous plan→act→verify pass."
                                .into(),
                        ),
                        snapshot: None,
                        saved_path: None,
                        result_kind: CommandResultKindDto::Text,
                        payload: None,
                    });
                }
                let workspace = workspace_path.context("Missing workspace")?;
                let snapshot = self
                    .send_prompt(SendPromptInput {
                        workspace_path: workspace,
                        conversation_id,
                        prompt,
                        agent_id: Some("loop".into()),
                    })
                    .await?;
                Ok(CommandRunResultDto {
                    title: "/loop".into(),
                    body: None,
                    snapshot: Some(snapshot),
                    saved_path: None,
                    result_kind: CommandResultKindDto::Snapshot,
                    payload: None,
                })
            }
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
            "bash" => {
                let workspace = self
                    .resolve_workspace(workspace_path)
                    .await
                    .context("Missing workspace")?;
                let shell_command = args.join(" ").trim().to_string();
                if shell_command.is_empty() {
                    return Ok(CommandRunResultDto {
                        title: "/bash".into(),
                        body: Some("usage: /bash <command>".into()),
                        snapshot: None,
                        saved_path: None,
                        result_kind: CommandResultKindDto::Text,
                        payload: None,
                    });
                }
                Ok(CommandRunResultDto {
                    title: format!("/bash {shell_command}"),
                    body: Some(run_shell_command(&workspace, &shell_command)?),
                    snapshot: None,
                    saved_path: None,
                    result_kind: CommandResultKindDto::Text,
                    payload: None,
                })
            }
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
                    "Available MVP commands: /help, /agent, /goal, /loop, /bash <command>, /compact, /workspace-status. Args: {}",
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

    /// Text search over the workspace (ripgrep, falling back to `git grep`).
    /// This is a literal/substring search, not the semantic index the original
    /// GUI used — graff's codedb index isn't exposed as a CLI for the adapter.
    pub async fn workspace_query(
        &self,
        input: WorkspaceQueryInput,
    ) -> Result<WorkspaceSearchPayloadDto> {
        let limit = input.limit.unwrap_or(50).min(500);
        let results = if input.query.trim().is_empty() {
            vec![]
        } else {
            workspace_text_search(
                &input.workspace_path,
                &input.query,
                input.ends_with.as_deref(),
                input.starts_with.as_deref(),
                limit,
            )
        };
        Ok(WorkspaceSearchPayloadDto {
            workspace_path: input.workspace_path,
            query: input.query,
            results,
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

    /// Sets the active agent and applies it to the live conversation when present.
    /// Sets the reasoning-effort level (low|medium|high). Stored for future
    /// sessions and forwarded to the active session if one is live.
    pub async fn set_effort(&self, level: String, _: Option<String>) -> Result<()> {
        let conversation_id = {
            let mut state = self.state.lock().await;
            state.selected_effort = Some(level.clone());
            state.active_conversation_id.clone()
        };
        if let Some(conversation_id) = conversation_id {
            if self.session_exists(&conversation_id).await {
                self.send_control(
                    &conversation_id,
                    serde_json::json!({ "type": "set_effort", "level": level }),
                )
                .await?;
            }
        }
        Ok(())
    }

    /// Toggles Codex "fast" mode (priority service tier). Stored for future
    /// sessions and forwarded to the active session if one is live.
    pub async fn set_fast(&self, on: bool, _: Option<String>) -> Result<()> {
        let conversation_id = {
            let mut state = self.state.lock().await;
            state.fast_enabled = on;
            state.active_conversation_id.clone()
        };
        if let Some(conversation_id) = conversation_id {
            if self.session_exists(&conversation_id).await {
                self.send_control(
                    &conversation_id,
                    serde_json::json!({ "type": "set_fast", "on": on }),
                )
                .await?;
            }
        }
        self.persist_prompt_settings().await;
        Ok(())
    }

    pub async fn set_active_agent(
        &self,
        agent_id: String,
        _: Option<String>,
    ) -> Result<AgentsPayloadDto> {
        let conversation_id = {
            let mut state = self.state.lock().await;
            state.active_agent_id = Some(agent_id.clone());
            let conversation_id = state.active_conversation_id.clone();
            if let Some(conversation_id) = &conversation_id {
                if let Some(conversation) = state.conversations.get_mut(conversation_id) {
                    conversation.active_agent_id = Some(agent_id.clone());
                }
            }
            conversation_id
        };
        if let Some(conversation_id) = conversation_id {
            if self.session_exists(&conversation_id).await {
                let id = if agent_id == "forge" {
                    ""
                } else {
                    agent_id.as_str()
                };
                self.send_control(
                    &conversation_id,
                    serde_json::json!({ "type": "set_agent", "id": id }),
                )
                .await?;
            }
        }
        Ok(self.agents_payload().await)
    }

    /// Lists MCP servers configured in the workspace `.mcp.json`.
    pub async fn list_mcp_servers(
        &self,
        workspace_path: Option<String>,
    ) -> Result<McpSettingsPayloadDto> {
        let servers = match self.resolve_workspace(workspace_path).await {
            Some(workspace) => read_mcp_servers(&workspace),
            None => vec![],
        };
        Ok(McpSettingsPayloadDto { servers })
    }

    /// Merges imported `mcpServers` entries into the workspace `.mcp.json`.
    pub async fn import_mcp_config(&self, input: McpImportInput) -> Result<McpSettingsPayloadDto> {
        let workspace = self
            .resolve_workspace(None)
            .await
            .context("No active workspace to import MCP config into")?;
        let incoming: serde_json::Value =
            serde_json::from_str(&input.json).context("Invalid MCP config JSON")?;
        // Accept either {"mcpServers": {...}} or a bare {name: {...}} map.
        let incoming = incoming.get("mcpServers").cloned().unwrap_or(incoming);
        let incoming = incoming
            .as_object()
            .context("MCP config must be an object of servers")?;

        let mut config =
            read_mcp_config(&workspace).unwrap_or_else(|| serde_json::json!({ "mcpServers": {} }));
        let servers = config
            .as_object_mut()
            .context("`.mcp.json` is not a JSON object")?
            .entry("mcpServers")
            .or_insert_with(|| serde_json::json!({}));
        let servers = servers
            .as_object_mut()
            .context("`mcpServers` is not a JSON object")?;
        for (name, server) in incoming {
            servers.insert(name.clone(), server.clone());
        }
        write_mcp_config(&workspace, &config)?;
        self.list_mcp_servers(Some(workspace)).await
    }

    /// Removes a server from the workspace `.mcp.json`.
    pub async fn remove_mcp_server(
        &self,
        input: McpServerActionInput,
    ) -> Result<McpSettingsPayloadDto> {
        let workspace = self
            .resolve_workspace(None)
            .await
            .context("No active workspace")?;
        if let Some(mut config) = read_mcp_config(&workspace) {
            if let Some(servers) = config
                .get_mut("mcpServers")
                .and_then(serde_json::Value::as_object_mut)
            {
                servers.remove(&input.name);
            }
            write_mcp_config(&workspace, &config)?;
        }
        self.list_mcp_servers(Some(workspace)).await
    }

    /// Re-reads `.mcp.json`. New entries apply to sessions spawned afterwards;
    /// live sessions keep the MCP set they started with.
    pub async fn reload_mcp_servers(
        &self,
        workspace_path: Option<String>,
    ) -> Result<McpSettingsPayloadDto> {
        self.list_mcp_servers(workspace_path).await
    }

    /// MCP OAuth login — not applicable: graff runs stdio MCP servers only.
    pub async fn login_mcp_server(&self, _: McpServerActionInput) -> Result<McpSettingsPayloadDto> {
        anyhow::bail!(
            "graff runs stdio MCP servers (command/args) only; OAuth login does not apply"
        )
    }

    /// MCP OAuth logout — not applicable: graff runs stdio MCP servers only.
    pub async fn logout_mcp_server(
        &self,
        _: McpServerActionInput,
    ) -> Result<McpSettingsPayloadDto> {
        anyhow::bail!(
            "graff runs stdio MCP servers (command/args) only; OAuth logout does not apply"
        )
    }

    /// Resolves the workspace to act on: the argument if set, else the active one.
    async fn resolve_workspace(&self, workspace_path: Option<String>) -> Option<String> {
        if let Some(workspace) = workspace_path.filter(|workspace| !workspace.is_empty()) {
            return Some(workspace);
        }
        self.state.lock().await.active_workspace_path.clone()
    }

    /// Compacts the live conversation and records the real compaction result.
    pub async fn compact_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> Result<SessionSnapshotDto> {
        {
            let mut state = self.state.lock().await;
            set_active_workspace(&mut state, &workspace_path);
        }
        let ack = self
            .send_control(&conversation_id, serde_json::json!({ "type": "compact" }))
            .await?;
        let chars = ack
            .get("chars")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);
        self.mutate_conversation(&conversation_id, move |conversation| {
            let request_id = format!("compact-{}", Uuid::new_v4().simple());
            conversation
                .messages
                .push(SessionMessageDto::ContextCompacted {
                    id: request_id.clone(),
                    request_id,
                    text: format!("Conversation compacted to a {chars}-character summary."),
                });
        })
        .await;
        self.persist_conversations().await;
        self.snapshot().await
    }

    /// Stops a prompt in the local GUI state.
    pub async fn stop_prompt(&self, input: ChatBindingDto) -> Result<()> {
        // Killing the session child makes the in-flight stream_turn read loop
        // hit EOF and finish, keeping whatever streamed so far. The next prompt
        // respawns a fresh session.
        self.drop_session(&input.conversation_id).await;
        self.mutate_conversation(&input.conversation_id, |conversation| {
            conversation.active_request_ids.clear();
            conversation.queued_prompts.clear();
        })
        .await;
        let _ = self.emit().await;
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
        if state.conversations.contains_key(&conversation_id) {
            state.active_conversation_id = Some(conversation_id.clone());
            state
                .selected_by_workspace
                .insert(workspace_path, conversation_id);
        } else if let Some(fallback_id) = first_workspace_conversation_id(&state, &workspace_path) {
            state.active_conversation_id = Some(fallback_id.clone());
            state
                .selected_by_workspace
                .insert(workspace_path, fallback_id);
        } else {
            state.active_conversation_id = None;
            state.selected_by_workspace.remove(&workspace_path);
        }
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
                request_agent_ids: HashMap::new(),
                queued_prompts: VecDeque::new(),
                active_agent_id: None,
                plan_mode: false,
                ultracode_enabled: false,
                todos: Vec::new(),
                goal: None,
                updated_at: now_millis(),
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

    /// Answers an in-flight `ask_user` prompt: writes the reply to the graff
    /// child's stdin (unblocking it), clears the pending followup, and lets the
    /// still-running stream_turn loop pick up the resulting tool_result.
    pub async fn respond_followup(
        &self,
        response: FollowupResponseDto,
    ) -> Result<SessionSnapshotDto> {
        let request = {
            let mut state = self.state.lock().await;
            let conversation_id =
                state
                    .pending_followups
                    .iter()
                    .find_map(|(conversation_id, request)| {
                        (request.followup_id == response.followup_id)
                            .then(|| conversation_id.clone())
                    });
            conversation_id.and_then(|id| state.pending_followups.remove(&id))
        };
        // No matching prompt (already answered, or the session was dropped):
        // just return the current snapshot so the UI reconciles.
        let Some(request) = request else {
            return self.snapshot().await;
        };

        let answer = followup_answer_line(&request, &response);
        let stdin = {
            let sessions = self.sessions.lock().await;
            sessions
                .get(&request.conversation_id)
                .map(|session| session.stdin.clone())
        };
        if let Some(stdin) = stdin {
            if let Err(error) = write_session_line(&stdin, &answer).await {
                self.drop_session(&request.conversation_id).await;
                return Err(anyhow::Error::new(error)
                    .context("Failed to send follow-up answer to graff session"));
            }
        }

        if request.followup_id.starts_with("legacy-") {
            let name = "ask_user".to_string();
            let summary = tool_result_summary(&answer);
            let detail = if answer.is_empty() {
                None
            } else {
                Some(ToolResultDetailDto::Text {
                    text: answer.clone(),
                })
            };
            let id = format!("{}-toolend-{}", request.request_id, Uuid::new_v4().simple());
            let rid = request.request_id.clone();
            self.mutate_conversation(&request.conversation_id, move |conversation| {
                conversation.messages.push(SessionMessageDto::ToolEnd {
                    id,
                    request_id: rid,
                    name,
                    call_id: None,
                    summary,
                    is_error: response.cancelled,
                    detail,
                });
            })
            .await;
        }

        self.emit().await?;
        self.snapshot().await
    }

    /// Archives a conversation from local state.
    pub async fn archive_conversation(
        &self,
        workspace_path: String,
        conversation_id: String,
    ) -> Result<SessionSnapshotDto> {
        self.drop_session(&conversation_id).await;
        let mut state = self.state.lock().await;
        state.conversations.remove(&conversation_id);
        if state.selected_by_workspace.get(&workspace_path) == Some(&conversation_id) {
            state.selected_by_workspace.remove(&workspace_path);
        }
        state
            .selected_by_workspace
            .retain(|_, selected_id| selected_id != &conversation_id);
        if state.active_conversation_id.as_deref() == Some(&conversation_id) {
            if state.active_workspace_path.as_deref() == Some(&workspace_path) {
                state.active_conversation_id =
                    first_workspace_conversation_id(&state, &workspace_path);
            } else {
                state.active_conversation_id = None;
            }
        }
        drop(state);
        self.persist_conversations().await;
        self.snapshot().await
    }

    /// Archives a workspace from the local registry.
    pub async fn archive_workspace(&self, workspace_path: String) -> Result<SessionSnapshotDto> {
        self.projects
            .archive_workspace(Path::new(&workspace_path))?;
        let conversation_ids: Vec<String> = {
            let state = self.state.lock().await;
            state
                .conversations
                .values()
                .filter(|conversation| conversation.workspace_path == workspace_path)
                .map(|conversation| conversation.conversation_id.clone())
                .collect()
        };
        for conversation_id in &conversation_ids {
            self.drop_session(conversation_id).await;
        }
        let removed_conversation_ids: HashSet<String> = conversation_ids.into_iter().collect();
        let mut state = self.state.lock().await;
        state.workspaces.retain(|path| path != &workspace_path);
        state
            .conversations
            .retain(|_, conversation| conversation.workspace_path != workspace_path);
        state.selected_by_workspace.remove(&workspace_path);
        state
            .selected_by_workspace
            .retain(|_, conversation_id| !removed_conversation_ids.contains(conversation_id));
        if state.active_workspace_path.as_deref() == Some(&workspace_path) {
            state.active_workspace_path = state.workspaces.first().cloned();
            state.active_conversation_id = state
                .active_workspace_path
                .clone()
                .and_then(|path| first_workspace_conversation_id(&state, &path));
        } else if state
            .active_conversation_id
            .as_ref()
            .is_some_and(|conversation_id| removed_conversation_ids.contains(conversation_id))
        {
            state.active_conversation_id = state
                .active_workspace_path
                .clone()
                .and_then(|path| first_workspace_conversation_id(&state, &path));
        }
        drop(state);
        self.persist_conversations().await;
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
        let registered = self.projects.list_workspaces().unwrap_or_default();
        for workspace in &registered {
            let path = workspace.path.to_string_lossy().into_owned();
            if !state.workspaces.contains(&path) {
                state.workspaces.push(path);
            }
        }
        // path -> (kind, display_name): routes managed chats to the "Chats"
        // section (vs "Projects") and supplies their readable name.
        let registrations: HashMap<String, (WorkspaceKindDto, Option<String>)> = registered
            .into_iter()
            .map(|workspace| {
                let kind = match workspace.kind {
                    RegisteredWorkspaceKind::ManagedChat => WorkspaceKindDto::ManagedChat,
                    RegisteredWorkspaceKind::Project => WorkspaceKindDto::Project,
                };
                (
                    workspace.path.to_string_lossy().into_owned(),
                    (kind, workspace.display_name),
                )
            })
            .collect();
        normalize_runtime_selection(&mut state);
        let active_conversation_id = state.active_conversation_id.clone();
        let pending_followups = state.pending_followups.clone();
        let visible_followup = active_conversation_id
            .as_ref()
            .and_then(|id| pending_followups.get(id).cloned());
        let visible = active_conversation_id
            .as_ref()
            .and_then(|id| state.conversations.get(id))
            .cloned();
        let conversation_views = state
            .conversations
            .values()
            .map(|conversation| {
                let followup = pending_followups
                    .get(&conversation.conversation_id)
                    .cloned();
                conversation_view(conversation, followup)
            })
            .collect();
        let workspaces = state
            .workspaces
            .iter()
            .map(|path| {
                let mut workspace_convos: Vec<&ConversationState> = state
                    .conversations
                    .values()
                    .filter(|conversation| &conversation.workspace_path == path)
                    .collect();
                // Newest chats first (most recently sent), drafts (updated_at 0)
                // fall to the bottom.
                workspace_convos.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
                let conversations = workspace_convos
                    .into_iter()
                    .map(|conversation| ConversationSessionSummaryDto {
                        conversation_id: conversation.conversation_id.clone(),
                        title: conversation.title.clone(),
                        updated_at: (conversation.updated_at > 0)
                            .then(|| conversation.updated_at.to_string()),
                        is_draft: conversation.messages.is_empty(),
                        is_running: !conversation.active_request_ids.is_empty(),
                        has_pending_followup: pending_followups
                            .contains_key(&conversation.conversation_id),
                    })
                    .collect();
                let (kind, display_name) = registrations
                    .get(path)
                    .cloned()
                    .unwrap_or((WorkspaceKindDto::Project, None));
                let selected_conversation_id = selected_workspace_conversation_id(&state, path);
                WorkspaceSessionDto {
                    kind,
                    workspace_path: path.clone(),
                    workspace_name: display_name.unwrap_or_else(|| workspace_name(path)),
                    configured: true,
                    configuration_error: None,
                    selected_conversation_id,
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
            visible_request_agent_ids: visible
                .as_ref()
                .map(|c| c.request_agent_ids.clone())
                .unwrap_or_default(),
            visible_todos: visible
                .as_ref()
                .map(|c| c.todos.clone())
                .unwrap_or_default(),
            visible_followup,
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

/// Runs a literal substring search over the workspace. Tries ripgrep first
/// (fast, .gitignore-aware), then `git grep`. Returns up to `limit` matches.
fn workspace_text_search(
    workspace_path: &str,
    query: &str,
    ends_with: Option<&[String]>,
    starts_with: Option<&str>,
    limit: usize,
) -> Vec<WorkspaceSearchResultDto> {
    let mut command = Command::new("rg");
    command.args([
        "--line-number",
        "--no-heading",
        "--color",
        "never",
        "--fixed-strings",
        "--smart-case",
        "--max-count",
        "20",
    ]);
    if let Some(exts) = ends_with {
        for ext in exts {
            command
                .arg("--glob")
                .arg(format!("*.{}", ext.trim_start_matches('.')));
        }
    }
    command
        .arg("--")
        .arg(query)
        .arg(".")
        .current_dir(workspace_path);

    let stdout = match command.output() {
        Ok(output) => String::from_utf8_lossy(&output.stdout).into_owned(),
        // ripgrep absent: fall back to git grep (needs a git repo).
        Err(_) => {
            let output = Command::new("git")
                .args([
                    "grep",
                    "--line-number",
                    "--fixed-strings",
                    "-I",
                    "-e",
                    query,
                ])
                .current_dir(workspace_path)
                .output();
            match output {
                Ok(output) => String::from_utf8_lossy(&output.stdout).into_owned(),
                Err(_) => return vec![],
            }
        }
    };

    parse_grep_results(&stdout, starts_with, limit)
}

/// Parses `path:line:content` lines (ripgrep / git grep) into search results.
fn parse_grep_results(
    text: &str,
    starts_with: Option<&str>,
    limit: usize,
) -> Vec<WorkspaceSearchResultDto> {
    text.lines()
        .filter_map(|line| {
            let mut parts = line.splitn(3, ':');
            let path = parts.next()?;
            let line_no: u32 = parts.next()?.parse().ok()?;
            let content = parts.next()?;
            if let Some(prefix) = starts_with {
                let normalized = path.trim_start_matches("./");
                if !normalized.starts_with(prefix) {
                    return None;
                }
            }
            Some(WorkspaceSearchResultDto {
                node_id: format!("{path}:{line_no}"),
                kind: "match".into(),
                path: Some(path.trim_start_matches("./").to_string()),
                start_line: Some(line_no),
                end_line: Some(line_no),
                preview: content.trim().chars().take(200).collect(),
                relevance: None,
                distance: None,
            })
        })
        .take(limit)
        .collect()
}

/// On-disk form of a conversation (transient request state is not persisted).
#[derive(serde::Serialize, serde::Deserialize)]
struct PersistedConversation {
    workspace_path: String,
    conversation_id: String,
    title: String,
    messages: Vec<SessionMessageDto>,
    active_agent_id: Option<String>,
    #[serde(default)]
    plan_mode: bool,
    #[serde(default)]
    ultracode_enabled: bool,
    #[serde(default)]
    goal: Option<String>,
    #[serde(default)]
    updated_at: i64,
}

/// Path to the transcript store (`~/.codegraff-gui/conversations.json`).
#[derive(serde::Serialize, serde::Deserialize, Default)]
struct PersistedPromptSettings {
    #[serde(default)]
    selected_provider: Option<String>,
    #[serde(default)]
    selected_model: Option<String>,
    #[serde(default)]
    selected_effort: Option<String>,
    #[serde(default)]
    fast_enabled: bool,
}

/// Path to the persisted prompt selection (`~/.codegraff-gui/prompt-settings.json`).
fn prompt_settings_store_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".codegraff-gui")
            .join("prompt-settings.json")
    })
}

/// Loads the last model/effort/fast selection so it survives app restarts.
fn load_persisted_prompt_settings() -> PersistedPromptSettings {
    let Some(path) = prompt_settings_store_path() else {
        return PersistedPromptSettings::default();
    };
    let Ok(data) = std::fs::read_to_string(&path) else {
        return PersistedPromptSettings::default();
    };
    serde_json::from_str(&data).unwrap_or_default()
}

fn save_prompt_settings(settings: &PersistedPromptSettings) {
    let Some(path) = prompt_settings_store_path() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(data) = serde_json::to_string_pretty(settings) {
        let _ = std::fs::write(&path, data);
    }
}

fn conversations_store_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".codegraff-gui")
            .join("conversations.json")
    })
}

/// Loads persisted transcripts so past chats survive a restart. Continuing a
/// chat now spawns `graff --json --resume <conversation_id>`, so new/updated
/// chats also regain engine-side model context when their session file exists.
fn load_persisted_conversations() -> HashMap<String, ConversationState> {
    let Some(path) = conversations_store_path() else {
        return HashMap::new();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    let Ok(items) = serde_json::from_str::<Vec<PersistedConversation>>(&text) else {
        return HashMap::new();
    };
    items
        .into_iter()
        .map(|conversation| {
            let title = recover_conversation_title(&conversation.title, &conversation.messages);
            (
                conversation.conversation_id.clone(),
                ConversationState {
                    workspace_path: conversation.workspace_path,
                    conversation_id: conversation.conversation_id,
                    title,
                    messages: conversation.messages,
                    active_request_ids: vec![],
                    request_agent_ids: HashMap::new(),
                    queued_prompts: VecDeque::new(),
                    active_agent_id: conversation.active_agent_id,
                    plan_mode: conversation.plan_mode,
                    ultracode_enabled: conversation.ultracode_enabled,
                    todos: Vec::new(),
                    goal: conversation.goal,
                    updated_at: conversation.updated_at,
                },
            )
        })
        .collect()
}

fn recover_conversation_title(title: &str, messages: &[SessionMessageDto]) -> String {
    if !is_placeholder_title(title) {
        return title.to_string();
    }

    first_user_message_text(messages)
        .map(title_from_prompt)
        .unwrap_or_else(|| title_from_prompt(""))
}

fn first_user_message_text(messages: &[SessionMessageDto]) -> Option<&str> {
    messages.iter().find_map(|message| match message {
        SessionMessageDto::User { text, .. } if !text.trim().is_empty() => Some(text.as_str()),
        _ => None,
    })
}

fn set_active_workspace(state: &mut RuntimeState, workspace_path: &str) {
    state.active_workspace_path = Some(workspace_path.into());
    if !state.workspaces.iter().any(|path| path == workspace_path) {
        state.workspaces.insert(0, workspace_path.into());
    }
}

fn normalize_runtime_selection(state: &mut RuntimeState) {
    let conversations = &state.conversations;
    state
        .selected_by_workspace
        .retain(|workspace_path, conversation_id| {
            conversations
                .get(conversation_id)
                .is_some_and(|conversation| &conversation.workspace_path == workspace_path)
        });

    if let Some(active_conversation_id) = state.active_conversation_id.clone() {
        let active_workspace_path = state.active_workspace_path.clone();
        let is_valid_active = state
            .conversations
            .get(&active_conversation_id)
            .is_some_and(|conversation| {
                active_workspace_path
                    .as_ref()
                    .is_none_or(|path| &conversation.workspace_path == path)
            });
        if !is_valid_active {
            state.active_conversation_id = active_workspace_path
                .as_deref()
                .and_then(|workspace_path| first_workspace_conversation_id(state, workspace_path));
        }
    }
}

fn selected_workspace_conversation_id(
    state: &RuntimeState,
    workspace_path: &str,
) -> Option<String> {
    state
        .selected_by_workspace
        .get(workspace_path)
        .filter(|conversation_id| {
            state
                .conversations
                .get(*conversation_id)
                .is_some_and(|conversation| conversation.workspace_path == workspace_path)
        })
        .cloned()
}

fn first_workspace_conversation_id(state: &RuntimeState, workspace_path: &str) -> Option<String> {
    state
        .conversations
        .values()
        .filter(|conversation| conversation.workspace_path == workspace_path)
        .max_by(|a, b| {
            a.updated_at
                .cmp(&b.updated_at)
                .then_with(|| a.conversation_id.cmp(&b.conversation_id))
        })
        .map(|conversation| conversation.conversation_id.clone())
}

fn conversation_view(
    conversation: &ConversationState,
    followup: Option<FollowupRequestDto>,
) -> ConversationViewSnapshotDto {
    ConversationViewSnapshotDto {
        workspace_path: conversation.workspace_path.clone(),
        conversation_id: conversation.conversation_id.clone(),
        messages: conversation.messages.clone(),
        active_request_ids: conversation.active_request_ids.clone(),
        request_agent_ids: conversation.request_agent_ids.clone(),
        todos: conversation.todos.clone(),
        followup,
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
        requires_conversation: matches!(name, "compact" | "goal" | "loop" | "ultracode"),
        argument_hint: None,
        result_kind: CommandResultKindDto::Text,
    }
}

/// macOS GUI processes launched from Finder/Dock get launchd's minimal
/// environment, not the user's shell — so `export OPENAI_API_KEY=…` (and any
/// other `*_API_KEY`) from .zshrc/.zprofile is invisible to children we spawn.
/// Capture the login shell's environment once (best-effort, time-bounded) so a
/// GUI-spawned `graff` sees the same provider keys the terminal `graff` does.
fn login_shell_env() -> &'static std::collections::HashMap<String, String> {
    static ENV: std::sync::OnceLock<std::collections::HashMap<String, String>> =
        std::sync::OnceLock::new();
    ENV.get_or_init(|| {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            // -il = interactive login shell: sources the login profile AND
            // .zshrc/.bashrc, where most users export their *_API_KEY.
            let out = std::process::Command::new(&shell)
                .args(["-ilc", "env"])
                .output();
            let _ = tx.send(out);
        });
        let mut map = std::collections::HashMap::new();
        if let Ok(Ok(out)) = rx.recv_timeout(std::time::Duration::from_secs(4)) {
            if out.status.success() {
                for line in String::from_utf8_lossy(&out.stdout).lines() {
                    if let Some((k, v)) = line.split_once('=') {
                        map.insert(k.to_string(), v.to_string());
                    }
                }
            }
        }
        map
    })
}

fn bash_command() -> CommandDescriptorDto {
    CommandDescriptorDto {
        argument_hint: Some("<command>".into()),
        ..command("bash", "Run a shell command in the workspace.", true)
    }
}

/// Spawns a persistent `graff --json` child for a conversation. `--yolo` skips
/// permission prompts (the GUI has no approval surface yet); stderr is discarded
/// since the protocol carries errors as `error` events on stdout.
fn spawn_graff_session(
    workspace_path: &str,
    model: Option<&str>,
    conversation_id: &str,
) -> Result<GraffSession> {
    let bin = codegraff_binary();
    let mut command = tokio::process::Command::new(&bin);
    command
        .arg("--json")
        .arg("--yolo")
        .arg("--resume")
        .arg(conversation_id);
    if let Some(model) = model.filter(|model| !model.is_empty() && *model != "default") {
        command.arg("--model").arg(model);
    }
    // macOS GUI apps (Finder/Dock) inherit launchd's minimal env, not the user's
    // shell — so OPENAI_API_KEY & co. exported in .zshrc are invisible to graff,
    // which then silently falls back to a file-based login (e.g. an empty
    // codegraff account). Pass the login shell's env so the GUI sees the same
    // provider keys the terminal does.
    command.envs(login_shell_env());
    let mut child = command
        .current_dir(workspace_path)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .with_context(|| {
            format!(
                "Failed to launch the codegraff engine ('{bin}'). Install the CLI (curl -fsSL https://codegraff.com/install.sh | sh) or set CODEGRAFF_GUI_BINARY to the graff binary path."
            )
        })?;
    let stdin = child.stdin.take().context("graff session missing stdin")?;
    let stdout = child
        .stdout
        .take()
        .context("graff session missing stdout")?;
    let reader = BufReader::new(stdout).lines();
    Ok(GraffSession {
        child,
        stdin: Arc::new(Mutex::new(stdin)),
        reader: Some(reader),
    })
}

/// Reads the model catalog from `graff --schema`. Returns empty on any failure
/// (missing binary, parse error) so callers fall back to the CLI default.
async fn codegraff_schema_models() -> Vec<ModelOption> {
    let output = match tokio::process::Command::new(codegraff_binary())
        .arg("--schema")
        .output()
        .await
    {
        Ok(output) if output.status.success() => output.stdout,
        _ => return vec![],
    };
    let schema: serde_json::Value = match serde_json::from_slice(&output) {
        Ok(schema) => schema,
        Err(_) => return vec![],
    };
    let provider_names: HashMap<String, String> = schema
        .get("providers")
        .and_then(serde_json::Value::as_array)
        .map(|providers| {
            providers
                .iter()
                .filter_map(|provider| {
                    Some((
                        provider.get("id")?.as_str()?.to_string(),
                        provider
                            .get("name")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or(provider.get("id")?.as_str()?)
                            .to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();
    let provider_defaults: HashMap<String, String> = schema
        .get("providers")
        .and_then(serde_json::Value::as_array)
        .map(|providers| {
            providers
                .iter()
                .filter_map(|provider| {
                    Some((
                        provider.get("id")?.as_str()?.to_string(),
                        provider.get("default_model")?.as_str()?.to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();

    schema
        .get("models")
        .and_then(serde_json::Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter_map(|model| {
                    let provider = model.get("provider")?.as_str()?.to_string();
                    let name = model.get("name")?.as_str()?.to_string();
                    Some(ModelOption {
                        provider_name: provider_names.get(&provider).cloned(),
                        is_default: provider_defaults
                            .get(&provider)
                            .is_some_and(|default_model| default_model == &name),
                        provider,
                        name,
                        context: model.get("context").and_then(serde_json::Value::as_u64),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Reads and parses the workspace `.mcp.json`, or None if absent/invalid.
fn read_mcp_config(workspace_path: &str) -> Option<serde_json::Value> {
    let path = Path::new(workspace_path).join(".mcp.json");
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Writes the workspace `.mcp.json` pretty-printed.
fn write_mcp_config(workspace_path: &str, config: &serde_json::Value) -> Result<()> {
    let path = Path::new(workspace_path).join(".mcp.json");
    let text = serde_json::to_string_pretty(config).context("Failed to serialize .mcp.json")?;
    std::fs::write(path, text).context("Failed to write .mcp.json")
}

/// Builds server summaries from the workspace `.mcp.json`. Tool counts are 0:
/// MCP tools are loaded inside the `graff` session and aren't enumerable here.
fn read_mcp_servers(workspace_path: &str) -> Vec<McpServerSummaryDto> {
    let config = match read_mcp_config(workspace_path) {
        Some(config) => config,
        None => return vec![],
    };
    let servers = match config
        .get("mcpServers")
        .and_then(serde_json::Value::as_object)
    {
        Some(servers) => servers,
        None => return vec![],
    };
    servers
        .iter()
        .map(|(name, cfg)| {
            let url = cfg.get("url").and_then(serde_json::Value::as_str);
            let command = cfg.get("command").and_then(serde_json::Value::as_str);
            let args = cfg
                .get("args")
                .and_then(serde_json::Value::as_array)
                .map(|args| {
                    args.iter()
                        .filter_map(serde_json::Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" ")
                })
                .unwrap_or_default();
            let (server_type, target) = match url {
                Some(url) => ("http".to_string(), url.to_string()),
                None => {
                    let target = match command {
                        Some(command) if args.is_empty() => command.to_string(),
                        Some(command) => format!("{command} {args}"),
                        None => String::new(),
                    };
                    ("stdio".to_string(), target)
                }
            };
            McpServerSummaryDto {
                name: name.clone(),
                server_type,
                target,
                is_disabled: cfg
                    .get("disabled")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                tool_count: 0,
                tools: vec![],
                error: None,
                auth_status: None,
            }
        })
        .collect()
}

/// Human-readable provider name, reusing the adapter's provider table.
fn provider_display_name(provider_id: &str) -> String {
    fallback_providers()
        .iter()
        .find(|provider| provider.id == provider_id)
        .map(|provider| provider.name.to_string())
        .unwrap_or_else(|| provider_id.to_string())
}

fn filtered_catalog_models<'a>(
    catalog: &'a [ModelOption],
    configured_provider_ids: &HashSet<String>,
) -> Vec<&'a ModelOption> {
    catalog
        .iter()
        .filter(|model| configured_provider_ids.contains(&model.provider))
        .collect()
}

fn prompt_model_option(model: &ModelOption) -> PromptModelOptionDto {
    // Effort-capable providers (mirrors the binary's effortApplies):
    // codex takes reasoning.effort via the Responses API; codegraff and
    // deepseek take a top-level reasoning_effort. But the gateway's gpt-*
    // models go through /v1/chat/completions, which rejects reasoning_effort.
    let effort_capable = match model.provider.as_str() {
        "codex" => true,
        "codegraff" | "deepseek" => !model.name.starts_with("gpt-"),
        "kimi" => true,
        _ => false,
    };
    let reasoning_efforts: Vec<String> = if effort_capable {
        vec!["low".into(), "medium".into(), "high".into()]
    } else {
        vec![]
    };

    PromptModelOptionDto {
        provider_id: model.provider.clone(),
        provider_name: model
            .provider_name
            .clone()
            .unwrap_or_else(|| provider_display_name(&model.provider)),
        model_id: model.name.clone(),
        model_name: Some(model.name.clone()),
        context_length: model.context,
        supports_reasoning: !reasoning_efforts.is_empty(),
        reasoning_efforts,
    }
}

fn selected_prompt_model_pair(
    catalog: &[ModelOption],
    configured_provider_ids: &HashSet<String>,
    selected_provider: Option<&str>,
    selected_model: Option<&str>,
) -> Option<(String, String)> {
    let available_catalog = filtered_catalog_models(catalog, configured_provider_ids);

    let default_model = available_catalog
        .iter()
        .find(|model| model.provider == "codegraff" && model.is_default)
        .copied()
        .or_else(|| {
            available_catalog
                .iter()
                .find(|model| model.is_default)
                .copied()
        })
        .or_else(|| available_catalog.first().copied());

    selected_provider
        .zip(selected_model)
        .and_then(|(provider, model)| {
            available_catalog
                .iter()
                .find(|candidate| candidate.provider == provider && candidate.name == model)
                .map(|candidate| (candidate.provider.clone(), candidate.name.clone()))
        })
        .or_else(|| default_model.map(|model| (model.provider.clone(), model.name.clone())))
}

fn prompt_model_arg(provider: &str, model: &str) -> String {
    format!("{provider} {model}")
}

fn selected_pair_exists(
    catalog: &[ModelOption],
    configured_provider_ids: &HashSet<String>,
    selected_provider: Option<&str>,
    selected_model: Option<&str>,
) -> bool {
    let Some((provider, model)) = selected_provider.zip(selected_model) else {
        return false;
    };
    filtered_catalog_models(catalog, configured_provider_ids)
        .iter()
        .any(|candidate| candidate.provider == provider && candidate.name == model)
}

fn build_prompt_settings_from_catalog(
    catalog: &[ModelOption],
    configured_provider_ids: &HashSet<String>,
    selected_provider: Option<&str>,
    selected_model: Option<&str>,
    selected_effort: Option<String>,
    fast_enabled: bool,
) -> PromptSettingsDto {
    if catalog.is_empty() {
        if configured_provider_ids.contains("codegraff") {
            return PromptSettingsDto {
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
                fast_enabled,
            };
        }

        return PromptSettingsDto {
            available_models: vec![],
            selected_provider_id: None,
            selected_model_id: None,
            selected_reasoning_effort: None,
            fast_enabled,
        };
    }

    let available_catalog = filtered_catalog_models(catalog, configured_provider_ids);
    let available_models = available_catalog
        .iter()
        .map(|model| prompt_model_option(model))
        .collect();

    let selected_pair = selected_prompt_model_pair(
        catalog,
        configured_provider_ids,
        selected_provider,
        selected_model,
    );
    let selected_effort = if selected_pair_exists(
        catalog,
        configured_provider_ids,
        selected_provider,
        selected_model,
    ) {
        selected_effort
    } else {
        None
    };

    PromptSettingsDto {
        available_models,
        selected_provider_id: selected_pair.as_ref().map(|(provider, _)| provider.clone()),
        selected_model_id: selected_pair.as_ref().map(|(_, model)| model.clone()),
        selected_reasoning_effort: selected_pair.and(selected_effort),
        fast_enabled,
    }
}

/// Writes one newline-delimited protocol request to a session's stdin. Locks
/// the shared stdin handle internally so a turn write and an `ask_user` answer
/// can't interleave on the pipe.
async fn write_session_line(
    stdin: &Mutex<tokio::process::ChildStdin>,
    line: &str,
) -> std::io::Result<()> {
    let mut stdin = stdin.lock().await;
    stdin.write_all(line.as_bytes()).await?;
    stdin.write_all(b"\n").await?;
    stdin.flush().await
}

/// A short, single-line summary of a tool result for the collapsed UI row.
fn tool_result_summary(text: &str) -> Option<String> {
    let first_line = text.lines().find(|line| !line.trim().is_empty())?.trim();
    if first_line.is_empty() {
        return None;
    }
    const LIMIT: usize = 160;
    if first_line.chars().count() > LIMIT {
        Some(format!(
            "{}…",
            first_line.chars().take(LIMIT).collect::<String>()
        ))
    } else {
        Some(first_line.to_string())
    }
}

/// Parses the `todos` array from a `todo_write` tool call's input into typed
/// items. The harness sends `{"todos":[{"content":string,"status":string}]}`
/// with replace-the-whole-list semantics and no ids, so a stable id is derived
/// from the item's index. Unknown/missing statuses default to `Pending`.
fn parse_todo_items(input: Option<&serde_json::Value>) -> Vec<SessionTodoDto> {
    input
        .and_then(|value| value.get("todos"))
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .enumerate()
                .map(|(index, item)| {
                    let content = item
                        .get("content")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    let status = match item.get("status").and_then(serde_json::Value::as_str) {
                        Some("in_progress") => SessionTodoStatusDto::InProgress,
                        Some("completed") => SessionTodoStatusDto::Completed,
                        Some("cancelled") => SessionTodoStatusDto::Cancelled,
                        _ => SessionTodoStatusDto::Pending,
                    };
                    SessionTodoDto {
                        id: format!("todo-{index:04}"),
                        content,
                        status,
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Maps a `tool_call` event's name + input JSON to a typed UI detail. Known
/// built-ins get rich rows; everything else (incl. MCP tools) falls back to
/// `Unknown`, which renders the tool name.
fn tool_call_detail(name: &str, input: Option<&serde_json::Value>) -> ToolCallDetailDto {
    let str_field = |key: &str| -> Option<String> {
        input
            .and_then(|value| value.get(key))
            .and_then(serde_json::Value::as_str)
            .map(str::to_string)
    };
    match name {
        "bash" => ToolCallDetailDto::Shell {
            command: str_field("command").unwrap_or_default(),
            cwd: None,
            description: None,
        },
        "read_file" => ToolCallDetailDto::FileRead {
            path: str_field("path").unwrap_or_default(),
            start_line: None,
            end_line: None,
        },
        "write_file" => ToolCallDetailDto::FileUpdate {
            path: str_field("path").unwrap_or_default(),
            operation: FileOperationDto::Overwrite,
        },
        "edit_file" => ToolCallDetailDto::FileUpdate {
            path: str_field("path").unwrap_or_default(),
            operation: FileOperationDto::Replace,
        },
        "subagent" => ToolCallDetailDto::Task {
            agent_id: str_field("agent").unwrap_or_default(),
            label: str_field("description").unwrap_or_else(|| "subagent".to_string()),
        },
        // Todos render in the dedicated task-progress dock, not the activity
        // feed; the GUI hides these ops, but only when the detail kind matches.
        "todo_write" => ToolCallDetailDto::TodoWrite {
            count: input
                .and_then(|value| value.get("todos"))
                .and_then(serde_json::Value::as_array)
                .map(Vec::len)
                .unwrap_or(0),
        },
        "todo_read" => ToolCallDetailDto::TodoRead,
        "workflow" => ToolCallDetailDto::Task {
            agent_id: String::new(),
            label: "workflow".to_string(),
        },
        // Surface codedb's query like a command chip (e.g. "codedb search foo")
        // instead of a bare "Ran codedb", mirroring how bash renders.
        "codedb" => ToolCallDetailDto::Shell {
            command: format!("codedb {}", str_field("command").unwrap_or_default())
                .trim()
                .to_string(),
            cwd: None,
            description: None,
        },
        other => ToolCallDetailDto::Unknown {
            name: other.to_string(),
        },
    }
}

/// Builds the interactive followup from an `ask_user` tool call's input. A
/// non-empty `options` array makes it a single-choice prompt; otherwise it's a
/// free-text prompt.
fn build_followup_request(
    conversation_id: &str,
    request_id: &str,
    workspace_path: &str,
    input: Option<&serde_json::Value>,
    followup_id: Option<String>,
) -> FollowupRequestDto {
    let question = input
        .and_then(|value| value.get("question"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    let options = input
        .and_then(|value| value.get("options"))
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(serde_json::Value::as_str)
                .enumerate()
                .map(|(index, label)| FollowupOptionDto {
                    id: format!("option-{index}"),
                    label: label.to_string(),
                })
                .collect::<Vec<_>>()
        })
        .filter(|options| !options.is_empty());
    let kind = if options.is_some() {
        FollowupKind::Single
    } else {
        FollowupKind::Text
    };
    FollowupRequestDto {
        followup_id: followup_id.unwrap_or_else(|| Uuid::new_v4().to_string()),
        workspace_path: workspace_path.to_string(),
        conversation_id: conversation_id.to_string(),
        request_id: request_id.to_string(),
        kind,
        question,
        options,
    }
}

/// The single line written to graff's stdin in reply to an `ask_user` prompt.
/// New binaries expect structured answer JSON, preserving multiline text via
/// JSON escaping. Legacy followups keep the pre-protocol plain answer line.
fn followup_answer_line(request: &FollowupRequestDto, response: &FollowupResponseDto) -> String {
    let answer = if response.cancelled {
        String::new()
    } else {
        match request.kind {
            FollowupKind::Text => response.text.clone().unwrap_or_default(),
            FollowupKind::Single | FollowupKind::Multi => {
                let selected = response.selected_option_ids.clone().unwrap_or_default();
                let options = request.options.clone().unwrap_or_default();
                selected
                    .iter()
                    .filter_map(|id| {
                        options
                            .iter()
                            .find(|option| &option.id == id)
                            .map(|option| option.label.clone())
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        }
    };
    if request.followup_id.starts_with("legacy-") {
        return answer.replace(['\n', '\r'], " ");
    }
    serde_json::json!({
        "type": "answer",
        "text": answer,
        "cancelled": response.cancelled,
        "call_id": request.followup_id,
    })
    .to_string()
}

/// Resolves the `graff` binary to an ABSOLUTE path. Sessions spawn with a child
/// `current_dir` set to the workspace, and a relative program path would be
/// resolved against that workspace (not the repo) — so a relative override like
/// `CODEGRAFF_GUI_BINARY=../zig-out/bin/graff` must be canonicalized here.
fn codegraff_binary() -> String {
    // 1. Explicit override, canonicalized to absolute when it resolves to a file.
    if let Some(value) = std::env::var("CODEGRAFF_GUI_BINARY")
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        if let Ok(absolute) = std::fs::canonicalize(&value) {
            return absolute.to_string_lossy().into_owned();
        }
        // Doesn't resolve from the current dir — fall through to the built-in.
    }
    // 2. Bundled sidecar: Tauri's externalBin lands next to the app executable
    //    (Contents/MacOS/graff on macOS), so a packaged .app is self-contained —
    //    no separate CLI install needed. This is what fixes GUI-only users.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join("graff");
            if p.is_file() {
                return p.to_string_lossy().into_owned();
            }
        }
    }
    // 3. Dev build: <crate>/../../zig-out/bin/graff (only exists on a dev machine).
    let candidate = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/graff");
    if let Ok(absolute) = std::fs::canonicalize(&candidate) {
        return absolute.to_string_lossy().into_owned();
    }
    // 4. Known install locations. A Finder/Dock-launched .app inherits launchd's
    //    minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which excludes ~/bin,
    //    /usr/local/bin and /opt/homebrew/bin — exactly where the CLI installer
    //    puts `graff`. So a bare PATH lookup (step 5) misses an installed binary
    //    and the session spawn fails with ENOENT. Probe the standard spots by
    //    absolute path first.
    if let Ok(home) = std::env::var("HOME") {
        for rel in ["bin/graff", ".local/bin/graff"] {
            let p = Path::new(&home).join(rel);
            if p.is_file() {
                return p.to_string_lossy().into_owned();
            }
        }
    }
    for abs in [
        "/opt/homebrew/bin/graff",
        "/usr/local/bin/graff",
        "/usr/bin/graff",
    ] {
        if Path::new(abs).is_file() {
            return abs.to_string();
        }
    }
    // 5. Last resort: bare name, resolved against whatever PATH we inherited.
    "graff".into()
}

#[derive(Debug, Clone)]
struct CodegraffProvider {
    id: String,
    name: String,
    env_key: Option<String>,
    auth_method: ProviderAuthMethodKindDto,
}

/// Static fallback list, used only when `graff --schema` can't be read (e.g.
/// the binary is missing or too old). The live list comes from the harness —
/// see `schema_providers`.
fn fallback_providers() -> Vec<CodegraffProvider> {
    use ProviderAuthMethodKindDto::*;
    fn p(
        id: &str,
        name: &str,
        env: Option<&str>,
        auth: ProviderAuthMethodKindDto,
    ) -> CodegraffProvider {
        CodegraffProvider {
            id: id.into(),
            name: name.into(),
            env_key: env.map(Into::into),
            auth_method: auth,
        }
    }
    vec![
        p(
            "codegraff",
            "Codegraff",
            Some("CODEGRAFF_API_KEY"),
            CodegraffDevice,
        ),
        p("anthropic", "Anthropic", Some("ANTHROPIC_API_KEY"), ApiKey),
        p("deepseek", "DeepSeek", Some("DEEPSEEK_API_KEY"), ApiKey),
        p("openai", "OpenAI", Some("OPENAI_API_KEY"), ApiKey),
        p("minimax", "MiniMax", Some("MINIMAX_API_KEY"), ApiKey),
        p("xiaomi", "Xiaomi", Some("XIAOMI_API_KEY"), ApiKey),
        p("kimi", "Kimi", Some("KIMI_API_KEY"), ApiKey),
        p("xai", "xAI", Some("XAI_API_KEY"), ApiKey),
        p("zai", "Z.AI", Some("ZAI_API_KEY"), ApiKey),
        p("codex", "Codex / ChatGPT", None, CodexDevice),
    ]
}

/// The provider list the settings page renders, derived live from the harness's
/// `graff --schema` so adding a provider in the Zig binary makes it appear here
/// automatically — names, env vars, and login method all come from the harness.
/// codegraff (primary login) is pinned first and codex last; otherwise harness
/// order is preserved. Falls back to `fallback_providers` if the schema can't
/// be read.
async fn schema_providers() -> Vec<CodegraffProvider> {
    let output = match tokio::process::Command::new(codegraff_binary())
        .arg("--schema")
        .output()
        .await
    {
        Ok(output) if output.status.success() => output,
        _ => return fallback_providers(),
    };
    let Ok(schema) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
        return fallback_providers();
    };
    let Some(entries) = schema.get("providers").and_then(|value| value.as_array()) else {
        return fallback_providers();
    };
    let mut providers: Vec<CodegraffProvider> = entries
        .iter()
        .filter_map(|entry| {
            let id = entry.get("id")?.as_str()?.to_string();
            let name = entry
                .get("name")
                .and_then(|value| value.as_str())
                .unwrap_or(&id)
                .to_string();
            let auth_method = match entry.get("login").and_then(|value| value.as_str()) {
                Some("codegraff_device") => ProviderAuthMethodKindDto::CodegraffDevice,
                Some("codex_device") => ProviderAuthMethodKindDto::CodexDevice,
                _ => ProviderAuthMethodKindDto::ApiKey,
            };
            // Only api-key providers surface an env var; login providers carry a
            // placeholder env_key in the schema that the UI must not show.
            let env_key = if matches!(auth_method, ProviderAuthMethodKindDto::ApiKey) {
                entry
                    .get("env_key")
                    .and_then(|value| value.as_str())
                    .filter(|value| !value.is_empty())
                    .map(|value| value.to_string())
            } else {
                None
            };
            Some(CodegraffProvider {
                id,
                name,
                env_key,
                auth_method,
            })
        })
        .collect();
    if providers.is_empty() {
        return fallback_providers();
    }
    providers.sort_by_key(|provider| match provider.id.as_str() {
        "codegraff" => 0u8,
        "codex" => 2,
        _ => 1,
    });
    providers
}

async fn list_codegraff_providers() -> Result<Vec<ProviderSummaryDto>> {
    let key_list = codegraff_key_list().await.unwrap_or_default();
    Ok(schema_providers()
        .await
        .iter()
        .map(|provider| provider_summary_with_key_list(provider, &key_list))
        .collect())
}

async fn configured_provider_ids() -> HashSet<String> {
    let key_list = codegraff_key_list().await.unwrap_or_default();
    configured_provider_ids_from_providers(&schema_providers().await, &key_list)
}

fn configured_provider_ids_from_providers(
    providers: &[CodegraffProvider],
    key_list: &str,
) -> HashSet<String> {
    providers
        .iter()
        .filter(|provider| provider_configured(provider, key_list))
        .map(|provider| provider.id.clone())
        .collect()
}

async fn provider_summary(provider_id: &str) -> Result<ProviderSummaryDto> {
    let key_list = codegraff_key_list().await.unwrap_or_default();
    let providers = schema_providers().await;
    let provider = providers
        .iter()
        .find(|provider| provider.id == provider_id)
        .with_context(|| format!("Unknown provider {provider_id}"))?;
    Ok(provider_summary_with_key_list(provider, &key_list))
}

fn provider_summary_with_key_list(
    provider: &CodegraffProvider,
    key_list: &str,
) -> ProviderSummaryDto {
    let mut auth_methods = vec![ProviderAuthMethodDto {
        kind: provider.auth_method.clone(),
        label: provider_auth_label(provider),
    }];
    // Kimi accepts both an API key and a device-code OAuth login (`graff login
    // kimi`). Offer both so users can re-auth via the CLI's OAuth flow when
    // their key is removed or expires — mirroring codegraff/codex.
    if provider.id == "kimi" {
        auth_methods.push(ProviderAuthMethodDto {
            kind: ProviderAuthMethodKindDto::KimiDevice,
            label: "Kimi Code device login".into(),
        });
    }
    ProviderSummaryDto {
        id: provider.id.clone(),
        name: provider.name.clone(),
        configured: provider_configured(provider, key_list),
        auth_methods,
        env_override: provider_env_override(provider),
    }
}

fn validate_provider_auth_completion(
    summary: &ProviderSummaryDto,
    submitted_api_key: bool,
) -> Result<()> {
    if submitted_api_key || summary.configured {
        return Ok(());
    }

    anyhow::bail!(
        "Provider login not detected yet. Complete the login flow in Terminal, then try Finish setup again."
    )
}

/// Builds the env-override hint when a provider's `<PROVIDER>_API_KEY` is set,
/// locating where it's defined so the UI can offer to open that file.
fn provider_env_override(provider: &CodegraffProvider) -> Option<ProviderEnvOverrideDto> {
    let env_key = provider.env_key.as_deref()?;
    let is_set = std::env::var(env_key)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .is_some();
    if !is_set {
        return None;
    }
    let (file_path, line) = match find_env_definition(env_key) {
        Some((path, line)) => (Some(path), Some(line)),
        None => (None, None),
    };
    Some(ProviderEnvOverrideDto {
        env_key: env_key.to_string(),
        file_path,
        line,
    })
}

/// Scans the user's shell startup files for where `env_key` is exported,
/// returning the file path and 1-based line number of the first definition.
fn find_env_definition(env_key: &str) -> Option<(String, u32)> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let candidates = [
        ".zshenv",
        ".zprofile",
        ".zshrc",
        ".profile",
        ".bashrc",
        ".bash_profile",
        ".config/fish/config.fish",
    ];
    for relative in candidates {
        let path = home.join(relative);
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for (index, raw_line) in text.lines().enumerate() {
            let line = raw_line.trim_start();
            if line.starts_with('#') {
                continue;
            }
            let defines = line.contains(&format!("{env_key}="))
                || line.contains(&format!("set -x {env_key} "))
                || line.contains(&format!("set -gx {env_key} "));
            if defines {
                return Some((path.to_string_lossy().into_owned(), (index + 1) as u32));
            }
        }
    }
    None
}

fn provider_auth_label(provider: &CodegraffProvider) -> String {
    match provider.auth_method {
        ProviderAuthMethodKindDto::ApiKey => provider
            .env_key
            .as_deref()
            .map(|env_key| format!("API key ({env_key} or graff key set {})", provider.id))
            .unwrap_or_else(|| "API key".into()),
        ProviderAuthMethodKindDto::CodegraffDevice => "Codegraff device login".into(),
        ProviderAuthMethodKindDto::CodexDevice => "Codex browser login".into(),
        ProviderAuthMethodKindDto::KimiDevice => "Kimi Code device login".into(),
        _ => "Unsupported".into(),
    }
}

fn provider_configured(provider: &CodegraffProvider, key_list: &str) -> bool {
    if provider
        .env_key
        .as_deref()
        .and_then(|env_key| std::env::var(env_key).ok())
        .filter(|value| !value.trim().is_empty())
        .is_some()
    {
        return true;
    }

    let home = std::env::var_os("HOME").map(PathBuf::from);
    provider_login_configured(provider, key_list, home.as_deref())
}

fn provider_login_configured(
    provider: &CodegraffProvider,
    key_list: &str,
    home: Option<&Path>,
) -> bool {
    match provider.id.as_str() {
        "codegraff" => {
            home_file_exists(home, ".simple-harness-codegraff.json")
                || key_list_mentions_provider(key_list, &provider.id)
        }
        "codex" => home_codex_auth_has_valid_token(home),
        "kimi" => {
            key_list_mentions_provider(key_list, &provider.id) || kimi_auth_has_valid_token(home)
        }
        _ => key_list_mentions_provider(key_list, &provider.id),
    }
}

fn key_list_mentions_provider(key_list: &str, provider_id: &str) -> bool {
    // `graff key list` lists every provider; a provider only counts as keyed
    // when its row's trailing "stored" column isn't the "—" placeholder.
    key_list.lines().any(|line| {
        let mut parts = line.split_whitespace();
        parts.next() == Some(provider_id)
            && parts
                .last()
                .map_or(false, |stored| stored != "—" && stored != "-")
    })
}

fn home_file_exists(home: Option<&Path>, relative_path: &str) -> bool {
    home.map(|home| home.join(relative_path).exists())
        .unwrap_or(false)
}

fn home_codex_auth_has_valid_token(home: Option<&Path>) -> bool {
    home.map(|home| codex_auth_file_has_valid_token(&home.join(".codex/auth.json")))
        .unwrap_or(false)
}

/// Kimi OAuth login (`graff login kimi`) writes a JSON token file to
/// `~/.kimi/credentials/graff-oauth.json`. The CLI auto-refreshes the
/// access token when near expiry, so a non-empty access_token means logged in.
fn kimi_auth_has_valid_token(home: Option<&Path>) -> bool {
    home.map(|home| {
        let path = home.join(".kimi/credentials/graff-oauth.json");
        let Ok(text) = std::fs::read_to_string(&path) else {
            return false;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            return false;
        };
        value
            .get("access_token")
            .and_then(|token| token.as_str())
            .map(|token| !token.trim().is_empty())
            .unwrap_or(false)
    })
    .unwrap_or(false)
}

fn codex_auth_file_has_valid_token(path: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    codex_auth_text_has_valid_token(&text)
}

fn codex_auth_text_has_valid_token(text: &str) -> bool {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return false;
    };
    value
        .get("tokens")
        .and_then(|tokens| tokens.get("access_token"))
        .or_else(|| value.get("access_token"))
        .and_then(|token| token.as_str())
        .map(|token| !token.trim().is_empty())
        .unwrap_or(false)
}

fn provider_env_key(provider_id: &str) -> Option<String> {
    fallback_providers()
        .into_iter()
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
        kind: ProviderAuthSessionKindDto::CliLogin,
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

/// Deletes a provider's stored credential everywhere the CLI persists it:
/// macOS Keychain (service `simple-harness`, account=provider), the
/// `~/.simple-harness-keys.json` fallback, and the codegraff/codex login files.
/// Missing entries are not an error (removal is idempotent).
fn remove_stored_credential(provider_id: &str) -> Result<()> {
    let home = std::env::var_os("HOME").map(PathBuf::from);

    // macOS Keychain entry written by `graff key set`.
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("security")
            .args([
                "delete-generic-password",
                "-s",
                "simple-harness",
                "-a",
                provider_id,
            ])
            .output();
    }

    // The 0600 JSON fallback store (used off macOS; cleaned everywhere to be safe).
    if let Some(home) = &home {
        let path = home.join(".simple-harness-keys.json");
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(mut value) = serde_json::from_str::<serde_json::Value>(&text) {
                let removed = value
                    .as_object_mut()
                    .map(|object| object.remove(provider_id).is_some())
                    .unwrap_or(false);
                if removed {
                    let text =
                        serde_json::to_string(&value).context("Failed to serialize key store")?;
                    std::fs::write(&path, text).context("Failed to update key store")?;
                }
            }
        }
    }

    // Provider-specific login files.
    if let Some(home) = &home {
        match provider_id {
            "codegraff" => {
                let _ = std::fs::remove_file(home.join(".simple-harness-codegraff.json"));
            }
            "codex" => {
                let _ = std::fs::remove_file(home.join(".codex/auth.json"));
            }
            "kimi" => {
                let _ = std::fs::remove_file(home.join(".kimi/credentials/graff-oauth.json"));
            }
            _ => {}
        }
    }

    Ok(())
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
        // `open -a Terminal <bin> --args login` passes the args to Terminal.app,
        // not to graff, and opens the binary as a document (a bare REPL). Instead
        // write a tiny executable launcher and open it with Terminal: Terminal
        // runs an executable `.command` file, so the full `graff login [codex]`
        // command line reaches graff — and unlike AppleScript `do script`, this
        // needs no Apple Events / Automation permission.
        let mut command_line = shell_single_quote(&binary);
        command_line.push_str(" login");
        if let Some(target) = login_target {
            command_line.push(' ');
            command_line.push_str(&shell_single_quote(target));
        }
        let script_path =
            std::env::temp_dir().join(format!("graff-login-{}.command", Uuid::new_v4().simple()));
        let script = format!("#!/bin/sh\n{command_line}\nrm -f \"$0\"\n");
        std::fs::write(&script_path, script)
            .context("Failed to write graff login launcher script")?;
        std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o700))
            .context("Failed to mark graff login launcher executable")?;
        tokio::process::Command::new("open")
            .args(["-a", "Terminal"])
            .arg(&script_path)
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

/// Wraps `value` in single quotes for a POSIX shell, escaping embedded quotes.
#[cfg(target_os = "macos")]
fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Normalizes a model-generated title: first line, stripped of quotes/punctuation,
/// capped to a handful of words.
fn clean_title(raw: &str) -> String {
    let first = raw.trim().lines().next().unwrap_or("").trim();
    let trimmed = first
        .trim_matches(|c: char| c == '"' || c == '\'' || c == '.' || c == ':' || c.is_whitespace());
    trimmed
        .split_whitespace()
        .take(8)
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(60)
        .collect()
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
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

fn is_placeholder_title(title: &str) -> bool {
    let title = title.trim();
    title.is_empty() || title.eq_ignore_ascii_case("New chat")
}

fn run_shell_command(workspace_path: &str, shell_command: &str) -> Result<String> {
    let output = Command::new("/bin/sh")
        .args(["-c", shell_command])
        .current_dir(workspace_path)
        .output()
        .with_context(|| format!("Failed to run shell command in {workspace_path}"))?;
    Ok(format_command_output(&output))
}

fn format_command_output(output: &std::process::Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut text = String::new();
    if !stdout.is_empty() {
        text.push_str(&stdout);
    }
    if !stderr.is_empty() {
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str("[stderr]\n");
        text.push_str(&stderr);
    }
    match output.status.code() {
        Some(0) => {}
        Some(code) => {
            if !text.is_empty() && !text.ends_with('\n') {
                text.push('\n');
            }
            text.push_str(&format!("[exit code {code}]"));
        }
        None => {
            if !text.is_empty() && !text.ends_with('\n') {
                text.push('\n');
            }
            text.push_str("[terminated abnormally]");
        }
    }
    if text.is_empty() {
        "(no output)".into()
    } else {
        text
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn mk_output(stdout: &[u8], stderr: &[u8], raw_status: i32) -> std::process::Output {
        use std::os::unix::process::ExitStatusExt;
        std::process::Output {
            status: std::process::ExitStatus::from_raw(raw_status),
            stdout: stdout.to_vec(),
            stderr: stderr.to_vec(),
        }
    }

    #[test]
    #[cfg(unix)]
    fn format_command_output_empty_is_no_output() {
        // stdout+stderr empty, exit 0 -> the "(no output)" placeholder.
        assert_eq!(
            format_command_output(&mk_output(b"", b"", 0)),
            "(no output)"
        );
    }

    #[test]
    #[cfg(unix)]
    fn format_command_output_stdout_only_unchanged() {
        assert_eq!(
            format_command_output(&mk_output(b"hello\n", b"", 0)),
            "hello\n"
        );
    }

    #[test]
    #[cfg(unix)]
    fn format_command_output_stderr_only_gets_label() {
        // No stdout, so no leading newline; "[stderr]" label prefixes stderr.
        assert_eq!(
            format_command_output(&mk_output(b"", b"oops\n", 0)),
            "[stderr]\noops\n"
        );
    }

    #[test]
    #[cfg(unix)]
    fn format_command_output_stderr_separator_and_nonzero_exit() {
        // stdout present -> "[stderr]" goes on its own line after a separator.
        let out = format_command_output(&mk_output(b"out\n", b"err\n", 1 << 8));
        assert!(out.contains("out\n[stderr]\nerr\n"));
        assert!(out.ends_with("[exit code 1]"));
    }

    #[test]
    #[cfg(unix)]
    fn format_command_output_signal_terminated_is_abnormal() {
        // raw status 2 -> WIFSIGNALED -> status.code() is None.
        assert!(format_command_output(&mk_output(b"", b"", 2)).contains("[terminated abnormally]"));
    }

    fn followup(
        id: &str,
        kind: FollowupKind,
        options: Option<Vec<FollowupOptionDto>>,
    ) -> FollowupRequestDto {
        FollowupRequestDto {
            followup_id: id.to_string(),
            workspace_path: "/tmp/work".to_string(),
            conversation_id: "chat-1".to_string(),
            request_id: "request-1".to_string(),
            kind,
            question: "Continue?".to_string(),
            options,
        }
    }

    #[test]
    fn structured_followup_answer_preserves_multiline_text() {
        let request = followup("call-1", FollowupKind::Text, None);
        let response = FollowupResponseDto {
            followup_id: "call-1".to_string(),
            cancelled: false,
            text: Some("line 1\nline 2".to_string()),
            selected_option_ids: None,
        };
        let line = followup_answer_line(&request, &response);
        let json: serde_json::Value = serde_json::from_str(&line).expect("answer JSON");
        assert_eq!(json["type"], "answer");
        assert_eq!(json["text"], "line 1\nline 2");
        assert_eq!(json["cancelled"], false);
        assert_eq!(json["call_id"], "call-1");
    }

    #[test]
    fn structured_followup_answer_serializes_cancel() {
        let request = followup("call-2", FollowupKind::Text, None);
        let response = FollowupResponseDto {
            followup_id: "call-2".to_string(),
            cancelled: true,
            text: Some("ignored".to_string()),
            selected_option_ids: None,
        };
        let line = followup_answer_line(&request, &response);
        let json: serde_json::Value = serde_json::from_str(&line).expect("answer JSON");
        assert_eq!(json["type"], "answer");
        assert_eq!(json["text"], "");
        assert_eq!(json["cancelled"], true);
        assert_eq!(json["call_id"], "call-2");
    }

    #[test]
    fn legacy_followup_answer_flattens_choice_labels() {
        let request = followup(
            "legacy-1",
            FollowupKind::Single,
            Some(vec![FollowupOptionDto {
                id: "option-0".to_string(),
                label: "yes\nplease".to_string(),
            }]),
        );
        let response = FollowupResponseDto {
            followup_id: "legacy-1".to_string(),
            cancelled: false,
            text: None,
            selected_option_ids: Some(vec!["option-0".to_string()]),
        };
        assert_eq!(followup_answer_line(&request, &response), "yes please");
    }

    #[test]
    fn placeholder_title_detection_accepts_empty_and_new_chat() {
        assert!(is_placeholder_title(""));
        assert!(is_placeholder_title("  New chat  "));
        assert!(is_placeholder_title("new CHAT"));
        assert!(!is_placeholder_title("Investigate stale sidebar state"));
    }

    #[test]
    fn recover_conversation_title_uses_first_user_message() {
        let messages = vec![
            SessionMessageDto::Assistant {
                id: "assistant-1".into(),
                request_id: "request-1".into(),
                text: "Hello".into(),
            },
            SessionMessageDto::User {
                id: "user-1".into(),
                request_id: "request-1".into(),
                text: "Fix the new chat title regression with deterministic fallback".into(),
            },
        ];

        assert_eq!(
            recover_conversation_title("New chat", &messages),
            "Fix the new chat title regression with deterministic"
        );
        assert_eq!(
            recover_conversation_title("Custom title", &messages),
            "Custom title"
        );
    }

    #[test]
    fn selected_workspace_conversation_ignores_stale_ids() {
        let mut state = RuntimeState::default();
        state.conversations.insert(
            "chat-1".into(),
            ConversationState {
                workspace_path: "/tmp/work".into(),
                conversation_id: "chat-1".into(),
                title: "Existing".into(),
                messages: vec![],
                active_request_ids: vec![],
                request_agent_ids: HashMap::new(),
                queued_prompts: VecDeque::new(),
                active_agent_id: None,
                plan_mode: false,
                ultracode_enabled: false,
                todos: Vec::new(),
                goal: None,
                updated_at: 10,
            },
        );
        state
            .selected_by_workspace
            .insert("/tmp/work".into(), "missing".into());

        assert_eq!(
            selected_workspace_conversation_id(&state, "/tmp/work"),
            None
        );

        state
            .selected_by_workspace
            .insert("/tmp/work".into(), "chat-1".into());
        assert_eq!(
            selected_workspace_conversation_id(&state, "/tmp/work"),
            Some("chat-1".into())
        );
    }

    #[test]
    fn provider_configured_detects_codegraff_login_file() {
        let temp_dir = std::env::temp_dir().join(format!(
            "codegraff-provider-test-{}",
            Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir");
        std::fs::write(temp_dir.join(".simple-harness-codegraff.json"), "{}")
            .expect("write login file");

        let configured = provider_login_configured(
            &CodegraffProvider {
                id: "codegraff".into(),
                name: "Codegraff".into(),
                env_key: None,
                auth_method: ProviderAuthMethodKindDto::CodegraffDevice,
            },
            "",
            Some(&temp_dir),
        );
        let _ = std::fs::remove_dir_all(temp_dir);

        assert!(configured);
    }

    #[test]
    fn codex_auth_text_requires_nonempty_access_token() {
        assert!(codex_auth_text_has_valid_token(
            r#"{"tokens":{"access_token":"token"}}"#
        ));
        assert!(codex_auth_text_has_valid_token(
            r#"{"access_token":"legacy-token"}"#
        ));
        assert!(!codex_auth_text_has_valid_token(
            r#"{"tokens":{"access_token":" "}}"#
        ));
        assert!(!codex_auth_text_has_valid_token("{}"));
        assert!(!codex_auth_text_has_valid_token("not json"));
    }

    #[test]
    fn provider_configured_detects_codex_auth_file_token() {
        let temp_dir =
            std::env::temp_dir().join(format!("codex-provider-test-{}", Uuid::new_v4().simple()));
        let codex_dir = temp_dir.join(".codex");
        std::fs::create_dir_all(&codex_dir).expect("create codex dir");
        std::fs::write(
            codex_dir.join("auth.json"),
            r#"{"tokens":{"access_token":"token"}}"#,
        )
        .expect("write codex auth file");

        let configured = provider_login_configured(
            &CodegraffProvider {
                id: "codex".into(),
                name: "Codex / ChatGPT".into(),
                env_key: None,
                auth_method: ProviderAuthMethodKindDto::CodexDevice,
            },
            "",
            Some(&temp_dir),
        );
        let _ = std::fs::remove_dir_all(temp_dir);

        assert!(configured);
    }

    fn provider_summary_for_test(configured: bool) -> ProviderSummaryDto {
        ProviderSummaryDto {
            id: "codegraff".into(),
            name: "Codegraff".into(),
            configured,
            auth_methods: vec![ProviderAuthMethodDto {
                kind: ProviderAuthMethodKindDto::CodegraffDevice,
                label: "Codegraff device login".into(),
            }],
            env_override: None,
        }
    }

    #[test]
    fn provider_completion_rejects_unfinished_cli_login() {
        let error = validate_provider_auth_completion(&provider_summary_for_test(false), false)
            .expect_err("unfinished login should be rejected");

        assert!(
            error
                .to_string()
                .contains("Provider login not detected yet")
        );
    }

    #[test]
    fn provider_completion_accepts_configured_cli_login() {
        validate_provider_auth_completion(&provider_summary_for_test(true), false)
            .expect("configured login should complete");
    }

    #[test]
    fn provider_completion_allows_api_key_completion_to_report_summary() {
        validate_provider_auth_completion(&provider_summary_for_test(false), true)
            .expect("api-key completion is validated by graff key set");
    }

    fn model(provider: &str, name: &str) -> ModelOption {
        ModelOption {
            provider: provider.into(),
            provider_name: None,
            name: name.into(),
            context: None,
            is_default: provider == "codegraff" && name == "deepseek-v4-pro",
        }
    }

    fn provider_ids(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_string()).collect()
    }

    #[test]
    fn prompt_model_arg_includes_provider_to_disambiguate_duplicate_names() {
        assert_eq!(prompt_model_arg("codex", "gpt-5.5"), "codex gpt-5.5");
        assert_eq!(
            prompt_model_arg("codegraff", "gpt-5.5"),
            "codegraff gpt-5.5"
        );
    }

    #[test]
    fn prompt_settings_returns_no_models_without_configured_providers() {
        let settings = build_prompt_settings_from_catalog(
            &[
                model("codegraff", "deepseek-v4-pro"),
                model("codex", "gpt-5.5"),
            ],
            &HashSet::new(),
            None,
            None,
            Some("high".into()),
            true,
        );

        assert!(settings.available_models.is_empty());
        assert_eq!(settings.selected_provider_id, None);
        assert_eq!(settings.selected_model_id, None);
        assert_eq!(settings.selected_reasoning_effort, None);
        assert!(settings.fast_enabled);
    }

    #[test]
    fn prompt_settings_filters_models_to_configured_providers() {
        let settings = build_prompt_settings_from_catalog(
            &[
                model("codegraff", "deepseek-v4-pro"),
                model("codex", "gpt-5.5"),
                model("openai", "gpt-4.1"),
            ],
            &provider_ids(&["codex"]),
            None,
            None,
            None,
            false,
        );

        assert_eq!(settings.available_models.len(), 1);
        assert_eq!(settings.available_models[0].provider_id, "codex");
        assert_eq!(settings.available_models[0].model_id, "gpt-5.5");
        assert_eq!(settings.selected_provider_id.as_deref(), Some("codex"));
        assert_eq!(settings.selected_model_id.as_deref(), Some("gpt-5.5"));
    }

    #[test]
    fn prompt_settings_ignores_persisted_unconfigured_model() {
        let settings = build_prompt_settings_from_catalog(
            &[
                model("codegraff", "deepseek-v4-pro"),
                model("codex", "gpt-5.5"),
            ],
            &provider_ids(&["codegraff"]),
            Some("codex"),
            Some("gpt-5.5"),
            Some("medium".into()),
            false,
        );

        assert_eq!(settings.available_models.len(), 1);
        assert_eq!(settings.selected_provider_id.as_deref(), Some("codegraff"));
        assert_eq!(
            settings.selected_model_id.as_deref(),
            Some("deepseek-v4-pro")
        );
        assert_eq!(settings.selected_reasoning_effort, None);
    }

    #[test]
    fn selected_prompt_model_pair_falls_back_from_unavailable_codex_model() {
        let pair = selected_prompt_model_pair(
            &[
                model("codegraff", "deepseek-v4-pro"),
                model("codex", "gpt-5.5"),
            ],
            &provider_ids(&["codegraff", "codex"]),
            Some("codex"),
            Some("gpt-5.5-codex"),
        );

        assert_eq!(pair, Some(("codegraff".into(), "deepseek-v4-pro".into())));
    }

    #[test]
    fn prompt_settings_schema_fallback_requires_configured_codegraff() {
        let unavailable =
            build_prompt_settings_from_catalog(&[], &HashSet::new(), None, None, None, false);
        assert!(unavailable.available_models.is_empty());

        let available = build_prompt_settings_from_catalog(
            &[],
            &provider_ids(&["codegraff"]),
            None,
            None,
            None,
            true,
        );
        assert_eq!(available.available_models.len(), 1);
        assert_eq!(available.selected_provider_id.as_deref(), Some("codegraff"));
        assert_eq!(available.selected_model_id.as_deref(), Some("default"));
        assert!(available.fast_enabled);
    }

    #[test]
    fn normalize_runtime_selection_falls_back_to_existing_conversation() {
        let mut state = RuntimeState {
            active_workspace_path: Some("/tmp/work".into()),
            active_conversation_id: Some("missing".into()),
            ..RuntimeState::default()
        };
        state.conversations.insert(
            "chat-old".into(),
            ConversationState {
                workspace_path: "/tmp/work".into(),
                conversation_id: "chat-old".into(),
                title: "Old".into(),
                messages: vec![],
                active_request_ids: vec![],
                request_agent_ids: HashMap::new(),
                queued_prompts: VecDeque::new(),
                active_agent_id: None,
                plan_mode: false,
                ultracode_enabled: false,
                todos: Vec::new(),
                goal: None,
                updated_at: 10,
            },
        );
        state.conversations.insert(
            "chat-new".into(),
            ConversationState {
                workspace_path: "/tmp/work".into(),
                conversation_id: "chat-new".into(),
                title: "New".into(),
                messages: vec![],
                active_request_ids: vec![],
                request_agent_ids: HashMap::new(),
                queued_prompts: VecDeque::new(),
                active_agent_id: None,
                plan_mode: false,
                ultracode_enabled: false,
                todos: Vec::new(),
                goal: None,
                updated_at: 20,
            },
        );
        state
            .selected_by_workspace
            .insert("/tmp/work".into(), "missing".into());

        normalize_runtime_selection(&mut state);

        assert_eq!(state.active_conversation_id, Some("chat-new".into()));
        assert_eq!(state.selected_by_workspace.get("/tmp/work"), None);
    }
}
