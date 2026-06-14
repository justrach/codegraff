use std::path::{Path, PathBuf};

use anyhow::Context;
use forge_api::API;

use crate::persistence::project_store::RegisteredWorkspaceKind;

use super::{
    ForgeRuntime, PersistedConversationSummary, RuntimeManager, RuntimeState, WorkspaceKind,
    WorkspaceSessionState, configuration_error_message, fallback_workspace_state,
    format_error_chain, read_config, resolved_workspace_display_name,
};

impl RuntimeManager {
    pub(super) async fn ensure_known_workspaces_loaded(&self) -> anyhow::Result<()> {
        let registered_workspaces = self.projects.list_workspaces()?;
        let workspace_keys = registered_workspaces
            .iter()
            .map(|workspace| workspace.path.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        let missing = {
            let mut state = self.state.lock().await;
            state.workspace_order = workspace_keys.clone();
            registered_workspaces
                .into_iter()
                .filter(|workspace| {
                    !state
                        .workspaces
                        .contains_key(workspace.path.to_string_lossy().as_ref())
                })
                .collect::<Vec<_>>()
        };

        for workspace in missing {
            let workspace_path = workspace.path.to_string_lossy().into_owned();
            let workspace_kind = map_workspace_kind(workspace.kind);
            let workspace_state = self
                .load_workspace_state(
                    workspace.path.clone(),
                    workspace_kind,
                    workspace.display_name.clone(),
                    None,
                )
                .await
                .unwrap_or_else(|error| {
                    fallback_workspace_state(
                        &workspace.path,
                        workspace_kind,
                        workspace.display_name.as_deref(),
                        format_error_chain(&error),
                    )
                });

            let mut state = self.state.lock().await;
            state
                .workspaces
                .entry(workspace_path)
                .or_insert(workspace_state);
        }

        Ok(())
    }

    pub(super) async fn ensure_workspace_runtime(
        &self,
        workspace_path: &str,
    ) -> anyhow::Result<ForgeRuntime> {
        if let Some(runtime) = self
            .state
            .lock()
            .await
            .workspaces
            .get(workspace_path)
            .and_then(|workspace| workspace.runtime.clone())
        {
            return Ok(runtime);
        }

        let workspace_path_buf = PathBuf::from(workspace_path);
        let (config, configuration_error) = read_config();
        let runtime = self
            .factory
            .build_runtime(
                workspace_path_buf.clone(),
                config.clone(),
                configuration_error.clone(),
            )
            .await?;

        let configured = runtime.config.session.is_some();
        let configuration_error =
            configuration_error_message(configured, runtime.configuration_error.clone());
        let (workspace_kind, workspace_name) = self.resolve_workspace_identity(workspace_path)?;

        let mut state = self.state.lock().await;
        let workspace = sync_workspace_session_state(
            &mut state,
            workspace_path,
            workspace_kind,
            &workspace_name,
        );
        workspace.configured = configured;
        workspace.configuration_error = configuration_error;
        workspace.runtime = Some(runtime.clone());

        if !state
            .workspace_order
            .iter()
            .any(|item| item == workspace_path)
        {
            state.workspace_order.insert(0, workspace_path.to_string());
        }

        Ok(runtime)
    }

    pub(super) async fn refresh_workspace_conversations(
        &self,
        workspace_path: &str,
    ) -> anyhow::Result<()> {
        let runtime = self.ensure_workspace_runtime(workspace_path).await?;
        let conversations = runtime.api.get_conversations(None).await?;
        let persisted_conversations = conversations
            .iter()
            .map(PersistedConversationSummary::from_conversation)
            .collect::<Vec<_>>();
        let configured = runtime.config.session.is_some();
        let configuration_error =
            configuration_error_message(configured, runtime.configuration_error.clone());
        let (workspace_kind, workspace_name) = self.resolve_workspace_identity(workspace_path)?;

        let mut state = self.state.lock().await;
        let workspace = sync_workspace_session_state(
            &mut state,
            workspace_path,
            workspace_kind,
            &workspace_name,
        );
        workspace.configured = configured;
        workspace.configuration_error = configuration_error;
        workspace.persisted_conversations = persisted_conversations.clone();

        for persisted in persisted_conversations {
            if let Some(conversation) = state.conversations.get_mut(&persisted.conversation_id) {
                if conversation.title.is_none() {
                    conversation.title = Some(persisted.title.clone());
                }
                if conversation.updated_at.is_none() {
                    conversation.updated_at = persisted.updated_at.clone();
                }
                conversation.workspace_path = workspace_path.to_string();
            }
        }

        Ok(())
    }

    async fn load_workspace_state(
        &self,
        workspace_path: PathBuf,
        kind: WorkspaceKind,
        display_name: Option<String>,
        resident_runtime: Option<ForgeRuntime>,
    ) -> anyhow::Result<WorkspaceSessionState> {
        let runtime = if let Some(runtime) = resident_runtime.clone() {
            runtime
        } else {
            let (config, configuration_error) = read_config();
            self.factory
                .build_runtime(workspace_path.clone(), config, configuration_error)
                .await?
        };

        let configured = runtime.config.session.is_some();
        let configuration_error =
            configuration_error_message(configured, runtime.configuration_error.clone());
        let conversations = runtime.api.get_conversations(None).await?;

        Ok(WorkspaceSessionState {
            runtime: resident_runtime,
            kind,
            workspace_name: resolved_workspace_display_name(
                kind,
                &workspace_path,
                display_name.as_deref(),
            ),
            configured,
            configuration_error,
            selected_conversation_id: None,
            persisted_conversations: conversations
                .iter()
                .map(PersistedConversationSummary::from_conversation)
                .collect(),
        })
    }

    pub(super) fn resolve_workspace_registration(
        &self,
        workspace_path: &str,
    ) -> anyhow::Result<(WorkspaceKind, Option<String>)> {
        let registration = self
            .projects
            .get_workspace_registration(Path::new(workspace_path))?;
        let workspace_kind = registration
            .as_ref()
            .map(|registered| map_workspace_kind(registered.kind))
            .unwrap_or(WorkspaceKind::Project);
        let display_name = registration.and_then(|registered| registered.display_name);
        Ok((workspace_kind, display_name))
    }

    pub(super) fn resolve_workspace_identity(
        &self,
        workspace_path: &str,
    ) -> anyhow::Result<(WorkspaceKind, String)> {
        let (workspace_kind, display_name) = self.resolve_workspace_registration(workspace_path)?;
        let workspace_name = resolved_workspace_display_name(
            workspace_kind,
            Path::new(workspace_path),
            display_name.as_deref(),
        );
        Ok((workspace_kind, workspace_name))
    }
}

pub(crate) fn canonicalize_workspace_path(path: PathBuf) -> anyhow::Result<String> {
    Ok(path
        .canonicalize()
        .with_context(|| format!("Failed to open workspace {}", path.display()))?
        .to_string_lossy()
        .into_owned())
}

fn map_workspace_kind(kind: RegisteredWorkspaceKind) -> WorkspaceKind {
    match kind {
        RegisteredWorkspaceKind::Project => WorkspaceKind::Project,
        RegisteredWorkspaceKind::ManagedChat => WorkspaceKind::ManagedChat,
    }
}

pub(super) fn sync_workspace_session_state<'a>(
    state: &'a mut RuntimeState,
    workspace_path: &str,
    workspace_kind: WorkspaceKind,
    workspace_name: &str,
) -> &'a mut WorkspaceSessionState {
    let workspace = state
        .workspaces
        .entry(workspace_path.to_string())
        .or_insert_with(|| WorkspaceSessionState {
            kind: workspace_kind,
            workspace_name: workspace_name.to_string(),
            ..WorkspaceSessionState::default()
        });
    update_workspace_identity(workspace, workspace_kind, workspace_name);
    workspace
}

pub(super) fn update_workspace_identity(
    workspace: &mut WorkspaceSessionState,
    workspace_kind: WorkspaceKind,
    workspace_name: &str,
) {
    workspace.kind = workspace_kind;
    workspace.workspace_name.clear();
    workspace.workspace_name.push_str(workspace_name);
}
