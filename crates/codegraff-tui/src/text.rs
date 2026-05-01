use ratatui::style::Style;
use ratatui::text::{Line, Span};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Returns the display width of a string using terminal cell width semantics.
pub(crate) fn visible_width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

/// Sanitizes terminal-oriented text before it is rendered by ratatui.
pub(crate) fn sanitize_render_text(text: &str) -> String {
    strip_ansi_escape_sequences(text)
        .chars()
        .map(|ch| match ch {
            '\n' => '\n',
            '\r' => '\n',
            '\t' => ' ',
            '\u{fffd}' => ' ',
            ch if ch.is_control() => ' ',
            ch => ch,
        })
        .collect()
}

/// Strips ANSI escape sequences that can corrupt the alternate-screen buffer.
pub(crate) fn strip_ansi_escape_sequences(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            output.push(ch);
            continue;
        }

        match chars.peek().copied() {
            Some('[') => {
                chars.next();
                let mut terminated = false;
                let mut aborted = false;
                for ch in chars.by_ref() {
                    if ch.is_whitespace() {
                        aborted = true;
                        break;
                    }
                    if ('@'..='~').contains(&ch) {
                        terminated = true;
                        break;
                    }
                }
                if aborted || !terminated {
                    break;
                }
            }
            Some(']') => {
                chars.next();
                let mut previous = '\0';
                for ch in chars.by_ref() {
                    if ch == '\u{7}' || (previous == '\u{1b}' && ch == '\\') {
                        break;
                    }
                    previous = ch;
                }
            }
            Some(_) => {
                chars.next();
            }
            None => {}
        }
    }

    output
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
    let sanitized = sanitize_render_text(text);
    let label_prefix = format!("{label}: ");
    let continuation_prefix = " ".repeat(label_prefix.chars().count());

    let mut physical_lines = sanitized.lines().peekable();
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
    let mut hard_limit = text.len();
    let mut display_width = 0;

    for (index, ch) in text.char_indices() {
        let ch_width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if display_width + ch_width > width {
            hard_limit = index;
            break;
        }
        display_width += ch_width;
    }

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
