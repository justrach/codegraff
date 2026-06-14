use std::path::Path;

use forge_domain::{ContextMessage, Conversation, Role};
use roxmltree::{Document, Node};

use crate::dto::{
    FileOperationDto, SessionMessageDto, ToolCallDetailDto, map_tool_call_detail,
    map_tool_result_detail, summarize_tool_result,
};
use crate::runtime::WorkspaceKind;

const DISPLAY_PROMPT_TAGS: &[&str] = &["feedback", "task"];
const PARTIAL_SUMMARY_FRAME_PREFIX: &str = "Use the following summary frames as the authoritative reference for all coding suggestions and decisions. Do not re-explain or revisit it unless I ask. Additional summary frames will be added as the conversation progresses.";
const PARTIAL_SUMMARY_FRAME_HEADING: &str = "## Summary";
const PARTIAL_SUMMARY_FRAME_FOOTER: &str = "Proceed with implementation based on this context.";
const CONTEXT_COMPACTED_LABEL: &str = "Context automatically compacted";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SummaryFrameRole {
    User,
    Assistant,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum SummaryFrameContent {
    Text(String),
    Tool(SummaryFrameTool),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SummaryFrameBlock {
    role: SummaryFrameRole,
    contents: Vec<SummaryFrameContent>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SummaryFrameTool {
    name: String,
    detail: ToolCallDetailDto,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PersistedConversationSummary {
    pub(crate) conversation_id: String,
    pub(crate) title: String,
    pub(crate) updated_at: Option<String>,
}

impl PersistedConversationSummary {
    pub(crate) fn from_conversation(conversation: &Conversation) -> Self {
        Self {
            conversation_id: conversation.id.into_string(),
            title: conversation_title(conversation),
            updated_at: conversation
                .metadata
                .updated_at
                .or(Some(conversation.metadata.created_at))
                .map(|value| value.to_rfc3339()),
        }
    }
}

pub(crate) fn history_request_id(conversation_id: &str) -> String {
    format!("history:{conversation_id}")
}

pub(crate) fn session_messages_from_conversation(
    conversation: &Conversation,
) -> Vec<SessionMessageDto> {
    let request_id = history_request_id(&conversation.id.to_string());
    let mut messages = Vec::new();

    if let Some(context) = &conversation.context {
        for (index, entry) in context.messages.iter().enumerate() {
            match &entry.message {
                ContextMessage::Text(text) => match text.role {
                    Role::User => {
                        if let Some(summary_messages) =
                            expand_internal_summary_frame(&text.content, &request_id, index)
                        {
                            messages.extend(summary_messages);
                            continue;
                        }

                        let content = user_prompt_text_for_display(&text.content);
                        if !content.is_empty() {
                            messages.push(SessionMessageDto::User {
                                id: format!("history-user:{index}"),
                                request_id: request_id.clone(),
                                text: content,
                            });
                        }
                    }
                    Role::Assistant => {
                        let reasoning = text
                            .reasoning_details
                            .as_ref()
                            .map(|details| {
                                details
                                    .iter()
                                    .filter_map(|detail| detail.text.as_deref())
                                    .map(str::trim)
                                    .filter(|text| !text.is_empty())
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            })
                            .filter(|text| !text.is_empty());

                        if let Some(reasoning) = reasoning {
                            messages.push(SessionMessageDto::Reasoning {
                                id: format!("history-reasoning:{index}"),
                                request_id: request_id.clone(),
                                text: reasoning,
                            });
                        }

                        let content = text.content.trim();
                        if !content.is_empty() {
                            messages.push(SessionMessageDto::Assistant {
                                id: format!("history-assistant:{index}"),
                                request_id: request_id.clone(),
                                text: content.to_string(),
                            });
                        }

                        if let Some(tool_calls) = &text.tool_calls {
                            messages.extend(tool_calls.iter().map(|tool_call| {
                                SessionMessageDto::ToolStart {
                                    id: format!(
                                        "history-tool-start:{index}:{}",
                                        tool_call
                                            .call_id
                                            .as_ref()
                                            .map(|call_id| call_id.as_str())
                                            .unwrap_or_else(|| tool_call.name.as_str()),
                                    ),
                                    request_id: request_id.clone(),
                                    name: tool_call.name.as_str().to_string(),
                                    call_id: tool_call
                                        .call_id
                                        .as_ref()
                                        .map(|call_id| call_id.as_str().to_string()),
                                    detail: map_tool_call_detail(tool_call),
                                }
                            }));
                        }
                    }
                    Role::System => {}
                },
                ContextMessage::Tool(result) => {
                    messages.push(SessionMessageDto::ToolEnd {
                        id: format!("history-tool-end:{index}"),
                        request_id: request_id.clone(),
                        name: result.name.as_str().to_string(),
                        call_id: result
                            .call_id
                            .as_ref()
                            .map(|call_id| call_id.as_str().to_string()),
                        summary: summarize_tool_result(result),
                        is_error: result.is_error(),
                        detail: map_tool_result_detail(result),
                    });
                }
                ContextMessage::Image(_) => {}
            }
        }
    }

    messages
}

pub(crate) fn derive_conversation_title_from_messages(messages: &[SessionMessageDto]) -> String {
    if let Some(title) = messages.iter().find_map(title_candidate_from_message) {
        return title;
    }

    "New chat".to_string()
}

pub(crate) fn user_prompt_text_for_display(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    match extract_structured_prompt_text(trimmed) {
        Some(text) => text,
        None => trimmed.to_string(),
    }
}

pub(crate) fn workspace_name(path: &Path) -> String {
    path.file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

pub(crate) fn workspace_display_name(kind: WorkspaceKind, path: &Path) -> String {
    match kind {
        WorkspaceKind::Project => workspace_name(path),
        WorkspaceKind::ManagedChat => "New chat".to_string(),
    }
}

pub(crate) fn resolved_workspace_display_name(
    kind: WorkspaceKind,
    path: &Path,
    display_name: Option<&str>,
) -> String {
    display_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| workspace_display_name(kind, path))
}

fn conversation_title(conversation: &Conversation) -> String {
    if let Some(title) = conversation
        .title
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
    {
        let display = if is_internal_summary_frame(title) {
            String::new()
        } else {
            user_prompt_text_for_display(title)
        };

        if !display.is_empty() {
            return display;
        }
    }

    derive_conversation_title_from_messages(&session_messages_from_conversation(conversation))
}

fn title_candidate_from_message(message: &SessionMessageDto) -> Option<String> {
    match message {
        SessionMessageDto::User { text, .. } => {
            if is_internal_summary_frame(text) {
                return None;
            }

            let display = user_prompt_text_for_display(text);
            if display.is_empty() {
                None
            } else {
                Some(display.chars().take(72).collect())
            }
        }
        SessionMessageDto::Assistant { text, .. } => {
            let collapsed = collapse_whitespace(text);
            if collapsed.is_empty() {
                None
            } else {
                Some(collapsed.chars().take(72).collect())
            }
        }
        _ => None,
    }
}

fn collapse_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn expand_internal_summary_frame(
    value: &str,
    request_id: &str,
    entry_index: usize,
) -> Option<Vec<SessionMessageDto>> {
    let blocks = parse_internal_summary_frame(value)?;
    let request_id = request_id.to_string();
    let mut messages = vec![SessionMessageDto::ContextCompacted {
        id: format!("history-summary-compacted:{entry_index}"),
        request_id: request_id.clone(),
        text: CONTEXT_COMPACTED_LABEL.to_string(),
    }];

    for (block_index, block) in blocks.into_iter().enumerate() {
        let role = block.role;
        let mut tool_index = 0usize;
        let mut text_index = 0usize;

        for content in block.contents {
            match (role, content) {
                (SummaryFrameRole::User, SummaryFrameContent::Text(text)) => {
                    let display = user_prompt_text_for_display(&text);
                    if display.is_empty() {
                        continue;
                    }

                    messages.push(SessionMessageDto::User {
                        id: format!(
                            "history-summary-user:{entry_index}:{block_index}:{text_index}"
                        ),
                        request_id: request_id.clone(),
                        text: display,
                    });
                    text_index += 1;
                }
                (SummaryFrameRole::Assistant, SummaryFrameContent::Text(text)) => {
                    let trimmed = text.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    messages.push(SessionMessageDto::Assistant {
                        id: format!(
                            "history-summary-assistant:{entry_index}:{block_index}:{text_index}"
                        ),
                        request_id: request_id.clone(),
                        text: trimmed.to_string(),
                    });
                    text_index += 1;
                }
                (SummaryFrameRole::Assistant, SummaryFrameContent::Tool(tool)) => {
                    let call_id = format!("summary:{entry_index}:{block_index}:{tool_index}");

                    messages.push(SessionMessageDto::ToolStart {
                        id: format!(
                            "history-summary-tool-start:{entry_index}:{block_index}:{tool_index}"
                        ),
                        request_id: request_id.clone(),
                        name: tool.name.clone(),
                        call_id: Some(call_id.clone()),
                        detail: tool.detail.clone(),
                    });
                    messages.push(SessionMessageDto::ToolEnd {
                        id: format!(
                            "history-summary-tool-end:{entry_index}:{block_index}:{tool_index}"
                        ),
                        request_id: request_id.clone(),
                        name: tool.name,
                        call_id: Some(call_id),
                        summary: None,
                        is_error: false,
                        detail: None,
                    });
                    tool_index += 1;
                }
                _ => {}
            }
        }
    }

    Some(messages)
}

fn is_internal_summary_frame(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.starts_with(PARTIAL_SUMMARY_FRAME_PREFIX)
        && trimmed.contains(PARTIAL_SUMMARY_FRAME_HEADING)
        && trimmed.ends_with(PARTIAL_SUMMARY_FRAME_FOOTER)
}

fn parse_internal_summary_frame(value: &str) -> Option<Vec<SummaryFrameBlock>> {
    if !is_internal_summary_frame(value) {
        return None;
    }

    let trimmed = value.trim();
    let footer_start = trimmed.rfind(PARTIAL_SUMMARY_FRAME_FOOTER)?;
    let before_footer = trimmed[..footer_start].trim_end();
    let summary_body = before_footer
        .strip_prefix(PARTIAL_SUMMARY_FRAME_PREFIX)?
        .trim_start();
    let summary_body = summary_body
        .strip_prefix(PARTIAL_SUMMARY_FRAME_HEADING)?
        .trim_start();
    let summary_body = summary_body
        .strip_suffix("---")
        .unwrap_or(summary_body)
        .trim_end();
    let lines = summary_body.lines().collect::<Vec<_>>();
    let mut blocks = Vec::new();
    let mut cursor = 0usize;

    while cursor < lines.len() {
        let line = lines[cursor].trim();
        if line.is_empty() {
            cursor += 1;
            continue;
        }

        if line == "---" {
            break;
        }

        let Some(role) = parse_summary_frame_role(line) else {
            cursor += 1;
            continue;
        };
        cursor += 1;

        let mut contents = Vec::new();
        while cursor < lines.len() {
            let line = lines[cursor].trim();
            if line == "---" || parse_summary_frame_role(line).is_some() {
                break;
            }
            if line.is_empty() {
                cursor += 1;
                continue;
            }

            if line == "````" {
                let text = collect_fenced_block(&lines, &mut cursor, "````");
                if !text.trim().is_empty() {
                    contents.push(SummaryFrameContent::Text(text));
                }
                continue;
            }

            if let Some(tool) = parse_summary_frame_tool(&lines, &mut cursor) {
                contents.push(SummaryFrameContent::Tool(tool));
                continue;
            }

            let text = collect_plain_block(&lines, &mut cursor);
            if !text.trim().is_empty() {
                contents.push(SummaryFrameContent::Text(text));
            }
        }

        if !contents.is_empty() {
            blocks.push(SummaryFrameBlock { role, contents });
        }
    }

    Some(blocks)
}

fn parse_summary_frame_role(line: &str) -> Option<SummaryFrameRole> {
    let trimmed = line.trim();
    let remainder = trimmed.strip_prefix("### ")?;
    let (_, role) = remainder.split_once(". ")?;

    Some(match role.trim() {
        "User" => SummaryFrameRole::User,
        "Assistant" => SummaryFrameRole::Assistant,
        _ => SummaryFrameRole::Other,
    })
}

fn parse_summary_frame_tool(lines: &[&str], cursor: &mut usize) -> Option<SummaryFrameTool> {
    let line = lines.get(*cursor)?.trim();

    if let Some(value) = line.strip_prefix("**Read:**") {
        *cursor += 1;
        let path = extract_inline_value(value)?;
        return Some(SummaryFrameTool {
            name: "read".to_string(),
            detail: ToolCallDetailDto::FileRead { path, start_line: None, end_line: None },
        });
    }

    if let Some(value) = line.strip_prefix("**Update:**") {
        *cursor += 1;
        return Some(SummaryFrameTool {
            name: "update".to_string(),
            detail: ToolCallDetailDto::FileUpdate {
                path: extract_inline_value(value)?,
                operation: FileOperationDto::Replace,
            },
        });
    }

    if let Some(value) = line.strip_prefix("**Delete:**") {
        *cursor += 1;
        return Some(SummaryFrameTool {
            name: "remove".to_string(),
            detail: ToolCallDetailDto::FileUpdate {
                path: extract_inline_value(value)?,
                operation: FileOperationDto::Remove,
            },
        });
    }

    if let Some(value) = line.strip_prefix("**Search:**") {
        *cursor += 1;
        return Some(SummaryFrameTool {
            name: "search".to_string(),
            detail: ToolCallDetailDto::Search {
                pattern: extract_inline_value(value)?,
                path: None,
                glob: None,
                file_type: None,
            },
        });
    }

    if let Some(value) = line.strip_prefix("**Skill:**") {
        *cursor += 1;
        return Some(SummaryFrameTool {
            name: "skill".to_string(),
            detail: ToolCallDetailDto::Skill { name: extract_inline_value(value)? },
        });
    }

    if line == "**Semantic Search:**" {
        *cursor += 1;
        let queries = collect_bullet_values(lines, cursor);
        if queries.is_empty() {
            return None;
        }

        return Some(SummaryFrameTool {
            name: "codebase_search".to_string(),
            detail: ToolCallDetailDto::CodebaseSearch { queries },
        });
    }

    if line.starts_with("**Execute:**") {
        *cursor += 1;
        skip_blank_lines(lines, cursor);
        let command = collect_fenced_block(lines, cursor, "```");
        if command.trim().is_empty() {
            return None;
        }

        return Some(SummaryFrameTool {
            name: "shell".to_string(),
            detail: ToolCallDetailDto::Shell { command, cwd: None, description: None },
        });
    }

    if line == "**Task Plan:**" {
        *cursor += 1;
        let changes = collect_bullet_values(lines, cursor);
        if changes.is_empty() {
            return None;
        }

        return Some(SummaryFrameTool {
            name: "todo_write".to_string(),
            detail: ToolCallDetailDto::TodoWrite { count: changes.len() },
        });
    }

    if let Some(value) = line.strip_prefix("**MCP:**") {
        *cursor += 1;
        return Some(SummaryFrameTool {
            name: "mcp".to_string(),
            detail: ToolCallDetailDto::Unknown {
                name: extract_inline_value(value).unwrap_or_else(|| "mcp".to_string()),
            },
        });
    }

    None
}

fn collect_fenced_block(lines: &[&str], cursor: &mut usize, fence: &str) -> String {
    let Some(line) = lines.get(*cursor) else {
        return String::new();
    };
    if line.trim() != fence {
        return String::new();
    }

    *cursor += 1;
    let start = *cursor;
    while *cursor < lines.len() && lines[*cursor].trim() != fence {
        *cursor += 1;
    }
    let text = lines[start..(*cursor).min(lines.len())].join("\n");
    if *cursor < lines.len() {
        *cursor += 1;
    }
    text
}

fn collect_bullet_values(lines: &[&str], cursor: &mut usize) -> Vec<String> {
    let mut values = Vec::new();

    while *cursor < lines.len() {
        let line = lines[*cursor].trim();
        if let Some(value) = line.strip_prefix("- ") {
            if let Some(text) = extract_inline_value(value) {
                values.push(text);
            }
            *cursor += 1;
            continue;
        }
        if line.is_empty() {
            *cursor += 1;
            continue;
        }
        break;
    }

    values
}

fn collect_plain_block(lines: &[&str], cursor: &mut usize) -> String {
    let start = *cursor;
    while *cursor < lines.len() {
        let line = lines[*cursor].trim();
        if line.is_empty()
            || line == "---"
            || line == "````"
            || parse_summary_frame_role(line).is_some()
            || line.starts_with("**")
        {
            break;
        }
        *cursor += 1;
    }

    lines[start..*cursor].join("\n")
}

fn extract_inline_value(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Some(inner) = trimmed
        .strip_prefix('`')
        .and_then(|value| value.strip_suffix('`'))
    {
        let value = inner.trim();
        if value.is_empty() {
            None
        } else {
            Some(value.to_string())
        }
    } else {
        Some(trimmed.to_string())
    }
}

fn skip_blank_lines(lines: &[&str], cursor: &mut usize) {
    while *cursor < lines.len() && lines[*cursor].trim().is_empty() {
        *cursor += 1;
    }
}

fn extract_structured_prompt_text(value: &str) -> Option<String> {
    let wrapped = format!("<prompt_display>{value}</prompt_display>");
    let document = Document::parse(&wrapped).ok()?;
    let root = document.root_element();
    let mut parts = Vec::new();

    for child in root.children() {
        if child.is_text() {
            if !child.text().unwrap_or_default().trim().is_empty() {
                return None;
            }
            continue;
        }

        if !child.is_element() {
            continue;
        }

        let tag_name = child.tag_name().name();
        if is_hidden_prompt_tag(tag_name) {
            continue;
        }
        if !DISPLAY_PROMPT_TAGS.contains(&tag_name) {
            return None;
        }

        let text = collapse_whitespace(&collect_node_text(child));
        if !text.is_empty() {
            parts.push(text);
        }
    }

    Some(parts.join(" "))
}

fn is_hidden_prompt_tag(tag_name: &str) -> bool {
    tag_name.starts_with("system_")
}

fn collect_node_text(node: Node<'_, '_>) -> String {
    node.descendants()
        .filter(|child| child.is_text())
        .filter_map(|child| child.text())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_domain::{Context, ContextMessage, ConversationId, ToolCatalog, ToolResult};

    fn partial_summary_frame() -> &'static str {
        "Use the following summary frames as the authoritative reference for all coding suggestions and decisions. Do not re-explain or revisit it unless I ask. Additional summary frames will be added as the conversation progresses.\n\n## Summary\n\n### 1. User\n\n````\n<task>Fix the reopen behavior.</task>\n````\n\n### 2. Assistant\n\n**Read:** `src-tauri/src/runtime/transforms.rs`\n**Update:** `src-tauri/src/runtime/transforms.rs`\n**Execute:** \n```\ncargo test --manifest-path src-tauri/Cargo.toml runtime::transforms\n```\n````\nImplemented the reopen fix.\n````\n\n### 3. User\n\n````\n<feedback>Only persist the chat after the first message.</feedback>\n<system_date>2026-04-20</system_date>\n````\n\n---\n\nProceed with implementation based on this context."
    }

    #[test]
    fn test_session_messages_from_conversation_preserves_tool_activity_history() {
        let conversation_id = ConversationId::generate();
        let todo_call = ToolCatalog::tool_call_todo_read().call_id("call_todos");
        let read_call = ToolCatalog::tool_call_read("/tmp/package.json").call_id("call_read");
        let fixture = Conversation::new(conversation_id).context(
            Context::default()
                .add_message(ContextMessage::user("<task>inspect</task>", None))
                .add_message(ContextMessage::assistant(
                    "",
                    None,
                    None,
                    Some(vec![todo_call.clone(), read_call.clone()]),
                ))
                .add_tool_results(vec![
                    ToolResult::from(todo_call).success("<todos count=\"0\">\n</todos>"),
                    ToolResult::from(read_call).success("1:{\n2:  \"name\": \"demo\"\n3:}\n"),
                ])
                .add_message(ContextMessage::assistant("Done.", None, None, None)),
        );

        let actual = session_messages_from_conversation(&fixture);

        let request_id = format!("history:{}", conversation_id.into_string());
        let expected = vec![
            SessionMessageDto::User {
                id: "history-user:0".to_string(),
                request_id: request_id.clone(),
                text: "inspect".to_string(),
            },
            SessionMessageDto::ToolStart {
                id: "history-tool-start:1:call_todos".to_string(),
                request_id: request_id.clone(),
                name: "todo_read".to_string(),
                call_id: Some("call_todos".to_string()),
                detail: map_tool_call_detail(
                    &ToolCatalog::tool_call_todo_read().call_id("call_todos"),
                ),
            },
            SessionMessageDto::ToolStart {
                id: "history-tool-start:1:call_read".to_string(),
                request_id: request_id.clone(),
                name: "read".to_string(),
                call_id: Some("call_read".to_string()),
                detail: map_tool_call_detail(
                    &ToolCatalog::tool_call_read("/tmp/package.json").call_id("call_read"),
                ),
            },
            SessionMessageDto::ToolEnd {
                id: "history-tool-end:2".to_string(),
                request_id: request_id.clone(),
                name: "todo_read".to_string(),
                call_id: Some("call_todos".to_string()),
                summary: Some("<todos count=\"0\">\n</todos>".to_string()),
                is_error: false,
                detail: None,
            },
            SessionMessageDto::ToolEnd {
                id: "history-tool-end:3".to_string(),
                request_id: request_id.clone(),
                name: "read".to_string(),
                call_id: Some("call_read".to_string()),
                summary: Some("1:{\n2:  \"name\": \"demo\"\n3:}".to_string()),
                is_error: false,
                detail: map_tool_result_detail(
                    &ToolResult::from(
                        ToolCatalog::tool_call_read("/tmp/package.json").call_id("call_read"),
                    )
                    .success("1:{\n2:  \"name\": \"demo\"\n3:}\n"),
                ),
            },
            SessionMessageDto::Assistant {
                id: "history-assistant:4".to_string(),
                request_id,
                text: "Done.".to_string(),
            },
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn test_session_messages_from_conversation_skips_internal_summary_frames() {
        let conversation_id = ConversationId::generate();
        let fixture = Conversation::new(conversation_id).context(
            Context::default()
                .add_message(ContextMessage::user(partial_summary_frame(), None))
                .add_message(ContextMessage::assistant(
                    "Applied the change.",
                    None,
                    None,
                    None,
                )),
        );

        let request_id = format!("history:{}", conversation_id.into_string());
        let actual = session_messages_from_conversation(&fixture);

        let expected = vec![
            SessionMessageDto::ContextCompacted {
                id: "history-summary-compacted:0".to_string(),
                request_id: request_id.clone(),
                text: CONTEXT_COMPACTED_LABEL.to_string(),
            },
            SessionMessageDto::User {
                id: "history-summary-user:0:0:0".to_string(),
                request_id: request_id.clone(),
                text: "Fix the reopen behavior.".to_string(),
            },
            SessionMessageDto::ToolStart {
                id: "history-summary-tool-start:0:1:0".to_string(),
                request_id: request_id.clone(),
                name: "read".to_string(),
                call_id: Some("summary:0:1:0".to_string()),
                detail: ToolCallDetailDto::FileRead {
                    path: "src-tauri/src/runtime/transforms.rs".to_string(),
                    start_line: None,
                    end_line: None,
                },
            },
            SessionMessageDto::ToolEnd {
                id: "history-summary-tool-end:0:1:0".to_string(),
                request_id: request_id.clone(),
                name: "read".to_string(),
                call_id: Some("summary:0:1:0".to_string()),
                summary: None,
                is_error: false,
                detail: None,
            },
            SessionMessageDto::ToolStart {
                id: "history-summary-tool-start:0:1:1".to_string(),
                request_id: request_id.clone(),
                name: "update".to_string(),
                call_id: Some("summary:0:1:1".to_string()),
                detail: ToolCallDetailDto::FileUpdate {
                    path: "src-tauri/src/runtime/transforms.rs".to_string(),
                    operation: FileOperationDto::Replace,
                },
            },
            SessionMessageDto::ToolEnd {
                id: "history-summary-tool-end:0:1:1".to_string(),
                request_id: request_id.clone(),
                name: "update".to_string(),
                call_id: Some("summary:0:1:1".to_string()),
                summary: None,
                is_error: false,
                detail: None,
            },
            SessionMessageDto::ToolStart {
                id: "history-summary-tool-start:0:1:2".to_string(),
                request_id: request_id.clone(),
                name: "shell".to_string(),
                call_id: Some("summary:0:1:2".to_string()),
                detail: ToolCallDetailDto::Shell {
                    command: "cargo test --manifest-path src-tauri/Cargo.toml runtime::transforms"
                        .to_string(),
                    cwd: None,
                    description: None,
                },
            },
            SessionMessageDto::ToolEnd {
                id: "history-summary-tool-end:0:1:2".to_string(),
                request_id: request_id.clone(),
                name: "shell".to_string(),
                call_id: Some("summary:0:1:2".to_string()),
                summary: None,
                is_error: false,
                detail: None,
            },
            SessionMessageDto::Assistant {
                id: "history-summary-assistant:0:1:0".to_string(),
                request_id: request_id.clone(),
                text: "Implemented the reopen fix.".to_string(),
            },
            SessionMessageDto::User {
                id: "history-summary-user:0:2:0".to_string(),
                request_id: request_id.clone(),
                text: "Only persist the chat after the first message.".to_string(),
            },
            SessionMessageDto::Assistant {
                id: "history-assistant:1".to_string(),
                request_id,
                text: "Applied the change.".to_string(),
            },
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn test_session_messages_from_conversation_hides_system_prefixed_prompt_tags() {
        let conversation_id = ConversationId::generate();
        let fixture = Conversation::new(conversation_id).context(
            Context::default()
                .add_message(ContextMessage::user(
                    "<system_reminder>You have pending todo items.</system_reminder>",
                    None,
                ))
                .add_message(ContextMessage::user(
                    "<feedback>Continue please.</feedback>\n<system_date>2026-04-28</system_date>",
                    None,
                )),
        );

        let actual = session_messages_from_conversation(&fixture);
        let request_id = format!("history:{}", conversation_id.into_string());

        assert_eq!(
            actual,
            vec![SessionMessageDto::User {
                id: "history-user:1".to_string(),
                request_id,
                text: "Continue please.".to_string(),
            }]
        );
    }

    #[test]
    fn test_persisted_conversation_summary_title_falls_back_from_internal_summary_frame() {
        let conversation_id = ConversationId::generate();
        let fixture = Conversation::new(conversation_id)
            .title(Some(partial_summary_frame().to_string()))
            .context(Context::default().add_message(ContextMessage::user(
                "<feedback>Only persist the chat after the first message.</feedback>\n<system_date>2026-04-20</system_date>",
                None,
            )));

        let actual = PersistedConversationSummary::from_conversation(&fixture);

        assert_eq!(
            actual.title,
            "Only persist the chat after the first message."
        );
    }
}
