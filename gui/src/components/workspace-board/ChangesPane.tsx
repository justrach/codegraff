import { useEffect, useMemo, useState } from "react";
import type { IDockviewPanelProps } from "dockview-react";
import { ChevronRight, FileText } from "lucide-react";

import { PatchDiff } from "@codegraff/diffs/react";

import { openWorkspacePathInTarget } from "@/app/sessionClientActions";
import {
  EDITOR_APP_TARGET_IDS,
  appTargets,
} from "@/components/conversation-panel/constants/conversationHeader";
import { usePreferredOpenTarget } from "@/components/conversation-panel/hooks/usePreferredOpenTarget";
import {
  getFileDiffDisplayName,
  getFileDiffDisplayPath,
} from "@/components/chat/activity-results/utils/fileDiff";
import {
  fileChangeBadge,
  formatFileChangeLabel,
} from "@/components/chat/activity-results/utils/fileChangeLabel";
import {
  resolveRenderableFileDiff,
  type ResolvedFileDiff,
} from "@/components/chat/activity-results/utils/renderableFileDiff";
import { cn } from "@/utils/cn";
import { PaneSurface } from "@/components/ui/PaneSurface";
import { useConversationView, useWorkspaceMeta } from "@/hooks/useSession";

import type { PlaceholderPaneParams } from "./types/layout";
import {
  deriveSessionFileChanges,
  type SessionFileChange,
} from "./utils/sessionFileChanges";

function PlaceholderBody({
  operation,
  byteCount,
}: {
  operation: SessionFileChange["operation"];
  byteCount: number | null;
}) {
  const { title, detail } = formatFileChangeLabel(operation, byteCount);
  return (
    <div className="flex items-center gap-1.5 px-2 py-1.5 text-xs text-muted-foreground">
      <span className="font-medium text-foreground/80">{title}</span>
      {detail != null ? (
        <>
          <span className="text-muted-foreground/40">·</span>
          <span className="font-mono text-[11px]">{detail}</span>
        </>
      ) : null}
    </div>
  );
}

interface ChangeRowProps {
  change: SessionFileChange;
  resolved: ResolvedFileDiff | null;
  workspacePath: string;
  canOpenInEditor: boolean;
  onOpenInEditor: (path: string) => void;
}

function ChangeRow({
  change,
  resolved,
  workspacePath,
  canOpenInEditor,
  onOpenInEditor,
}: ChangeRowProps) {
  const [open, setOpen] = useState(false);
  const displayName = getFileDiffDisplayName(change.path);
  const displayPath = getFileDiffDisplayPath(change.path, workspacePath);
  const badge = fileChangeBadge(change.operation, change.editCount);
  const stats = resolved?.status === "diff" ? resolved : null;

  return (
    <div className="overflow-hidden rounded-xl border border-border bg-card shadow-[var(--elevation-xs)] ring-1 ring-foreground/[0.04] transition-shadow hover:shadow-[var(--elevation-sm)]">
      <div className="flex items-center gap-2 pr-2">
        <button
          type="button"
          aria-expanded={open}
          onClick={() => setOpen((value) => !value)}
          className="flex min-w-0 flex-1 items-center gap-2 px-3 py-2.5 text-left"
        >
          <ChevronRight
            strokeWidth={2}
            className={cn(
              "size-3.5 shrink-0 text-muted-foreground transition-transform",
              open && "rotate-90",
            )}
          />
          <span className="truncate font-mono text-xs font-medium text-foreground">
            {displayName}
          </span>
          {badge != null ? (
            <span className="shrink-0 rounded-full border border-border px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground">
              {badge}
            </span>
          ) : null}
          <span className="ml-auto shrink-0 font-mono text-xs tabular-nums">
            {stats != null ? (
              <span className="inline-flex items-center gap-2">
                <span className="text-success">+{stats.additions}</span>
                <span className="text-destructive">-{stats.deletions}</span>
              </span>
            ) : (
              <span className="text-muted-foreground/60">·</span>
            )}
          </span>
        </button>
        {canOpenInEditor ? (
          <button
            type="button"
            title="Open in editor"
            onClick={() => onOpenInEditor(change.path)}
            className="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          >
            <FileText className="size-3.5" />
          </button>
        ) : null}
      </div>
      {open ? (
        <div className="border-t border-border px-2 py-2">
          {resolved == null ? (
            <div className="px-2 py-3 text-xs text-muted-foreground">Loading diff…</div>
          ) : resolved.status === "diff" ? (
            <PatchDiff
              patch={resolved.patch}
              className="block max-w-full overflow-hidden text-xs/relaxed"
              options={{ lineDiffType: "word", showFileHeader: false }}
            />
          ) : (
            <PlaceholderBody operation={resolved.operation} byteCount={resolved.byteCount} />
          )}
          <div className="px-2 pt-2">
            <code className="font-mono text-[11px] text-muted-foreground">{displayPath}</code>
          </div>
        </div>
      ) : null}
    </div>
  );
}

export function ChangesPane({
  params,
}: IDockviewPanelProps<PlaceholderPaneParams>) {
  const binding = useMemo(
    () => ({
      workspacePath: params.workspacePath,
      conversationId: params.conversationId,
    }),
    [params.workspacePath, params.conversationId],
  );
  const view = useConversationView(binding);
  const workspaceMeta = useWorkspaceMeta(params.workspacePath);

  const availableOpenTargets =
    workspaceMeta.runtimeStatus?.availableOpenTargets ?? [];
  const availableEditorTargets = appTargets.filter(
    (target) =>
      EDITOR_APP_TARGET_IDS.includes(target.id) &&
      availableOpenTargets.includes(target.id),
  );
  const { resolvedPreferredAppId } =
    usePreferredOpenTarget(availableEditorTargets);
  const canOpenInEditor = availableEditorTargets.length > 0;

  const changes = useMemo(
    () => deriveSessionFileChanges(view?.messages ?? []),
    [view?.messages],
  );

  // Resolve each change to a renderable diff (reads file contents from disk for
  // create/overwrite, which the harness reports only as a byte summary).
  const [resolvedByPath, setResolvedByPath] = useState<
    Record<string, ResolvedFileDiff>
  >({});
  useEffect(() => {
    let cancelled = false;
    void Promise.all(
      changes.map(async (change) => {
        const result = await resolveRenderableFileDiff({
          workspacePath: params.workspacePath,
          path: change.path,
          patch: change.patch,
          operation: change.operation,
        });
        return [change.path, result] as const;
      }),
    ).then((entries) => {
      if (!cancelled) {
        setResolvedByPath(Object.fromEntries(entries));
      }
    });
    return () => {
      cancelled = true;
    };
  }, [changes, params.workspacePath]);

  const totals = useMemo(() => {
    let additions = 0;
    let deletions = 0;
    for (const change of changes) {
      const resolved = resolvedByPath[change.path];
      if (resolved?.status === "diff") {
        additions += resolved.additions;
        deletions += resolved.deletions;
      }
    }
    return { additions, deletions };
  }, [changes, resolvedByPath]);

  const handleOpenInEditor = (path: string) => {
    void openWorkspacePathInTarget(params.workspacePath, resolvedPreferredAppId, path);
  };

  return (
    <PaneSurface className="overflow-auto">
      <div className="sticky top-0 z-10 flex items-center gap-3 border-b border-border bg-background/70 px-4 py-3 text-xs backdrop-blur-md">
        <span className="font-medium text-foreground">
          {changes.length === 0
            ? "No files changed"
            : `${changes.length} file${changes.length === 1 ? "" : "s"} changed`}
        </span>
        {changes.length > 0 ? (
          <span className="inline-flex items-center gap-2 font-mono tabular-nums">
            <span className="text-success">+{totals.additions}</span>
            <span className="text-destructive">-{totals.deletions}</span>
          </span>
        ) : null}
      </div>

      {changes.length === 0 ? (
        <div className="px-4 py-10 text-center text-xs text-muted-foreground">
          File edits made during this conversation will appear here.
        </div>
      ) : (
        <div className="flex flex-col gap-2 p-3">
          {changes.map((change) => (
            <ChangeRow
              key={change.path}
              change={change}
              resolved={resolvedByPath[change.path] ?? null}
              workspacePath={params.workspacePath}
              canOpenInEditor={canOpenInEditor}
              onOpenInEditor={handleOpenInEditor}
            />
          ))}
        </div>
      )}
    </PaneSurface>
  );
}
