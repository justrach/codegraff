"use client";

import TaskRows, { type TaskItem } from "@/components/primitives/TaskRows";

export function taskItems(todos: { id: string; content: string; status: string }[]): TaskItem[] {
  return todos.map(todo => ({ key: todo.id, label: todo.content,
    status: todo.status === "in_progress" ? "in_progress" : todo.status === "completed" ? "completed" : "pending" }));
}

/** Dismiss presentation only; the agent's checklist remains intact. */
export default function TasksPane({ items, onClose }: { items: TaskItem[]; onClose(): void }) {
  return (
    <aside aria-label="Tasks" className="hidden w-[360px] shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page lg:flex"
      style={{ animation: "fade-in 300ms ease both" }}>
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-line px-4">
        <span className="text-[13px] font-semibold text-ink">Tasks</span>
        <button type="button" onClick={onClose} aria-label="Hide tasks" title="Hide tasks"
          className="flex h-7 w-7 items-center justify-center rounded-md text-ink-2 hover:bg-hover">×</button>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        <TaskRows variant="List" items={items} />
      </div>
    </aside>
  );
}
