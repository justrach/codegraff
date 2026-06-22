import { useEffect, useState } from "react";

import type { FileOperation } from "@/services/desktop/types/contracts";

import {
  resolveRenderableFileDiff,
  resolveSyncFileDiff,
  type ResolvedFileDiff,
} from "../utils/renderableFileDiff";

export interface UseRenderableFileDiffInput {
  workspacePath: string | null;
  path: string;
  patch: string;
  operation?: FileOperation | null;
}

export type RenderableFileDiffState = ResolvedFileDiff | { status: "loading" };

/**
 * Resolves a single file change to a renderable diff for the transcript card.
 * Edits render immediately (no flash, no disk read); create/overwrite read the
 * file from disk and synthesize an all-additions diff; removals fall back to a
 * placeholder.
 */
export function useRenderableFileDiff({
  workspacePath,
  path,
  patch,
  operation,
}: UseRenderableFileDiffInput): RenderableFileDiffState {
  const syncDiff = resolveSyncFileDiff(path, patch);
  const hasSyncDiff = syncDiff != null;

  const [asyncState, setAsyncState] = useState<RenderableFileDiffState>({
    status: "loading",
  });

  useEffect(() => {
    if (hasSyncDiff) {
      return;
    }

    let cancelled = false;
    void resolveRenderableFileDiff({ workspacePath, path, patch, operation }).then(
      (resolved) => {
        if (!cancelled) {
          setAsyncState(resolved);
        }
      },
    );

    return () => {
      cancelled = true;
    };
  }, [workspacePath, path, patch, operation, hasSyncDiff]);

  return syncDiff ?? asyncState;
}
