import { releaseAttachments, type Attachment } from "./attachments";

type Update<T> = T | ((current: T) => T);
export type ComposerDraft = { draft: string; attachments: Attachment[]; uploads: number; attachError: string | null };

/** A chat owns its unsent text and uploads even while its pane is hidden. */
export function createComposerDraft(release = releaseAttachments) {
  let snapshot: ComposerDraft = { draft: "", attachments: [], uploads: 0, attachError: null };
  const listeners = new Set<() => void>();
  let disposed = false;
  function update<K extends keyof ComposerDraft>(field: K, value: Update<ComposerDraft[K]>) {
    const next = typeof value === "function" ? value(snapshot[field]) : value;
    if (disposed) {
      // An upload can finish after its chat closes. Never retain its preview.
      if (field === "attachments") release(next as Attachment[]);
      return;
    }
    if (Object.is(next, snapshot[field])) return;
    snapshot = { ...snapshot, [field]: next };
    listeners.forEach(listener => listener());
  }
  return {
    getSnapshot: () => snapshot,
    subscribe: (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; },
    setDraft: (value: Update<string>) => update("draft", value),
    setAttachments: (value: Update<Attachment[]>) => update("attachments", value),
    setUploads: (value: Update<number>) => update("uploads", value),
    setAttachError: (value: Update<string | null>) => update("attachError", value),
    dispose: () => {
      if (disposed) return;
      disposed = true;
      release(snapshot.attachments);
      snapshot = { draft: "", attachments: [], uploads: 0, attachError: null };
      listeners.clear();
    },
  };
}
export type ComposerDraftStore = ReturnType<typeof createComposerDraft>;
