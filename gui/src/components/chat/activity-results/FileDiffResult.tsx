import { Suspense, lazy, useCallback } from "react";

import { openWorkspacePathInTarget } from "@/app/sessionClientActions";
import {
  EDITOR_APP_TARGET_IDS,
  appTargets,
} from "@/components/conversation-panel/constants/conversationHeader";
import { usePreferredOpenTarget } from "@/components/conversation-panel/hooks/usePreferredOpenTarget";
import { useWorkspaceMeta } from "@/hooks/useSession";
import { LoadingSpinner } from "@/components/ui/LoadingSpinner";
import {
  ActivityResultCard,
  ActivityResultPreformattedBody,
} from "./ActivityResultCard";
import type { FileDiffResultProps } from "../types/chatComponents";
import {
  getFileDiffDisplayName,
  getFileDiffDisplayPath,
  getFileDiffPatchStats,
} from "./utils/fileDiff";

const LazyPatchDiff = lazy(async () => {
  const module = await import("@pierre/diffs/react");
  return { default: module.PatchDiff };
});

function FileDiffLoadingBody() {
  return (
    <div className="flex min-h-32 items-center justify-center gap-2 px-3 py-6 text-xs/relaxed text-muted-foreground">
      <LoadingSpinner className="size-4" />
      <span>Loading diff...</span>
    </div>
  );
}

export function FileDiffResult({ result, workspacePath }: FileDiffResultProps) {
  const workspaceMeta = useWorkspaceMeta(workspacePath);
  const isGitPatch = result.patch.startsWith("diff --git ");
  const patchStats = getFileDiffPatchStats(result.patch);
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

  const footer = {
    leading: (
      <code className="font-mono text-xs text-muted-foreground">
        {displayPath}
      </code>
    ),
    trailing:
      patchStats == null ? null : (
        <span className="inline-flex items-center gap-2 font-mono text-xs">
          <span className="text-success">
            +{patchStats.additions}
          </span>
          <span className="text-destructive">
            -{patchStats.deletions}
          </span>
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
      {isGitPatch ? (
        <Suspense fallback={<FileDiffLoadingBody />}>
          <LazyPatchDiff
            patch={result.patch}
            disableWorkerPool
            className="block max-w-full overflow-hidden text-xs/relaxed"
            options={{
              diffIndicators: "bars",
              diffStyle: "unified",
              lineDiffType: "word-alt",
              overflow: "scroll",
              disableFileHeader: true,
              themeType: "system",
            }}
          />
        </Suspense>
      ) : (
        <ActivityResultPreformattedBody text={result.patch} />
      )}
    </ActivityResultCard>
  );
}
