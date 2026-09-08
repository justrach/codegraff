"use client";
import { createContext, useContext, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { createComposerDraft, type ComposerDraftStore } from "@/lib/composer-draft";

export const ComposerDraftContext = createContext<ComposerDraftStore | null>(null);

export function useComposerDraft() {
  const shared = useContext(ComposerDraftContext);
  const [local] = useState(createComposerDraft);
  const store = shared ?? local;
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      // Development effect replay must not dispose a still-mounted draft.
      queueMicrotask(() => { if (!mounted.current) local.dispose(); });
    };
  }, [local]);
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  return { ...snapshot, setDraft: store.setDraft, setAttachments: store.setAttachments,
    setUploads: store.setUploads, setAttachError: store.setAttachError };
}
