use std::collections::HashMap;
use std::fmt;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

mod logging;
mod terminal;
mod text;
mod tool_card;

use logging::{codegraff_log_path, install_panic_logger, log_error, log_info};
use terminal::TerminalGuard;
use text::{
    push_wrapped, sanitize_render_text, truncate_single_line, visible_width, word_boundary_take,
    wrap_line,
};
use tool_card::{ToolEntry, ToolStatus, compact_tool_output, push_tool_lines};

use anyhow::{Context, Result};
use crossterm::event::{
    self, Event as TerminalEvent, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEvent,
    MouseEventKind,
};
use forge_api::{
    API, AgentInfo, AnyProvider, ApiKeyRequest, AuthContextRequest, AuthContextResponse,
    AuthMethod, ChatRequest, ChatResponse, ChatResponseContent, ConfigOperation, Conversation,
    Event, ForgeAPI, ForgeConfig, InputModality, Model, ModelConfig, ProviderId, TokenCount,
    URLParamSpec, Usage,
};
use futures::StreamExt;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

const MAX_COMPOSER_INNER_HEIGHT: usize = 9;
const LARGE_PASTE_CHAR_THRESHOLD: usize = 1_000;
const IMAGE_THUMBNAIL_COLUMNS: usize = 10;
const IMAGE_THUMBNAIL_ROWS: usize = 3;
const TUI_INPUT_POLL_MILLIS: u64 = 50;
const SCROLL_LINE_STEP: usize = 3;
const SCROLL_PAGE_STEP: usize = 12;
const MOUSE_SCROLL_STEP: usize = 5;

#[tokio::main]
async fn main() -> Result<()> {
    let log_path = codegraff_log_path();
    install_panic_logger(log_path.clone());
    let _ = rustls::crypto::ring::default_provider().install_default();
    log_info(&log_path, "starting Codegraff");

    let result = async {
        let config =
            ForgeConfig::read().context("Failed to read Forge configuration from .forge.toml")?;
        let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        let api = ForgeAPI::init(cwd, config);
        Tui::new(api, log_path.clone()).run().await
    }
    .await;

    if let Err(error) = &result {
        log_error(&log_path, "fatal Codegraff error", error);
    }

    result
}

struct Tui<A> {
    api: A,
    conversation_id: forge_api::ConversationId,
    transcript: Vec<TranscriptEntry>,
    composer: String,
    pending_pastes: Vec<PendingPaste>,
    large_paste_counter: usize,
    image_attachments: Vec<ImageAttachment>,
    usage: Option<UsageSummary>,
    active_model: Option<String>,
    overlay: Option<Overlay>,
    status: TuiStatus,
    scroll_from_bottom: usize,
    composer_scroll_from_bottom: usize,
    overlay_scroll_from_top: usize,
    overlay_input: String,
    selected_tool: Option<usize>,
    is_streaming: bool,
    workflow_run: Option<WorkflowRun>,
    workflow_task: Option<JoinHandle<()>>,
    chat_task: Option<JoinHandle<()>>,
    should_quit: bool,
    log_path: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TuiStatus {
    Ready,
    Thinking,
    Reasoning,
    Finished,
    Error,
    Interrupted,
}

#[derive(Clone)]
enum TranscriptEntry {
    User(UserMessage),
    Assistant(String),
    Tool(ToolEntry),
    Error(String),
    Status(String),
}

#[derive(Clone)]
struct UserMessage {
    text: String,
    images: Vec<ImageAttachment>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PendingPaste {
    placeholder: String,
    text: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ImagePreview {
    width: u32,
    height: u32,
    thumbnail: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct UsageSummary {
    last: Option<UsageLine>,
    session: Option<UsageLine>,
    context_tokens: Option<String>,
    model: Option<ModelStats>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ModelStats {
    provider: String,
    id: String,
    name: Option<String>,
    context_length: Option<String>,
    tools_supported: Option<bool>,
    supports_parallel_tool_calls: Option<bool>,
    supports_reasoning: Option<bool>,
    input_modalities: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
struct ModelOption {
    provider_id: ProviderId,
    model: Model,
}

impl ModelOption {
    fn new(provider_id: ProviderId, model: Model) -> Self {
        Self { provider_id, model }
    }
}

impl fmt::Display for ModelOption {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} / {}", self.provider_id, self.model.id)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ModelCommand {
    List,
    Select(usize),
    Cancel,
    Invalid(String),
    NotCommand,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnectIntent {
    Connect,
    Login,
}

impl ConnectIntent {
    fn command(self) -> &'static str {
        match self {
            Self::Connect => "/connect",
            Self::Login => "/login",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::Connect => "Connect provider",
            Self::Login => "Log in to provider",
        }
    }

    fn cancelled_message(self) -> &'static str {
        match self {
            Self::Connect => "Connect cancelled.",
            Self::Login => "Login cancelled.",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ConnectCommand {
    Open,
    Provider(usize),
    AuthMethod(usize),
    Field(String),
    Submit,
    Cancel,
    Invalid(String),
    NotCommand,
}

#[derive(Clone, Debug)]
struct ConnectDialog {
    intent: ConnectIntent,
    step: ConnectStep,
}

#[derive(Clone, Debug)]
struct ModelDialog {
    options: Vec<ModelOption>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum WorkflowCommand {
    Open(String),
    Approve,
    Cancel,
    Export,
    Edit(usize, String),
    Invalid(String),
    NotCommand,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum WorkflowOverlayAction {
    Approve,
    Edit,
    Export,
    Cancel,
    Select(usize),
    Invalid(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkflowDialogMode {
    Review,
    EditTask,
}

#[derive(Clone, Debug)]
struct WorkflowDialog {
    goal: String,
    nodes: Vec<WorkflowNode>,
    selected_node: usize,
    mode: WorkflowDialogMode,
}

#[derive(Clone, Debug)]
struct WorkflowRun {
    dialog: WorkflowDialog,
    status: WorkflowRunStatus,
    trace: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkflowRunStatus {
    Running,
    Finished,
    Error,
    Interrupted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkflowNode {
    name: String,
    worker: String,
    task: String,
    dependencies: Vec<String>,
    access: Vec<String>,
    artifact: String,
    stop_condition: String,
}

#[derive(Clone, Debug)]
enum Overlay {
    Connect(Box<ConnectDialog>),
    Model(ModelDialog),
    Workflow(WorkflowDialog),
}

#[derive(Clone, Debug)]
enum ConnectStep {
    ProviderSelection {
        providers: Vec<ProviderOption>,
    },
    AuthMethodSelection {
        provider: ProviderOption,
        methods: Vec<AuthMethod>,
    },
    ApiKeyInput {
        provider: ProviderOption,
        request: ApiKeyRequest,
        form: ApiKeyForm,
    },
}

#[derive(Clone, Debug)]
struct ProviderOption {
    provider: AnyProvider,
}

impl ProviderOption {
    fn new(provider: AnyProvider) -> Self {
        Self { provider }
    }

    fn id(&self) -> ProviderId {
        self.provider.id()
    }

    fn auth_methods(&self) -> &[AuthMethod] {
        self.provider.auth_methods()
    }

    fn is_configured(&self) -> bool {
        self.provider.is_configured()
    }

    fn host(&self) -> String {
        self.provider
            .url()
            .and_then(|url| url.domain().map(str::to_string))
            .unwrap_or_else(|| "template".to_string())
    }
}

#[derive(Clone, Debug)]
struct ApiKeyForm {
    api_key: String,
    url_params: Vec<ConnectField>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConnectField {
    name: String,
    value: String,
    options: Option<Vec<String>>,
}

impl ConnectField {
    fn new(name: String, value: String, options: Option<Vec<String>>) -> Self {
        Self { name, value, options }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ConnectFieldUpdate {
    ApiKey(String),
    UrlParam { name: String, value: String },
    Invalid(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct UsageLine {
    prompt_tokens: String,
    completion_tokens: String,
    total_tokens: String,
    cached_tokens: String,
    cost: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ImageAttachment {
    path: String,
    preview: Option<ImagePreview>,
}

impl ImageAttachment {
    fn new(path: impl Into<String>) -> Self {
        Self { path: path.into(), preview: None }
    }

    fn with_preview(mut self) -> Self {
        self.preview = load_image_preview(Path::new(&self.path)).ok();
        self
    }

    fn tag(&self) -> String {
        format!("@[{}]", self.path)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ImageCommand {
    Attach(ImageAttachment),
    Invalid(String),
    NotCommand,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ToolShortcut {
    Next,
    Previous,
    Toggle,
    None,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ComposerScrollShortcut {
    UpOne,
    DownOne,
    UpPage,
    DownPage,
    Top,
    Bottom,
    None,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ComposerEditShortcut {
    ClearLine,
    DeletePreviousWord,
    None,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EscapeAction {
    StopAgent,
    ClearComposer,
}

enum AppEvent {
    Input(KeyEvent),
    Mouse(MouseEvent),
    Paste(String),
    Chat(Result<ChatResponse>),
    WorkflowChat(Result<ChatResponse>),
}

impl<A> Tui<A> {
    fn finish_streaming(&mut self, status: TuiStatus) {
        self.is_streaming = false;
        self.status = status;
    }
}

impl<A: API + 'static> Tui<A> {
    fn new(api: A, log_path: PathBuf) -> Self {
        let conversation = Conversation::generate();
        Self {
            api,
            conversation_id: conversation.id,
            transcript: vec![
                TranscriptEntry::Status(
                    "Codegraff started. Type /login to connect providers, /models to choose a model, /workflow <goal> to review an agent topology, paste image paths with Cmd+V/Ctrl+V, or use /image <path>. Press Enter to send. Ctrl+C exits."
                        .to_string(),
                ),
                TranscriptEntry::Status(format!("Logs: {}", log_path.display())),
            ],
            composer: String::new(),
            pending_pastes: Vec::new(),
            large_paste_counter: 0,
            image_attachments: Vec::new(),
            usage: None,
            active_model: None,
            overlay: None,
            status: TuiStatus::Ready,
            scroll_from_bottom: 0,
            composer_scroll_from_bottom: 0,
            overlay_scroll_from_top: 0,
            overlay_input: String::new(),
            selected_tool: None,
            is_streaming: false,
            workflow_run: None,
            workflow_task: None,
            chat_task: None,
            should_quit: false,
            log_path,
        }
    }

    async fn run(mut self) -> Result<()> {
        self.api
            .upsert_conversation(Conversation::new(self.conversation_id))
            .await?;
        self.refresh_active_model().await;

        let mut terminal = TerminalGuard::enter()?;
        let (tx, mut rx) = mpsc::unbounded_channel();
        spawn_input_reader(tx.clone(), self.log_path.clone());

        loop {
            if let Err(error) = terminal.draw(|frame| self.render(frame)) {
                self.log_error("terminal draw failed", &error);
                return Err(error);
            }

            if self.should_quit {
                break;
            }

            if let Some(event) = rx.recv().await {
                match event {
                    AppEvent::Input(key) => {
                        if let Err(error) = self.handle_input(key, tx.clone()).await {
                            self.log_error("input handling failed", &error);
                            return Err(error);
                        }
                    }
                    AppEvent::Mouse(mouse) => self.handle_mouse(mouse),
                    AppEvent::Paste(text) => self.handle_paste(text),
                    AppEvent::Chat(response) => self.handle_chat_response(response).await,
                    AppEvent::WorkflowChat(response) => {
                        self.handle_workflow_chat_response(response).await
                    }
                }
            }
        }

        Ok(())
    }

    async fn handle_input(
        &mut self,
        key: KeyEvent,
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> Result<()> {
        if !is_key_press(key) {
            return Ok(());
        }

        if key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('c')) {
            self.should_quit = true;
            return Ok(());
        }

        if self.handle_overlay_input(key, tx.clone()).await? {
            return Ok(());
        }

        if is_clipboard_paste_key(key) {
            self.paste_from_clipboard();
            return Ok(());
        }

        if self.handle_composer_scroll_key(key) {
            return Ok(());
        }

        if self.handle_edit_key(key) {
            return Ok(());
        }

        if self.handle_scroll_key(key) {
            return Ok(());
        }

        if self.handle_tool_key(key) {
            return Ok(());
        }

        match key.code {
            KeyCode::Char(_) => {
                if let Some(ch) = composer_input_char(key) {
                    self.push_composer_char(ch);
                }
            }
            KeyCode::Enter if is_multiline_input_key(key) => self.push_composer_char('\n'),
            KeyCode::Backspace => self.delete_composer_char(),
            KeyCode::Enter if !self.is_streaming => self.handle_enter(tx).await?,
            KeyCode::Esc => self.handle_escape(),
            _ => {}
        }

        Ok(())
    }

    async fn handle_overlay_input(
        &mut self,
        key: KeyEvent,
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> Result<bool> {
        let Some(overlay) = self.overlay.as_ref() else {
            return Ok(false);
        };

        match key.code {
            KeyCode::Esc => {
                if self.cancel_workflow_edit_mode() {
                    return Ok(true);
                }
                let message = self.overlay.as_ref().and_then(|overlay| match overlay {
                    Overlay::Connect(dialog) => Some(dialog.intent.cancelled_message()),
                    Overlay::Model(_) => None,
                    Overlay::Workflow(_) => Some("Workflow cancelled."),
                });
                self.close_overlay();
                if let Some(message) = message {
                    self.transcript
                        .push(TranscriptEntry::Status(message.to_string()));
                    self.scroll_from_bottom = 0;
                }
                Ok(true)
            }
            KeyCode::Char('a') if self.workflow_review_shortcut_ready() => {
                self.approve_workflow(tx).await?;
                Ok(true)
            }
            KeyCode::Char('e') if self.workflow_review_shortcut_ready() => {
                self.enter_workflow_edit_mode();
                Ok(true)
            }
            KeyCode::Char('x') if self.workflow_review_shortcut_ready() => {
                self.export_workflow();
                Ok(true)
            }
            KeyCode::Char('c') if self.workflow_review_shortcut_ready() => {
                self.close_overlay();
                self.transcript
                    .push(TranscriptEntry::Status("Workflow cancelled.".to_string()));
                self.scroll_from_bottom = 0;
                Ok(true)
            }
            KeyCode::Up if matches!(overlay, Overlay::Workflow(_)) => {
                self.select_previous_workflow_node();
                Ok(true)
            }
            KeyCode::Down if matches!(overlay, Overlay::Workflow(_)) => {
                self.select_next_workflow_node();
                Ok(true)
            }
            KeyCode::Up => {
                self.overlay_scroll_from_top = self
                    .overlay_scroll_from_top
                    .saturating_sub(SCROLL_LINE_STEP);
                Ok(true)
            }
            KeyCode::Down => {
                self.overlay_scroll_from_top = self
                    .overlay_scroll_from_top
                    .saturating_add(SCROLL_LINE_STEP);
                Ok(true)
            }
            KeyCode::PageUp => {
                self.overlay_scroll_from_top = self
                    .overlay_scroll_from_top
                    .saturating_sub(SCROLL_PAGE_STEP);
                Ok(true)
            }
            KeyCode::PageDown => {
                self.overlay_scroll_from_top = self
                    .overlay_scroll_from_top
                    .saturating_add(SCROLL_PAGE_STEP);
                Ok(true)
            }
            KeyCode::Home => {
                self.overlay_scroll_from_top = 0;
                Ok(true)
            }
            KeyCode::End => {
                self.overlay_scroll_from_top = usize::MAX;
                Ok(true)
            }
            KeyCode::Backspace => {
                self.overlay_input.pop();
                Ok(true)
            }
            KeyCode::Enter => {
                self.submit_overlay_input(tx).await?;
                Ok(true)
            }
            KeyCode::Char(_) => {
                if let Some(ch) = composer_input_char(key) {
                    self.overlay_input.push(ch);
                }
                Ok(true)
            }
            _ => Ok(true),
        }
    }

    async fn submit_overlay_input(&mut self, tx: mpsc::UnboundedSender<AppEvent>) -> Result<()> {
        match self.overlay.clone() {
            Some(Overlay::Model(_)) => self.submit_numbered_overlay_selection().await,
            Some(Overlay::Connect(dialog)) => match dialog.step {
                ConnectStep::ProviderSelection { .. } | ConnectStep::AuthMethodSelection { .. } => {
                    self.submit_numbered_overlay_selection().await
                }
                ConnectStep::ApiKeyInput { .. } => self.submit_connect_overlay_input().await,
            },
            Some(Overlay::Workflow(_)) => self.submit_workflow_overlay_input(tx).await,
            None => Ok(()),
        }
    }

    async fn submit_numbered_overlay_selection(&mut self) -> Result<()> {
        let selection = self.overlay_input.trim().parse::<usize>();
        let Ok(index) = selection else {
            self.transcript.push(TranscriptEntry::Error(
                "Type a number in the dialog, then press Enter.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return Ok(());
        };

        if index == 0 {
            self.transcript.push(TranscriptEntry::Error(
                "Selection must be greater than zero.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return Ok(());
        }

        self.overlay_input.clear();
        self.overlay_scroll_from_top = 0;

        match self.overlay.clone() {
            Some(Overlay::Model(_)) => self.select_model(index).await,
            Some(Overlay::Connect(dialog)) => match dialog.step {
                ConnectStep::ProviderSelection { .. } => self.select_connect_provider(index).await,
                ConnectStep::AuthMethodSelection { .. } => {
                    self.select_connect_auth_method(index).await
                }
                ConnectStep::ApiKeyInput { .. } => {}
            },
            Some(Overlay::Workflow(_)) | None => {}
        }

        Ok(())
    }

    async fn submit_connect_overlay_input(&mut self) -> Result<()> {
        let input = self.overlay_input.trim().to_string();
        self.overlay_input.clear();
        self.overlay_scroll_from_top = 0;

        match input.as_str() {
            "" => Ok(()),
            "submit" => {
                self.submit_connect_dialog().await;
                Ok(())
            }
            "cancel" => {
                let message = self.connect_intent().cancelled_message();
                self.close_overlay();
                self.transcript
                    .push(TranscriptEntry::Status(message.to_string()));
                self.scroll_from_bottom = 0;
                Ok(())
            }
            update => {
                self.update_connect_field(update.to_string());
                Ok(())
            }
        }
    }

    fn selection_overlay_active(&self) -> bool {
        self.overlay.is_some()
    }

    fn close_overlay(&mut self) {
        self.overlay = None;
        self.overlay_scroll_from_top = 0;
        self.overlay_input.clear();
        self.status = TuiStatus::Ready;
    }

    fn handle_mouse_scroll(&mut self, kind: MouseEventKind) {
        if self.selection_overlay_active() {
            handle_overlay_mouse_scroll_offset(&mut self.overlay_scroll_from_top, kind);
            return;
        }

        handle_mouse_scroll_offset(&mut self.scroll_from_bottom, kind);
    }

    fn reset_overlay_selection_state(&mut self) {
        self.overlay_scroll_from_top = 0;
        self.overlay_input.clear();
    }

    fn handle_mouse(&mut self, mouse: MouseEvent) {
        self.handle_mouse_scroll(mouse.kind);
    }

    fn push_composer_char(&mut self, ch: char) {
        if self.overlay.is_some() {
            return;
        }
        self.composer.push(ch);
        self.composer_scroll_from_bottom = 0;
    }

    fn delete_composer_char(&mut self) {
        if self.overlay.is_some() {
            return;
        }
        self.composer.pop();
        self.composer_scroll_from_bottom = 0;
    }

    fn clear_composer(&mut self) {
        self.composer.clear();
        self.pending_pastes.clear();
        self.image_attachments.clear();
        self.composer_scroll_from_bottom = 0;
    }

    fn handle_escape(&mut self) {
        if self.overlay.is_some() {
            self.close_overlay();
            return;
        }

        match escape_action(self.is_streaming) {
            EscapeAction::StopAgent => self.stop_agent(),
            EscapeAction::ClearComposer => self.clear_composer(),
        }
    }

    fn stop_agent(&mut self) {
        self.abort_chat_task();
        self.is_streaming = false;
        self.status = TuiStatus::Interrupted;
        self.transcript.push(TranscriptEntry::Status(
            "Stopped current agent run. Press Enter to send a new prompt.".to_string(),
        ));
        self.scroll_from_bottom = 0;
    }

    fn log_error(&self, context: &str, error: &anyhow::Error) {
        log_error(&self.log_path, context, error);
    }

    fn handle_paste(&mut self, text: String) {
        if self.overlay.is_none() {
            self.apply_paste_text(text);
        }
    }

    fn paste_from_clipboard(&mut self) {
        if self.overlay.is_some() {
            return;
        }

        match read_clipboard_text() {
            Ok(text) if text.is_empty() => {
                self.transcript
                    .push(TranscriptEntry::Status("Clipboard is empty.".to_string()));
                self.scroll_from_bottom = 0;
            }
            Ok(text) => self.apply_paste_text(text),
            Err(text_error) => match read_clipboard_image() {
                Ok(image) => self.attach_image(image),
                Err(image_error) => {
                    self.transcript.push(TranscriptEntry::Error(format!(
                        "Clipboard paste failed: text unavailable ({text_error}); image unavailable ({image_error})."
                    )));
                    self.scroll_from_bottom = 0;
                }
            },
        }
    }

    fn apply_paste_text(&mut self, text: String) {
        let normalized = normalize_paste_text(&text);
        let pasted = parse_pasted_images(&normalized);
        if pasted.is_empty() {
            self.insert_pasted_text(normalized);
            self.composer_scroll_from_bottom = 0;
            return;
        }

        for image in pasted {
            self.attach_image(image);
        }
        self.composer_scroll_from_bottom = 0;
    }

    fn insert_pasted_text(&mut self, text: String) {
        let char_count = text.chars().count();
        if char_count > LARGE_PASTE_CHAR_THRESHOLD {
            let placeholder = self.next_large_paste_placeholder(char_count);
            log_info(
                &self.log_path,
                &format!("large paste stored as {placeholder}: {char_count} chars"),
            );
            self.pending_pastes
                .push(PendingPaste { placeholder: placeholder.clone(), text });
            self.composer.push_str(&placeholder);
        } else {
            self.composer.push_str(&text);
        }
    }

    fn next_large_paste_placeholder(&mut self, char_count: usize) -> String {
        self.large_paste_counter = self.large_paste_counter.saturating_add(1);
        if self.large_paste_counter == 1 {
            format!("[Pasted Content {char_count} chars]")
        } else {
            format!(
                "[Pasted Content {char_count} chars #{}]",
                self.large_paste_counter
            )
        }
    }

    fn attach_image(&mut self, image: ImageAttachment) {
        let image = image.with_preview();
        self.image_attachments.push(image);
        self.composer_scroll_from_bottom = 0;
    }

    async fn handle_enter(&mut self, tx: mpsc::UnboundedSender<AppEvent>) -> Result<()> {
        let raw_prompt = self.composer.trim().to_string();
        if raw_prompt == "/usage" {
            self.show_usage().await;
            self.composer.clear();
            self.composer_scroll_from_bottom = 0;
            return Ok(());
        }

        match parse_model_command(&raw_prompt) {
            ModelCommand::List => {
                self.show_models().await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ModelCommand::Select(index) => {
                self.select_model(index).await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ModelCommand::Cancel => {
                self.close_overlay();
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ModelCommand::Invalid(message) => {
                self.transcript.push(TranscriptEntry::Error(message));
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            ModelCommand::NotCommand => {}
        }

        match parse_connect_command(&raw_prompt) {
            ConnectCommand::Open => {
                self.open_connect_dialog().await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Provider(index) => {
                self.select_connect_provider(index).await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::AuthMethod(index) => {
                self.select_connect_auth_method(index).await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Field(update) => {
                self.update_connect_field(update);
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Submit => {
                self.submit_connect_dialog().await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Cancel => {
                let message = self.connect_intent().cancelled_message();
                self.close_overlay();
                self.transcript
                    .push(TranscriptEntry::Status(message.to_string()));
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Invalid(message) => {
                self.transcript.push(TranscriptEntry::Error(message));
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::NotCommand => {}
        }

        match parse_login_command(&raw_prompt) {
            ConnectCommand::Open => {
                self.open_login_dialog().await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Provider(index) => {
                self.select_connect_provider(index).await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::AuthMethod(index) => {
                self.select_connect_auth_method(index).await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Field(update) => {
                self.update_connect_field(update);
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Submit => {
                self.submit_connect_dialog().await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Cancel => {
                let message = self.connect_intent().cancelled_message();
                self.close_overlay();
                self.transcript
                    .push(TranscriptEntry::Status(message.to_string()));
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::Invalid(message) => {
                self.transcript.push(TranscriptEntry::Error(message));
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            ConnectCommand::NotCommand => {}
        }

        if raw_prompt == "/workflow status" {
            self.show_workflow_status();
            self.composer.clear();
            self.composer_scroll_from_bottom = 0;
            return Ok(());
        }

        if raw_prompt == "/workflow trace" {
            self.show_workflow_trace();
            self.composer.clear();
            self.composer_scroll_from_bottom = 0;
            return Ok(());
        }

        match parse_workflow_command(&raw_prompt) {
            WorkflowCommand::Open(goal) => {
                self.show_workflow_preview(goal).await;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            WorkflowCommand::Approve => {
                self.approve_workflow(tx).await?;
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            WorkflowCommand::Cancel => {
                self.close_overlay();
                self.transcript
                    .push(TranscriptEntry::Status("Workflow cancelled.".to_string()));
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            WorkflowCommand::Export => {
                self.export_workflow();
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            WorkflowCommand::Edit(index, task) => {
                self.edit_workflow_node(index, task);
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                return Ok(());
            }
            WorkflowCommand::Invalid(message) => {
                self.transcript.push(TranscriptEntry::Error(message));
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            WorkflowCommand::NotCommand => {}
        }

        if raw_prompt == "/logs" {
            self.transcript.push(TranscriptEntry::Status(format!(
                "Codegraff logs: {}",
                self.log_path.display()
            )));
            self.composer.clear();
            self.composer_scroll_from_bottom = 0;
            self.scroll_from_bottom = 0;
            return Ok(());
        }

        match parse_image_command(&raw_prompt) {
            ImageCommand::Attach(image) => {
                self.attach_image(image.clone());
                self.composer.clear();
                return Ok(());
            }
            ImageCommand::Invalid(message) => {
                self.transcript.push(TranscriptEntry::Error(message));
                self.scroll_from_bottom = 0;
                return Ok(());
            }
            ImageCommand::NotCommand => {}
        }

        if raw_prompt.is_empty() && self.image_attachments.is_empty() {
            return Ok(());
        }

        let expanded_prompt = expand_pending_pastes(&raw_prompt, &self.pending_pastes);
        let event = build_chat_event(&expanded_prompt, &self.image_attachments);
        let display_prompt = build_display_prompt(&raw_prompt, &self.image_attachments);
        self.abort_chat_task();
        self.composer.clear();
        self.pending_pastes.clear();
        self.composer_scroll_from_bottom = 0;
        let images = std::mem::take(&mut self.image_attachments);
        self.transcript.push(TranscriptEntry::User(UserMessage {
            text: display_prompt,
            images,
        }));
        self.scroll_from_bottom = 0;
        self.status = TuiStatus::Thinking;
        self.is_streaming = true;
        self.spawn_chat(event, tx).await?;

        Ok(())
    }

    async fn spawn_chat(
        &mut self,
        event: Event,
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> Result<()> {
        let chat = ChatRequest::new(event, self.conversation_id);
        let mut stream = self.api.chat(chat).await?;
        let log_path = self.log_path.clone();

        let task = tokio::spawn(async move {
            while let Some(response) = stream.next().await {
                if let Err(error) = &response {
                    log_error(&log_path, "chat stream emitted error", error);
                }
                if tx.send(AppEvent::Chat(response)).is_err() {
                    log_info(&log_path, "chat stream receiver dropped");
                    return;
                }
            }
        });
        self.chat_task = Some(task);

        Ok(())
    }

    async fn spawn_workflow(
        &mut self,
        event: Event,
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> Result<()> {
        let chat = ChatRequest::new(event, self.conversation_id);
        let mut stream = self.api.chat(chat).await?;
        let log_path = self.log_path.clone();

        let task = tokio::spawn(async move {
            while let Some(response) = stream.next().await {
                if let Err(error) = &response {
                    log_error(&log_path, "workflow stream emitted error", error);
                }
                if tx.send(AppEvent::WorkflowChat(response)).is_err() {
                    log_info(&log_path, "workflow stream receiver dropped");
                    return;
                }
            }
        });
        self.workflow_task = Some(task);

        Ok(())
    }

    fn abort_chat_task(&mut self) {
        if let Some(task) = self.chat_task.take() {
            task.abort();
        }
    }

    async fn handle_chat_response(&mut self, response: Result<ChatResponse>) {
        match response {
            Ok(response) => {
                let should_refresh_usage = self.push_chat_response(response).await;
                if should_refresh_usage {
                    self.refresh_usage().await;
                }
            }
            Err(error) => {
                self.log_error("chat response handling failed", &error);
                self.abort_chat_task();
                self.finish_streaming(TuiStatus::Error);
                self.transcript
                    .push(TranscriptEntry::Error(format!("{error:#}")));
            }
        }
    }

    async fn handle_workflow_chat_response(&mut self, response: Result<ChatResponse>) {
        match response {
            Ok(response) => {
                let finished = self.push_workflow_response(response);
                if finished {
                    self.abort_workflow_task();
                    if let Some(run) = &mut self.workflow_run {
                        run.status = WorkflowRunStatus::Finished;
                    }
                    self.transcript.push(TranscriptEntry::Status(
                        "Workflow finished in the background. Use /workflow trace to inspect it."
                            .to_string(),
                    ));
                    self.scroll_from_bottom = 0;
                    self.refresh_usage().await;
                }
            }
            Err(error) => {
                self.log_error("workflow response handling failed", &error);
                self.abort_workflow_task();
                if let Some(run) = &mut self.workflow_run {
                    run.status = WorkflowRunStatus::Error;
                    run.trace.push(format!("error: {error:#}"));
                }
                self.transcript.push(TranscriptEntry::Error(format!(
                    "Background workflow failed: {error:#}. Use /workflow trace for details."
                )));
                self.scroll_from_bottom = 0;
            }
        }
    }

    fn abort_workflow_task(&mut self) {
        if let Some(task) = self.workflow_task.take() {
            task.abort();
        }
    }

    async fn refresh_usage(&mut self) {
        match self.api.conversation(&self.conversation_id).await {
            Ok(Some(conversation)) => {
                self.usage = usage_summary_from_conversation(&conversation);
            }
            Ok(None) => {}
            Err(error) => {
                self.log_error("usage refresh failed", &error);
                self.transcript.push(TranscriptEntry::Status(format!(
                    "Usage refresh failed: {error:#}"
                )));
                self.scroll_from_bottom = 0;
            }
        }
    }

    async fn show_usage(&mut self) {
        self.refresh_usage().await;
        let model = self.model_stats().await;
        if let Some(usage) = &mut self.usage {
            usage.model = model;
        } else if model.is_some() {
            self.usage =
                Some(UsageSummary { last: None, session: None, context_tokens: None, model });
        }

        match &self.usage {
            Some(usage) => {
                for detail in usage_detail_lines(usage) {
                    self.transcript.push(TranscriptEntry::Status(detail));
                }
            }
            None => self.transcript.push(TranscriptEntry::Status(
                "Usage is not available yet. Send a message first.".to_string(),
            )),
        }
        self.scroll_from_bottom = 0;
    }

    async fn show_models(&mut self) {
        match self.model_options().await {
            Ok(models) if models.is_empty() => {
                self.transcript.push(TranscriptEntry::Status(
                    "No registered provider models found. Type /login to connect a provider in CodeGraff first."
                        .to_string(),
                ));
                self.overlay = None;
            }
            Ok(models) => {
                self.reset_overlay_selection_state();
                self.overlay = Some(Overlay::Model(ModelDialog { options: models }));
                self.status = TuiStatus::Ready;
            }
            Err(error) => {
                self.log_error("model list failed", &error);
                self.transcript.push(TranscriptEntry::Error(format!(
                    "Models unavailable: {error:#}"
                )));
            }
        }
        self.scroll_from_bottom = 0;
    }

    async fn select_model(&mut self, index: usize) {
        match self.model_options().await {
            Ok(models) if models.is_empty() => self.transcript.push(TranscriptEntry::Status(
                "No registered provider models found. Type /login to connect a provider in CodeGraff first."
                    .to_string(),
            )),
            Ok(models) => {
                let Some(option) = models.get(index.saturating_sub(1)) else {
                    self.transcript.push(TranscriptEntry::Error(format!(
                        "Model selection {index} is out of range. Type /models to list available models."
                    )));
                    self.scroll_from_bottom = 0;
                    return;
                };

                let config = ModelConfig::new(option.provider_id.clone(), option.model.id.clone());
                match self
                    .api
                    .update_config(vec![ConfigOperation::SetSessionConfig(config)])
                    .await
                {
                    Ok(()) => {
                        self.usage = None;
                        self.overlay = None;
                        self.active_model = Some(model_label(option));
                        self.transcript.push(TranscriptEntry::Status(format!(
                            "Switched to model: {} / {}",
                            option.provider_id, option.model.id
                        )));
                    }
                    Err(error) => {
                        self.log_error("model selection failed", &error);
                        self.transcript.push(TranscriptEntry::Error(format!(
                            "Model selection failed: {error:#}"
                        )));
                    }
                }
            }
            Err(error) => {
                self.log_error("model list failed", &error);
                self.transcript.push(TranscriptEntry::Error(format!(
                    "Models unavailable: {error:#}"
                )));
            }
        }
        self.scroll_from_bottom = 0;
    }

    async fn model_options(&self) -> Result<Vec<ModelOption>> {
        let mut provider_models = self.api.get_all_provider_models().await?;
        provider_models.iter_mut().for_each(|provider| {
            provider
                .models
                .sort_by(|a, b| a.id.as_str().cmp(b.id.as_str()))
        });
        provider_models.sort_by(|a, b| a.provider_id.as_ref().cmp(b.provider_id.as_ref()));

        Ok(provider_models
            .into_iter()
            .flat_map(|provider| {
                let provider_id = provider.provider_id;
                provider
                    .models
                    .into_iter()
                    .map(move |model| ModelOption::new(provider_id.clone(), model))
            })
            .collect())
    }

    async fn refresh_active_model(&mut self) {
        self.active_model = self
            .api
            .get_session_config()
            .await
            .map(|config| model_config_label(&config));
    }

    async fn open_connect_dialog(&mut self) {
        self.open_provider_auth_dialog(ConnectIntent::Connect).await;
    }

    async fn open_login_dialog(&mut self) {
        self.open_provider_auth_dialog(ConnectIntent::Login).await;
    }

    async fn open_provider_auth_dialog(&mut self, intent: ConnectIntent) {
        match self.connect_provider_options().await {
            Ok(providers) if providers.is_empty() => self.transcript.push(TranscriptEntry::Status(
                "No providers found to connect. Check your CodeGraff provider configuration."
                    .to_string(),
            )),
            Ok(providers) => {
                self.reset_overlay_selection_state();
                self.overlay = Some(Overlay::Connect(Box::new(ConnectDialog {
                    intent,
                    step: ConnectStep::ProviderSelection { providers },
                })));
            }
            Err(error) => {
                self.log_error("connect provider list failed", &error);
                self.transcript.push(TranscriptEntry::Error(format!(
                    "Connect unavailable: {error:#}"
                )));
            }
        }
        self.scroll_from_bottom = 0;
    }

    fn connect_intent(&self) -> ConnectIntent {
        match self.overlay.as_ref() {
            Some(Overlay::Connect(dialog)) => dialog.intent,
            _ => ConnectIntent::Connect,
        }
    }

    async fn connect_provider_options(&self) -> Result<Vec<ProviderOption>> {
        let mut providers = self
            .api
            .get_providers()
            .await?
            .into_iter()
            .map(ProviderOption::new)
            .collect::<Vec<_>>();
        providers.sort_by(|a, b| a.id().as_ref().cmp(b.id().as_ref()));
        Ok(providers)
    }

    async fn select_connect_provider(&mut self, index: usize) {
        let Some(Overlay::Connect(dialog)) = self.overlay.as_ref() else {
            self.transcript.push(TranscriptEntry::Error(
                "No connect dialog is open. Type /login or /connect first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        let (intent, provider) = match &dialog.step {
            ConnectStep::ProviderSelection { providers } => (
                dialog.intent,
                providers.get(index.saturating_sub(1)).cloned(),
            ),
            _ => (dialog.intent, None),
        };

        let Some(provider) = provider else {
            self.transcript.push(TranscriptEntry::Error(format!(
                "{} selection {index} is out of range. Type {} to list providers.",
                intent.title(),
                intent.command()
            )));
            self.scroll_from_bottom = 0;
            return;
        };

        let methods = provider.auth_methods().to_vec();
        if methods.is_empty() {
            self.transcript.push(TranscriptEntry::Error(format!(
                "{} does not expose any authentication methods.",
                provider.id()
            )));
            self.scroll_from_bottom = 0;
            return;
        }

        if methods.len() == 1 {
            let Some(method) = methods.first().cloned() else {
                self.transcript.push(TranscriptEntry::Error(format!(
                    "{} does not expose any authentication methods.",
                    provider.id()
                )));
                self.scroll_from_bottom = 0;
                return;
            };
            self.begin_connect_auth(provider, method).await;
        } else {
            self.reset_overlay_selection_state();
            self.overlay = Some(Overlay::Connect(Box::new(ConnectDialog {
                intent,
                step: ConnectStep::AuthMethodSelection { provider, methods },
            })));
            self.transcript.push(TranscriptEntry::Status(format!(
                "Pick an auth method with {} auth <number>.",
                intent.command()
            )));
            self.scroll_from_bottom = 0;
        }
    }

    async fn select_connect_auth_method(&mut self, index: usize) {
        let Some(Overlay::Connect(dialog)) = self.overlay.as_ref() else {
            self.transcript.push(TranscriptEntry::Error(
                "No connect dialog is open. Type /login or /connect first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        let selection = match &dialog.step {
            ConnectStep::AuthMethodSelection { provider, methods } => methods
                .get(index.saturating_sub(1))
                .cloned()
                .map(|method| (provider.clone(), method)),
            _ => None,
        };

        let Some((provider, method)) = selection else {
            self.transcript.push(TranscriptEntry::Error(format!(
                "Auth method selection {index} is out of range."
            )));
            self.scroll_from_bottom = 0;
            return;
        };

        self.begin_connect_auth(provider, method).await;
    }

    async fn begin_connect_auth(&mut self, provider: ProviderOption, method: AuthMethod) {
        let provider_id = provider.id();
        match self
            .api
            .init_provider_auth(provider_id.clone(), method)
            .await
        {
            Ok(AuthContextRequest::ApiKey(request)) => {
                let form = build_api_key_form(&provider_id, &request);
                self.overlay = Some(Overlay::Connect(Box::new(ConnectDialog {
                    intent: self.connect_intent(),
                    step: ConnectStep::ApiKeyInput { provider, request, form },
                })));
                let command = self.connect_intent().command();
                self.transcript.push(TranscriptEntry::Status(format!(
                    "Editing {provider_id}. Set fields with {command} set <field>=<value>, then {command} submit."
                )));
            }
            Ok(AuthContextRequest::DeviceCode(request)) => {
                let display_uri = request
                    .verification_uri_complete
                    .as_ref()
                    .unwrap_or(&request.verification_uri);
                self.overlay = None;
                self.transcript.push(TranscriptEntry::Status(format!(
                    "Open {display_uri} and enter code {}. Complete this CodeGraff OAuth flow with `forge provider login {provider_id}` for now.",
                    request.user_code
                )));
            }
            Ok(AuthContextRequest::Code(request)) => {
                self.overlay = None;
                self.transcript.push(TranscriptEntry::Status(format!(
                    "Open {}. Complete this CodeGraff OAuth code flow with `forge provider login {provider_id}` for now.",
                    request.authorization_url
                )));
            }
            Err(error) => {
                self.log_error("connect auth init failed", &error);
                self.transcript.push(TranscriptEntry::Error(format!(
                    "Connect failed to start: {error:#}"
                )));
            }
        }
        self.scroll_from_bottom = 0;
    }

    fn update_connect_field(&mut self, update: String) {
        let parsed = parse_connect_field_update(&update);
        let Some(Overlay::Connect(dialog)) = &mut self.overlay else {
            self.transcript.push(TranscriptEntry::Error(
                "No connect dialog is open. Type /login or /connect first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        let ConnectStep::ApiKeyInput { form, .. } = &mut dialog.step else {
            self.transcript.push(TranscriptEntry::Error(
                "Pick a provider before setting connect fields.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        match parsed {
            ConnectFieldUpdate::ApiKey(value) => {
                form.api_key = value;
                self.transcript.push(TranscriptEntry::Status(
                    "Updated API key field.".to_string(),
                ));
            }
            ConnectFieldUpdate::UrlParam { name, value } => {
                let Some(field) = form.url_params.iter_mut().find(|field| field.name == name)
                else {
                    self.transcript.push(TranscriptEntry::Error(format!(
                        "Unknown connect field `{name}`. Check the dialog for field names."
                    )));
                    self.scroll_from_bottom = 0;
                    return;
                };
                if let Some(options) = &field.options
                    && !options.iter().any(|option| option == &value)
                {
                    self.transcript.push(TranscriptEntry::Error(format!(
                        "Invalid value `{value}` for {name}. Options: {}",
                        options.join(", ")
                    )));
                    self.scroll_from_bottom = 0;
                    return;
                }
                field.value = value;
                self.transcript
                    .push(TranscriptEntry::Status(format!("Updated {name}.")));
            }
            ConnectFieldUpdate::Invalid(message) => {
                self.transcript.push(TranscriptEntry::Error(message))
            }
        }
        self.scroll_from_bottom = 0;
    }

    async fn submit_connect_dialog(&mut self) {
        let Some(Overlay::Connect(dialog)) = self.overlay.clone() else {
            self.transcript.push(TranscriptEntry::Error(
                "No connect dialog is open. Type /login or /connect first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        let ConnectStep::ApiKeyInput { provider, request, form } = dialog.step else {
            self.transcript.push(TranscriptEntry::Error(
                "Connect form is not ready yet. Pick a provider first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        let provider_id = provider.id();
        let api_key = form.api_key.trim().to_string();
        if api_key.is_empty() {
            self.transcript.push(TranscriptEntry::Error(
                "API key cannot be empty. Type key=<value> in the connect dialog.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        }

        let mut url_params = HashMap::new();
        for field in &form.url_params {
            if field.value.trim().is_empty() {
                self.transcript.push(TranscriptEntry::Error(format!(
                    "{} cannot be empty. Type {}=<value> in the connect dialog.",
                    field.name, field.name
                )));
                self.scroll_from_bottom = 0;
                return;
            }
            url_params.insert(
                field.name.clone(),
                field.value.trim_end_matches('/').to_string(),
            );
        }

        let response = AuthContextResponse::api_key(request, api_key, url_params);
        match self
            .api
            .complete_provider_auth(provider_id.clone(), response, Duration::from_secs(0))
            .await
        {
            Ok(()) => {
                self.overlay = None;
                self.transcript.push(TranscriptEntry::Status(format!(
                    "{provider_id} connected successfully. Use /models to pick a model."
                )));
            }
            Err(error) => {
                self.log_error("connect submit failed", &error);
                self.transcript
                    .push(TranscriptEntry::Error(format!("Connect failed: {error:#}")));
            }
        }
        self.scroll_from_bottom = 0;
    }

    async fn show_workflow_preview(&mut self, goal: String) {
        let agents = self.api.get_agent_infos().await.unwrap_or_default();
        let nodes = build_workflow(&goal, &agents);
        let summary = workflow_summary(&nodes);
        self.reset_overlay_selection_state();
        self.overlay = Some(Overlay::Workflow(WorkflowDialog {
            goal,
            nodes,
            selected_node: 0,
            mode: WorkflowDialogMode::Review,
        }));
        self.transcript.push(TranscriptEntry::Status(format!(
            "Workflow review ready: {summary}. Use ↑↓ to inspect nodes, Enter to approve, e to edit, x to export, Esc to cancel."
        )));
        self.scroll_from_bottom = 0;
    }

    async fn approve_workflow(&mut self, tx: mpsc::UnboundedSender<AppEvent>) -> Result<()> {
        let Some(Overlay::Workflow(dialog)) = self.overlay.clone() else {
            self.transcript.push(TranscriptEntry::Error(
                "No workflow dialog is open. Type /workflow <goal> first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return Ok(());
        };

        self.close_overlay();
        let summary = workflow_summary(&dialog.nodes);
        self.transcript.push(TranscriptEntry::Status(format!(
            "Workflow running in background: {summary}. You can keep chatting; use /workflow status or /workflow trace when you want details."
        )));
        self.scroll_from_bottom = 0;
        self.workflow_run = Some(WorkflowRun {
            dialog: dialog.clone(),
            status: WorkflowRunStatus::Running,
            trace: workflow_start_trace(&dialog),
        });

        let prompt = approved_workflow_prompt(&dialog);
        self.abort_workflow_task();
        self.spawn_workflow(Event::new(prompt), tx).await
    }

    fn export_workflow(&mut self) {
        let output = match self.overlay.as_ref() {
            Some(Overlay::Workflow(dialog)) => export_workflow(dialog),
            _ => match self.workflow_run.as_ref() {
                Some(run) => export_workflow(&run.dialog),
                None => {
                    self.transcript.push(TranscriptEntry::Error(
                        "No workflow is available. Type /workflow <goal> first.".to_string(),
                    ));
                    self.scroll_from_bottom = 0;
                    return;
                }
            },
        };

        self.transcript.push(TranscriptEntry::Status(output));
        self.scroll_from_bottom = 0;
    }

    fn show_workflow_status(&mut self) {
        let Some(run) = self.workflow_run.as_ref() else {
            self.transcript.push(TranscriptEntry::Status(
                "No workflow has run yet. Type /workflow <goal> to start one.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        self.transcript.push(TranscriptEntry::Status(format!(
            "Workflow {}: {}. Use /workflow trace for details.",
            workflow_status_label(run.status),
            workflow_summary(&run.dialog.nodes)
        )));
        self.scroll_from_bottom = 0;
    }

    fn show_workflow_trace(&mut self) {
        let Some(run) = self.workflow_run.as_ref() else {
            self.transcript.push(TranscriptEntry::Status(
                "No workflow trace is available yet.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        self.transcript.push(TranscriptEntry::Status(format!(
            "workflow trace ({})\n{}",
            workflow_status_label(run.status),
            run.trace.join("\n")
        )));
        self.scroll_from_bottom = 0;
    }

    fn edit_workflow_node(&mut self, index: usize, task: String) {
        let Some(Overlay::Workflow(dialog)) = &mut self.overlay else {
            self.transcript.push(TranscriptEntry::Error(
                "No workflow dialog is open. Type /workflow <goal> first.".to_string(),
            ));
            self.scroll_from_bottom = 0;
            return;
        };

        let Some(node) = dialog.nodes.get_mut(index.saturating_sub(1)) else {
            self.transcript.push(TranscriptEntry::Error(format!(
                "Workflow node {index} is out of range."
            )));
            self.scroll_from_bottom = 0;
            return;
        };

        node.task = task;
        dialog.selected_node = index.saturating_sub(1);
        dialog.mode = WorkflowDialogMode::Review;
        self.overlay_input.clear();
        self.transcript.push(TranscriptEntry::Status(format!(
            "Updated workflow node {index}: {}.",
            node.name
        )));
        self.scroll_from_bottom = 0;
    }

    async fn submit_workflow_overlay_input(
        &mut self,
        tx: mpsc::UnboundedSender<AppEvent>,
    ) -> Result<()> {
        let Some(Overlay::Workflow(dialog)) = self.overlay.as_ref() else {
            return Ok(());
        };

        match dialog.mode {
            WorkflowDialogMode::EditTask => {
                let task = self.overlay_input.trim().to_string();
                if task.is_empty() {
                    self.transcript.push(TranscriptEntry::Error(
                        "Type a replacement task, then press Enter.".to_string(),
                    ));
                    self.scroll_from_bottom = 0;
                    return Ok(());
                }
                let index = dialog.selected_node + 1;
                self.edit_workflow_node(index, task);
                Ok(())
            }
            WorkflowDialogMode::Review => {
                match workflow_overlay_action(self.overlay_input.trim()) {
                    WorkflowOverlayAction::Approve => self.approve_workflow(tx).await,
                    WorkflowOverlayAction::Edit => {
                        self.enter_workflow_edit_mode();
                        Ok(())
                    }
                    WorkflowOverlayAction::Export => {
                        self.export_workflow();
                        self.overlay_input.clear();
                        Ok(())
                    }
                    WorkflowOverlayAction::Cancel => {
                        self.close_overlay();
                        self.transcript
                            .push(TranscriptEntry::Status("Workflow cancelled.".to_string()));
                        self.scroll_from_bottom = 0;
                        Ok(())
                    }
                    WorkflowOverlayAction::Select(index) => {
                        self.select_workflow_node(index);
                        self.overlay_input.clear();
                        Ok(())
                    }
                    WorkflowOverlayAction::Invalid(message) => {
                        self.transcript.push(TranscriptEntry::Error(message));
                        self.scroll_from_bottom = 0;
                        Ok(())
                    }
                }
            }
        }
    }

    fn enter_workflow_edit_mode(&mut self) {
        let Some(Overlay::Workflow(dialog)) = &mut self.overlay else {
            return;
        };
        dialog.mode = WorkflowDialogMode::EditTask;
        self.overlay_input.clear();
        self.overlay_scroll_from_top = 0;
    }

    fn cancel_workflow_edit_mode(&mut self) -> bool {
        let Some(Overlay::Workflow(dialog)) = &mut self.overlay else {
            return false;
        };
        if dialog.mode != WorkflowDialogMode::EditTask {
            return false;
        }
        dialog.mode = WorkflowDialogMode::Review;
        self.overlay_input.clear();
        true
    }

    fn workflow_review_shortcut_ready(&self) -> bool {
        matches!(
            self.overlay.as_ref(),
            Some(Overlay::Workflow(WorkflowDialog {
                mode: WorkflowDialogMode::Review,
                ..
            }))
        ) && self.overlay_input.is_empty()
    }

    fn select_workflow_node(&mut self, index: usize) {
        let Some(Overlay::Workflow(dialog)) = &mut self.overlay else {
            return;
        };
        if index == 0 || index > dialog.nodes.len() {
            self.transcript.push(TranscriptEntry::Error(format!(
                "Workflow node {index} is out of range."
            )));
            self.scroll_from_bottom = 0;
            return;
        }
        dialog.selected_node = index - 1;
        dialog.mode = WorkflowDialogMode::Review;
        self.overlay_scroll_from_top = 0;
    }

    fn select_next_workflow_node(&mut self) {
        let Some(Overlay::Workflow(dialog)) = &mut self.overlay else {
            return;
        };
        if dialog.nodes.is_empty() {
            return;
        }
        dialog.selected_node = (dialog.selected_node + 1).min(dialog.nodes.len() - 1);
        self.overlay_scroll_from_top = 0;
    }

    fn select_previous_workflow_node(&mut self) {
        let Some(Overlay::Workflow(dialog)) = &mut self.overlay else {
            return;
        };
        dialog.selected_node = dialog.selected_node.saturating_sub(1);
        self.overlay_scroll_from_top = 0;
    }

    async fn model_stats(&self) -> Option<ModelStats> {
        let config = self.api.get_session_config().await?;
        let models = self.api.get_models().await.ok();
        Some(model_stats_from_config(&config, models.as_deref()))
    }

    fn handle_composer_scroll_key(&mut self, key: KeyEvent) -> bool {
        match composer_scroll_shortcut(key) {
            ComposerScrollShortcut::UpOne => {
                adjust_scroll_offset(
                    &mut self.composer_scroll_from_bottom,
                    ScrollDirection::Up,
                    SCROLL_LINE_STEP,
                );
                true
            }
            ComposerScrollShortcut::DownOne => {
                adjust_scroll_offset(
                    &mut self.composer_scroll_from_bottom,
                    ScrollDirection::Down,
                    SCROLL_LINE_STEP,
                );
                true
            }
            ComposerScrollShortcut::UpPage => {
                adjust_scroll_offset(
                    &mut self.composer_scroll_from_bottom,
                    ScrollDirection::Up,
                    SCROLL_PAGE_STEP,
                );
                true
            }
            ComposerScrollShortcut::DownPage | ComposerScrollShortcut::Bottom => {
                self.composer_scroll_from_bottom = 0;
                true
            }
            ComposerScrollShortcut::Top => {
                self.composer_scroll_from_bottom = usize::MAX;
                true
            }
            ComposerScrollShortcut::None => false,
        }
    }

    fn handle_edit_key(&mut self, key: KeyEvent) -> bool {
        match composer_edit_shortcut(key) {
            ComposerEditShortcut::ClearLine => {
                self.composer.clear();
                self.composer_scroll_from_bottom = 0;
                true
            }
            ComposerEditShortcut::DeletePreviousWord => {
                delete_previous_word(&mut self.composer);
                self.composer_scroll_from_bottom = 0;
                true
            }
            ComposerEditShortcut::None => false,
        }
    }
    fn handle_scroll_key(&mut self, key: KeyEvent) -> bool {
        match key.code {
            KeyCode::Up => {
                adjust_scroll_offset(
                    &mut self.scroll_from_bottom,
                    ScrollDirection::Up,
                    SCROLL_LINE_STEP,
                );
                true
            }
            KeyCode::Down => {
                adjust_scroll_offset(
                    &mut self.scroll_from_bottom,
                    ScrollDirection::Down,
                    SCROLL_LINE_STEP,
                );
                true
            }
            KeyCode::PageUp => {
                adjust_scroll_offset(
                    &mut self.scroll_from_bottom,
                    ScrollDirection::Up,
                    SCROLL_PAGE_STEP,
                );
                true
            }
            KeyCode::PageDown => {
                adjust_scroll_offset(
                    &mut self.scroll_from_bottom,
                    ScrollDirection::Down,
                    SCROLL_PAGE_STEP,
                );
                true
            }
            KeyCode::Home => {
                self.scroll_from_bottom = usize::MAX;
                true
            }
            KeyCode::End => {
                self.scroll_from_bottom = 0;
                true
            }
            _ => false,
        }
    }

    fn handle_tool_key(&mut self, key: KeyEvent) -> bool {
        match tool_shortcut(key) {
            ToolShortcut::Next => {
                self.select_next_tool();
                true
            }
            ToolShortcut::Previous => {
                self.select_previous_tool();
                true
            }
            ToolShortcut::Toggle => {
                self.toggle_selected_tool();
                true
            }
            ToolShortcut::None => false,
        }
    }

    fn select_next_tool(&mut self) {
        let tool_indexes = self.tool_indexes();
        if tool_indexes.is_empty() {
            self.selected_tool = None;
            return;
        }

        self.selected_tool = match self.selected_tool {
            Some(current) => tool_indexes
                .iter()
                .position(|index| *index == current)
                .map(|position| tool_indexes[(position + 1) % tool_indexes.len()])
                .or_else(|| tool_indexes.first().copied()),
            None => tool_indexes.first().copied(),
        };
    }

    fn select_previous_tool(&mut self) {
        let tool_indexes = self.tool_indexes();
        if tool_indexes.is_empty() {
            self.selected_tool = None;
            return;
        }

        self.selected_tool = match self.selected_tool {
            Some(current) => tool_indexes
                .iter()
                .position(|index| *index == current)
                .map(|position| {
                    let previous = position
                        .checked_sub(1)
                        .unwrap_or_else(|| tool_indexes.len().saturating_sub(1));
                    tool_indexes[previous]
                })
                .or_else(|| tool_indexes.first().copied()),
            None => tool_indexes.first().copied(),
        };
    }

    fn toggle_selected_tool(&mut self) {
        let Some(index) = self.selected_tool else {
            return;
        };

        if let Some(TranscriptEntry::Tool(tool)) = self.transcript.get_mut(index) {
            tool.expanded = !tool.expanded;
        }
    }

    fn tool_indexes(&self) -> Vec<usize> {
        self.transcript
            .iter()
            .enumerate()
            .filter_map(|(index, entry)| matches!(entry, TranscriptEntry::Tool(_)).then_some(index))
            .collect()
    }

    fn push_tool(&mut self, tool: ToolEntry) {
        self.transcript.push(TranscriptEntry::Tool(tool));
        self.selected_tool = Some(self.transcript.len().saturating_sub(1));
    }

    fn update_latest_running_tool(&mut self, status: ToolStatus, detail: String) -> bool {
        self.transcript
            .iter_mut()
            .rev()
            .find_map(|entry| match entry {
                TranscriptEntry::Tool(tool) if tool.status == ToolStatus::Running => Some(tool),
                _ => None,
            })
            .map(|tool| {
                tool.status = status;
                if !detail.is_empty() {
                    tool.detail = detail;
                }
            })
            .is_some()
    }

    fn push_workflow_response(&mut self, response: ChatResponse) -> bool {
        let Some(run) = &mut self.workflow_run else {
            return matches!(response, ChatResponse::TaskComplete);
        };

        if response.is_empty() {
            return false;
        }

        match response {
            ChatResponse::TaskMessage { content } => match content {
                ChatResponseContent::Markdown { text, .. } => {
                    append_trace_chunk(&mut run.trace, text);
                }
                ChatResponseContent::ToolInput(title) => {
                    let detail = title.sub_title.unwrap_or_default();
                    if detail.is_empty() {
                        run.trace.push("tool input".to_string());
                    } else {
                        run.trace.push(format!("tool input: {detail}"));
                    }
                }
                ChatResponseContent::ToolOutput(text) => {
                    let detail = compact_tool_output(&text);
                    if !detail.is_empty() {
                        run.trace.push(format!("tool output: {detail}"));
                    }
                }
            },
            ChatResponse::TaskReasoning { content } => {
                if !content.trim().is_empty() {
                    append_trace_chunk(&mut run.trace, format!("reasoning: {content}"));
                }
            }
            ChatResponse::ToolCallStart { tool_call, notifier } => {
                run.trace.push(format!("tool started: {}", tool_call.name));
                notifier.notify_one();
            }
            ChatResponse::ToolCallEnd(result) => {
                let status = if result.is_error() { "failed" } else { "done" };
                run.trace
                    .push(format!("tool finished: {} [{status}]", result.name));
            }
            ChatResponse::RetryAttempt { cause, duration } => {
                run.trace.push(format!(
                    "retrying in {}s: {}",
                    duration.as_secs(),
                    cause.as_str()
                ));
            }
            ChatResponse::Interrupt { reason } => {
                run.status = WorkflowRunStatus::Interrupted;
                run.trace.push(format!("interrupted: {reason:?}"));
                self.transcript.push(TranscriptEntry::Error(
                    "Background workflow was interrupted. Use /workflow trace for details."
                        .to_string(),
                ));
                self.scroll_from_bottom = 0;
                return true;
            }
            ChatResponse::TaskComplete => return true,
        }

        false
    }

    async fn push_chat_response(&mut self, response: ChatResponse) -> bool {
        if response.is_empty() {
            return false;
        }

        match response {
            ChatResponse::TaskMessage { content } => match content {
                ChatResponseContent::Markdown { text, .. } => self.append_assistant(text),
                ChatResponseContent::ToolInput(title) => {
                    let detail = title.sub_title.unwrap_or_default();
                    if !detail.is_empty() {
                        self.update_latest_running_tool(ToolStatus::Running, detail);
                    }
                }
                ChatResponseContent::ToolOutput(text) => {
                    let detail = compact_tool_output(&text);
                    if !self.update_latest_running_tool(ToolStatus::Running, detail.clone()) {
                        self.push_tool(ToolEntry::info("Tool output", detail));
                    }
                }
            },
            ChatResponse::TaskReasoning { content: _ } => {
                self.status = TuiStatus::Reasoning;
            }
            ChatResponse::ToolCallStart { tool_call, notifier } => {
                self.push_tool(ToolEntry::running(tool_call.name.to_string()));
                notifier.notify_one();
            }
            ChatResponse::ToolCallEnd(result) => {
                let status = if result.is_error() {
                    ToolStatus::Failed
                } else {
                    ToolStatus::Done
                };
                if !self.update_latest_running_tool(status, String::new()) {
                    self.push_tool(ToolEntry::finished(result.name.to_string(), status));
                }
            }
            ChatResponse::RetryAttempt { cause, duration } => {
                self.transcript.push(TranscriptEntry::Status(format!(
                    "Retrying in {}s: {}",
                    duration.as_secs(),
                    cause.as_str()
                )));
            }
            ChatResponse::Interrupt { reason } => {
                self.abort_chat_task();
                self.finish_streaming(TuiStatus::Interrupted);
                self.transcript
                    .push(TranscriptEntry::Error(format!("Interrupted: {reason:?}")));
            }
            ChatResponse::TaskComplete => {
                self.abort_chat_task();
                self.finish_streaming(TuiStatus::Finished);
                return true;
            }
        }

        false
    }

    fn append_assistant(&mut self, text: String) {
        append_assistant_entry(&mut self.transcript, text);
    }

    fn render(&self, frame: &mut ratatui::Frame<'_>) {
        let area = frame.area();
        frame.render_widget(Clear, area);
        let composer_width = area.width.saturating_sub(2) as usize;
        let composer_lines = self.composer_lines(composer_width);
        let composer_height = composer_height(area.height, composer_lines.len());

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Min(1),
                Constraint::Length(composer_height),
            ])
            .split(area);

        let background_style = if self.overlay.is_some() {
            Style::default().fg(Color::DarkGray).bg(Color::Black)
        } else {
            Style::default()
        };
        let composer_style = if self.overlay.is_some() || self.is_streaming {
            Style::default().fg(Color::DarkGray).bg(Color::Black)
        } else {
            Style::default()
        };

        let header = Paragraph::new(header_line(
            self.status,
            self.active_model.as_deref(),
            chunks[0].width.saturating_sub(2) as usize,
        ))
        .style(background_style)
        .block(Block::default().borders(Borders::ALL));
        frame.render_widget(header, chunks[0]);

        let transcript_lines = self.transcript_lines(chunks[1].width.saturating_sub(2) as usize);
        let transcript_inner_height = chunks[1].height.saturating_sub(2) as usize;
        let max_scroll = transcript_lines
            .len()
            .saturating_sub(transcript_inner_height);
        let scroll_from_bottom = self.scroll_from_bottom.min(max_scroll);
        let transcript_scroll = max_scroll
            .saturating_sub(scroll_from_bottom)
            .min(u16::MAX as usize) as u16;
        let chat_title = chat_title(area.width);
        let transcript = Paragraph::new(transcript_lines)
            .style(background_style)
            .block(Block::default().title(chat_title).borders(Borders::ALL))
            .scroll((transcript_scroll, 0));
        frame.render_widget(transcript, chunks[1]);

        let composer_inner_height = chunks[2].height.saturating_sub(2) as usize;
        let max_composer_scroll = composer_lines.len().saturating_sub(composer_inner_height);
        let composer_scroll_from_bottom = self.composer_scroll_from_bottom.min(max_composer_scroll);
        let composer_scroll = max_composer_scroll
            .saturating_sub(composer_scroll_from_bottom)
            .min(u16::MAX as usize) as u16;
        let prompt_title = prompt_title(area.width);
        let composer = Paragraph::new(composer_lines)
            .style(composer_style)
            .block(Block::default().title(prompt_title).borders(Borders::ALL))
            .scroll((composer_scroll, 0));
        frame.render_widget(composer, chunks[2]);

        if let Some(overlay) = &self.overlay {
            let dialog_area = overlay_area(area);
            frame.render_widget(Clear, dialog_area);
            let dialog_inner_height = dialog_area.height.saturating_sub(2) as usize;
            match overlay {
                Overlay::Connect(dialog) => {
                    let lines = connect_dialog_lines(
                        dialog,
                        dialog_area.width.saturating_sub(2) as usize,
                        self.overlay_input.as_str(),
                    );
                    let max_overlay_scroll = lines.len().saturating_sub(dialog_inner_height);
                    let overlay_scroll = self
                        .overlay_scroll_from_top
                        .min(max_overlay_scroll)
                        .min(u16::MAX as usize) as u16;
                    let dialog = Paragraph::new(lines)
                        .block(
                            Block::default()
                                .title("Connect provider")
                                .borders(Borders::ALL),
                        )
                        .scroll((overlay_scroll, 0));
                    frame.render_widget(dialog, dialog_area);
                }
                Overlay::Model(dialog) => {
                    let lines = model_dialog_lines(
                        dialog,
                        dialog_area.width.saturating_sub(2) as usize,
                        self.overlay_input.as_str(),
                    );
                    let max_overlay_scroll = lines.len().saturating_sub(dialog_inner_height);
                    let overlay_scroll = self
                        .overlay_scroll_from_top
                        .min(max_overlay_scroll)
                        .min(u16::MAX as usize) as u16;
                    let dialog = Paragraph::new(lines)
                        .block(Block::default().title("Select model").borders(Borders::ALL))
                        .scroll((overlay_scroll, 0));
                    frame.render_widget(dialog, dialog_area);
                }
                Overlay::Workflow(dialog) => {
                    let lines = workflow_dialog_lines(
                        dialog,
                        dialog_area.width.saturating_sub(2) as usize,
                        self.overlay_input.as_str(),
                    );
                    let max_overlay_scroll = lines.len().saturating_sub(dialog_inner_height);
                    let overlay_scroll = self
                        .overlay_scroll_from_top
                        .min(max_overlay_scroll)
                        .min(u16::MAX as usize) as u16;
                    let dialog = Paragraph::new(lines)
                        .block(
                            Block::default()
                                .title("Review workflow topology")
                                .borders(Borders::ALL),
                        )
                        .scroll((overlay_scroll, 0));
                    frame.render_widget(dialog, dialog_area);
                }
            }
        }
    }

    fn composer_lines(&self, width: usize) -> Vec<Line<'static>> {
        build_composer_lines(&self.composer, &self.image_attachments, width)
    }

    fn transcript_lines(&self, width: usize) -> Vec<Line<'static>> {
        let mut lines = Vec::new();

        for (entry_index, entry) in self.transcript.iter().enumerate() {
            match entry {
                TranscriptEntry::User(message) => {
                    push_user_message_lines(&mut lines, message, width)
                }
                TranscriptEntry::Assistant(text) => {
                    push_markdown_message_lines(&mut lines, "CodeGraff", text, width)
                }
                TranscriptEntry::Tool(tool) => push_tool_lines(
                    &mut lines,
                    tool,
                    self.selected_tool == Some(entry_index),
                    width,
                ),
                TranscriptEntry::Error(text) => push_wrapped(
                    &mut lines,
                    "Error",
                    text,
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                    width,
                ),
                TranscriptEntry::Status(text) => push_wrapped(
                    &mut lines,
                    "Status",
                    text,
                    Style::default()
                        .fg(Color::Blue)
                        .add_modifier(Modifier::BOLD),
                    width,
                ),
            }
            lines.push(Line::raw(""));
        }

        lines
    }
}

fn model_label(option: &ModelOption) -> String {
    short_model_label(option.provider_id.to_string(), option.model.id.as_str())
}

fn model_config_label(config: &ModelConfig) -> String {
    short_model_label(config.provider.to_string(), config.model.as_str())
}

fn short_model_label(provider: impl AsRef<str>, model: &str) -> String {
    let model = model
        .rsplit('/')
        .next()
        .filter(|model| !model.is_empty())
        .unwrap_or(model);
    format!("{}:{}", provider.as_ref(), model)
}

fn format_model_option(index: usize, option: &ModelOption) -> String {
    let mut details = Vec::new();
    if let Some(name) = option.model.name.as_deref().filter(|name| !name.is_empty()) {
        details.push(name.to_string());
    }
    if let Some(context) = option.model.context_length {
        details.push(format!("context {}", format_context_length(context)));
    }
    if option.model.tools_supported == Some(true) {
        details.push("tools".to_string());
    }
    if option.model.supports_reasoning == Some(true) {
        details.push("reasoning".to_string());
    }
    if option
        .model
        .input_modalities
        .contains(&InputModality::Image)
    {
        details.push("image".to_string());
    }

    let suffix = if details.is_empty() {
        String::new()
    } else {
        format!(" ({})", details.join(" · "))
    };

    format!("{index}. {option}{suffix}")
}

fn format_context_length(limit: u64) -> String {
    if limit >= 1_000_000 {
        format!("{}M", limit / 1_000_000)
    } else if limit >= 1_000 {
        format!("{}k", limit / 1_000)
    } else {
        limit.to_string()
    }
}

fn parse_model_command(input: &str) -> ModelCommand {
    let Some(rest) = input.strip_prefix("/models") else {
        return ModelCommand::NotCommand;
    };

    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return ModelCommand::NotCommand;
    }

    let selector = rest.trim();
    if selector.is_empty() {
        return ModelCommand::List;
    }

    if selector == "cancel" {
        return ModelCommand::Cancel;
    }

    match selector.parse::<usize>() {
        Ok(index) if index > 0 => ModelCommand::Select(index),
        _ => ModelCommand::Invalid(
            "Usage: /models to choose models, /models <number> to switch, or /models cancel."
                .to_string(),
        ),
    }
}

fn parse_login_command(input: &str) -> ConnectCommand {
    parse_provider_auth_command(input, "/login")
}

fn parse_connect_command(input: &str) -> ConnectCommand {
    parse_provider_auth_command(input, "/connect")
}

fn parse_provider_auth_command(input: &str, prefix: &str) -> ConnectCommand {
    let Some(rest) = input.strip_prefix(prefix) else {
        return ConnectCommand::NotCommand;
    };

    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return ConnectCommand::NotCommand;
    }

    let command = rest.trim();
    if command.is_empty() {
        return ConnectCommand::Open;
    }

    if command == "submit" {
        return ConnectCommand::Submit;
    }

    if command == "cancel" {
        return ConnectCommand::Cancel;
    }

    if let Some(selector) = command.strip_prefix("auth ") {
        return match selector.trim().parse::<usize>() {
            Ok(index) if index > 0 => ConnectCommand::AuthMethod(index),
            _ => ConnectCommand::Invalid(format!(
                "Usage: {prefix} auth <number> to choose an auth method."
            )),
        };
    }

    if let Some(update) = command.strip_prefix("set ") {
        let update = update.trim();
        if update.is_empty() {
            return ConnectCommand::Invalid(format!(
                "Usage: {prefix} set <field>=<value> to edit the provider login form."
            ));
        }
        return ConnectCommand::Field(update.to_string());
    }

    match command.parse::<usize>() {
        Ok(index) if index > 0 => ConnectCommand::Provider(index),
        _ => ConnectCommand::Invalid(format!(
            "Usage: {prefix}, {prefix} <number>, {prefix} auth <number>, {prefix} set <field>=<value>, {prefix} submit, or {prefix} cancel."
        )),
    }
}

fn parse_connect_field_update(update: &str) -> ConnectFieldUpdate {
    let Some((name, value)) = update.split_once('=') else {
        return ConnectFieldUpdate::Invalid(
            "Usage: /login set <field>=<value>. Use `key` for the API key.".to_string(),
        );
    };

    let name = name.trim();
    let value = value.trim().to_string();
    if name.is_empty() {
        return ConnectFieldUpdate::Invalid("Connect field name cannot be empty.".to_string());
    }

    match name {
        "key" | "api_key" | "apikey" => ConnectFieldUpdate::ApiKey(value),
        name => ConnectFieldUpdate::UrlParam { name: name.to_string(), value },
    }
}

fn parse_workflow_command(input: &str) -> WorkflowCommand {
    let Some(rest) = input
        .strip_prefix("/workflow")
        .or_else(|| input.strip_prefix(":workflow"))
    else {
        return WorkflowCommand::NotCommand;
    };

    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return WorkflowCommand::NotCommand;
    }

    let command = rest.trim();
    if command.is_empty() {
        return WorkflowCommand::Invalid(
            "Usage: /workflow <goal> to open a workflow review dialog.".to_string(),
        );
    }

    match command {
        "approve" | "run" => return WorkflowCommand::Approve,
        "cancel" => return WorkflowCommand::Cancel,
        "export" | "dump" => return WorkflowCommand::Export,
        _ => {}
    }

    if let Some(edit) = command.strip_prefix("edit ") {
        let Some((index, task)) = edit.trim().split_once(char::is_whitespace) else {
            return WorkflowCommand::Invalid(
                "Usage: /workflow edit <number> <replacement task>.".to_string(),
            );
        };
        return match (index.trim().parse::<usize>(), task.trim()) {
            (Ok(index), task) if index > 0 && !task.is_empty() => {
                WorkflowCommand::Edit(index, task.to_string())
            }
            _ => WorkflowCommand::Invalid(
                "Usage: /workflow edit <number> <replacement task>.".to_string(),
            ),
        };
    }

    WorkflowCommand::Open(unquote_workflow_goal(command))
}

fn unquote_workflow_goal(goal: &str) -> String {
    let goal = goal.trim();
    if goal.len() >= 2
        && ((goal.starts_with('"') && goal.ends_with('"'))
            || (goal.starts_with('\'') && goal.ends_with('\'')))
    {
        goal[1..goal.len() - 1].trim().to_string()
    } else {
        goal.to_string()
    }
}

fn workflow_overlay_action(input: &str) -> WorkflowOverlayAction {
    let action = input.trim();
    if action.is_empty() || matches!(action, "a" | "approve" | "run") {
        return WorkflowOverlayAction::Approve;
    }

    match action {
        "e" | "edit" => WorkflowOverlayAction::Edit,
        "x" | "export" | "dump" => WorkflowOverlayAction::Export,
        "c" | "cancel" => WorkflowOverlayAction::Cancel,
        _ => match action.parse::<usize>() {
            Ok(index) if index > 0 => WorkflowOverlayAction::Select(index),
            _ => WorkflowOverlayAction::Invalid(
                "Workflow dialog actions: Enter/a approve, e edit, x export, c cancel, or a node number."
                    .to_string(),
            ),
        },
    }
}

fn build_workflow(goal: &str, agents: &[AgentInfo]) -> Vec<WorkflowNode> {
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
            WorkflowNode {
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

fn workflow_summary(nodes: &[WorkflowNode]) -> String {
    nodes
        .iter()
        .map(|node| format!("{}({})", node.name, node.worker))
        .collect::<Vec<_>>()
        .join(" -> ")
}

fn export_workflow(dialog: &WorkflowDialog) -> String {
    let mut output = format!(
        "workflow:\n  goal: {}\n  topology: {}",
        dialog.goal,
        workflow_summary(&dialog.nodes)
    );
    for (index, node) in dialog.nodes.iter().enumerate() {
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

fn workflow_start_trace(dialog: &WorkflowDialog) -> Vec<String> {
    let mut trace = vec![
        format!("goal: {}", dialog.goal),
        format!("topology: {}", workflow_summary(&dialog.nodes)),
    ];
    trace.extend(dialog.nodes.iter().enumerate().map(|(index, node)| {
        format!(
            "node {}: {}({}) · artifact: {} · stop: {}",
            index + 1,
            node.name,
            node.worker,
            node.artifact,
            node.stop_condition
        )
    }));
    trace
}

fn workflow_status_label(status: WorkflowRunStatus) -> &'static str {
    match status {
        WorkflowRunStatus::Running => "running",
        WorkflowRunStatus::Finished => "finished",
        WorkflowRunStatus::Error => "failed",
        WorkflowRunStatus::Interrupted => "interrupted",
    }
}

fn append_trace_chunk(trace: &mut Vec<String>, text: String) {
    if text.trim().is_empty() {
        return;
    }

    if let Some(last) = trace.last_mut()
        && !last.starts_with("tool ")
        && !last.starts_with("retrying ")
        && !last.starts_with("node ")
        && !last.starts_with("goal:")
        && !last.starts_with("topology:")
        && last.len().saturating_add(text.len()) <= 2_000
    {
        last.push_str(&text);
        return;
    }

    trace.push(text);
}

fn approved_workflow_prompt(dialog: &WorkflowDialog) -> String {
    format!(
        "Run this approved CodeGraff workflow topology. Execute the nodes in dependency order, respect each node's access list, and log each produced artifact.\n\n{}",
        export_workflow(dialog)
    )
}

fn build_api_key_form(provider_id: &ProviderId, request: &ApiKeyRequest) -> ApiKeyForm {
    let api_key = request
        .api_key
        .as_ref()
        .map(|key| key.as_ref().to_string())
        .unwrap_or_else(|| {
            if allows_local_api_key(provider_id) {
                "local".to_string()
            } else {
                String::new()
            }
        });

    let existing_params = request.existing_params.as_ref();
    let url_params = request
        .required_params
        .iter()
        .map(|param| connect_field_from_param(param, existing_params))
        .collect();

    ApiKeyForm { api_key, url_params }
}

fn connect_field_from_param(
    param: &URLParamSpec,
    existing_params: Option<&forge_api::URLParameters>,
) -> ConnectField {
    let existing = existing_params
        .and_then(|params| params.get(&param.name))
        .map(|value| value.as_str().to_string());
    let value = existing
        .or_else(|| {
            param
                .options
                .as_ref()
                .and_then(|options| options.first().cloned())
        })
        .unwrap_or_default();
    ConnectField::new(param.name.to_string(), value, param.options.clone())
}

fn allows_local_api_key(provider_id: &ProviderId) -> bool {
    matches!(
        provider_id.as_ref().as_ref(),
        "ollama" | "vllm" | "lm_studio" | "llama_cpp" | "jan_ai"
    )
}

fn model_dialog_lines(dialog: &ModelDialog, width: usize, input: &str) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    push_dialog_line(&mut lines, "Choose model", width);
    push_dialog_line(
        &mut lines,
        "Type a number here and press Enter. Esc closes this dialog.",
        width,
    );
    push_dialog_line(&mut lines, &dialog_input_line("Selection", input), width);
    lines.push(Line::raw(""));
    for (index, option) in dialog.options.iter().enumerate() {
        push_dialog_line(&mut lines, &format_model_option(index + 1, option), width);
    }
    lines
}

fn connect_dialog_lines(dialog: &ConnectDialog, width: usize, input: &str) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    match &dialog.step {
        ConnectStep::ProviderSelection { providers } => {
            push_dialog_line(&mut lines, dialog.intent.title(), width);
            push_dialog_line(
                &mut lines,
                "Type a number here and press Enter. Esc closes this dialog.",
                width,
            );
            push_dialog_line(&mut lines, &dialog_input_line("Selection", input), width);
            lines.push(Line::raw(""));
            for (index, provider) in providers.iter().enumerate() {
                push_dialog_line(
                    &mut lines,
                    &format_connect_provider_option(index + 1, provider),
                    width,
                );
            }
        }
        ConnectStep::AuthMethodSelection { provider, methods } => {
            push_dialog_line(&mut lines, &format!("Provider: {}", provider.id()), width);
            push_dialog_line(
                &mut lines,
                "Type a number here and press Enter. Esc closes this dialog.",
                width,
            );
            push_dialog_line(&mut lines, &dialog_input_line("Selection", input), width);
            lines.push(Line::raw(""));
            for (index, method) in methods.iter().enumerate() {
                push_dialog_line(
                    &mut lines,
                    &format!("{}. {}", index + 1, auth_method_label(method)),
                    width,
                );
            }
        }
        ConnectStep::ApiKeyInput { provider, form, .. } => {
            push_dialog_line(&mut lines, &format!("Provider: {}", provider.id()), width);
            push_dialog_line(
                &mut lines,
                "Type key=<api-key>, field=<value>, submit, or cancel directly in this dialog.",
                width,
            );
            push_dialog_line(&mut lines, &dialog_input_line("Input", input), width);
            lines.push(Line::raw(""));
            let key_state = if form.api_key.trim().is_empty() {
                "<empty>"
            } else {
                "<set, hidden>"
            };
            push_dialog_line(&mut lines, &format!("key = {key_state}"), width);
            push_dialog_line(&mut lines, "  type key=<api-key>", width);

            for field in &form.url_params {
                let value = if field.value.is_empty() {
                    "<empty>"
                } else {
                    &field.value
                };
                push_dialog_line(&mut lines, &format!("{} = {value}", field.name), width);
                if let Some(options) = &field.options {
                    push_dialog_line(
                        &mut lines,
                        &format!("  options: {}", options.join(", ")),
                        width,
                    );
                }
                push_dialog_line(&mut lines, &format!("  type {}=<value>", field.name), width);
            }

            lines.push(Line::raw(""));
            push_dialog_line(&mut lines, "submit  ·  cancel", width);
        }
    }
    lines
}

fn workflow_dialog_lines(dialog: &WorkflowDialog, width: usize, input: &str) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    push_dialog_line(&mut lines, &format!("Goal: {}", dialog.goal), width);
    push_dialog_line(
        &mut lines,
        &format!("Topology: {}", workflow_summary(&dialog.nodes)),
        width,
    );
    lines.push(Line::raw(""));
    match dialog.mode {
        WorkflowDialogMode::Review => {
            push_dialog_line(
                &mut lines,
                "Use ↑↓ or type a node number to inspect. Enter/a approves, e edits selected task, x exports, c/Esc cancels.",
                width,
            );
            push_dialog_line(&mut lines, &dialog_input_line("Action", input), width);
        }
        WorkflowDialogMode::EditTask => {
            push_dialog_line(
                &mut lines,
                "Editing selected node task. Type the replacement task and press Enter. Esc returns to review.",
                width,
            );
            push_dialog_line(&mut lines, &dialog_input_line("Task", input), width);
        }
    }
    lines.push(Line::raw(""));

    for (index, node) in dialog.nodes.iter().enumerate() {
        let marker = if index == dialog.selected_node {
            "▶"
        } else {
            " "
        };
        push_dialog_line(
            &mut lines,
            &format!("{marker} {}. {} ({})", index + 1, node.name, node.worker),
            width,
        );
        if index == dialog.selected_node {
            push_dialog_line(&mut lines, &format!("   task: {}", node.task), width);
            push_dialog_line(
                &mut lines,
                &format!("   dependencies: {}", list_or_none(&node.dependencies)),
                width,
            );
            push_dialog_line(
                &mut lines,
                &format!("   access: {}", list_or_none(&node.access)),
                width,
            );
            push_dialog_line(
                &mut lines,
                &format!("   artifact: {}", node.artifact),
                width,
            );
            push_dialog_line(
                &mut lines,
                &format!("   stop: {}", node.stop_condition),
                width,
            );
            lines.push(Line::raw(""));
        }
    }

    lines
}

fn dialog_input_line(label: &str, input: &str) -> String {
    if input.is_empty() {
        format!("{label}: ▌")
    } else {
        format!("{label}: {input}▌")
    }
}

fn list_or_none(values: &[String]) -> String {
    if values.is_empty() {
        "none".to_string()
    } else {
        values.join(", ")
    }
}

fn push_dialog_line(lines: &mut Vec<Line<'static>>, text: &str, width: usize) {
    for line in wrap_line(text, width.max(1)) {
        lines.push(Line::raw(line));
    }
}

fn format_connect_provider_option(index: usize, provider: &ProviderOption) -> String {
    let state = if provider.is_configured() {
        "connected"
    } else {
        "not connected"
    };
    let methods = provider
        .auth_methods()
        .iter()
        .map(auth_method_label)
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "{index}. {} ({state}) · {} · {}",
        provider.id(),
        provider.host(),
        methods
    )
}

fn auth_method_label(method: &AuthMethod) -> &'static str {
    match method {
        AuthMethod::ApiKey => "API key",
        AuthMethod::OAuthDevice(_) => "OAuth device",
        AuthMethod::OAuthCode(_) => "OAuth code",
        AuthMethod::GoogleAdc => "Google ADC",
        AuthMethod::AwsProfile => "AWS profile",
        AuthMethod::CodexDevice(_) => "Codex device",
    }
}

fn overlay_area(area: Rect) -> Rect {
    let width = area.width.min(96).min(area.width.saturating_sub(4)).max(1);
    let height = area
        .height
        .min(18)
        .min(area.height.saturating_sub(4))
        .max(1);
    let x = area.x + area.width.saturating_sub(width + 2);
    let y = area.y + 2.min(area.height.saturating_sub(height));

    Rect::new(x, y, width, height)
}

fn model_stats_from_config(config: &ModelConfig, models: Option<&[Model]>) -> ModelStats {
    let matched_model = models.and_then(|models| {
        models
            .iter()
            .find(|model| model.id.as_str() == config.model.as_str())
    });

    ModelStats {
        provider: config.provider.to_string(),
        id: config.model.as_str().to_string(),
        name: matched_model.and_then(|model| model.name.clone()),
        context_length: matched_model
            .and_then(|model| model.context_length)
            .map(|count| count.to_string()),
        tools_supported: matched_model.and_then(|model| model.tools_supported),
        supports_parallel_tool_calls: matched_model
            .and_then(|model| model.supports_parallel_tool_calls),
        supports_reasoning: matched_model.and_then(|model| model.supports_reasoning),
        input_modalities: matched_model
            .map(|model| {
                model
                    .input_modalities
                    .iter()
                    .map(|modality| format!("{modality:?}").to_lowercase())
                    .collect()
            })
            .unwrap_or_default(),
    }
}

fn image_display_name(image: &ImageAttachment) -> String {
    Path::new(&image.path)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| image.path.clone())
}

fn image_compact_label(image: &ImageAttachment) -> String {
    match &image.preview {
        Some(preview) => format!(
            "{} · {}x{}",
            image_display_name(image),
            preview.width,
            preview.height
        ),
        None => image_display_name(image),
    }
}

fn push_user_message_lines(lines: &mut Vec<Line<'static>>, message: &UserMessage, width: usize) {
    push_wrapped(
        lines,
        "You",
        &message.text,
        Style::default()
            .fg(Color::Green)
            .add_modifier(Modifier::BOLD),
        width,
    );

    for (index, image) in message.images.iter().enumerate() {
        push_image_summary_lines(lines, image, index + 1, width);
    }
}

fn push_image_chip_lines(
    lines: &mut Vec<Line<'static>>,
    image: &ImageAttachment,
    index: usize,
    width: usize,
) {
    let label = truncate_single_line(&image_compact_label(image), width.saturating_sub(12).max(8));
    lines.push(Line::from(vec![
        Span::styled(
            format!("  ◼ Img {index} "),
            Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(label, Style::default().fg(Color::DarkGray)),
    ]));
}

fn push_image_summary_lines(
    lines: &mut Vec<Line<'static>>,
    image: &ImageAttachment,
    index: usize,
    width: usize,
) {
    let label = truncate_single_line(&image_compact_label(image), width.saturating_sub(14).max(8));
    lines.push(Line::from(vec![
        Span::styled(
            format!("  ◼ Image {index} "),
            Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(label, Style::default().fg(Color::DarkGray)),
    ]));
}

fn load_image_preview(path: &Path) -> Result<ImagePreview> {
    let image = image::open(path)
        .with_context(|| format!("Failed to open image preview for {}", path.display()))?
        .to_luma8();
    let (width, height) = image.dimensions();
    anyhow::ensure!(width > 0 && height > 0, "image has no pixels");

    let resized = image::imageops::resize(
        &image,
        IMAGE_THUMBNAIL_COLUMNS as u32,
        IMAGE_THUMBNAIL_ROWS as u32,
        image::imageops::FilterType::Triangle,
    );

    let mut thumbnail = Vec::new();
    for y in 0..IMAGE_THUMBNAIL_ROWS as u32 {
        let mut row = String::new();
        for x in 0..IMAGE_THUMBNAIL_COLUMNS as u32 {
            let luminance = resized.get_pixel(x, y).0[0];
            row.push(luminance_char(luminance));
        }
        thumbnail.push(row);
    }

    Ok(ImagePreview { width, height, thumbnail })
}

fn luminance_char(luminance: u8) -> char {
    match luminance {
        0..=31 => ' ',
        32..=63 => '░',
        64..=127 => '▒',
        128..=191 => '▓',
        _ => '█',
    }
}

fn push_markdown_message_lines(
    lines: &mut Vec<Line<'static>>,
    label: &str,
    text: &str,
    width: usize,
) {
    let label_style = Style::default()
        .fg(Color::Cyan)
        .add_modifier(Modifier::BOLD);
    let mut in_code_block = false;
    let mut emitted_first_line = false;

    let sanitized_text = sanitize_render_text(text);
    for physical_line in sanitized_text.lines() {
        let trimmed = physical_line.trim_start();
        if trimmed.starts_with("```") {
            let language = trimmed.trim_start_matches('`').trim();
            let fence_label = if in_code_block {
                "╰─".to_string()
            } else if language.is_empty() {
                "╭─ code".to_string()
            } else {
                format!("╭─ {language}")
            };
            push_markdown_wrapped_spans(
                lines,
                label,
                vec![Span::styled(
                    fence_label,
                    Style::default().fg(Color::DarkGray),
                )],
                0,
                label_style,
                width,
                &mut emitted_first_line,
            );
            in_code_block = !in_code_block;
            continue;
        }

        let rendered = markdown_line_spans(physical_line, in_code_block);
        push_markdown_wrapped_spans(
            lines,
            label,
            rendered.spans,
            rendered.continuation_columns,
            label_style,
            width,
            &mut emitted_first_line,
        );
    }

    if !emitted_first_line {
        push_wrapped(lines, label, "", label_style, width);
    }
}

struct MarkdownLine {
    spans: Vec<Span<'static>>,
    continuation_columns: usize,
}

fn markdown_line_spans(line: &str, in_code_block: bool) -> MarkdownLine {
    if in_code_block {
        return MarkdownLine {
            spans: vec![
                Span::styled("│ ", Style::default().fg(Color::DarkGray)),
                Span::styled(line.to_string(), Style::default().fg(Color::LightBlue)),
            ],
            continuation_columns: 2,
        };
    }

    let indent = line.len().saturating_sub(line.trim_start().len());
    let trimmed = line.trim_start();
    if trimmed.is_empty() {
        return MarkdownLine { spans: vec![Span::raw("")], continuation_columns: 0 };
    }

    if markdown_horizontal_rule(trimmed) {
        return MarkdownLine {
            spans: vec![Span::styled(
                "─".repeat(24),
                Style::default().fg(Color::DarkGray),
            )],
            continuation_columns: 0,
        };
    }

    if let Some((level, heading)) = markdown_heading(trimmed) {
        let style = match level {
            1 => Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            2 => Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
            _ => Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        };
        return MarkdownLine {
            spans: vec![
                Span::styled(heading_marker(level), style),
                Span::styled(strip_inline_markdown(heading), style),
            ],
            continuation_columns: 2,
        };
    }

    if let Some(quote) = trimmed.strip_prefix("> ") {
        let mut spans = vec![Span::styled("▌ ", Style::default().fg(Color::Blue))];
        spans.extend(inline_markdown_spans(
            quote,
            Style::default()
                .fg(Color::LightBlue)
                .add_modifier(Modifier::ITALIC),
        ));
        return MarkdownLine { spans, continuation_columns: 2 };
    }

    if let Some((marker, item)) = markdown_list_item(trimmed) {
        let prefix = format!("{}{} ", " ".repeat(indent), marker);
        let continuation_columns = prefix.chars().count();
        let mut spans = vec![Span::styled(prefix, Style::default().fg(Color::LightGreen))];
        spans.extend(inline_markdown_spans(
            item,
            Style::default().fg(Color::Reset),
        ));
        return MarkdownLine { spans, continuation_columns };
    }

    let mut spans = Vec::new();
    if indent > 0 {
        spans.push(Span::raw(" ".repeat(indent)));
    }
    spans.extend(inline_markdown_spans(trimmed, Style::default()));
    MarkdownLine { spans, continuation_columns: indent }
}

fn heading_marker(level: usize) -> &'static str {
    match level {
        1 => "▰ ",
        2 => "◆ ",
        _ => "◇ ",
    }
}

fn markdown_horizontal_rule(trimmed: &str) -> bool {
    matches!(trimmed, "---" | "***" | "___")
}

fn markdown_heading(trimmed: &str) -> Option<(usize, &str)> {
    let level = trimmed.chars().take_while(|ch| *ch == '#').count();
    if !(1..=6).contains(&level) {
        return None;
    }

    trimmed
        .chars()
        .nth(level)
        .filter(|ch| ch.is_whitespace())
        .map(|_| (level, trimmed[level..].trim()))
}

fn markdown_list_item(trimmed: &str) -> Option<(String, &str)> {
    if let Some(item) = trimmed
        .strip_prefix("- [x] ")
        .or_else(|| trimmed.strip_prefix("* [x] "))
    {
        return Some(("☑".to_string(), item));
    }

    if let Some(item) = trimmed
        .strip_prefix("- [ ] ")
        .or_else(|| trimmed.strip_prefix("* [ ] "))
    {
        return Some(("☐".to_string(), item));
    }

    if let Some(item) = trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
    {
        return Some(("•".to_string(), item));
    }

    let dot_index = trimmed.find(". ")?;
    let marker = &trimmed[..dot_index];
    if marker.is_empty() || !marker.chars().all(|ch| ch.is_ascii_digit()) {
        return None;
    }

    Some((format!("{marker}."), trimmed[dot_index + 2..].trim_start()))
}

fn inline_markdown_spans(text: &str, base_style: Style) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    let mut remaining = text;

    while !remaining.is_empty() {
        let Some((position, marker)) = next_inline_marker(remaining) else {
            push_inline_text(&mut spans, remaining, base_style);
            break;
        };

        if position > 0 {
            push_inline_text(&mut spans, &remaining[..position], base_style);
            remaining = &remaining[position..];
            continue;
        }

        if marker == "`"
            && let Some(end) = remaining[1..].find('`')
        {
            let code = &remaining[1..1 + end];
            spans.push(Span::styled(
                format!(" {code} "),
                Style::default().fg(Color::Yellow).bg(Color::Black),
            ));
            remaining = &remaining[end + 2..];
            continue;
        }

        if marker == "["
            && let Some((label, url, consumed)) = markdown_link(remaining)
        {
            spans.push(Span::styled(
                label.to_string(),
                base_style
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::UNDERLINED),
            ));
            spans.push(Span::styled(
                format!(" ({url})"),
                Style::default().fg(Color::DarkGray),
            ));
            remaining = &remaining[consumed..];
            continue;
        }

        if marker == "**"
            && let Some(end) = remaining[2..].find("**")
        {
            let bold = &remaining[2..2 + end];
            spans.push(Span::styled(
                strip_inline_markdown(bold),
                base_style.add_modifier(Modifier::BOLD),
            ));
            remaining = &remaining[end + 4..];
            continue;
        }

        if (marker == "*" || marker == "_")
            && let Some(end) = remaining[1..].find(marker)
        {
            let italic = &remaining[1..1 + end];
            spans.push(Span::styled(
                strip_inline_markdown(italic),
                base_style.add_modifier(Modifier::ITALIC),
            ));
            remaining = &remaining[end + 2..];
            continue;
        }

        push_inline_text(&mut spans, marker, base_style);
        remaining = &remaining[marker.len()..];
    }

    if spans.is_empty() {
        spans.push(Span::raw(String::new()));
    }

    spans
}

fn markdown_link(text: &str) -> Option<(&str, &str, usize)> {
    let label_end = text.find("](")?;
    let url_start = label_end + 2;
    let url_end = text[url_start..].find(')')? + url_start;
    Some((&text[1..label_end], &text[url_start..url_end], url_end + 1))
}

fn next_inline_marker(text: &str) -> Option<(usize, &'static str)> {
    let mut best: Option<(usize, &'static str)> = None;
    for marker in ["`", "**", "*", "_", "["] {
        let Some(position) = text.find(marker) else {
            continue;
        };
        match best {
            Some((best_position, best_marker))
                if position > best_position
                    || (position == best_position && marker.len() <= best_marker.len()) => {}
            _ => best = Some((position, marker)),
        }
    }
    best
}

fn push_inline_text(spans: &mut Vec<Span<'static>>, text: &str, style: Style) {
    if !text.is_empty() {
        spans.push(Span::styled(text.to_string(), style));
    }
}

fn strip_inline_markdown(text: &str) -> String {
    text.replace("**", "").replace(['`', '_'], "")
}

fn push_markdown_wrapped_spans(
    lines: &mut Vec<Line<'static>>,
    label: &str,
    spans: Vec<Span<'static>>,
    continuation_columns: usize,
    label_style: Style,
    width: usize,
    emitted_first_line: &mut bool,
) {
    let label_prefix = format!("{label}: ");
    let first_prefix = if *emitted_first_line {
        "  ".to_string()
    } else {
        label_prefix
    };
    let continuation_prefix = if *emitted_first_line {
        format!("  {}", " ".repeat(continuation_columns))
    } else {
        format!(
            "{}{}",
            " ".repeat(format!("{label}: ").chars().count()),
            " ".repeat(continuation_columns)
        )
    };
    let available_width = width.saturating_sub(first_prefix.chars().count()).max(1);
    let chunks = wrap_spans(spans, available_width);

    for (index, chunk) in chunks.into_iter().enumerate() {
        let line_prefix = if index == 0 {
            first_prefix.clone()
        } else {
            continuation_prefix.clone()
        };
        let prefix_style = if !*emitted_first_line && index == 0 {
            label_style
        } else {
            Style::default()
        };
        let line_prefix_width = visible_width(&line_prefix);
        let allowed_content_width = width.saturating_sub(line_prefix_width);
        let bounded_chunk = bound_spans_to_width(chunk, allowed_content_width);
        let mut line_spans = vec![Span::styled(line_prefix, prefix_style)];
        line_spans.extend(bounded_chunk);
        lines.push(Line::from(line_spans));
    }

    *emitted_first_line = true;
}

fn bound_spans_to_width(spans: Vec<Span<'static>>, width: usize) -> Vec<Span<'static>> {
    let mut bounded = Vec::new();
    let mut remaining_width = width;

    for span in spans {
        if remaining_width == 0 {
            break;
        }

        let text = truncate_to_width(&span.content, remaining_width);
        remaining_width = remaining_width.saturating_sub(visible_width(&text));
        bounded.push(Span::styled(text, span.style));
    }

    if bounded.is_empty() {
        bounded.push(Span::raw(String::new()));
    }

    bounded
}

fn truncate_to_width(text: &str, width: usize) -> String {
    let mut output = String::new();
    let mut used_width = 0;

    for ch in text.chars() {
        let ch_width = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if used_width + ch_width > width {
            break;
        }
        output.push(ch);
        used_width += ch_width;
    }

    output
}

fn wrap_spans(spans: Vec<Span<'static>>, width: usize) -> Vec<Vec<Span<'static>>> {
    let width = width.max(1);
    let mut lines: Vec<Vec<Span<'static>>> = vec![Vec::new()];
    let mut current_width = 0;

    for span in spans {
        let style = span.style;
        let mut text = sanitize_render_text(&span.content);
        if text.is_empty() {
            if current_width == 0 {
                lines
                    .last_mut()
                    .expect("line should exist")
                    .push(Span::styled(text, style));
            }
            continue;
        }

        while !text.is_empty() {
            let remaining = width.saturating_sub(current_width).max(1);
            let take = word_boundary_take(&text, remaining);
            let chunk = text[..take].trim_start().to_string();
            let chunk_width = visible_width(&chunk);
            lines
                .last_mut()
                .expect("line should exist")
                .push(Span::styled(chunk, style));
            current_width += chunk_width;
            text = text[take..].to_string();

            if !text.is_empty() {
                lines.push(Vec::new());
                current_width = 0;
            }
        }
    }

    if lines.is_empty() || lines.last().is_some_and(Vec::is_empty) {
        vec![vec![Span::raw(String::new())]]
    } else {
        lines
    }
}

fn parse_image_command(input: &str) -> ImageCommand {
    let trimmed = input.trim();
    let Some(path) = trimmed
        .strip_prefix("/image ")
        .or_else(|| trimmed.strip_prefix(":image "))
    else {
        return ImageCommand::NotCommand;
    };

    let path = path.trim().trim_matches('"');
    if path.is_empty() {
        return ImageCommand::Invalid("Usage: /image <path-to-png-jpg-webp>".to_string());
    }

    if !is_supported_image_path(Path::new(path)) {
        return ImageCommand::Invalid(format!(
            "Unsupported image type: {path}. Supported: png, jpg, jpeg, webp"
        ));
    }

    ImageCommand::Attach(ImageAttachment::new(path))
}

fn is_supported_image_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "webp"
            )
        })
        .unwrap_or(false)
}

fn build_chat_event(prompt: &str, images: &[ImageAttachment]) -> Event {
    Event::new(build_chat_prompt(prompt, images))
}

fn build_chat_prompt(prompt: &str, images: &[ImageAttachment]) -> String {
    let tags = images
        .iter()
        .map(ImageAttachment::tag)
        .collect::<Vec<_>>()
        .join(" ");

    match (prompt.trim().is_empty(), tags.is_empty()) {
        (true, true) => String::new(),
        (true, false) => format!("Please analyze the attached image(s).\n\n{tags}"),
        (false, true) => prompt.trim().to_string(),
        (false, false) => format!("{}\n\n{tags}", prompt.trim()),
    }
}

fn parse_pasted_images(text: &str) -> Vec<ImageAttachment> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter_map(|line| pasted_image_path(line).map(ImageAttachment::new))
        .collect()
}

fn pasted_image_path(text: &str) -> Option<String> {
    let path = text
        .trim()
        .trim_matches('"')
        .trim_start_matches("file://")
        .to_string();
    is_supported_image_path(Path::new(&path)).then_some(path)
}

fn normalize_paste_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

fn expand_pending_pastes(prompt: &str, pending_pastes: &[PendingPaste]) -> String {
    let mut expanded = prompt.to_string();
    for paste in pending_pastes {
        if expanded.contains(&paste.placeholder) {
            expanded = expanded.replace(&paste.placeholder, &paste.text);
        }
    }
    expanded
}

fn build_display_prompt(prompt: &str, images: &[ImageAttachment]) -> String {
    let image_summary = match images.len() {
        0 => String::new(),
        1 => format!("[1 image: {}]", image_display_name(&images[0])),
        count => format!("[{count} images attached]"),
    };

    match (prompt.trim().is_empty(), image_summary.is_empty()) {
        (true, true) => String::new(),
        (true, false) => image_summary,
        (false, true) => prompt.trim().to_string(),
        (false, false) => format!("{}\n{}", prompt.trim(), image_summary),
    }
}

fn build_composer_lines(
    composer: &str,
    images: &[ImageAttachment],
    width: usize,
) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    if images.is_empty() {
        lines.push(Line::from(vec![
            Span::styled("Hint: ", Style::default().fg(Color::DarkGray)),
            Span::raw("paste image path (Cmd+V/Ctrl+V) or /image <path>"),
        ]));
    } else {
        let summary = match images.len() {
            1 => "1 image attached".to_string(),
            count => format!("{count} images attached"),
        };
        lines.push(Line::from(vec![
            Span::styled(
                summary,
                Style::default()
                    .fg(Color::Magenta)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "  Enter sends · Shift+↑↓ scroll",
                Style::default().fg(Color::DarkGray),
            ),
        ]));
        for (index, image) in images.iter().enumerate() {
            push_image_chip_lines(&mut lines, image, index + 1, width);
        }
    }

    push_wrapped(
        &mut lines,
        ">",
        composer,
        Style::default().fg(Color::Green),
        width,
    );
    lines
}

fn composer_height(terminal_height: u16, composer_line_count: usize) -> u16 {
    let desired = composer_line_count
        .saturating_add(2)
        .clamp(3, MAX_COMPOSER_INNER_HEIGHT.saturating_add(2));
    let max_height = terminal_height.saturating_sub(6).max(3) as usize;
    desired.min(max_height).max(3) as u16
}

fn chat_title(width: u16) -> &'static str {
    if width < 48 {
        "Chat"
    } else if width < 72 {
        "Chat  ↑↓ scroll  Tab tool"
    } else {
        "Chat  ↑↓ scroll  Tab tool  Ctrl+E expand"
    }
}

fn prompt_title(width: u16) -> &'static str {
    if width < 64 {
        "Prompt"
    } else {
        "Prompt  Shift/Cmd+↑↓ scroll  Cmd+⌫ clear  Opt+⌫ word"
    }
}

fn spawn_input_reader(tx: mpsc::UnboundedSender<AppEvent>, log_path: PathBuf) {
    tokio::spawn(async move {
        loop {
            match event::poll(Duration::from_millis(TUI_INPUT_POLL_MILLIS)) {
                Ok(true) => match event::read() {
                    Ok(TerminalEvent::Key(key)) => {
                        if tx.send(AppEvent::Input(key)).is_err() {
                            log_info(&log_path, "input reader receiver dropped");
                            return;
                        }
                    }
                    Ok(TerminalEvent::Paste(text)) => {
                        if tx.send(AppEvent::Paste(text)).is_err() {
                            log_info(&log_path, "paste receiver dropped");
                            return;
                        }
                    }
                    Ok(TerminalEvent::Mouse(mouse)) => {
                        if tx.send(AppEvent::Mouse(mouse)).is_err() {
                            log_info(&log_path, "mouse receiver dropped");
                            return;
                        }
                    }
                    Ok(_) => {}
                    Err(error) => {
                        let error = anyhow::Error::from(error);
                        log_error(&log_path, "terminal event read failed", &error);
                        let _ = tx.send(AppEvent::Chat(Err(error)));
                        return;
                    }
                },
                Ok(false) => {}
                Err(error) => {
                    let error = anyhow::Error::from(error);
                    log_error(&log_path, "terminal event poll failed", &error);
                    let _ = tx.send(AppEvent::Chat(Err(error)));
                    return;
                }
            }
        }
    });
}

fn is_clipboard_paste_key(key: KeyEvent) -> bool {
    matches!(key.code, KeyCode::Char('v' | 'V'))
        && (key.modifiers.contains(KeyModifiers::CONTROL)
            || key.modifiers.contains(KeyModifiers::SUPER))
}

fn escape_action(is_streaming: bool) -> EscapeAction {
    if is_streaming {
        EscapeAction::StopAgent
    } else {
        EscapeAction::ClearComposer
    }
}

fn read_clipboard_text() -> Result<String> {
    #[cfg(not(target_os = "android"))]
    {
        let text = arboard::Clipboard::new()?.get_text()?;
        Ok(text)
    }

    #[cfg(target_os = "android")]
    {
        anyhow::bail!("clipboard access is not supported on Android")
    }
}

fn read_clipboard_image() -> Result<ImageAttachment> {
    #[cfg(not(target_os = "android"))]
    {
        let image = arboard::Clipboard::new()?.get_image()?;
        let path = clipboard_image_path();
        write_rgba_png(
            &path,
            image.width as u32,
            image.height as u32,
            image.bytes.as_ref(),
        )?;
        Ok(ImageAttachment::new(path.to_string_lossy()))
    }

    #[cfg(target_os = "android")]
    {
        anyhow::bail!("clipboard image access is not supported on Android")
    }
}

fn clipboard_image_path() -> PathBuf {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    std::env::temp_dir().join(format!("codegraff-clipboard-{timestamp}.png"))
}

fn write_rgba_png(path: &Path, width: u32, height: u32, bytes: &[u8]) -> Result<()> {
    let expected_len = width as usize * height as usize * 4;
    anyhow::ensure!(
        bytes.len() == expected_len,
        "clipboard image had {} bytes, expected {expected_len} for {width}x{height} RGBA",
        bytes.len()
    );

    let image = image::RgbaImage::from_raw(width, height, bytes.to_vec())
        .context("Failed to construct RGBA clipboard image")?;
    let mut encoded = Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(image)
        .write_to(&mut encoded, image::ImageFormat::Png)
        .context("Failed to encode clipboard image as PNG")?;
    std::fs::write(path, encoded.into_inner())
        .with_context(|| format!("Failed to write clipboard image to {}", path.display()))?;
    Ok(())
}

fn delete_previous_word(text: &mut String) {
    let trimmed_len = text.trim_end_matches(char::is_whitespace).len();
    text.truncate(trimmed_len);

    while let Some(ch) = text.chars().last() {
        if ch.is_whitespace() {
            break;
        }
        text.pop();
    }
}

fn is_multiline_input_key(key: KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::SHIFT)
}

fn composer_input_char(key: KeyEvent) -> Option<char> {
    let KeyCode::Char(ch) = key.code else {
        return None;
    };

    if key.modifiers.contains(KeyModifiers::SHIFT) {
        return Some(shifted_ascii_char(ch));
    }

    Some(ch)
}

fn shifted_ascii_char(ch: char) -> char {
    match ch {
        'a'..='z' => ch.to_ascii_uppercase(),
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        ch => ch,
    }
}

fn adjust_scroll_offset(offset: &mut usize, direction: ScrollDirection, amount: usize) {
    match direction {
        ScrollDirection::Up => *offset = offset.saturating_add(amount),
        ScrollDirection::Down => *offset = offset.saturating_sub(amount),
    }
}

fn adjust_top_scroll_offset(offset: &mut usize, direction: ScrollDirection, amount: usize) {
    match direction {
        ScrollDirection::Up => *offset = offset.saturating_sub(amount),
        ScrollDirection::Down => *offset = offset.saturating_add(amount),
    }
}

#[derive(Clone, Copy)]
enum ScrollDirection {
    Up,
    Down,
}

fn handle_overlay_mouse_scroll_offset(offset: &mut usize, kind: MouseEventKind) {
    match kind {
        MouseEventKind::ScrollUp => {
            adjust_top_scroll_offset(offset, ScrollDirection::Up, MOUSE_SCROLL_STEP)
        }
        MouseEventKind::ScrollDown => {
            adjust_top_scroll_offset(offset, ScrollDirection::Down, MOUSE_SCROLL_STEP)
        }
        _ => {}
    }
}

fn handle_mouse_scroll_offset(offset: &mut usize, kind: MouseEventKind) {
    match kind {
        MouseEventKind::ScrollUp => {
            adjust_scroll_offset(offset, ScrollDirection::Up, MOUSE_SCROLL_STEP)
        }
        MouseEventKind::ScrollDown => {
            adjust_scroll_offset(offset, ScrollDirection::Down, MOUSE_SCROLL_STEP)
        }
        _ => {}
    }
}

fn is_key_press(key: KeyEvent) -> bool {
    matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat)
}

fn composer_scroll_shortcut(key: KeyEvent) -> ComposerScrollShortcut {
    let shift_or_command = key.modifiers.contains(KeyModifiers::SHIFT)
        || key.modifiers.contains(KeyModifiers::SUPER)
        || key.modifiers.contains(KeyModifiers::CONTROL);

    if !shift_or_command {
        return ComposerScrollShortcut::None;
    }

    match key.code {
        KeyCode::Up => ComposerScrollShortcut::UpOne,
        KeyCode::Down => ComposerScrollShortcut::DownOne,
        KeyCode::PageUp => ComposerScrollShortcut::UpPage,
        KeyCode::PageDown => ComposerScrollShortcut::DownPage,
        KeyCode::Home => ComposerScrollShortcut::Top,
        KeyCode::End => ComposerScrollShortcut::Bottom,
        _ => ComposerScrollShortcut::None,
    }
}

fn composer_edit_shortcut(key: KeyEvent) -> ComposerEditShortcut {
    let command_or_control = key.modifiers.contains(KeyModifiers::SUPER)
        || key.modifiers.contains(KeyModifiers::CONTROL);
    let option_or_alt = key.modifiers.contains(KeyModifiers::ALT);

    match key.code {
        KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            ComposerEditShortcut::ClearLine
        }
        KeyCode::Char('w') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            ComposerEditShortcut::DeletePreviousWord
        }
        KeyCode::Backspace | KeyCode::Delete if command_or_control => {
            ComposerEditShortcut::ClearLine
        }
        KeyCode::Backspace | KeyCode::Delete if option_or_alt => {
            ComposerEditShortcut::DeletePreviousWord
        }
        _ => ComposerEditShortcut::None,
    }
}

fn tool_shortcut(key: KeyEvent) -> ToolShortcut {
    match key.code {
        KeyCode::Tab => ToolShortcut::Next,
        KeyCode::BackTab => ToolShortcut::Previous,
        KeyCode::Char('e') if key.modifiers.contains(KeyModifiers::CONTROL) => ToolShortcut::Toggle,
        _ => ToolShortcut::None,
    }
}

fn append_assistant_entry(transcript: &mut Vec<TranscriptEntry>, text: String) {
    if let Some(TranscriptEntry::Assistant(message)) = transcript.last_mut() {
        message.push_str(&text);
        return;
    }

    transcript.push(TranscriptEntry::Assistant(text));
}

fn usage_summary_from_conversation(conversation: &Conversation) -> Option<UsageSummary> {
    let last = conversation.usage().map(usage_line);
    let session = conversation.accumulated_usage().map(|mut usage| {
        usage.cost = conversation.accumulated_cost();
        usage_line(usage)
    });
    let context_tokens = conversation.token_count().map(format_token_count);

    if last.is_none() && session.is_none() && context_tokens.is_none() {
        None
    } else {
        Some(UsageSummary { last, session, context_tokens, model: None })
    }
}

fn usage_line(usage: Usage) -> UsageLine {
    UsageLine {
        prompt_tokens: format_token_count(usage.prompt_tokens),
        completion_tokens: format_token_count(usage.completion_tokens),
        total_tokens: format_token_count(usage.total_tokens),
        cached_tokens: format_token_count(usage.cached_tokens),
        cost: usage.cost.map(format_cost),
    }
}

fn format_token_count(count: TokenCount) -> String {
    count.to_string()
}

fn format_cost(cost: f64) -> String {
    if cost < 0.01 {
        format!("${cost:.4}")
    } else {
        format!("${cost:.2}")
    }
}

fn header_line(status: TuiStatus, active_model: Option<&str>, width: usize) -> Line<'static> {
    let status_text = compact_status(status);
    let model_text = active_model.map(|model| format!("  [{model}]"));
    let reserved_width = "Codegraff  ".chars().count()
        + model_text
            .as_deref()
            .map(|model| model.chars().count())
            .unwrap_or_default();
    let available_width = width.saturating_sub(reserved_width);
    let status_text = truncate_single_line(status_text, available_width);

    let mut spans = vec![
        Span::styled(
            "Codegraff",
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(status_text, Style::default().fg(status_color(status))),
    ];
    if let Some(model_text) = model_text {
        spans.push(Span::styled(
            model_text,
            Style::default().fg(Color::DarkGray),
        ));
    }

    Line::from(spans)
}

fn usage_detail_lines(usage: &UsageSummary) -> Vec<String> {
    let mut lines = Vec::new();

    if let Some(last) = &usage.last {
        lines.push(format!(
            "Last: prompt {} · completion {} · total {} · cached {}{}",
            last.prompt_tokens,
            last.completion_tokens,
            last.total_tokens,
            last.cached_tokens,
            last.cost
                .as_ref()
                .map(|cost| format!(" · {cost}"))
                .unwrap_or_default()
        ));
    }

    if let Some(session) = &usage.session {
        lines.push(format!(
            "Session: prompt {} · completion {} · total {} · cached {}{}",
            session.prompt_tokens,
            session.completion_tokens,
            session.total_tokens,
            session.cached_tokens,
            session
                .cost
                .as_ref()
                .map(|cost| format!(" · {cost}"))
                .unwrap_or_default()
        ));
    }

    if let Some(context_tokens) = &usage.context_tokens {
        lines.push(format!("Context: {context_tokens} tokens"));
    }

    if let Some(model) = &usage.model {
        lines.push(format!("Model: {} / {}", model.provider, model.id));
        if let Some(name) = &model.name {
            lines.push(format!("Model name: {name}"));
        }
        let mut capabilities = Vec::new();
        if let Some(context_length) = &model.context_length {
            capabilities.push(format!("context {context_length}"));
        }
        if model.tools_supported == Some(true) {
            capabilities.push("tools".to_string());
        }
        if model.supports_parallel_tool_calls == Some(true) {
            capabilities.push("parallel tools".to_string());
        }
        if model.supports_reasoning == Some(true) {
            capabilities.push("reasoning".to_string());
        }
        if !model.input_modalities.is_empty() {
            capabilities.push(format!("input {}", model.input_modalities.join("+")));
        }
        if !capabilities.is_empty() {
            lines.push(format!("Model stats: {}", capabilities.join(" · ")));
        }
    }

    lines
}

fn status_color(status: TuiStatus) -> Color {
    match status {
        TuiStatus::Ready => Color::Green,
        TuiStatus::Thinking | TuiStatus::Reasoning => Color::Yellow,
        TuiStatus::Error | TuiStatus::Interrupted => Color::Red,
        TuiStatus::Finished => Color::Blue,
    }
}

fn compact_status(status: TuiStatus) -> &'static str {
    match status {
        TuiStatus::Ready => "Ready",
        TuiStatus::Thinking => "Thinking...",
        TuiStatus::Reasoning => "Reasoning...",
        TuiStatus::Finished => "Finished",
        TuiStatus::Error => "Error",
        TuiStatus::Interrupted => "Interrupted",
    }
}

#[cfg(test)]
mod tests {
    use forge_api::ModelId;
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn login_command_opens_or_selects_provider_login() {
        let fixture = "/login 2";
        let actual = parse_login_command(fixture);
        let expected = ConnectCommand::Provider(2);

        assert_eq!(actual, expected);
    }

    #[test]
    fn login_command_rejects_invalid_auth_method_selection() {
        let fixture = "/login auth nope";
        let actual = parse_login_command(fixture);
        let expected = ConnectCommand::Invalid(
            "Usage: /login auth <number> to choose an auth method.".to_string(),
        );

        assert_eq!(actual, expected);
    }

    #[test]
    fn connect_command_still_opens_existing_connect_flow() {
        let fixture = "/connect";
        let actual = parse_connect_command(fixture);
        let expected = ConnectCommand::Open;

        assert_eq!(actual, expected);
    }

    #[test]
    fn connect_intent_uses_login_dialog_copy() {
        let fixture = ConnectIntent::Login;
        let actual = (
            fixture.command(),
            fixture.title(),
            fixture.cancelled_message(),
        );
        let expected = ("/login", "Log in to provider", "Login cancelled.");

        assert_eq!(actual, expected);
    }

    #[test]
    fn model_command_lists_or_selects_registered_provider_models() {
        let fixture = "/models 2";
        let actual = parse_model_command(fixture);
        let expected = ModelCommand::Select(2);

        assert_eq!(actual, expected);
    }

    #[test]
    fn model_command_rejects_invalid_selection() {
        let fixture = "/models abc";
        let actual = parse_model_command(fixture);
        let expected = ModelCommand::Invalid(
            "Usage: /models to choose models, /models <number> to switch, or /models cancel."
                .to_string(),
        );

        assert_eq!(actual, expected);
    }

    #[test]
    fn format_model_option_includes_provider_model_and_capabilities() {
        let fixture = ModelOption::new(
            ProviderId::OPEN_ROUTER,
            Model {
                id: ModelId::new("anthropic/claude-sonnet"),
                name: Some("Claude Sonnet".to_string()),
                description: None,
                context_length: Some(200_000),
                tools_supported: Some(true),
                supports_parallel_tool_calls: Some(true),
                supports_reasoning: Some(true),
                input_modalities: vec![InputModality::Text, InputModality::Image],
            },
        );
        let actual = format_model_option(1, &fixture);
        let expected = "1. OpenRouter / anthropic/claude-sonnet (Claude Sonnet · context 200k · tools · reasoning · image)";

        assert_eq!(actual, expected);
    }

    #[test]
    fn codegraff_log_path_respects_override() {
        let fixture = PathBuf::from("/tmp/codegraff-custom.log");
        let actual = logging::codegraff_log_path_from(Some(fixture.clone()), None, None);
        let expected = fixture;

        assert_eq!(actual, expected);
    }

    #[test]
    fn default_log_path_uses_state_directory() {
        let actual =
            logging::codegraff_log_path_from(None, Some(PathBuf::from("/tmp/state")), None);
        let expected = PathBuf::from("/tmp/state/codegraff/codegraff.log");

        assert_eq!(actual, expected);
    }

    #[test]
    fn append_log_line_writes_debug_file() {
        let fixture = std::env::temp_dir().join("codegraff-test-log.log");
        let _ = std::fs::remove_file(&fixture);
        logging::append_log_line(&fixture, "ERROR terminal draw failed: boom");
        let actual = std::fs::read_to_string(&fixture)
            .unwrap()
            .contains("ERROR terminal draw failed: boom");
        let expected = true;
        let _ = std::fs::remove_file(&fixture);

        assert_eq!(actual, expected);
    }

    #[test]
    fn usage_line_formats_token_usage_and_cost() {
        let fixture = Usage {
            prompt_tokens: TokenCount::Actual(120),
            completion_tokens: TokenCount::Actual(30),
            total_tokens: TokenCount::Actual(150),
            cached_tokens: TokenCount::Actual(40),
            cost: Some(0.0042),
        };
        let actual = usage_line(fixture);
        let expected = UsageLine {
            prompt_tokens: "120".to_string(),
            completion_tokens: "30".to_string(),
            total_tokens: "150".to_string(),
            cached_tokens: "40".to_string(),
            cost: Some("$0.0042".to_string()),
        };

        assert_eq!(actual, expected);
    }

    #[test]
    fn header_line_hides_usage_noise() {
        let fixture = UsageSummary {
            last: None,
            session: Some(UsageLine {
                prompt_tokens: "120".to_string(),
                completion_tokens: "30".to_string(),
                total_tokens: "150".to_string(),
                cached_tokens: "40".to_string(),
                cost: Some("$0.0042".to_string()),
            }),
            context_tokens: None,
            model: None,
        };
        let actual = render_line(header_line(TuiStatus::Finished, None, 80));
        let expected = "Codegraff  Finished";

        assert_eq!(fixture.session.is_some(), true);
        assert_eq!(actual, expected);
    }

    #[test]
    fn usage_detail_lines_show_last_session_and_context() {
        let fixture = UsageSummary {
            last: Some(UsageLine {
                prompt_tokens: "100".to_string(),
                completion_tokens: "25".to_string(),
                total_tokens: "125".to_string(),
                cached_tokens: "10".to_string(),
                cost: Some("$0.0030".to_string()),
            }),
            session: Some(UsageLine {
                prompt_tokens: "300".to_string(),
                completion_tokens: "75".to_string(),
                total_tokens: "375".to_string(),
                cached_tokens: "30".to_string(),
                cost: Some("$0.0090".to_string()),
            }),
            context_tokens: Some("~500".to_string()),
            model: Some(ModelStats {
                provider: "OpenRouter".to_string(),
                id: "anthropic/claude-sonnet".to_string(),
                name: Some("Claude Sonnet".to_string()),
                context_length: Some("200000".to_string()),
                tools_supported: Some(true),
                supports_parallel_tool_calls: Some(true),
                supports_reasoning: Some(true),
                input_modalities: vec!["text".to_string(), "image".to_string()],
            }),
        };
        let actual = usage_detail_lines(&fixture);
        let expected = vec![
            "Last: prompt 100 · completion 25 · total 125 · cached 10 · $0.0030".to_string(),
            "Session: prompt 300 · completion 75 · total 375 · cached 30 · $0.0090".to_string(),
            "Context: ~500 tokens".to_string(),
            "Model: OpenRouter / anthropic/claude-sonnet".to_string(),
            "Model name: Claude Sonnet".to_string(),
            "Model stats: context 200000 · tools · parallel tools · reasoning · input text+image"
                .to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_wraps_long_input_and_adds_hint() {
        let fixture = "can you go thru the entire repo real quick w codedb";
        let actual = rendered_composer_lines(fixture, &[], 22);
        let expected = vec![
            "Hint: paste image path (Cmd+V/Ctrl+V) or /image <path>".to_string(),
            ">: can you go thru the".to_string(),
            "    entire repo real q".to_string(),
            "   uick w codedb".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_height_grows_with_wrapped_input() {
        let actual = composer_height(40, 5);
        let expected = 7;

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_height_stays_usable_on_small_terminals() {
        let actual = composer_height(8, 20);
        let expected = 3;

        assert_eq!(actual, expected);
    }

    #[test]
    fn image_command_accepts_supported_image_paths() {
        let fixture = "/image /tmp/screen shot.png";
        let actual = parse_image_command(fixture);
        let expected = ImageCommand::Attach(ImageAttachment::new("/tmp/screen shot.png"));

        assert_eq!(actual, expected);
    }

    #[test]
    fn image_command_rejects_unsupported_image_paths() {
        let fixture = "/image /tmp/archive.zip";
        let actual = parse_image_command(fixture);
        let expected = ImageCommand::Invalid(
            "Unsupported image type: /tmp/archive.zip. Supported: png, jpg, jpeg, webp".to_string(),
        );

        assert_eq!(actual, expected);
    }

    #[test]
    fn chat_prompt_includes_image_tags_for_backend_attachments() {
        let fixture = vec![
            ImageAttachment::new("/tmp/a.png"),
            ImageAttachment::new("b.webp"),
        ];
        let actual = build_chat_prompt("describe these", &fixture);
        let expected = "describe these\n\n@[/tmp/a.png] @[b.webp]";

        assert_eq!(actual, expected);
    }

    #[test]
    fn display_prompt_summarizes_attached_images() {
        let fixture = vec![ImageAttachment::new("/tmp/a.png")];
        let actual = build_display_prompt("describe this", &fixture);
        let expected = "describe this\n[1 image: a.png]";

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_lists_attached_images_as_compact_chips() {
        let fixture = vec![ImageAttachment {
            path: "/tmp/a.png".to_string(),
            preview: Some(ImagePreview {
                width: 2,
                height: 2,
                thumbnail: vec!["█▓".to_string(), "▒░".to_string()],
            }),
        }];
        let actual = rendered_composer_lines("describe", &fixture, 40);
        let expected = vec![
            "1 image attached  Enter sends · Shift+↑↓ scroll".to_string(),
            "  ◼ Img 1 a.png · 2x2".to_string(),
            ">: describe".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn image_compact_label_mentions_loaded_preview_dimensions() {
        let fixture = ImageAttachment {
            path: "/tmp/a.png".to_string(),
            preview: Some(ImagePreview { width: 10, height: 20, thumbnail: Vec::new() }),
        };
        let actual = image_compact_label(&fixture);
        let expected = "a.png · 10x20";

        assert_eq!(actual, expected);
    }

    #[test]
    fn image_summary_does_not_render_large_preview_blocks_in_chat() {
        let fixture = ImageAttachment {
            path: "/tmp/a.png".to_string(),
            preview: Some(ImagePreview {
                width: 2, height: 2, thumbnail: vec!["█▓".to_string()]
            }),
        };
        let mut lines = Vec::new();
        push_image_summary_lines(&mut lines, &fixture, 1, 40);
        let actual = lines.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec!["  ◼ Image 1 a.png · 2x2".to_string()];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_heading_and_bullets_are_rendered_with_symbols() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(&mut fixture, "CodeGraff", "# Main\n## Title\n- item", 40);
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "CodeGraff: ▰ Main".to_string(),
            "  ◆ Title".to_string(),
            "  • item".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_code_blocks_are_preserved() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(&mut fixture, "CodeGraff", "```bash\ncargo test\n```", 40);
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "CodeGraff: ╭─ bash".to_string(),
            "  │ cargo test".to_string(),
            "  ╰─".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_task_lists_quotes_links_and_rules_render_cleanly() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(
            &mut fixture,
            "CodeGraff",
            "- [x] done\n- [ ] todo\n> quoted **text**\n---\n[docs](https://example.com)",
            60,
        );
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "CodeGraff: ☑ done".to_string(),
            "  ☐ todo".to_string(),
            "  ▌ quoted text".to_string(),
            "  ────────────────────────".to_string(),
            "  docs(https://example.com)".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_list_continuations_align_under_list_text() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(
            &mut fixture,
            "CodeGraff",
            "- this is a long item that should wrap nicely",
            24,
        );
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "CodeGraff: • this is a ".to_string(),
            "             long item ".to_string(),
            "             that should".to_string(),
            "             wrap nicely".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn pasted_image_path_attaches_supported_image() {
        let fixture = "file:///tmp/screen shot.png";
        let actual = pasted_image_path(fixture);
        let expected = Some("/tmp/screen shot.png".to_string());

        assert_eq!(actual, expected);
    }

    #[test]
    fn pasted_images_extracts_multiline_image_paths() {
        let fixture = "/tmp/a.png\n/tmp/b.webp\nplain text";
        let actual = parse_pasted_images(fixture);
        let expected = vec![
            ImageAttachment::new("/tmp/a.png"),
            ImageAttachment::new("/tmp/b.webp"),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn normalize_paste_text_preserves_text_with_normalized_newlines() {
        let fixture = "first\r\nsecond\rthird";
        let actual = normalize_paste_text(fixture);
        let expected = "first\nsecond\nthird";

        assert_eq!(actual, expected);
    }

    #[test]
    fn expand_pending_pastes_restores_large_paste_for_backend() {
        let fixture = vec![PendingPaste {
            placeholder: "[Pasted Content 1200 chars]".to_string(),
            text: "long pasted payload".to_string(),
        }];
        let actual =
            expand_pending_pastes("summarize [Pasted Content 1200 chars] please", &fixture);
        let expected = "summarize long pasted payload please";

        assert_eq!(actual, expected);
    }

    #[test]
    fn display_prompt_keeps_large_paste_placeholder_short() {
        let fixture = "explain [Pasted Content 1200 chars]";
        let actual = build_display_prompt(fixture, &[]);
        let expected = "explain [Pasted Content 1200 chars]";

        assert_eq!(actual, expected);
    }

    #[test]
    fn chat_event_includes_image_tags_for_backend_attachments() {
        let fixture = vec![ImageAttachment::new("/tmp/a.png")];
        let actual = build_chat_event("describe it", &fixture);

        let actual_value = actual
            .value
            .and_then(|value| value.as_user_prompt().map(|prompt| prompt.to_string()))
            .unwrap();
        let expected = "describe it\n\n@[/tmp/a.png]";

        assert_eq!(actual_value, expected);
    }

    #[test]
    fn append_assistant_starts_new_reply_after_tool_card() {
        let mut fixture = vec![
            TranscriptEntry::Assistant("first".to_string()),
            TranscriptEntry::Tool(ToolEntry::finished("read", ToolStatus::Done)),
        ];
        append_assistant_entry(&mut fixture, "second".to_string());
        let actual = transcript_texts(&fixture);
        let expected = vec![
            "assistant:first".to_string(),
            "tool:read".to_string(),
            "assistant:second".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn sanitize_tool_output_removes_control_characters() {
        let fixture = "ok\u{fffd}\u{0007}\nnext";
        let actual = tool_card::sanitize_tool_output(fixture);
        let expected = "ok\nnext";

        assert_eq!(actual, expected);
    }

    #[test]
    fn sanitize_tool_output_collapses_tool_table_spacing() {
        let fixture = "src/main.zig                                                           src/execd/main.zig";
        let actual = tool_card::sanitize_tool_output(fixture);
        let expected = "src/main.zig src/execd/main.zig";

        assert_eq!(actual, expected);
    }

    #[test]
    fn sanitize_tool_output_strips_ansi_escape_sequences() {
        let fixture =
            "\u{1b}[36m\u{1b}[2m\u{1b}[32m✓\u{1b}[0m \u{1b}[1msearch\u{1b}[0m 'permissions'";
        let actual = tool_card::sanitize_tool_output(fixture);
        let expected = "✓ search 'permissions'";

        assert_eq!(actual, expected);
    }

    #[test]
    fn sanitize_tool_output_drops_incomplete_ansi_sequences() {
        let fixture = "before\u{1b}[36 after";
        let actual = tool_card::sanitize_tool_output(fixture);
        let expected = "before";

        assert_eq!(actual, expected);
    }

    #[test]
    fn sanitize_tool_output_strips_osc_title_sequences() {
        let fixture = "before\u{1b}]0;forge title\u{7}after";
        let actual = tool_card::sanitize_tool_output(fixture);
        let expected = "beforeafter";

        assert_eq!(actual, expected);
    }

    #[test]
    fn sanitize_tool_output_strips_cursor_and_line_clear_sequences() {
        let fixture = "alpha\u{1b}[2K\u{1b}[1G beta\u{1b}[?25l";
        let actual = tool_card::sanitize_tool_output(fixture);
        let expected = "alpha beta";

        assert_eq!(actual, expected);
    }

    #[test]
    fn collapsed_tool_card_keeps_summary_to_one_line() {
        let fixture = ToolEntry::info(
            "outline",
            "Large output: 92 lines, 3445 bytes. Showing first 80 lines. more and more and more",
        );
        let actual = rendered_tool_lines(fixture, false, 46);
        let expected = vec![
            "  ▸ Tool outline [info]".to_string(),
            "    Large output: 92 lines, 3445 bytes. Showi…".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_keeps_multiple_large_paste_placeholders_unique_and_expandable() {
        let fixture = vec![
            PendingPaste {
                placeholder: "[Pasted Content 1200 chars]".to_string(),
                text: "first payload".to_string(),
            },
            PendingPaste {
                placeholder: "[Pasted Content 1400 chars #2]".to_string(),
                text: "second payload".to_string(),
            },
        ];
        let actual = expand_pending_pastes(
            "check [Pasted Content 1200 chars] then [Pasted Content 1400 chars #2]",
            &fixture,
        );
        let expected = "check first payload then second payload";

        assert_eq!(actual, expected);
    }

    #[test]
    fn large_paste_placeholder_can_repeat_without_losing_payload() {
        let fixture = vec![PendingPaste {
            placeholder: "[Pasted Content 1200 chars]".to_string(),
            text: "same payload".to_string(),
        }];
        let actual = expand_pending_pastes(
            "compare [Pasted Content 1200 chars] with [Pasted Content 1200 chars]",
            &fixture,
        );
        let expected = "compare same payload with same payload";

        assert_eq!(actual, expected);
    }

    #[test]
    fn normalize_paste_text_handles_empty_and_mixed_newlines() {
        let fixture = "\r\nfirst\rsecond\nthird\r";
        let actual = normalize_paste_text(fixture);
        let expected = "\nfirst\nsecond\nthird\n";

        assert_eq!(actual, expected);
    }

    #[test]
    fn pasted_image_path_accepts_quoted_file_urls() {
        let fixture = "\"file:///tmp/screen shot.jpeg\"";
        let actual = pasted_image_path(fixture);
        let expected = Some("/tmp/screen shot.jpeg".to_string());

        assert_eq!(actual, expected);
    }

    #[test]
    fn pasted_images_ignore_unsupported_or_non_path_lines() {
        let fixture = "hello\n/tmp/a.gif\nfile:///tmp/ok.webp\nnot-an-image";
        let actual = parse_pasted_images(fixture);
        let expected = vec![ImageAttachment::new("/tmp/ok.webp")];

        assert_eq!(actual, expected);
    }

    #[test]
    fn build_chat_prompt_sends_image_only_prompt_when_text_is_blank() {
        let fixture = vec![ImageAttachment::new("/tmp/a.png")];
        let actual = build_chat_prompt("   ", &fixture);
        let expected = "Please analyze the attached image(s).\n\n@[/tmp/a.png]";

        assert_eq!(actual, expected);
    }

    #[test]
    fn display_prompt_summarizes_multiple_images_without_paths() {
        let fixture = vec![
            ImageAttachment::new("/tmp/a.png"),
            ImageAttachment::new("/tmp/nested/b.jpeg"),
        ];
        let actual = build_display_prompt("", &fixture);
        let expected = "[2 images attached]";

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_height_keeps_prompt_area_visible_on_tiny_terminals() {
        let actual = vec![
            composer_height(4, 30),
            composer_height(8, 30),
            composer_height(80, 30),
        ];
        let expected = vec![3, 3, 11];

        assert_eq!(actual, expected);
    }

    #[test]
    fn chat_title_stays_short_on_narrow_terminals() {
        let actual = vec![chat_title(30), chat_title(60), chat_title(90)];
        let expected = vec![
            "Chat",
            "Chat  ↑↓ scroll  Tab tool",
            "Chat  ↑↓ scroll  Tab tool  Ctrl+E expand",
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn prompt_title_stays_short_on_narrow_terminals() {
        let actual = vec![prompt_title(40), prompt_title(100)];
        let expected = vec![
            "Prompt",
            "Prompt  Shift/Cmd+↑↓ scroll  Cmd+⌫ clear  Opt+⌫ word",
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn header_line_shows_active_model_when_available() {
        let actual = render_line(header_line(TuiStatus::Finished, Some("Codex:gpt-5.5"), 80));
        let expected = "Codegraff  Finished  [Codex:gpt-5.5]";

        assert_eq!(actual, expected);
    }

    #[test]
    fn short_model_label_uses_provider_and_last_model_segment() {
        let actual = short_model_label("OpenRouter", "anthropic/claude-sonnet-4");
        let expected = "OpenRouter:claude-sonnet-4";

        assert_eq!(actual, expected);
    }

    #[test]
    fn header_line_truncates_status_to_available_width() {
        let actual = render_line(header_line(TuiStatus::Interrupted, None, 16));
        let expected = "Codegraff  Inte…";

        assert_eq!(actual, expected);
    }

    #[test]
    fn wrap_line_handles_single_column_without_looping() {
        let fixture = "abc";
        let actual = wrap_line(fixture, 0);
        let expected = vec!["a".to_string(), "b".to_string(), "c".to_string()];

        assert_eq!(actual, expected);
    }

    #[test]
    fn push_wrapped_preserves_explicit_blank_lines() {
        let mut fixture = Vec::new();
        push_wrapped(&mut fixture, "You", "first\n\nsecond", Style::default(), 20);
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "You: first".to_string(),
            "  ".to_string(),
            "  second".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn compact_tool_output_sanitizes_before_counting_limits() {
        let fixture = format!(
            "{}\u{0007}",
            "x".repeat(tool_card::TOOL_OUTPUT_BYTE_LIMIT + 1)
        );
        let actual = compact_tool_output(&fixture);
        let expected_prefix = format!(
            "Large output: 1 lines, {} bytes. Showing first 1 lines.",
            tool_card::TOOL_OUTPUT_BYTE_LIMIT + 1
        );

        assert!(actual.starts_with(&expected_prefix));
    }

    #[test]
    fn collapsed_tool_title_is_truncated_to_card_width() {
        let fixture = ToolEntry::info("a-very-long-tool-name-that-should-not-break-layout", "ok");
        let actual = rendered_tool_lines(fixture, false, 24);
        let expected = vec!["  ▸ Tool a-very-… [info]".to_string(), "    ok".to_string()];

        assert_eq!(actual, expected);
    }

    #[test]
    fn dirty_tool_title_renders_cleanly() {
        let fixture = ToolEntry::info("\u{1b}[31msearch\u{1b}[0m\u{0007}\u{fffd}", "ok");
        let actual = rendered_tool_lines(fixture, false, 30);
        let expected = vec!["  ▸ Tool search [info]".to_string(), "    ok".to_string()];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_code_blocks_sanitize_terminal_artifacts() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(
            &mut fixture,
            "CodeGraff",
            "```bash\n\u{1b}[32mcargo test\u{1b}[0m\u{0007}\n```",
            40,
        );
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "CodeGraff: ╭─ bash".to_string(),
            "  │ cargo test ".to_string(),
            "  ╰─".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_inline_markup_is_removed_without_touching_attachment_tags() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(
            &mut fixture,
            "CodeGraff",
            "**bold** `code` [link](https://x.test) @[/tmp/a.png]",
            80,
        );
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec!["CodeGraff: boldcode link(https://x.test)@[/tmp/a.png]".to_string()];

        assert_eq!(actual, expected);
    }

    fn rendered_composer_lines(
        composer: &str,
        images: &[ImageAttachment],
        width: usize,
    ) -> Vec<String> {
        build_composer_lines(composer, images, width)
            .into_iter()
            .map(|line| {
                line.spans
                    .into_iter()
                    .map(|span| span.content.into_owned())
                    .collect::<String>()
            })
            .collect()
    }

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn modified_key(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, modifiers)
    }

    fn rendered_tool_lines(tool: ToolEntry, selected: bool, width: usize) -> Vec<String> {
        let mut fixture = Vec::new();
        push_tool_lines(&mut fixture, &tool, selected, width);

        fixture.into_iter().map(render_line).collect()
    }

    fn transcript_texts(entries: &[TranscriptEntry]) -> Vec<String> {
        entries
            .iter()
            .map(|entry| match entry {
                TranscriptEntry::Assistant(text) => format!("assistant:{text}"),
                TranscriptEntry::Tool(tool) => format!("tool:{}", tool.title),
                TranscriptEntry::User(message) => format!("user:{}", message.text),
                TranscriptEntry::Error(text) => format!("error:{text}"),
                TranscriptEntry::Status(text) => format!("status:{text}"),
            })
            .collect()
    }

    fn render_line(line: Line<'static>) -> String {
        line.spans
            .into_iter()
            .map(|span| span.content.into_owned())
            .collect::<String>()
    }

    #[test]
    fn write_rgba_png_rejects_wrong_byte_count() {
        let fixture = std::env::temp_dir().join("codegraff-test-invalid.png");
        let actual = write_rgba_png(&fixture, 2, 2, &[0, 0, 0, 0])
            .unwrap_err()
            .to_string();
        let expected = "clipboard image had 4 bytes, expected 16 for 2x2 RGBA";

        assert_eq!(actual, expected);
    }

    #[test]
    fn write_rgba_png_writes_supported_image_file() {
        let fixture = std::env::temp_dir().join("codegraff-test-valid.png");
        let _ = std::fs::remove_file(&fixture);
        write_rgba_png(&fixture, 1, 1, &[255, 0, 0, 255]).unwrap();
        let actual = is_supported_image_path(&fixture) && fixture.exists();
        let expected = true;
        let _ = std::fs::remove_file(&fixture);

        assert_eq!(actual, expected);
    }

    #[test]
    fn clipboard_image_path_uses_png_extension() {
        let actual = clipboard_image_path()
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_string);
        let expected = Some("png".to_string());

        assert_eq!(actual, expected);
    }

    #[test]
    fn clipboard_paste_key_accepts_control_or_super_v() {
        let actual = vec![
            is_clipboard_paste_key(modified_key(KeyCode::Char('v'), KeyModifiers::CONTROL)),
            is_clipboard_paste_key(modified_key(KeyCode::Char('V'), KeyModifiers::SUPER)),
            is_clipboard_paste_key(key(KeyCode::Char('v'))),
        ];
        let expected = vec![true, true, false];

        assert_eq!(actual, expected);
    }

    #[test]
    fn escape_stops_streaming_and_clears_idle_composer() {
        let actual = vec![escape_action(true), escape_action(false)];
        let expected = vec![EscapeAction::StopAgent, EscapeAction::ClearComposer];

        assert_eq!(actual, expected);
    }

    #[test]
    fn delete_previous_word_removes_trailing_word_and_spaces() {
        let mut fixture = "hello world   ".to_string();
        delete_previous_word(&mut fixture);
        let actual = fixture;
        let expected = "hello ";

        assert_eq!(actual, expected);
    }

    #[test]
    fn prompt_title_shows_input_shortcuts_on_wide_terminals() {
        let actual = prompt_title(100);
        let expected = "Prompt  Shift/Cmd+↑↓ scroll  Cmd+⌫ clear  Opt+⌫ word";

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_edit_shortcut_maps_mac_and_terminal_deletion_keys() {
        let actual = vec![
            composer_edit_shortcut(modified_key(KeyCode::Backspace, KeyModifiers::SUPER)),
            composer_edit_shortcut(modified_key(KeyCode::Delete, KeyModifiers::CONTROL)),
            composer_edit_shortcut(modified_key(KeyCode::Backspace, KeyModifiers::ALT)),
            composer_edit_shortcut(modified_key(KeyCode::Char('u'), KeyModifiers::CONTROL)),
            composer_edit_shortcut(modified_key(KeyCode::Char('w'), KeyModifiers::CONTROL)),
        ];
        let expected = vec![
            ComposerEditShortcut::ClearLine,
            ComposerEditShortcut::ClearLine,
            ComposerEditShortcut::DeletePreviousWord,
            ComposerEditShortcut::ClearLine,
            ComposerEditShortcut::DeletePreviousWord,
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn composer_scroll_accepts_command_or_shift_arrows() {
        let actual = vec![
            composer_scroll_shortcut(modified_key(KeyCode::Up, KeyModifiers::SUPER)),
            composer_scroll_shortcut(modified_key(KeyCode::Down, KeyModifiers::SHIFT)),
            composer_scroll_shortcut(modified_key(KeyCode::PageUp, KeyModifiers::CONTROL)),
            composer_scroll_shortcut(key(KeyCode::Up)),
        ];
        let expected = vec![
            ComposerScrollShortcut::UpOne,
            ComposerScrollShortcut::DownOne,
            ComposerScrollShortcut::UpPage,
            ComposerScrollShortcut::None,
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn mouse_wheel_scrolls_chat_transcript() {
        let mut fixture = 0;
        handle_mouse_scroll_offset(&mut fixture, MouseEventKind::ScrollUp);
        handle_mouse_scroll_offset(&mut fixture, MouseEventKind::ScrollDown);
        let actual = fixture;
        let expected = 0;

        assert_eq!(actual, expected);
    }

    #[test]
    fn overlay_mouse_wheel_scrolls_from_top() {
        let mut fixture = 0;
        handle_overlay_mouse_scroll_offset(&mut fixture, MouseEventKind::ScrollDown);
        handle_overlay_mouse_scroll_offset(&mut fixture, MouseEventKind::ScrollUp);
        let actual = fixture;
        let expected = 0;

        assert_eq!(actual, expected);
    }

    #[test]
    fn overlay_selection_dialogs_show_local_number_input() {
        let fixture = ModelDialog { options: Vec::new() };
        let actual = render_line(model_dialog_lines(&fixture, 80, "12")[2].clone());
        let expected = "Selection: 12▌";

        assert_eq!(actual, expected);
    }

    #[test]
    fn workflow_command_opens_quoted_goal_and_keeps_actions_available() {
        let fixture = vec![
            parse_workflow_command(":workflow \"fix parser test\""),
            parse_workflow_command("/workflow approve"),
            parse_workflow_command("/workflow edit 2 add exact cargo commands"),
        ];
        let expected = vec![
            WorkflowCommand::Open("fix parser test".to_string()),
            WorkflowCommand::Approve,
            WorkflowCommand::Edit(2, "add exact cargo commands".to_string()),
        ];

        assert_eq!(fixture, expected);
    }

    #[test]
    fn workflow_overlay_action_maps_local_dialog_controls() {
        let actual = vec![
            workflow_overlay_action(""),
            workflow_overlay_action("a"),
            workflow_overlay_action("e"),
            workflow_overlay_action("x"),
            workflow_overlay_action("c"),
            workflow_overlay_action("3"),
        ];
        let expected = vec![
            WorkflowOverlayAction::Approve,
            WorkflowOverlayAction::Approve,
            WorkflowOverlayAction::Edit,
            WorkflowOverlayAction::Export,
            WorkflowOverlayAction::Cancel,
            WorkflowOverlayAction::Select(3),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn workflow_builder_creates_reviewable_topology_with_access_lists() {
        let fixture = "Investigate this failing parser test, patch it, run targeted tests, then review the diff";
        let actual = build_workflow(fixture, &[]);
        let expected_names = vec!["research", "plan", "implement", "test", "review"];
        let expected_summary =
            "research(sage) -> plan(muse) -> implement(forge) -> test(forge) -> review(sage)";

        assert_eq!(
            actual
                .iter()
                .map(|node| node.name.as_str())
                .collect::<Vec<_>>(),
            expected_names
        );
        assert_eq!(workflow_summary(&actual), expected_summary);
        assert_eq!(actual[2].dependencies, vec!["plan".to_string()]);
        assert_eq!(
            actual[4].access,
            vec!["research", "plan", "implement", "test"]
        );
        assert_eq!(actual[3].artifact, "verification log");
    }

    #[test]
    fn workflow_dialog_lines_keep_input_inside_review_modal() {
        let fixture = WorkflowDialog {
            goal: "fix parser".to_string(),
            nodes: build_workflow("fix parser test", &[]),
            selected_node: 1,
            mode: WorkflowDialogMode::Review,
        };
        let actual = workflow_dialog_lines(&fixture, 120, "x")
            .into_iter()
            .map(render_line)
            .collect::<Vec<_>>();

        assert!(actual.contains(&"Action: x▌".to_string()));
        assert!(
            actual
                .iter()
                .any(|line| line.starts_with("▶ 2. test (forge)"))
        );
        assert!(
            actual
                .iter()
                .any(|line| line.contains("dependencies: implement"))
        );
    }

    #[test]
    fn workflow_export_contains_replayable_node_details() {
        let fixture = WorkflowDialog {
            goal: "fix parser".to_string(),
            nodes: build_workflow("fix parser test", &[]),
            selected_node: 0,
            mode: WorkflowDialogMode::Review,
        };
        let actual = export_workflow(&fixture);

        assert!(actual.contains("workflow:\n  goal: fix parser"));
        assert!(actual.contains("topology: implement(forge) -> test(forge)"));
        assert!(actual.contains("artifact: verification log"));
        assert!(actual.contains("access: implement"));
    }

    #[test]
    fn workflow_trace_starts_with_topology_without_chat_noise() {
        let fixture = WorkflowDialog {
            goal: "fix parser".to_string(),
            nodes: build_workflow("fix parser test", &[]),
            selected_node: 0,
            mode: WorkflowDialogMode::Review,
        };
        let actual = workflow_start_trace(&fixture);

        assert_eq!(actual[0], "goal: fix parser");
        assert_eq!(actual[1], "topology: implement(forge) -> test(forge)");
        assert!(
            actual
                .iter()
                .any(|line| line.contains("node 1: implement(forge)"))
        );
        assert!(
            actual
                .iter()
                .any(|line| line.contains("artifact: verification log"))
        );
    }

    #[test]
    fn workflow_status_labels_support_background_run_states() {
        let actual = vec![
            workflow_status_label(WorkflowRunStatus::Running),
            workflow_status_label(WorkflowRunStatus::Finished),
            workflow_status_label(WorkflowRunStatus::Error),
            workflow_status_label(WorkflowRunStatus::Interrupted),
        ];
        let expected = vec!["running", "finished", "failed", "interrupted"];

        assert_eq!(actual, expected);
    }

    #[test]
    fn workflow_trace_chunks_merge_markdown_without_tool_spam() {
        let mut fixture = Vec::new();
        append_trace_chunk(&mut fixture, "first".to_string());
        append_trace_chunk(&mut fixture, " chunk".to_string());
        fixture.push("tool started: read".to_string());
        append_trace_chunk(&mut fixture, "summary".to_string());
        let actual = fixture;
        let expected = vec![
            "first chunk".to_string(),
            "tool started: read".to_string(),
            "summary".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn luminance_thumbnail_uses_ascii_shading() {
        let actual = vec![
            luminance_char(0),
            luminance_char(70),
            luminance_char(150),
            luminance_char(255),
        ];
        let expected = vec![' ', '▒', '▓', '█'];

        assert_eq!(actual, expected);
    }

    #[test]
    fn shifted_question_mark_types_normally() {
        let fixture = modified_key(KeyCode::Char('?'), KeyModifiers::SHIFT);
        let actual = (
            composer_input_char(fixture),
            composer_edit_shortcut(fixture),
            composer_scroll_shortcut(fixture),
            tool_shortcut(fixture),
            is_clipboard_paste_key(fixture),
        );
        let expected = (
            Some('?'),
            ComposerEditShortcut::None,
            ComposerScrollShortcut::None,
            ToolShortcut::None,
            false,
        );

        assert_eq!(actual, expected);
    }

    #[test]
    fn shifted_base_punctuation_is_normalized_for_enhanced_keyboards() {
        let question = modified_key(KeyCode::Char('/'), KeyModifiers::SHIFT);
        let bang = modified_key(KeyCode::Char('1'), KeyModifiers::SHIFT);
        let upper = modified_key(KeyCode::Char('a'), KeyModifiers::SHIFT);
        let actual = (
            composer_input_char(question),
            composer_input_char(bang),
            composer_input_char(upper),
        );
        let expected = (Some('?'), Some('!'), Some('A'));

        assert_eq!(actual, expected);
    }

    #[test]
    fn key_release_events_are_ignored() {
        let fixture = KeyEvent::new_with_kind(
            KeyCode::Char('?'),
            KeyModifiers::SHIFT,
            KeyEventKind::Release,
        );
        let actual = is_key_press(fixture);
        let expected = false;

        assert_eq!(actual, expected);
    }

    #[test]
    fn key_repeat_events_are_accepted() {
        let fixture =
            KeyEvent::new_with_kind(KeyCode::Char('a'), KeyModifiers::NONE, KeyEventKind::Repeat);
        let actual = is_key_press(fixture);
        let expected = true;

        assert_eq!(actual, expected);
    }

    #[test]
    fn tool_shortcut_allows_plain_e_as_text_input() {
        let fixture = key(KeyCode::Char('e'));
        let actual = tool_shortcut(fixture);
        let expected = ToolShortcut::None;

        assert_eq!(actual, expected);
    }

    #[test]
    fn tool_shortcut_uses_control_e_for_expansion() {
        let fixture = modified_key(KeyCode::Char('e'), KeyModifiers::CONTROL);
        let actual = tool_shortcut(fixture);
        let expected = ToolShortcut::Toggle;

        assert_eq!(actual, expected);
    }

    #[test]
    fn tool_shortcut_selects_next_and_previous_tool_cards() {
        let next_fixture = key(KeyCode::Tab);
        let previous_fixture = key(KeyCode::BackTab);
        let actual = (tool_shortcut(next_fixture), tool_shortcut(previous_fixture));
        let expected = (ToolShortcut::Next, ToolShortcut::Previous);

        assert_eq!(actual, expected);
    }

    #[test]
    fn collapsed_tool_card_hides_verbose_detail() {
        let fixture = ToolEntry::info("read", "alpha beta gamma delta epsilon zeta eta theta");
        let actual = rendered_tool_lines(fixture, true, 34);
        let expected = vec![
            "> ▸ Tool read [info]".to_string(),
            "    alpha beta gamma delta epsilo…".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn expanded_tool_card_shows_full_detail_lines() {
        let mut fixture = ToolEntry::info("read", "first line\nsecond line");
        fixture.expanded = true;
        let actual = rendered_tool_lines(fixture, false, 20);
        let expected = vec![
            "  ▾ Tool read [info]".to_string(),
            "    first line".to_string(),
            "    second line".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn compact_tool_output_keeps_small_output_unchanged() {
        let fixture = "first\nsecond";
        let actual = compact_tool_output(fixture);
        let expected = "first\nsecond";

        assert_eq!(actual, expected);
    }

    #[test]
    fn compact_tool_output_truncates_large_output() {
        let fixture = (0..85)
            .map(|index| format!("line {index}"))
            .collect::<Vec<_>>()
            .join("\n");
        let actual = compact_tool_output(&fixture);
        let expected = format!(
            "Large output: 85 lines, {} bytes. Showing first 80 lines.\n{}\n... output truncated in TUI ...",
            fixture.len(),
            (0..80)
                .map(|index| format!("line {index}"))
                .collect::<Vec<_>>()
                .join("\n")
        );

        assert_eq!(actual, expected);
    }

    #[test]
    fn wrap_line_splits_long_lines_by_width() {
        let fixture = "abcdefgh";
        let actual = wrap_line(fixture, 3);
        let expected = vec!["abc".to_string(), "def".to_string(), "gh".to_string()];

        assert_eq!(actual, expected);
    }

    #[test]
    fn wrap_line_uses_terminal_width_for_wide_glyphs() {
        let fixture = "ツツツツ";
        let actual = wrap_line(fixture, 5);
        let expected = vec!["ツツ".to_string(), "ツツ".to_string()];

        assert_eq!(actual, expected);
    }

    #[test]
    fn expanded_tool_card_wraps_wide_glyph_lines_to_card_width() {
        let mut fixture = ToolEntry::info("codedb", "ツツツツ");
        fixture.expanded = true;
        let actual = rendered_tool_lines(fixture, false, 9);
        let expected = vec![
            "  ▾ Tool codedb [info]".to_string(),
            "    ツツ".to_string(),
            "    ツツ".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn expanded_tool_card_keeps_long_mixed_width_output_within_card_width() {
        let detail = "mcp_codedb_tool_codedb_searchツツツツツツツツツツツツツツツツ[done]";
        let mut fixture = ToolEntry::info("codedb", detail);
        fixture.expanded = true;
        let width = 24;
        let actual = rendered_tool_lines(fixture, false, width)
            .into_iter()
            .skip(1)
            .all(|line| text::visible_width(&line) <= width);
        let expected = true;

        assert_eq!(actual, expected);
    }

    #[test]
    fn collapsed_tool_card_keeps_no_line_over_width() {
        let fixture = ToolEntry::info(
            "mcp_codedb_tool_codedb_search_with_extremely_long_tool_name",
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda",
        );
        let width = 24;
        let actual = rendered_tool_lines(fixture, false, width)
            .into_iter()
            .all(|line| text::visible_width(&line) <= width);
        let expected = true;

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_wrapped_lines_keep_no_line_over_width() {
        let mut fixture = Vec::new();
        let width = 28;
        push_markdown_message_lines(
            &mut fixture,
            "CodeGraff",
            "- **bold** ツツツツツツツツツツツツ longwordwithoutspaces",
            width,
        );
        let actual = fixture
            .into_iter()
            .map(render_line)
            .all(|line| text::visible_width(&line) <= width);
        let expected = true;

        assert_eq!(actual, expected);
    }

    #[test]
    fn truncate_single_line_uses_terminal_width_for_wide_glyphs() {
        let fixture = "ツツツツ";
        let actual = truncate_single_line(fixture, 5);
        let expected = "ツツ…";

        assert_eq!(actual, expected);
    }

    #[test]
    fn push_wrapped_aligns_continuation_lines() {
        let mut fixture = Vec::new();
        push_wrapped(&mut fixture, "You", "abcdefgh", Style::default(), 8);
        let actual = fixture
            .into_iter()
            .map(|line| {
                line.spans
                    .into_iter()
                    .map(|span| span.content.into_owned())
                    .collect::<String>()
            })
            .collect::<Vec<_>>();
        let expected = vec![
            "You: abc".to_string(),
            "     def".to_string(),
            "     gh".to_string(),
        ];

        assert_eq!(actual, expected);
    }
}
