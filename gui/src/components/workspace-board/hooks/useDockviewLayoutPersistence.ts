import { useEffect, useRef } from "react";
import type { DockviewApi } from "dockview-react";

import { serializeDockviewLayout } from "../layout";
import type { UseDockviewLayoutPersistenceOptions } from "../types/workspaceBoard";

export function useDockviewLayoutPersistence({
  delayMs = 500,
  onPersist,
}: UseDockviewLayoutPersistenceOptions) {
  const persistTimeoutRef = useRef<number | null>(null);
  const lastPersistedLayoutJsonRef = useRef<string | null>(null);
  const isApplyingLayoutRef = useRef(false);

  function cancelPendingPersist() {
    if (persistTimeoutRef.current != null) {
      window.clearTimeout(persistTimeoutRef.current);
      persistTimeoutRef.current = null;
    }
  }

  useEffect(() => cancelPendingPersist, [delayMs, onPersist]);

  function markPersistedLayout(layoutJson: string | null) {
    lastPersistedLayoutJsonRef.current = layoutJson;
  }

  function schedulePersist(getApi: () => DockviewApi | null | undefined) {
    if (isApplyingLayoutRef.current) {
      return;
    }

    cancelPendingPersist();
    persistTimeoutRef.current = window.setTimeout(async () => {
      const api = getApi();
      if (api == null) {
        return;
      }

      const layoutJson = serializeDockviewLayout(api.toJSON());
      if (lastPersistedLayoutJsonRef.current === layoutJson) {
        return;
      }

      await onPersist(layoutJson);
      lastPersistedLayoutJsonRef.current = layoutJson;
    }, delayMs);
  }

  return {
    cancelPendingPersist,
    isApplyingLayoutRef,
    markPersistedLayout,
    schedulePersist,
  };
}
