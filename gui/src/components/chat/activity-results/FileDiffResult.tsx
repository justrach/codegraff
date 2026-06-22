import { useCallback } from "react";

import { PatchDiff } from "@codegraff/diffs/react";

import { openWorkspacePathInTarget } from "@/app/sessionClientActions";
import {
  EDITOR_APP_TARGET_IDS,
  appTargets,
} from "@/components/conversation-panel/constants/conversationHeader";
import { usePreferredOpenTarget } from "@/components/conversation-panel/hooks/usePreferredOpenTarget";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import { useWorkspaceMeta } from "@/hooks/useSession";
import { ActivityResultCard } from "./ActivityResultCard";
import type { FileDiffResultProps } from "../types/chatComponents";
import { useRenderableFileDiff } from "./hooks/useRenderableFileDiff";
import {
  getFileDiffDisplayName,
  getFileDiffDisplayPath,
} from "./utils/fileDiff";
import {
  formatFileChangeLabel,
  type FileChangePlaceholder,
} from "./utils/fileChangeLabel";

function FileDiffLoadingBody() {
  return (
    <div className="flex min-h-24 items-center justify-center gap-2 px-3 py-6 text-xs/relaxed text-muted-foreground">
      <LoadingSpinner className="size-4" />
      <span>Loading diff…</span>
    </div>
  );
}

function FileDiffPlaceholderBody({
  placeholder,
}: {
  placeholder: FileChangePlaceholder;
}) {
  const { title, detail } = formatFileChangeLabel(
    placeholder.operation,
    placeholder.byteCount,
  );
  return (
    <div className="flex items-center gap-1.5 px-3 py-2.5 text-xs text-muted-foreground">
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

export function FileDiffResult({ result, workspacePath }: FileDiffResultProps) {
  const workspaceMeta = useWorkspaceMeta(workspacePath);
  const rendered = useRenderableFileDiff({
    workspacePath,
    path: result.path,
    patch: result.patch,
    operation: result.operation,
  });
  const displayName = getFileDiffDisplayName(result.path);
  const displayPath = getFileDiffDisplayPath(result.path, workspacePath);
  const availableOpenTargets =
    workspaceMeta.runtimeStatus?.availableOpenTargets ?? [];
  const availableEditorTargets = appTargets.filter(
    (target) =>
      EDITOR_APP_TARGET_IDS.includes(target.id) &&
      availableOpenTargets.includes(target.id),
  );
  const { resolvedPreferredAppId } =
    usePreferredOpenTarget(availableEditorTargets);
  const canOpenInEditor =
    workspacePath != null && availableEditorTargets.length > 0;
  const handleOpenInEditor = useCallback(() => {
    if (workspacePath == null || availableEditorTargets.length === 0) {
      return;
    }

    void openWorkspacePathInTarget(
      workspacePath,
      resolvedPreferredAppId,
      result.path,
    );
  }, [availableEditorTargets.length, resolvedPreferredAppId, result.path, workspacePath]);

  const stats = rendered.status === "diff"
    ? { additions: rendered.additions, deletions: rendered.deletions }
    : null;

  const footer = {
    leading: (
      <code className="font-mono text-xs text-muted-foreground">
        {displayPath}
      </code>
    ),
    trailing:
      stats == null ? null : (
        <span className="inline-flex items-center gap-2 font-mono text-xs tabular-nums">
          <span className="text-success">+{stats.additions}</span>
          <span className="text-destructive">-{stats.deletions}</span>
        </span>
      ),
  };

  return (
    <ActivityResultCard
      title={
        canOpenInEditor ? (
          <button
            type="button"
            onClick={handleOpenInEditor}
            className="max-w-full cursor-pointer truncate font-mono text-xs text-foreground underline decoration-transparent underline-offset-2 transition hover:text-[color:var(--accent-dim)] hover:decoration-current dark:hover:text-[color:var(--accent)]"
          >
            {displayName}
          </button>
        ) : (
          <code className="font-mono text-xs text-foreground">
            {displayName}
          </code>
        )
      }
      copyText={result.copyText}
      footer={footer}
    >
      {rendered.status === "diff" ? (
        <div className="px-1 py-1.5">
          <PatchDiff
            patch={rendered.patch}
            className="block max-w-full overflow-hidden text-xs/relaxed"
            options={{ lineDiffType: "word", showFileHeader: false }}
          />
        </div>
      ) : rendered.status === "loading" ? (
        <FileDiffLoadingBody />
      ) : (
        <FileDiffPlaceholderBody placeholder={rendered} />
      )}
    </ActivityResultCard>
  );
}
