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

    fn push_chat_response(&mut self, response: ChatResponse) {
        if response.is_empty() {
            return;
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
                self.is_streaming = false;
                self.status = TuiStatus::Interrupted;
                self.transcript
                    .push(TranscriptEntry::Error(format!("Interrupted: {reason:?}")));
            }
            ChatResponse::TaskComplete => {
                self.is_streaming = false;
                self.status = TuiStatus::Finished;
            }
        }
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

        let header = Paragraph::new(Line::from(vec![
            Span::styled(
                "Codegraff",
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            Span::styled(
                compact_status(self.status),
                Style::default().fg(status_color(self.status)),
            ),
        ]))
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
            .style(if self.is_streaming {
                Style::default().fg(Color::DarkGray)
            } else {
                Style::default()
            })
            .block(Block::default().title(prompt_title).borders(Borders::ALL))
            .scroll((composer_scroll, 0));
        frame.render_widget(composer, chunks[2]);
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
                    push_markdown_message_lines(&mut lines, "Forge", text, width)
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

    for physical_line in text.lines() {
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

        if marker == "`" {
            if let Some(end) = remaining[1..].find('`') {
                let code = &remaining[1..1 + end];
                spans.push(Span::styled(
                    format!(" {code} "),
                    Style::default().fg(Color::Yellow).bg(Color::Black),
                ));
                remaining = &remaining[end + 2..];
                continue;
            }
        }

        if marker == "[" {
            if let Some((label, url, consumed)) = markdown_link(remaining) {
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
        }

        if marker == "**" {
            if let Some(end) = remaining[2..].find("**") {
                let bold = &remaining[2..2 + end];
                spans.push(Span::styled(
                    strip_inline_markdown(bold),
                    base_style.add_modifier(Modifier::BOLD),
                ));
                remaining = &remaining[end + 4..];
                continue;
            }
        }

        if marker == "*" || marker == "_" {
            if let Some(end) = remaining[1..].find(marker) {
                let italic = &remaining[1..1 + end];
                spans.push(Span::styled(
                    strip_inline_markdown(italic),
                    base_style.add_modifier(Modifier::ITALIC),
                ));
                remaining = &remaining[end + 2..];
                continue;
            }
        }

        push_inline_text(&mut spans, marker, base_style);
        remaining = &remaining[marker.len()..];
    }

    if spans.is_empty() {
