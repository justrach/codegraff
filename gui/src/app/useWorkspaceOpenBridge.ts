import { useEffect } from "react";

import * as desktopClient from "../services/desktop/client";
import { LATEST_WORKSPACE_STORAGE_KEY } from "./sessionSnapshot";

export function useWorkspaceOpenBridge(
  activeWorkspacePath: string | null,
  openWorkspaceByPath: (workspacePath: string) => Promise<void>,
) {
  useEffect(() => {
    if (activeWorkspacePath == null) {
      return;
    }

    window.localStorage.setItem(
      LATEST_WORKSPACE_STORAGE_KEY,
      activeWorkspacePath,
    );
  }, [activeWorkspacePath]);

  // `codegraff <path>` (code-style): open the path the launcher handed us —
  // either stashed before launch (cold start) or forwarded to this running
  // instance (single-instance). No-op in the browser/QA mock.
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void (async () => {
      try {
        const pending = await desktopClient.drainPendingOpen();
        if (!cancelled && pending) {
          void openWorkspaceByPath(pending);
        }
      } catch {
        // No pending path (or not running under Tauri) — ignore.
      }
      try {
        unlisten = await desktopClient.onOpenWorkspacePath((path) => {
          void openWorkspaceByPath(path);
        });
      } catch {
        // Event bridge unavailable (browser mode) — ignore.
      }
    })();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [openWorkspaceByPath]);
}
