use std::collections::{HashMap, VecDeque};

use forge_domain::{Todo, TodoStatus};
use roxmltree::{Document, Node};

use crate::dto::{SessionTodoDto, SessionTodoStatusDto};

enum TodoResultUpdate {
    Replace(Vec<ParsedTodo>),
    ApplyChanges(Vec<TodoChange>),
}

#[derive(Clone)]
struct ParsedTodo {
    content: String,
    status: SessionTodoStatusDto,
}

struct TodoChange {
    todo: ParsedTodo,
    kind: TodoChangeKind,
}

enum TodoChangeKind {
    Added,
    Updated,
    Removed,
}

pub(crate) fn map_session_todos(todos: &[Todo]) -> Vec<SessionTodoDto> {
    todos.iter().map(map_session_todo).collect()
}

pub(crate) fn apply_todo_result(current: &mut Vec<SessionTodoDto>, output: &str) -> bool {
    let Some(update) = parse_todo_result_update(output) else {
        return false;
    };

    match update {
        TodoResultUpdate::Replace(todos) => {
            replace_todos(current, todos);
        }
        TodoResultUpdate::ApplyChanges(changes) => {
            apply_todo_changes(current, changes);
        }
    }

    true
}

fn map_session_todo(todo: &Todo) -> SessionTodoDto {
    SessionTodoDto {
        id: todo.id.clone(),
        content: todo.content.clone(),
        status: map_todo_status(&todo.status),
    }
}

fn map_todo_status(status: &TodoStatus) -> SessionTodoStatusDto {
    match status {
        TodoStatus::Pending => SessionTodoStatusDto::Pending,
        TodoStatus::InProgress => SessionTodoStatusDto::InProgress,
        TodoStatus::Completed => SessionTodoStatusDto::Completed,
        TodoStatus::Cancelled => SessionTodoStatusDto::Cancelled,
    }
}

fn parse_todo_result_update(output: &str) -> Option<TodoResultUpdate> {
    let trimmed = output.trim();
    if trimmed.is_empty() {
        return None;
    }

    let document = Document::parse(trimmed).ok()?;
    let root = document.root_element();

    match root.tag_name().name() {
        "todos" => Some(TodoResultUpdate::Replace(
            root.children()
                .filter(|child| child.has_tag_name("todo"))
                .filter_map(parse_parsed_todo)
                .collect(),
        )),
        "todos_updated" => Some(TodoResultUpdate::ApplyChanges(
            root.children()
                .filter(|child| child.has_tag_name("todo"))
                .filter_map(parse_todo_change)
                .collect(),
        )),
        _ => None,
    }
}

fn parse_parsed_todo(node: Node<'_, '_>) -> Option<ParsedTodo> {
    let content = collect_todo_content(node)?;
    let status = parse_todo_status(node.attribute("status")?)?;

    Some(ParsedTodo { content, status })
}

fn parse_todo_change(node: Node<'_, '_>) -> Option<TodoChange> {
    let todo = parse_parsed_todo(node)?;
    let kind = match node.attribute("change")? {
        "added" => TodoChangeKind::Added,
        "updated" => TodoChangeKind::Updated,
        "removed" => TodoChangeKind::Removed,
        _ => return None,
    };

    Some(TodoChange { todo, kind })
}

fn parse_todo_status(value: &str) -> Option<SessionTodoStatusDto> {
    match value {
        "pending" => Some(SessionTodoStatusDto::Pending),
        "in_progress" => Some(SessionTodoStatusDto::InProgress),
        "completed" => Some(SessionTodoStatusDto::Completed),
        "cancelled" => Some(SessionTodoStatusDto::Cancelled),
        _ => None,
    }
}

fn collect_todo_content(node: Node<'_, '_>) -> Option<String> {
    let content = node
        .descendants()
        .filter(|child| child.is_text())
        .filter_map(|child| child.text())
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string();

    if content.is_empty() {
        None
    } else {
        Some(content)
    }
}

fn replace_todos(current: &mut Vec<SessionTodoDto>, todos: Vec<ParsedTodo>) {
    let mut existing_ids_by_content = HashMap::<String, VecDeque<String>>::new();
    for todo in current.iter() {
        existing_ids_by_content
            .entry(todo.content.clone())
            .or_default()
            .push_back(todo.id.clone());
    }

    let mut next = Vec::with_capacity(todos.len());
    for todo in todos {
        let id = existing_ids_by_content
            .get_mut(&todo.content)
            .and_then(VecDeque::pop_front)
            .unwrap_or_else(|| next_ephemeral_todo_id(&next, &todo.content));

        next.push(SessionTodoDto { id, content: todo.content, status: todo.status });
    }

    *current = next;
}

fn apply_todo_changes(current: &mut Vec<SessionTodoDto>, changes: Vec<TodoChange>) {
    for change in changes {
        match change.kind {
            TodoChangeKind::Added => current.push(SessionTodoDto {
                id: next_ephemeral_todo_id(current, &change.todo.content),
                content: change.todo.content,
                status: change.todo.status,
            }),
            TodoChangeKind::Updated => {
                if let Some(existing) = current
                    .iter_mut()
                    .find(|todo| todo.content == change.todo.content)
                {
                    existing.status = change.todo.status;
                } else {
                    current.push(SessionTodoDto {
                        id: next_ephemeral_todo_id(current, &change.todo.content),
                        content: change.todo.content,
                        status: change.todo.status,
                    });
                }
            }
            TodoChangeKind::Removed => {
                if let Some(index) = current
                    .iter()
                    .position(|todo| todo.content == change.todo.content)
                {
                    current.remove(index);
                }
            }
        }
    }
}

fn next_ephemeral_todo_id(current: &[SessionTodoDto], content: &str) -> String {
    ephemeral_todo_id(
        content,
        current
            .iter()
            .filter(|todo| todo.content == content)
            .count(),
    )
}

fn ephemeral_todo_id(content: &str, occurrence: usize) -> String {
    format!("ephemeral:{content}:{occurrence}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_todo_result_replaces_full_list_from_todo_read() {
        let mut current = Vec::new();

        let changed = apply_todo_result(
            &mut current,
            r#"<todos count="2"><todo status="pending">Read the code</todo><todo status="in_progress">Implement the dock</todo></todos>"#,
        );

        assert!(changed);
        assert_eq!(current.len(), 2);
        assert_eq!(current[0].content, "Read the code");
        assert_eq!(current[0].status, SessionTodoStatusDto::Pending);
        assert_eq!(current[1].status, SessionTodoStatusDto::InProgress);
    }

    #[test]
    fn apply_todo_result_updates_existing_items_from_todo_write() {
        let mut current = vec![SessionTodoDto {
            id: "todo-1".to_string(),
            content: "Implement the dock".to_string(),
            status: SessionTodoStatusDto::InProgress,
        }];

        let changed = apply_todo_result(
            &mut current,
            r#"<todos_updated changes="2"><todo status="completed" change="updated">Implement the dock</todo><todo status="pending" change="added">Run lint</todo></todos_updated>"#,
        );

        assert!(changed);
        assert_eq!(current.len(), 2);
        assert_eq!(current[0].id, "todo-1");
        assert_eq!(current[0].status, SessionTodoStatusDto::Completed);
        assert_eq!(current[1].content, "Run lint");
        assert_eq!(current[1].status, SessionTodoStatusDto::Pending);
    }

    #[test]
    fn apply_todo_result_preserves_matching_ids_on_todo_read() {
        let mut current = vec![SessionTodoDto {
            id: "todo-1".to_string(),
            content: "Implement the dock".to_string(),
            status: SessionTodoStatusDto::Pending,
        }];

        let changed = apply_todo_result(
            &mut current,
            r#"<todos count="1"><todo status="completed">Implement the dock</todo></todos>"#,
        );

        assert!(changed);
        assert_eq!(current[0].id, "todo-1");
        assert_eq!(current[0].status, SessionTodoStatusDto::Completed);
    }

    #[test]
    fn apply_todo_result_only_removes_one_matching_duplicate() {
        let mut current = vec![
            SessionTodoDto {
                id: "todo-1".to_string(),
                content: "Run lint".to_string(),
                status: SessionTodoStatusDto::Pending,
            },
            SessionTodoDto {
                id: "todo-2".to_string(),
                content: "Run lint".to_string(),
                status: SessionTodoStatusDto::Completed,
            },
        ];

        let changed = apply_todo_result(
            &mut current,
            r#"<todos_updated changes="1"><todo status="pending" change="removed">Run lint</todo></todos_updated>"#,
        );

        assert!(changed);
        assert_eq!(current.len(), 1);
        assert_eq!(current[0].id, "todo-2");
    }

    #[test]
    fn apply_todo_result_keeps_duplicate_additions_distinct() {
        let mut current = vec![SessionTodoDto {
            id: "todo-1".to_string(),
            content: "Run lint".to_string(),
            status: SessionTodoStatusDto::Pending,
        }];

        let changed = apply_todo_result(
            &mut current,
            r#"<todos_updated changes="1"><todo status="pending" change="added">Run lint</todo></todos_updated>"#,
        );

        assert!(changed);
        assert_eq!(current.len(), 2);
        assert_eq!(current[0].id, "todo-1");
        assert_eq!(current[1].id, "ephemeral:Run lint:1");
    }
}
