import type { SessionTodo } from "@/services/desktop/types/contracts";

import { cn } from "@/utils/cn";

export function buildTodoSummary(todos: SessionTodo[]): string {
  let completedCount = 0;
  let activeCount = 0;

  for (const todo of todos) {
    if (todo.status === "completed") {
      completedCount += 1;
      continue;
    }

    if (isActiveTodo(todo)) {
      activeCount += 1;
    }
  }

  if (activeCount === 0) {
    return `${completedCount}/${todos.length} completed`;
  }

  return `${completedCount}/${todos.length} completed · ${activeCount} active`;
}

export function isActiveTodo(todo: SessionTodo) {
  return todo.status === "pending" || todo.status === "in_progress";
}

export function todoTextClassName(status: SessionTodo["status"]) {
  return cn(
    "min-w-0 flex-1",
    status === "in_progress" && "font-medium text-foreground",
    (status === "completed" || status === "cancelled") &&
      "text-muted-foreground line-through",
    status === "pending" && "text-muted-foreground",
  );
}
