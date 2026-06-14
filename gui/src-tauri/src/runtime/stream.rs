use forge_app::ForgeApp;
use forge_domain::{AgentId, ChatRequest, ChatResponse, ConversationId, Event};
use futures::StreamExt;
use tokio::sync::oneshot;

use crate::bridge::followup::{FollowupContext, with_followup_context};
use crate::dto::{
    ChatEventKind, SessionMessageDto, StatusCategoryDto, ToolCallDetailDto, ToolResultDetailDto,
};

use super::{
    ConversationSessionState, ForgeRuntime, RuntimeManager, apply_todo_result,
    derive_conversation_title_from_messages, format_error_chain, history_request_id,
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum StreamedMessageKind {
    Assistant,
    Reasoning,
}

pub(crate) struct StreamChatRequest {
    pub(super) runtime: ForgeRuntime,
    pub(super) workspace_path: String,
    pub(super) request_id: String,
    pub(super) conversation_id: String,
    pub(super) prompt: String,
    pub(super) agent_id: Option<String>,
    pub(super) stop_receiver: oneshot::Receiver<()>,
}

impl RuntimeManager {
    pub(super) async fn stream_chat(&self, request: StreamChatRequest) {
        let StreamChatRequest {
            runtime,
            workspace_path,
            request_id,
            conversation_id,
            prompt,
            agent_id,
            mut stop_receiver,
        } = request;
        let parsed_conversation_id = match ConversationId::parse(&conversation_id) {
            Ok(value) => value,
            Err(error) => {
                self.take_stop_request_sender(&request_id).await;
                self.record_stream_error(
                    &conversation_id,
                    &request_id,
                    format_error_chain(&anyhow::Error::new(error)),
                )
                .await;
                let _ = self.emit_session_snapshot().await;
                return;
            }
        };

        let context = FollowupContext {
            workspace_path: workspace_path.clone(),
            conversation_id: conversation_id.clone(),
            request_id: request_id.clone(),
        };
        let selected_agent_id = agent_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(AgentId::new)
            .unwrap_or_default();

        let stream = match with_followup_context(context, async {
            ForgeApp::new(runtime.services.clone())
                .chat(
                    selected_agent_id,
                    ChatRequest::new(Event::new(prompt), parsed_conversation_id),
                )
                .await
        })
        .await
        {
            Ok(stream) => stream,
            Err(error) => {
                self.take_stop_request_sender(&request_id).await;
                self.record_stream_error(&conversation_id, &request_id, format_error_chain(&error))
                    .await;
                let _ = self
                    .finish_request(&workspace_path, &conversation_id, &request_id, false)
                    .await;
                return;
            }
        };

        tokio::pin!(stream);
        let mut saw_complete = false;
        let mut saw_interrupt = false;

        loop {
            let item = tokio::select! {
                _ = &mut stop_receiver => {
                    self.take_stop_request_sender(&request_id).await;
                    self.record_local_interrupt(
                        &conversation_id,
                        &request_id,
                        "Stopped by user.",
                    )
                    .await;
                    let _ = self
                        .finish_request(&workspace_path, &conversation_id, &request_id, false)
                        .await;
                    return;
                }
                item = stream.next() => item,
            };

            let Some(item) = item else {
                break;
            };

            match item {
                Ok(response) => {
                    if let Some(output) = todo_result_output(&response) {
                        self.apply_todo_update(&conversation_id, output).await;
                    }

                    if let Some(mut event) = crate::dto::map_chat_response(&response) {
                        match &mut event {
                            ChatEventKind::ToolStart { call_id, detail, .. } => {
                                self.capture_pending_file_update(
                                    &conversation_id,
                                    &request_id,
                                    call_id.as_deref(),
                                    detail,
                                )
                                .await;
                            }
                            ChatEventKind::ToolEnd { call_id, is_error, detail, .. } => {
                                self.attach_file_diff_to_result(
                                    &conversation_id,
                                    &request_id,
                                    call_id.as_deref(),
                                    *is_error,
                                    detail,
                                )
                                .await;
                            }
                            _ => {}
                        }

                        if matches!(event, ChatEventKind::Complete) {
                            saw_complete = true;
                        }
                        if matches!(event, ChatEventKind::Interrupt { .. }) {
                            saw_interrupt = true;
                        }
                        self.apply_chat_event(&conversation_id, &request_id, event)
                            .await;
                        let _ = self.emit_session_snapshot().await;
                    }

                    if let ChatResponse::ToolCallStart { notifier, .. } = &response {
                        notifier.notify_one();
                    }
                }
                Err(error) => {
                    self.record_stream_error(
                        &conversation_id,
                        &request_id,
                        format_error_chain(&error),
                    )
                    .await;
                    let _ = self.emit_session_snapshot().await;
                    let _ = self
                        .finish_request(&workspace_path, &conversation_id, &request_id, false)
                        .await;
                    self.take_stop_request_sender(&request_id).await;
                    return;
                }
            }
        }

        self.take_stop_request_sender(&request_id).await;

        if !saw_complete {
            if !saw_interrupt {
                self.record_stream_error(
                    &conversation_id,
                    &request_id,
                    self.unexpected_stream_end_message(&conversation_id, &request_id)
                        .await,
                )
                .await;
                let _ = self.emit_session_snapshot().await;
            }
            self.finish_request(&workspace_path, &conversation_id, &request_id, false)
                .await
                .ok();
            return;
        }

        let _ = self
            .finish_request(&workspace_path, &conversation_id, &request_id, true)
            .await;
    }

    async fn apply_chat_event(
        &self,
        conversation_id: &str,
        request_id: &str,
        event: ChatEventKind,
    ) {
        let mut state = self.state.lock().await;
        let mut should_clear_followup = false;
        let mut next_ui_error: Option<String> = None;

        {
            let conversation = match state.conversations.get_mut(conversation_id) {
                Some(conversation) => conversation,
                None => return,
            };

            match event {
                ChatEventKind::Started => {}
                ChatEventKind::AssistantMarkdown { text } => {
                    append_streamed_message(
                        &mut conversation.messages,
                        StreamedMessageKind::Assistant,
                        request_id,
                        text,
                    );
                }
                ChatEventKind::Reasoning { text } => {
                    append_streamed_message(
                        &mut conversation.messages,
                        StreamedMessageKind::Reasoning,
                        request_id,
                        text,
                    );
                }
                ChatEventKind::Status { title, subtitle, category } => {
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::Status {
                        id: create_message_id("status", request_id, next_index),
                        request_id: request_id.to_string(),
                        title,
                        subtitle,
                        category,
                    });
                }
                ChatEventKind::StatusOutput { text } => {
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::StatusOutput {
                        id: create_message_id("status-output", request_id, next_index),
                        request_id: request_id.to_string(),
                        text,
                    });
                }
                ChatEventKind::ToolStart { name, call_id, detail } => {
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::ToolStart {
                        id: create_message_id("tool-start", request_id, next_index),
                        request_id: request_id.to_string(),
                        name,
                        call_id,
                        detail,
                    });
                }
                ChatEventKind::ToolEnd { name, call_id, summary, is_error, detail } => {
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::ToolEnd {
                        id: create_message_id("tool-end", request_id, next_index),
                        request_id: request_id.to_string(),
                        name,
                        call_id,
                        summary,
                        is_error,
                        detail,
                    });
                }
                ChatEventKind::Retry { cause, duration_ms } => {
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::Status {
                        id: create_message_id("status", request_id, next_index),
                        request_id: request_id.to_string(),
                        title: "Retrying request".to_string(),
                        subtitle: Some(format!("{cause} ({duration_ms} ms)")),
                        category: StatusCategoryDto::Warning,
                    });
                }
                ChatEventKind::Interrupt { reason } => {
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::Status {
                        id: create_message_id("status", request_id, next_index),
                        request_id: request_id.to_string(),
                        title: "Interrupted".to_string(),
                        subtitle: Some(reason),
                        category: StatusCategoryDto::Warning,
                    });
                }
                ChatEventKind::Complete => {
                    clear_request_tracking(conversation, request_id);
                }
                ChatEventKind::Error { message } => {
                    should_clear_followup = true;
                    next_ui_error = Some(message.clone());
                    clear_request_tracking(conversation, request_id);
                    let next_index = conversation.messages.len();
                    conversation.messages.push(SessionMessageDto::Error {
                        id: create_message_id("error", request_id, next_index),
                        request_id: request_id.to_string(),
                        message,
                    });
                }
            }

            conversation.title = Some(derive_conversation_title_from_messages(
                &conversation.messages,
            ));
        }

        if let Some(message) = next_ui_error {
            state.ui_error = Some(message);
        }
        if should_clear_followup {
            state
                .pending_followups_by_conversation
                .remove(conversation_id);
        }
    }

    async fn record_stream_error(&self, conversation_id: &str, request_id: &str, message: String) {
        let mut state = self.state.lock().await;
        if let Some(conversation) = state.conversations.get_mut(conversation_id) {
            clear_request_tracking(conversation, request_id);
            let next_index = conversation.messages.len();
            conversation.messages.push(SessionMessageDto::Error {
                id: create_message_id("error", request_id, next_index),
                request_id: request_id.to_string(),
                message: message.clone(),
            });
            conversation.title = Some(derive_conversation_title_from_messages(
                &conversation.messages,
            ));
        }
        state
            .pending_followups_by_conversation
            .remove(conversation_id);
        state.ui_error = Some(message);
    }

    async fn record_local_interrupt(&self, conversation_id: &str, request_id: &str, reason: &str) {
        let mut state = self.state.lock().await;
        if let Some(conversation) = state.conversations.get_mut(conversation_id) {
            let next_index = conversation.messages.len();
            conversation.messages.push(SessionMessageDto::Status {
                id: create_message_id("status", request_id, next_index),
                request_id: request_id.to_string(),
                title: "Interrupted".to_string(),
                subtitle: Some(reason.to_string()),
                category: StatusCategoryDto::Warning,
            });
            conversation.title = Some(derive_conversation_title_from_messages(
                &conversation.messages,
            ));
        }
    }

    async fn finish_request(
        &self,
        workspace_path: &str,
        conversation_id: &str,
        request_id: &str,
        reload_from_persistence: bool,
    ) -> anyhow::Result<()> {
        let completed_request_agent_id = {
            let mut state = self.state.lock().await;
            if let Some(conversation) = state.conversations.get_mut(conversation_id) {
                clear_request_tracking(conversation, request_id);
                conversation.request_agent_ids.get(request_id).cloned()
            } else {
                None
            }
        };

        let _ = self.refresh_workspace_conversations(workspace_path).await;
        if reload_from_persistence {
            let order_hint = self
                .state
                .lock()
                .await
                .conversations
                .get(conversation_id)
                .map(|conversation| conversation.order);
            let _ = self
                .reload_conversation_from_persistence(workspace_path, conversation_id, order_hint)
                .await;

            if let Some(agent_id) = completed_request_agent_id {
                let mut state = self.state.lock().await;
                if let Some(conversation) = state.conversations.get_mut(conversation_id) {
                    conversation
                        .request_agent_ids
                        .insert(history_request_id(conversation_id), agent_id);
                }
            }
        }
        let snapshot = self.snapshot().await?;
        self.emit_snapshot(snapshot)?;
        Ok(())
    }

    async fn unexpected_stream_end_message(
        &self,
        conversation_id: &str,
        request_id: &str,
    ) -> String {
        let state = self.state.lock().await;
        let Some(conversation) = state.conversations.get(conversation_id) else {
            return build_unexpected_stream_end_message(&[], request_id);
        };

        build_unexpected_stream_end_message(&conversation.messages, request_id)
    }

    async fn apply_todo_update(&self, conversation_id: &str, output: &str) {
        let mut state = self.state.lock().await;
        let Some(conversation) = state.conversations.get_mut(conversation_id) else {
            return;
        };

        let _ = apply_todo_result(&mut conversation.todos, output);
    }
}

pub(crate) fn create_message_id(prefix: &str, request_id: &str, index: usize) -> String {
    format!("{prefix}:{request_id}:{index}")
}

fn clear_request_tracking(conversation: &mut ConversationSessionState, request_id: &str) {
    conversation
        .active_request_ids
        .retain(|current| current != request_id);
    conversation
        .pending_file_updates
        .retain(|_, pending| pending.request_id != request_id);
    conversation
        .pending_anonymous_file_updates
        .retain(|pending| pending.request_id != request_id);
}

fn append_streamed_message(
    messages: &mut Vec<SessionMessageDto>,
    kind: StreamedMessageKind,
    request_id: &str,
    text: String,
) {
    match messages.last_mut() {
        Some(SessionMessageDto::Assistant {
            request_id: current_request_id,
            text: current_text,
            ..
        }) if kind == StreamedMessageKind::Assistant && current_request_id == request_id => {
            current_text.push_str(&text);
        }
        Some(SessionMessageDto::Reasoning {
            request_id: current_request_id,
            text: current_text,
            ..
        }) if kind == StreamedMessageKind::Reasoning && current_request_id == request_id => {
            current_text.push_str(&text);
        }
        _ => {
            let next_index = messages.len();
            match kind {
                StreamedMessageKind::Assistant => messages.push(SessionMessageDto::Assistant {
                    id: create_message_id("assistant", request_id, next_index),
                    request_id: request_id.to_string(),
                    text,
                }),
                StreamedMessageKind::Reasoning => messages.push(SessionMessageDto::Reasoning {
                    id: create_message_id("reasoning", request_id, next_index),
                    request_id: request_id.to_string(),
                    text,
                }),
            }
        }
    }
}

fn todo_result_output(response: &ChatResponse) -> Option<&str> {
    let ChatResponse::ToolCallEnd(result) = response else {
        return None;
    };

    let name = result.name.as_str();
    if name != "todo_read" && name != "todo_write" {
        return None;
    }

    result.output.as_str()
}

fn build_unexpected_stream_end_message(messages: &[SessionMessageDto], request_id: &str) -> String {
    for message in messages.iter().rev() {
        match message {
            SessionMessageDto::ToolEnd {
                request_id: current_request_id,
                name,
                summary,
                is_error,
                detail,
                ..
            } if current_request_id == request_id && *is_error => {
                if let Some(message) =
                    failed_tool_message(name, summary.as_deref(), detail.as_ref())
                {
                    return message;
                }
            }
            SessionMessageDto::ToolStart {
                request_id: current_request_id, name, detail, ..
            } if current_request_id == request_id => {
                return in_progress_tool_message(detail);
            }
            SessionMessageDto::StatusOutput { request_id: current_request_id, text, .. }
                if current_request_id == request_id =>
            {
                let text = text.trim();
                if !text.is_empty() {
                    return text.to_string();
                }
            }
            SessionMessageDto::Status {
                request_id: current_request_id,
                title,
                subtitle,
                category,
                ..
            } if current_request_id == request_id
                && matches!(
                    category,
                    StatusCategoryDto::Error | StatusCategoryDto::Warning
                ) =>
            {
                return match subtitle
                    .as_deref()
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
                {
                    Some(subtitle) => format!("{title}: {subtitle}"),
                    None => title.clone(),
                };
            }
            _ => {}
        }
    }

    "The request ended before the model reported completion.".to_string()
}

fn failed_tool_message(
    name: &str,
    summary: Option<&str>,
    detail: Option<&ToolResultDetailDto>,
) -> Option<String> {
    match detail {
        Some(ToolResultDetailDto::Text { text }) if !text.trim().is_empty() => {
            Some(text.trim().to_string())
        }
        Some(ToolResultDetailDto::ShellOutput { stderr, stdout, exit_code, .. }) => stderr
            .as_ref()
            .map(|output| output.content.trim())
            .filter(|text| !text.is_empty())
            .map(str::to_string)
            .or_else(|| {
                stdout
                    .as_ref()
                    .map(|output| output.content.trim())
                    .filter(|text| !text.is_empty())
                    .map(str::to_string)
            })
            .or_else(|| exit_code.map(|code| format!("{name} failed with exit code {code}."))),
        _ => summary
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
            .or_else(|| Some(format!("{name} failed."))),
    }
}

fn in_progress_tool_message(detail: &ToolCallDetailDto) -> String {
    match detail {
        ToolCallDetailDto::FileUpdate { path, .. } => {
            format!("The request ended while updating {path}.")
        }
        ToolCallDetailDto::FileRead { path, .. } => {
            format!("The request ended while reading {path}.")
        }
        ToolCallDetailDto::Shell { command, .. } => {
            format!("The request ended while running `{command}`.")
        }
        ToolCallDetailDto::Search { pattern, path, .. } => match path {
            Some(path) => format!("The request ended while searching {path} for {pattern}."),
            None => format!("The request ended while searching for {pattern}."),
        },
        ToolCallDetailDto::CodebaseSearch { queries } if !queries.is_empty() => format!(
            "The request ended while running a codebase search for {}.",
            queries.join(", ")
        ),
        ToolCallDetailDto::CodebaseSearch { .. } => {
            "The request ended while running a codebase search.".to_string()
        }
        ToolCallDetailDto::Fetch { url } => {
            format!("The request ended while fetching {url}.")
        }
        ToolCallDetailDto::Followup { question } => {
            format!("The request ended while waiting for follow-up: {question}")
        }
        ToolCallDetailDto::Plan { plan_name } => {
            format!("The request ended while updating the plan {plan_name}.")
        }
        ToolCallDetailDto::Skill { name } => {
            format!("The request ended while loading the skill {name}.")
        }
        ToolCallDetailDto::Task { agent_id } => {
            format!("The request ended while delegating to {agent_id}.")
        }
        ToolCallDetailDto::TodoWrite { .. } => {
            "The request ended while updating the todo list.".to_string()
        }
        ToolCallDetailDto::TodoRead => "The request ended while reading the todo list.".to_string(),
        ToolCallDetailDto::Unknown { name } => {
            format!("The request ended while running {name}.")
        }
    }
}
