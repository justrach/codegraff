import { useMemo } from "react";
import type { IDockviewPanelProps } from "dockview-react";

import { FilesChanged, type FilesChangedItem } from "@codegraff/diffs/react";

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
import { PaneSurface } from "@/components/ui/PaneSurface";
import { useConversationView, useWorkspaceMeta } from "@/hooks/useSession";

import type { PlaceholderPaneParams } from "./types/layout";
import { deriveSessionFileChanges } from "./utils/sessionFileChanges";

function operationBadge(change: {
  operation: string | null;
  editCount: number;
}): string | undefined {
  if (change.operation === "create") {
    return "added";
  }
  if (change.operation === "remove") {
    return "removed";
  }
  if (change.editCount > 1) {
    return `${change.editCount} edits`;
  }
  return undefined;
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

  const totals = useMemo(
    () =>
      changes.reduce(
        (acc, change) => ({
          additions: acc.additions + change.additions,
          deletions: acc.deletions + change.deletions,
        }),
        { additions: 0, deletions: 0 },
      ),
    [changes],
  );

  const items: FilesChangedItem[] = changes.map((change) => ({
    key: change.path,
    path: getFileDiffDisplayPath(change.path, params.workspacePath),
    patch: change.patch,
    additions: change.additions,
    deletions: change.deletions,
    badge: operationBadge(change),
    headerExtra: canOpenInEditor ? (
      <button
        type="button"
        className="cursor-pointer font-mono text-xs text-muted-foreground underline decoration-transparent underline-offset-2 transition hover:text-foreground hover:decoration-current"
        onClick={() => {
          void openWorkspacePathInTarget(
            params.workspacePath,
            resolvedPreferredAppId,
            change.path,
          );
        }}
      >
        {getFileDiffDisplayName(change.path)}
      </button>
    ) : undefined,
  }));

  return (
    <PaneSurface className="overflow-auto p-3">
      <div className="mb-3 flex items-center gap-3 text-xs">
        <span className="font-medium text-foreground">
          {changes.length === 0
            ? "No files changed"
            : `${changes.length} file${changes.length === 1 ? "" : "s"} changed`}
        </span>
        {changes.length > 0 ? (
          <span className="inline-flex items-center gap-2 font-mono">
            <span className="text-success">+{totals.additions}</span>
            <span className="text-destructive">-{totals.deletions}</span>
          </span>
        ) : null}
      </div>
      <FilesChanged
        files={items}
        emptyState={
          <div className="px-1 py-6 text-center text-xs text-muted-foreground">
            File edits made during this conversation will appear here.
          </div>
        }
      />
    </PaneSurface>
  );
}
