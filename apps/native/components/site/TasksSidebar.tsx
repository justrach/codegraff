"use client";

import TaskRows from "@/components/primitives/TaskRows";

export type TaskItem = { id: string; content: string; status: string };

export default function TasksSidebar({ items, onClose }: { items: TaskItem[]; onClose: () => void }) {
  if (items.length === 0) return null;
  return (
    <aside
      data-tasks-sidebar
      className="hidden w-[360px] shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page lg:flex"
      style={{ animation: "fade-in 300ms ease both" }}
    >
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-line px-4">
        <span className="text-[13px] font-semibold text-ink">Tasks</span>
        <button
          type="button"
          aria-label="Close tasks"
          onClick={onClose}
          className="flex size-7 items-center justify-center rounded-[6px] text-ink-3 hover:bg-hover hover:text-ink"
        >
          ×
        </button>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        <TaskRows
          variant="List"
          items={items.map((todo) => ({
            key: todo.id,
            label: todo.content,
            status: todo.status === "in_progress" ? "in_progress" : todo.status === "completed" ? "completed" : "pending",
          }))}
        />
      </div>
    </aside>
  );
}
