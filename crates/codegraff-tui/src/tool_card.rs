use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use crate::text::{truncate_single_line, wrap_line};

/// Maximum number of tool output lines rendered before compacting.
pub(crate) const TOOL_OUTPUT_LINE_LIMIT: usize = 80;
/// Maximum number of tool output bytes rendered before compacting.
pub(crate) const TOOL_OUTPUT_BYTE_LIMIT: usize = 12_000;
const COLLAPSED_TOOL_DETAIL_LIMIT: usize = 72;

/// Display state for a tool invocation card.
#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum ToolStatus {
    Running,
    Done,
    Failed,
    Info,
}

impl ToolStatus {
    /// Returns the compact status label shown on a tool card.
    pub(crate) fn label(self) -> &'static str {
        match self {
            ToolStatus::Running => "running",
            ToolStatus::Done => "done",
            ToolStatus::Failed => "failed",
            ToolStatus::Info => "info",
        }
    }

    /// Returns the color used to render this status.
    pub(crate) fn color(self) -> Color {
        match self {
            ToolStatus::Running => Color::Yellow,
            ToolStatus::Done => Color::Green,
            ToolStatus::Failed => Color::Red,
            ToolStatus::Info => Color::Blue,
        }
    }
}

/// Tool transcript entry rendered by the CodeGraff TUI.
#[derive(Clone)]
pub(crate) struct ToolEntry {
    pub(crate) title: String,
    pub(crate) detail: String,
    pub(crate) status: ToolStatus,
    pub(crate) expanded: bool,
}

impl ToolEntry {
    /// Creates a running tool card.
    pub(crate) fn running(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            detail: String::new(),
            status: ToolStatus::Running,
            expanded: false,
        }
    }

    /// Creates a completed tool card.
    pub(crate) fn finished(title: impl Into<String>, status: ToolStatus) -> Self {
        Self {
            title: title.into(),
            detail: String::new(),
            status,
            expanded: false,
        }
    }

    /// Creates an informational tool card.
    pub(crate) fn info(title: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            detail: detail.into(),
            status: ToolStatus::Info,
            expanded: false,
        }
    }
}

/// Compacts large tool output while preserving useful leading context.
pub(crate) fn compact_tool_output(text: &str) -> String {
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

/// Sanitizes terminal-oriented output for stable rendering in the chat pane.
pub(crate) fn sanitize_tool_output(text: &str) -> String {
    let stripped = strip_ansi_escape_sequences(text);
    stripped
        .chars()
        .map(|ch| match ch {
            '\n' | '\t' => ch,
            '\u{fffd}' => ' ',
            ch if ch.is_control() => ' ',
            ch => ch,
        })
        .collect::<String>()
        .lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect::<Vec<_>>()
        .join("\n")
}

fn strip_ansi_escape_sequences(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            output.push(ch);
            continue;
        }

        if chars.next_if_eq(&'[').is_none() {
            continue;
        }

        for ch in chars.by_ref() {
            if ch.is_whitespace() {
                return output;
            }

            if ('@'..='~').contains(&ch) {
                break;
            }
        }
    }

    output
}

/// Pushes renderable lines for a tool card.
pub(crate) fn push_tool_lines(
    lines: &mut Vec<Line<'static>>,
    tool: &ToolEntry,
    selected: bool,
    width: usize,
) {
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

    let detail_width = width.saturating_sub(4).max(1);
    if tool.expanded {
        for detail_line in tool.detail.lines() {
            let wrapped = wrap_line(detail_line, detail_width);
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
