import type { TaskWorkspaceSummary } from "@/services/desktop/types/contracts";

import { Button } from "../ui/Button";

export function formatCheckoutBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return "size unavailable";
  }
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const shown = value >= 10 || unit === 0 ? value.toFixed(0) : value.toFixed(1);
  return `${shown} ${units[unit]}`;
}

export function TaskWorkspaceCard({
  name,
  task,
  busy,
  onOpen,
  onMerge,
  onArchive,
  onRun,
}: {
  name: string;
  task: TaskWorkspaceSummary;
  busy: boolean;
  onOpen: () => void;
  onMerge: () => void;
  onArchive: () => void;
  onRun: () => void;
}) {
  return (
    <article className="grid gap-2 rounded-lg border border-sidebar-border bg-sidebar-accent/40 p-2">
      <div className="min-w-0">
        <p className="truncate text-sm font-medium">{name}</p>
        <p className="truncate font-mono text-[11px] text-sidebar-foreground/70">
          {task.branch}
          <span className="text-sidebar-foreground/45"> · from {task.baseBranch}</span>
        </p>
        <p className="text-[11px] text-sidebar-foreground/60">
          {formatCheckoutBytes(task.checkoutBytes)}
          {task.mergedBack ? " · landed" : ""}
        </p>
      </div>
      {task.keepReason ? (
        <p className="text-[11px] text-amber-700 dark:text-amber-300">
          Kept — {task.keepReason}
        </p>
      ) : null}
      {task.setupError ? (
        <p className="line-clamp-3 text-[11px] text-destructive">
          Setup failed: {task.setupError}
        </p>
      ) : null}
      <div className="flex flex-wrap gap-1">
        <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onOpen}>
          Open
        </Button>
        <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onMerge}>
          Merge
        </Button>
        <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onArchive}>
          Archive
        </Button>
        {task.runScript ? (
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onRun}>
            Run
          </Button>
        ) : null}
      </div>
    </article>
  );
}
