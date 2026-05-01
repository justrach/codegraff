use ratatui::style::Style;
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthChar;

/// Returns the display width of a string using terminal cell width semantics.
pub(crate) fn visible_width(text: &str) -> usize {
    text.chars().filter_map(UnicodeWidthChar::width).sum()
}

/// Truncates a string to a single terminal-width-limited line with an ellipsis.
pub(crate) fn truncate_single_line(text: &str, limit: usize) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let limit = limit.max(1);
    if visible_width(&compact) <= limit {
        return compact;
    }

    let mut output = String::new();
    let mut width = 0;
    for ch in compact.chars() {
        let ch_width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if width + ch_width >= limit {
            break;
        }
        output.push(ch);
        width += ch_width;
    }
    output.push('…');
    output
}

/// Pushes wrapped labeled text into a line buffer.
pub(crate) fn push_wrapped(
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

/// Wraps a line by terminal display width.
pub(crate) fn wrap_line(line: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    if line.is_empty() {
        return vec![String::new()];
    }

    let mut wrapped = Vec::new();
    let mut chunk = String::new();
    let mut chunk_width = 0;

    for ch in line.chars() {
        let ch_width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if !chunk.is_empty() && chunk_width + ch_width > width {
            wrapped.push(std::mem::take(&mut chunk));
            chunk_width = 0;
        }
        chunk.push(ch);
        chunk_width += ch_width;
    }

    if !chunk.is_empty() {
        wrapped.push(chunk);
    }

    wrapped
}

/// Returns the byte index for a word-boundary-aware line break.
pub(crate) fn word_boundary_take(text: &str, width: usize) -> usize {
    let width = width.max(1);
    let hard_limit = text
        .char_indices()
        .nth(width)
        .map(|(index, _)| index)
        .unwrap_or(text.len());

    if hard_limit == text.len() {
        return hard_limit;
    }

    text[..hard_limit]
        .char_indices()
        .rev()
        .find(|(_, ch)| ch.is_whitespace())
        .map(|(index, ch)| index + ch.len_utf8())
        .filter(|index| *index > 0)
        .unwrap_or(hard_limit)
}
