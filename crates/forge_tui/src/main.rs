use std::io::{self, Cursor};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use crossterm::event::{
    self, DisableBracketedPaste, EnableBracketedPaste, Event as TerminalEvent, KeyCode, KeyEvent,
    KeyEventKind, KeyModifiers, KeyboardEnhancementFlags, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use forge_api::{
    API, ChatRequest, ChatResponse, ChatResponseContent, Conversation, Event, ForgeAPI, ForgeConfig,
};
use futures::StreamExt;
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};
use tokio::sync::mpsc;

const TOOL_OUTPUT_LINE_LIMIT: usize = 80;
const TOOL_OUTPUT_BYTE_LIMIT: usize = 12_000;
const COLLAPSED_TOOL_DETAIL_LIMIT: usize = 72;
const MAX_COMPOSER_INNER_HEIGHT: usize = 9;
const IMAGE_THUMBNAIL_COLUMNS: usize = 10;
const IMAGE_THUMBNAIL_ROWS: usize = 3;

#[tokio::main]
async fn main() -> Result<()> {
    let config =
        ForgeConfig::read().context("Failed to read Forge configuration from .forge.toml")?;
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let api = ForgeAPI::init(cwd, config);
    Tui::new(api).run().await
}

struct Tui<A> {
    api: A,
    conversation_id: forge_api::ConversationId,
    transcript: Vec<TranscriptEntry>,
    composer: String,
    image_attachments: Vec<ImageAttachment>,
    status: TuiStatus,
    scroll_from_bottom: usize,
    composer_scroll_from_bottom: usize,
    selected_tool: Option<usize>,
    is_streaming: bool,
    should_quit: bool,
}

#[derive(Clone, Copy)]
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
struct ImagePreview {
    width: u32,
    height: u32,
    thumbnail: Vec<String>,
}

#[derive(Clone)]
struct ToolEntry {
    title: String,
    detail: String,
    status: ToolStatus,
    expanded: bool,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum ToolStatus {
    Running,
    Done,
    Failed,
    Info,
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

impl ToolEntry {
    fn running(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            detail: String::new(),
            status: ToolStatus::Running,
            expanded: false,
        }
    }

    fn finished(title: impl Into<String>, status: ToolStatus) -> Self {
        Self {
            title: title.into(),
            detail: String::new(),
            status,
            expanded: false,
        }
    }

    fn info(title: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            detail: detail.into(),
            status: ToolStatus::Info,
            expanded: false,
        }
    }
}

impl ToolStatus {
    fn label(self) -> &'static str {
        match self {
            ToolStatus::Running => "running",
            ToolStatus::Done => "done",
            ToolStatus::Failed => "failed",
            ToolStatus::Info => "info",
        }
    }

    fn color(self) -> Color {
        match self {
            ToolStatus::Running => Color::Yellow,
            ToolStatus::Done => Color::Green,
            ToolStatus::Failed => Color::Red,
            ToolStatus::Info => Color::Blue,
        }
    }
}

enum AppEvent {
    Input(KeyEvent),
    Paste(String),
    Chat(Result<ChatResponse>),
}

impl<A: API + 'static> Tui<A> {
    fn new(api: A) -> Self {
        let conversation = Conversation::generate();
        Self {
            api,
            conversation_id: conversation.id,
            transcript: vec![TranscriptEntry::Status(
                "Codegraff started. Paste image paths with Cmd+V/Ctrl+V or use /image <path>. Press Enter to send. Ctrl+C exits."
                    .to_string(),
            )],
            composer: String::new(),
            image_attachments: Vec::new(),
            status: TuiStatus::Ready,
            scroll_from_bottom: 0,
            composer_scroll_from_bottom: 0,
            selected_tool: None,
            is_streaming: false,
            should_quit: false,
        }
    }

    async fn run(mut self) -> Result<()> {
        self.api
            .upsert_conversation(Conversation::new(self.conversation_id))
            .await?;

        let mut terminal = TerminalGuard::enter()?;
        let (tx, mut rx) = mpsc::unbounded_channel();
        spawn_input_reader(tx.clone());

        loop {
            terminal.draw(|frame| self.render(frame))?;

            if self.should_quit {
                break;
            }

            if let Some(event) = rx.recv().await {
                match event {
                    AppEvent::Input(key) => self.handle_input(key, tx.clone()).await?,
                    AppEvent::Paste(text) => self.handle_paste(text),
                    AppEvent::Chat(response) => self.handle_chat_response(response),
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
            KeyCode::Backspace => self.delete_composer_char(),
            KeyCode::Enter if !self.is_streaming => self.handle_enter(tx).await?,
            KeyCode::Esc => self.clear_composer(),
            _ => {}
        }

        Ok(())
    }

    fn push_composer_char(&mut self, ch: char) {
        self.composer.push(ch);
        self.composer_scroll_from_bottom = 0;
    }

    fn delete_composer_char(&mut self) {
        self.composer.pop();
        self.composer_scroll_from_bottom = 0;
    }

    fn clear_composer(&mut self) {
        self.composer.clear();
        self.image_attachments.clear();
        self.composer_scroll_from_bottom = 0;
    }

    fn handle_paste(&mut self, text: String) {
        self.apply_paste_text(text);
    }

    fn paste_from_clipboard(&mut self) {
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
        let pasted = parse_pasted_images(&text);
        if pasted.is_empty() {
            self.composer.push_str(&normalize_paste_text(&text));
            self.composer_scroll_from_bottom = 0;
            return;
        }

        for image in pasted {
            self.attach_image(image);
        }
        self.composer_scroll_from_bottom = 0;
    }

    fn attach_image(&mut self, image: ImageAttachment) {
        let image = image.with_preview();
        self.image_attachments.push(image);
        self.composer_scroll_from_bottom = 0;
    }

    async fn handle_enter(&mut self, tx: mpsc::UnboundedSender<AppEvent>) -> Result<()> {
        let raw_prompt = self.composer.trim().to_string();
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

        let event = build_chat_event(&raw_prompt, &self.image_attachments);
        let display_prompt = build_display_prompt(&raw_prompt, &self.image_attachments);
        self.composer.clear();
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

    async fn spawn_chat(&self, event: Event, tx: mpsc::UnboundedSender<AppEvent>) -> Result<()> {
        let chat = ChatRequest::new(event, self.conversation_id);
        let mut stream = self.api.chat(chat).await?;

        tokio::spawn(async move {
            while let Some(response) = stream.next().await {
                if tx.send(AppEvent::Chat(response)).is_err() {
                    return;
                }
            }
        });

        Ok(())
    }

    fn handle_chat_response(&mut self, response: Result<ChatResponse>) {
        match response {
            Ok(response) => self.push_chat_response(response),
            Err(error) => {
                self.is_streaming = false;
                self.status = TuiStatus::Error;
                self.transcript
                    .push(TranscriptEntry::Error(format!("{error:#}")));
            }
        }
    }

    fn handle_composer_scroll_key(&mut self, key: KeyEvent) -> bool {
        match composer_scroll_shortcut(key) {
            ComposerScrollShortcut::UpOne => {
                self.composer_scroll_from_bottom =
                    self.composer_scroll_from_bottom.saturating_add(1);
                true
            }
            ComposerScrollShortcut::DownOne => {
                self.composer_scroll_from_bottom =
                    self.composer_scroll_from_bottom.saturating_sub(1);
                true
            }
            ComposerScrollShortcut::UpPage => {
                self.composer_scroll_from_bottom =
                    self.composer_scroll_from_bottom.saturating_add(5);
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
                self.scroll_from_bottom = self.scroll_from_bottom.saturating_add(1);
                true
            }
            KeyCode::Down => {
                self.scroll_from_bottom = self.scroll_from_bottom.saturating_sub(1);
                true
            }
            KeyCode::PageUp => {
                self.scroll_from_bottom = self.scroll_from_bottom.saturating_add(10);
                true
            }
            KeyCode::PageDown => {
                self.scroll_from_bottom = self.scroll_from_bottom.saturating_sub(10);
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
