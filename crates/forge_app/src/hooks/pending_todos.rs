use sha2::{Digest, Sha256};

use async_trait::async_trait;
use forge_domain::{
    ContextMessage, Conversation, EndPayload, EventData, EventHandle, Template, Todo, TodoStatus,
};
use forge_template::Element;
use serde::Serialize;

use crate::TemplateEngine;

/// A single todo item prepared for template rendering.
#[derive(Serialize)]
struct TodoReminderItem {
    status: &'static str,
    content: String,
}

/// Template context for the pending-todos reminder.
#[derive(Serialize)]
struct PendingTodosContext {
    todos: Vec<TodoReminderItem>,
}

/// Default cap on the number of pending-todos reminders that may be
/// injected into a single conversation. Reached when the agent keeps
/// reshuffling its todo list (which changes the fingerprint and would
/// otherwise re-arm the orchestrator loop indefinitely). Mirrors the
/// `max_end_hook_rearms` config default.
const DEFAULT_MAX_REMINDERS: usize = 3;

/// Detects when the LLM signals task completion while there are still
/// pending or in-progress todo items.
///
/// When triggered, it injects a formatted reminder listing all
/// outstanding todos into the conversation context, preventing the
/// orchestrator from yielding prematurely.
///
/// Bounded by two checks to avoid runaway reminder loops:
///
/// 1. **Same-fingerprint dedupe**: if the most-recent reminder in
///    context already covers the current set of pending todos, skip.
/// 2. **Total-reminder cap**: if the conversation already contains
///    `max_reminders` reminders (across all fingerprints), skip even if
///    the agent keeps rewording its todos. The cap is configurable via
///    `PendingTodosHandler::with_max_reminders` and defaults to
///    [`DEFAULT_MAX_REMINDERS`].
#[derive(Debug, Clone)]
pub struct PendingTodosHandler {
    max_reminders: usize,
}

impl Default for PendingTodosHandler {
    fn default() -> Self {
        Self::new()
    }
}

impl PendingTodosHandler {
    /// Creates a new pending-todos handler with the default reminder cap.
    pub fn new() -> Self {
        Self { max_reminders: DEFAULT_MAX_REMINDERS }
    }

    /// Overrides the maximum number of pending-todo reminders that may
    /// be injected into a single conversation. Typically wired to
    /// `forge_config.max_end_hook_rearms` so a single config knob
    /// governs both the orchestrator's re-arm cap and the reminder cap.
    pub fn with_max_reminders(max_reminders: usize) -> Self {
        Self { max_reminders }
    }

    /// Counts how many pending-todos reminders already exist in the
    /// given conversation context. Used to enforce the total-reminder
    /// cap regardless of whether the agent rewords its todos between
    /// turns.
    fn count_existing_reminders(context: &forge_domain::Context) -> usize {
        context
            .messages
            .iter()
            .filter(|entry| {
                entry
                    .message
                    .content()
                    .map(|content| {
                        content
                            .lines()
                            .any(|line| line.trim_start().starts_with("todo_fingerprint=\""))
                    })
                    .unwrap_or(false)
            })
            .count()
    }

    fn pending_todo_fingerprint(todos: &[Todo]) -> String {
        let mut entries: Vec<String> = todos
            .iter()
            .filter_map(|todo| {
                let status = match todo.status {
                    TodoStatus::Pending => "pending",
                    TodoStatus::InProgress => "in_progress",
                    _ => return None,
                };
                Some(format!("{status}\0{}", todo.content))
            })
            .collect();
        entries.sort();

        let mut hasher = Sha256::new();
        for entry in entries {
            hasher.update(entry.as_bytes());
            hasher.update([0]);
        }

        hex::encode(hasher.finalize())
    }
}

#[async_trait]
impl EventHandle<EventData<EndPayload>> for PendingTodosHandler {
    async fn handle(
        &self,
        _event: &EventData<EndPayload>,
        conversation: &mut Conversation,
    ) -> anyhow::Result<()> {
        let pending_todos = conversation.metrics.get_active_todos();
        if pending_todos.is_empty() {
            return Ok(());
        }

        let current_fingerprint = Self::pending_todo_fingerprint(&pending_todos);

        let should_add_reminder = if let Some(context) = &conversation.context {
            // Cap total reminders regardless of fingerprint changes. If the
            // agent has already been told `max_reminders` times that it has
            // pending todos, further reminders won't help — let the
            // orchestrator yield and surface control to the user.
            if Self::count_existing_reminders(context) >= self.max_reminders {
                false
            } else {
                let last_reminder_fingerprint =
                    context.messages.iter().rev().find_map(|entry| {
                        let content = entry.message.content()?;
                        let fingerprint = content
                            .lines()
                            .find(|line| line.trim_start().starts_with("todo_fingerprint=\""))?
                            .split_once("\"")?
                            .1
                            .split_once("\"")?
                            .0;
                        Some(fingerprint.to_string())
                    });

                match last_reminder_fingerprint {
                    Some(last_fingerprint) => last_fingerprint != current_fingerprint,
                    None => true,
                }
            }
        } else {
            true
        };

        if !should_add_reminder {
            return Ok(());
        }

        let todo_items: Vec<TodoReminderItem> = pending_todos
            .iter()
            .filter_map(|todo| {
                let status = match todo.status {
                    TodoStatus::Pending => "PENDING",
                    TodoStatus::InProgress => "IN_PROGRESS",
                    _ => return None,
                };
                Some(TodoReminderItem { status, content: todo.content.clone() })
            })
            .collect();

        let ctx = PendingTodosContext { todos: todo_items };
        let reminder = TemplateEngine::default().render(
            Template::<PendingTodosContext>::new("forge-pending-todos-reminder.md"),
            &ctx,
        )?;

        if let Some(context) = conversation.context.as_mut() {
            let content = Element::new("system_reminder")
                .attr("todo_fingerprint", current_fingerprint)
                .text(reminder);
            context
                .messages
                .push(ContextMessage::user(content, None).into());
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use forge_domain::{
        Agent, Context, Conversation, EndPayload, EventData, EventHandle, Metrics, ModelId, Todo,
        TodoStatus,
    };
    use pretty_assertions::assert_eq;

    use super::*;

    fn fixture_agent() -> Agent {
        Agent::new(
            "test-agent",
            "test-provider".to_string().into(),
            ModelId::new("test-model"),
        )
    }

    fn fixture_conversation(todos: Vec<Todo>) -> Conversation {
        let mut conversation = Conversation::generate();
        conversation.context = Some(Context::default());
        conversation.metrics = Metrics::default().todos(todos);
        conversation
    }

    fn fixture_event() -> EventData<EndPayload> {
        EventData::new(fixture_agent(), ModelId::new("test-model"), EndPayload)
    }

    #[tokio::test]
    async fn test_no_pending_todos_does_nothing() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation = fixture_conversation(vec![]);

        let initial_msg_count = conversation.context.as_ref().unwrap().messages.len();
        handler.handle(&event, &mut conversation).await.unwrap();

        let actual = conversation.context.as_ref().unwrap().messages.len();
        let expected = initial_msg_count;
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_pending_todos_injects_reminder() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation = fixture_conversation(vec![
            Todo::new("Fix the build").status(TodoStatus::Pending),
            Todo::new("Write tests").status(TodoStatus::InProgress),
        ]);

        handler.handle(&event, &mut conversation).await.unwrap();

        let actual = conversation.context.as_ref().unwrap().messages.len();
        let expected = 1;
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_reminder_contains_formatted_list() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation = fixture_conversation(vec![
            Todo::new("Fix the build").status(TodoStatus::Pending),
            Todo::new("Write tests").status(TodoStatus::InProgress),
        ]);

        handler.handle(&event, &mut conversation).await.unwrap();

        let entry = &conversation.context.as_ref().unwrap().messages[0];
        let actual = entry.message.content().unwrap();
        assert!(actual.contains("todo_fingerprint=\""));
        assert!(actual.contains("- [PENDING] Fix the build"));
        assert!(actual.contains("- [IN_PROGRESS] Write tests"));
    }

    #[tokio::test]
    async fn test_completed_todos_not_included() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation = fixture_conversation(vec![
            Todo::new("Completed task").status(TodoStatus::Completed),
            Todo::new("Cancelled task").status(TodoStatus::Cancelled),
        ]);

        let initial_msg_count = conversation.context.as_ref().unwrap().messages.len();
        handler.handle(&event, &mut conversation).await.unwrap();

        let actual = conversation.context.as_ref().unwrap().messages.len();
        let expected = initial_msg_count;
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_reminder_not_duplicated_for_same_todos() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation =
            fixture_conversation(vec![Todo::new("Fix the build").status(TodoStatus::Pending)]);

        // First call should inject a reminder
        handler.handle(&event, &mut conversation).await.unwrap();
        let after_first = conversation.context.as_ref().unwrap().messages.len();
        assert_eq!(after_first, 1);

        // Second call with the same pending todos should NOT add another reminder
        handler.handle(&event, &mut conversation).await.unwrap();
        let after_second = conversation.context.as_ref().unwrap().messages.len();
        assert_eq!(after_second, 1); // Still 1, no duplicate
    }

    #[tokio::test]
    async fn test_reminder_not_duplicated_for_reordered_same_todos() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation = fixture_conversation(vec![
            Todo::new("Fix the build").status(TodoStatus::Pending),
            Todo::new("Write tests").status(TodoStatus::InProgress),
        ]);

        handler.handle(&event, &mut conversation).await.unwrap();
        let after_first = conversation.context.as_ref().unwrap().messages.len();
        assert_eq!(after_first, 1);

        conversation.metrics = conversation.metrics.clone().todos(vec![
            Todo::new("Write tests").status(TodoStatus::InProgress),
            Todo::new("Fix the build").status(TodoStatus::Pending),
        ]);

        handler.handle(&event, &mut conversation).await.unwrap();
        let after_second = conversation.context.as_ref().unwrap().messages.len();
        assert_eq!(after_second, 1);
    }

    #[tokio::test]
    async fn test_reminder_capped_when_todos_keep_changing() {
        // Regression: agent reshuffles its todo list each turn (changes
        // fingerprint), historically that re-armed the orchestrator loop
        // forever. The total-reminder cap forces yield after N reminders.
        let handler = PendingTodosHandler::with_max_reminders(3);
        let event = fixture_event();
        let mut conversation =
            fixture_conversation(vec![Todo::new("v1").status(TodoStatus::Pending)]);

        // Reminder 1: fresh fingerprint
        handler.handle(&event, &mut conversation).await.unwrap();
        assert_eq!(conversation.context.as_ref().unwrap().messages.len(), 1);

        // Reminder 2: change fingerprint by rewording
        conversation.metrics = conversation
            .metrics
            .clone()
            .todos(vec![Todo::new("v2").status(TodoStatus::Pending)]);
        handler.handle(&event, &mut conversation).await.unwrap();
        assert_eq!(conversation.context.as_ref().unwrap().messages.len(), 2);

        // Reminder 3: different fingerprint again, this is the last allowed
        conversation.metrics = conversation
            .metrics
            .clone()
            .todos(vec![Todo::new("v3").status(TodoStatus::Pending)]);
        handler.handle(&event, &mut conversation).await.unwrap();
        assert_eq!(conversation.context.as_ref().unwrap().messages.len(), 3);

        // Reminder 4: cap kicks in even though the fingerprint changed
        conversation.metrics = conversation
            .metrics
            .clone()
            .todos(vec![Todo::new("v4").status(TodoStatus::Pending)]);
        handler.handle(&event, &mut conversation).await.unwrap();
        let actual = conversation.context.as_ref().unwrap().messages.len();
        let expected = 3;
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_with_max_reminders_zero_disables_handler() {
        // Setting the cap to 0 effectively turns the handler off; useful
        // for tests / users who want the orchestrator to never re-arm on
        // pending todos.
        let handler = PendingTodosHandler::with_max_reminders(0);
        let event = fixture_event();
        let mut conversation =
            fixture_conversation(vec![Todo::new("Fix the build").status(TodoStatus::Pending)]);

        handler.handle(&event, &mut conversation).await.unwrap();
        let actual = conversation.context.as_ref().unwrap().messages.len();
        let expected = 0;
        assert_eq!(actual, expected);
    }

    #[tokio::test]
    async fn test_reminder_added_when_todos_change() {
        let handler = PendingTodosHandler::new();
        let event = fixture_event();
        let mut conversation = fixture_conversation(vec![
            Todo::new("Fix the build").status(TodoStatus::Pending),
            Todo::new("Write tests").status(TodoStatus::InProgress),
        ]);

        // First call should inject a reminder
        handler.handle(&event, &mut conversation).await.unwrap();
        let after_first = conversation.context.as_ref().unwrap().messages.len();
        assert_eq!(after_first, 1);

        // Simulate LLM completing one todo but leaving another pending
        // Update the conversation metrics with different todos
        conversation.metrics = conversation.metrics.clone().todos(vec![
            Todo::new("Fix the build").status(TodoStatus::Completed),
            Todo::new("Write tests").status(TodoStatus::InProgress),
            Todo::new("Add documentation").status(TodoStatus::Pending),
        ]);

        // Second call with different pending todos should add a new reminder
        handler.handle(&event, &mut conversation).await.unwrap();
        let after_second = conversation.context.as_ref().unwrap().messages.len();
        assert_eq!(after_second, 2); // New reminder added because todos changed
    }
}
