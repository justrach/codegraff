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
    text.replace("**", "").replace('`', "").replace('_', "")
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
        let mut line_spans = vec![Span::styled(line_prefix, prefix_style)];
        line_spans.extend(chunk);
        lines.push(Line::from(line_spans));
    }

    *emitted_first_line = true;
}

fn wrap_spans(spans: Vec<Span<'static>>, width: usize) -> Vec<Vec<Span<'static>>> {
    let width = width.max(1);
    let mut lines: Vec<Vec<Span<'static>>> = vec![Vec::new()];
    let mut current_width = 0;

    for span in spans {
        let style = span.style;
        let mut text = span.content.into_owned();
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
            let take = text
                .char_indices()
                .nth(remaining)
                .map(|(index, _)| index)
                .unwrap_or(text.len());
            let chunk = text[..take].to_string();
            lines
                .last_mut()
                .expect("line should exist")
                .push(Span::styled(chunk, style));
            current_width += text[..take].chars().count();
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
            1 => format!("1 image attached"),
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

fn spawn_input_reader(tx: mpsc::UnboundedSender<AppEvent>) {
    tokio::spawn(async move {
        loop {
            match event::poll(Duration::from_millis(50)) {
                Ok(true) => match event::read() {
                    Ok(TerminalEvent::Key(key)) => {
                        if tx.send(AppEvent::Input(key)).is_err() {
                            return;
                        }
                    }
                    Ok(TerminalEvent::Paste(text)) => {
                        if tx.send(AppEvent::Paste(text)).is_err() {
                            return;
                        }
                    }
                    Ok(_) => {}
                    Err(error) => {
                        let _ = tx.send(AppEvent::Chat(Err(error.into())));
                        return;
                    }
                },
                Ok(false) => {}
                Err(error) => {
                    let _ = tx.send(AppEvent::Chat(Err(error.into())));
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

fn compact_tool_output(text: &str) -> String {
    let sanitized = sanitize_tool_output(text);
    let total_lines = sanitized.lines().count();
    if total_lines <= TOOL_OUTPUT_LINE_LIMIT && sanitized.len() <= TOOL_OUTPUT_BYTE_LIMIT {
        return sanitized;
    }

    let shown_lines = total_lines.min(TOOL_OUTPUT_LINE_LIMIT);
    let mut output = format!(
        "Large output: {total_lines} lines, {} bytes. Showing first {shown_lines} lines.\n",
        sanitized.len()
    );

    for line in sanitized.lines().take(TOOL_OUTPUT_LINE_LIMIT) {
        output.push_str(line);
        output.push('\n');
    }

    output.push_str("... output truncated in TUI ...");
    output
}

fn sanitize_tool_output(text: &str) -> String {
    text.chars()
        .map(|ch| match ch {
            '\n' | '\t' => ch,
            '\u{fffd}' => ' ',
            ch if ch.is_control() => ' ',
            ch => ch,
        })
        .collect()
}

fn push_tool_lines(lines: &mut Vec<Line<'static>>, tool: &ToolEntry, selected: bool, width: usize) {
    let selector = if selected { ">" } else { " " };
    let toggle = if tool.expanded { "▾" } else { "▸" };
    let title = truncate_single_line(&tool.title, width.saturating_sub(18).max(8));
    let card_style = Style::default()
        .fg(tool.status.color())
        .add_modifier(Modifier::BOLD);

    lines.push(Line::from(vec![
        Span::styled(format!("{selector} {toggle} "), card_style),
        Span::styled("Tool ", card_style),
        Span::raw(title),
        Span::styled(format!(" [{}]", tool.status.label()), tool.status.color()),
    ]));

    if tool.detail.trim().is_empty() {
        return;
    }

    if tool.expanded {
        for detail_line in tool.detail.lines() {
            let wrapped = wrap_line(detail_line, width.saturating_sub(4).max(1));
            for chunk in wrapped {
                lines.push(Line::from(vec![Span::raw("    "), Span::raw(chunk)]));
            }
        }
        return;
    }

    let summary = truncate_single_line(tool.detail.trim(), COLLAPSED_TOOL_DETAIL_LIMIT);
    lines.push(Line::from(vec![
        Span::raw("    "),
        Span::styled(summary, Style::default().fg(Color::DarkGray)),
    ]));
}

fn truncate_single_line(text: &str, limit: usize) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let limit = limit.max(1);
    if compact.chars().count() <= limit {
        return compact;
    }

    let mut output = compact
        .chars()
        .take(limit.saturating_sub(1))
        .collect::<String>();
    output.push('…');
    output
}

fn push_wrapped(
    lines: &mut Vec<Line<'static>>,
    label: &str,
    text: &str,
    style: Style,
    width: usize,
) {
    let width = width.max(1);
    let label_prefix = format!("{label}: ");
    let continuation_prefix = " ".repeat(label_prefix.chars().count());

    let mut physical_lines = text.lines().peekable();
    if physical_lines.peek().is_none() {
        lines.push(Line::from(Span::styled(format!("{label}:"), style)));
        return;
    }

    for (index, physical_line) in physical_lines.enumerate() {
        let prefix = if index == 0 {
            label_prefix.as_str()
        } else {
            "  "
        };
        let continuation = if index == 0 {
            continuation_prefix.as_str()
        } else {
            "  "
        };
        let available_width = width.saturating_sub(prefix.chars().count()).max(1);
        let wrapped = wrap_line(physical_line, available_width);

        for (chunk_index, chunk) in wrapped.into_iter().enumerate() {
            if index == 0 && chunk_index == 0 {
                lines.push(Line::from(vec![
                    Span::styled(prefix.to_string(), style),
                    Span::raw(chunk),
                ]));
            } else if chunk_index == 0 {
                lines.push(Line::from(vec![
                    Span::raw(prefix.to_string()),
                    Span::raw(chunk),
                ]));
            } else {
                lines.push(Line::from(vec![
                    Span::raw(continuation.to_string()),
                    Span::raw(chunk),
                ]));
            }
        }
    }
}

fn wrap_line(line: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let chars = line.chars().collect::<Vec<_>>();

    if chars.is_empty() {
        return vec![String::new()];
    }

    let mut wrapped = Vec::new();
    let mut start = 0;

    while start < chars.len() {
        let end = (start + width).min(chars.len());
        wrapped.push(chars[start..end].iter().collect());
        start = end;
    }

    wrapped
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

struct TerminalGuard {
    terminal: Terminal<CrosstermBackend<io::Stdout>>,
}

impl TerminalGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(
            stdout,
            EnterAlternateScreen,
            EnableBracketedPaste,
            PushKeyboardEnhancementFlags(
                KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
                    | KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES,
            )
        )?;
        let backend = CrosstermBackend::new(stdout);
        let terminal = Terminal::new(backend)?;
        Ok(Self { terminal })
    }

    fn draw<F>(&mut self, render_callback: F) -> Result<()>
    where
        F: FnOnce(&mut ratatui::Frame<'_>),
    {
        self.terminal.draw(render_callback)?;
        Ok(())
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(
            self.terminal.backend_mut(),
            PopKeyboardEnhancementFlags,
            DisableBracketedPaste,
            LeaveAlternateScreen
        );
        let _ = self.terminal.show_cursor();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

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
        push_markdown_message_lines(&mut fixture, "Forge", "# Main\n## Title\n- item", 40);
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "Forge: ▰ Main".to_string(),
            "  ◆ Title".to_string(),
            "  • item".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_code_blocks_are_preserved() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(&mut fixture, "Forge", "```bash\ncargo test\n```", 40);
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "Forge: ╭─ bash".to_string(),
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
            "Forge",
            "- [x] done\n- [ ] todo\n> quoted **text**\n---\n[docs](https://example.com)",
            60,
        );
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "Forge: ☑ done".to_string(),
            "  ☐ todo".to_string(),
            "  ▌ quoted text".to_string(),
            "  ────────────────────────".to_string(),
            "  docs (https://example.com)".to_string(),
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn markdown_list_continuations_align_under_list_text() {
        let mut fixture = Vec::new();
        push_markdown_message_lines(
            &mut fixture,
            "Forge",
            "- this is a long item that should wrap nicely",
            24,
        );
        let actual = fixture.into_iter().map(render_line).collect::<Vec<_>>();
        let expected = vec![
            "Forge: • this is a long ".to_string(),
            "         item that should ".to_string(),
            "         wrap nicely".to_string(),
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
        let actual = sanitize_tool_output(fixture);
        let expected = "ok  \nnext";

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
            "    Large output: 92 lines, 3445 bytes. Showing first 80 lines. more and mo…"
                .to_string(),
        ];

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
        let control_fixture = modified_key(KeyCode::Char('v'), KeyModifiers::CONTROL);
        let super_fixture = modified_key(KeyCode::Char('v'), KeyModifiers::SUPER);
        let plain_fixture = key(KeyCode::Char('v'));
        let actual = (
            is_clipboard_paste_key(control_fixture),
            is_clipboard_paste_key(super_fixture),
            is_clipboard_paste_key(plain_fixture),
        );
        let expected = (true, true, false);

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

