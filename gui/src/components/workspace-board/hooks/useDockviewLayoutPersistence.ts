import { useEffect, useRef } from "react";
import type { DockviewApi } from "dockview-react";

import { serializeDockviewLayout } from "../layout";
import type { UseDockviewLayoutPersistenceOptions } from "../types/workspaceBoard";

type PersistLayout = (layoutJson: string) => Promise<void> | void;

type PendingLayoutSave = {
  key: string;
  layoutJson: string;
  persist: PersistLayout;
};

const DEFAULT_PERSIST_KEY = "__default__";

export function useDockviewLayoutPersistence({
  delayMs = 500,
  onPersist,
}: UseDockviewLayoutPersistenceOptions) {
  const persistTimeoutRef = useRef<number | null>(null);
  const pendingSaveRef = useRef<PendingLayoutSave | null>(null);
  const queuedSavesByKeyRef = useRef<Record<string, PendingLayoutSave>>({});
  const persistInFlightRef = useRef(false);
  const lastPersistedLayoutJsonByKeyRef = useRef<Record<string, string | null>>({});
  const isApplyingLayoutRef = useRef(false);

  function lastPersistedLayoutJson(key: string) {
    return lastPersistedLayoutJsonByKeyRef.current[key] ?? null;
  }

  function markKeyPersisted(key: string, layoutJson: string | null) {
    lastPersistedLayoutJsonByKeyRef.current = {
      ...lastPersistedLayoutJsonByKeyRef.current,
      [key]: layoutJson,
    };
  }

  function shiftQueuedSave(): PendingLayoutSave | null {
    const [key, save] = Object.entries(queuedSavesByKeyRef.current)[0] ?? [];
    if (key == null || save == null) {
      return null;
    }
    const next = { ...queuedSavesByKeyRef.current };
    delete next[key];
    queuedSavesByKeyRef.current = next;
    return save;
  }

  function queuedSaveCount() {
    return Object.keys(queuedSavesByKeyRef.current).length;
  }

  function drainPersistQueue() {
    if (persistInFlightRef.current) {
      return;
    }

    persistInFlightRef.current = true;
    void (async () => {
      try {
        while (queuedSaveCount() > 0) {
          const save = shiftQueuedSave();
          if (save == null) {
            continue;
          }
          if (lastPersistedLayoutJson(save.key) === save.layoutJson) {
            continue;
          }
          await save.persist(save.layoutJson);
          markKeyPersisted(save.key, save.layoutJson);
        }
      } finally {
        persistInFlightRef.current = false;
        if (queuedSaveCount() > 0) {
          drainPersistQueue();
        }
      }
    })();
  }

  function enqueuePersist(save: PendingLayoutSave) {
    if (lastPersistedLayoutJson(save.key) === save.layoutJson) {
      return;
    }
    queuedSavesByKeyRef.current = {
      ...queuedSavesByKeyRef.current,
      [save.key]: save,
    };
    drainPersistQueue();
  }

  function cancelPendingPersist() {
    if (persistTimeoutRef.current != null) {
      window.clearTimeout(persistTimeoutRef.current);
      persistTimeoutRef.current = null;
    }
    pendingSaveRef.current = null;
  }

  function flushPendingPersist() {
    const save = pendingSaveRef.current;
    cancelPendingPersist();
    if (save != null) {
      enqueuePersist(save);
    }
  }

  useEffect(() => flushPendingPersist, [delayMs, onPersist]);

  function markPersistedLayout(layoutJson: string | null, key = DEFAULT_PERSIST_KEY) {
    markKeyPersisted(key, layoutJson);
    if (pendingSaveRef.current?.key === key && pendingSaveRef.current.layoutJson === layoutJson) {
      cancelPendingPersist();
    }
    if (queuedSavesByKeyRef.current[key]?.layoutJson === layoutJson) {
      const next = { ...queuedSavesByKeyRef.current };
      delete next[key];
      queuedSavesByKeyRef.current = next;
    }
  }

  function schedulePersist(
    getApi: () => DockviewApi | null | undefined,
    persist: PersistLayout = onPersist,
    key = DEFAULT_PERSIST_KEY,
  ) {
    if (isApplyingLayoutRef.current) {
      return;
    }

    const api = getApi();
    if (api == null) {
      return;
    }

    const layoutJson = serializeDockviewLayout(api.toJSON());
    if (lastPersistedLayoutJson(key) === layoutJson) {
      cancelPendingPersist();
      return;
    }

    cancelPendingPersist();
    pendingSaveRef.current = { key, layoutJson, persist };
    persistTimeoutRef.current = window.setTimeout(() => {
      persistTimeoutRef.current = null;
      const pendingSave = pendingSaveRef.current;
      pendingSaveRef.current = null;
      if (pendingSave != null) {
        enqueuePersist(pendingSave);
      }
    }, delayMs);
  }

  return {
    cancelPendingPersist,
    flushPendingPersist,
    isApplyingLayoutRef,
    markPersistedLayout,
    schedulePersist,
  };
}
