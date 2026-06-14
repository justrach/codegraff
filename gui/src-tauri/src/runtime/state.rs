use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::Mutex;
use tokio::sync::mpsc;

use crate::bridge::emitter::UiEventEmitter;
use crate::bridge::followup::FollowupBridge;
use crate::dto::{FollowupRequestDto, SessionMessageDto, SessionTodoDto};
use crate::persistence::project_store::ProjectStore;
use crate::terminal::TerminalManager;

use super::{ForgeRuntime, PersistedConversationSummary, RuntimeManager};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum WorkspaceKind {
    #[default]
    Project,
    ManagedChat,
}

#[derive(Clone, Default)]
pub(crate) struct WorkspaceSessionState {
    pub(crate) runtime: Option<ForgeRuntime>,
    pub(crate) kind: WorkspaceKind,
    pub(crate) workspace_name: String,
    pub(crate) configured: bool,
    pub(crate) configuration_error: Option<String>,
    pub(crate) selected_conversation_id: Option<String>,
    pub(crate) persisted_conversations: Vec<PersistedConversationSummary>,
}

#[derive(Clone)]
pub(crate) struct PendingFileUpdateState {
    pub(crate) before_text: Option<String>,
    pub(crate) display_path: String,
    pub(crate) path: String,
    pub(crate) request_id: String,
    pub(crate) workspace_path: PathBuf,
}

#[derive(Clone, Default)]
pub(crate) struct ConversationSessionState {
    pub(crate) workspace_path: String,
    pub(crate) messages: Vec<SessionMessageDto>,
    pub(crate) todos: Vec<SessionTodoDto>,
    pub(crate) pending_file_updates: HashMap<String, PendingFileUpdateState>,
    pub(crate) pending_anonymous_file_updates: Vec<PendingFileUpdateState>,
    pub(crate) title: Option<String>,
    pub(crate) updated_at: Option<String>,
    pub(crate) active_request_ids: Vec<String>,
    pub(crate) request_agent_ids: HashMap<String, String>,
    pub(crate) is_local_draft: bool,
    pub(crate) order: u64,
}

#[derive(Clone, Default)]
pub(crate) struct RuntimeState {
    pub(crate) active_workspace_path: Option<String>,
    pub(crate) workspace_order: Vec<String>,
    pub(crate) workspaces: HashMap<String, WorkspaceSessionState>,
    pub(crate) conversations: HashMap<String, ConversationSessionState>,
    pub(crate) pending_followups_by_conversation: HashMap<String, FollowupRequestDto>,
    pub(crate) ui_error: Option<String>,
    pub(crate) next_order: u64,
}

impl RuntimeState {
    pub(crate) fn allocate_order(&mut self) -> u64 {
        self.next_order += 1;
        self.next_order
    }
}

pub(crate) fn shared_runtime_state() -> Arc<Mutex<RuntimeState>> {
    Arc::new(Mutex::new(RuntimeState::default()))
}

pub struct DesktopState {
    pub manager: Arc<RuntimeManager>,
    pub terminal_manager: Arc<TerminalManager>,
}

impl DesktopState {
    pub fn new(emitter: Arc<dyn UiEventEmitter>, projects: Arc<ProjectStore>) -> Self {
        let (followup_sender, followup_receiver) = mpsc::unbounded_channel();
        let followups = Arc::new(FollowupBridge::new(followup_sender));
        let manager = Arc::new(RuntimeManager::new(emitter.clone(), followups, projects));
        let terminal_manager = Arc::new(TerminalManager::new(emitter));
        let background_manager = manager.clone();
        tauri::async_runtime::spawn(async move {
            background_manager
                .handle_followup_requests(followup_receiver)
                .await;
        });

        Self { manager, terminal_manager }
    }
}
